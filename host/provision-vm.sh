#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
DISK_GB=75
BASE_IMAGE=""
BASE_IMAGE_SET=false
HEADLESS=false
GUEST_OS="macos"
VM_NAME=""

# --- Usage ---
usage() {
    echo "Usage: $0 <vm-name> [--linux] [--disk <GB>] [--base <image>] [--headless]"
    echo ""
    echo "  <vm-name>        Required. Name for the new Tart VM."
    echo "  --linux          Create a Linux VM (default: Debian Bookworm)."
    echo "  --disk <GB>      Disk size in GB (default: 75)."
    echo "  --base <image>   Source Tart image to clone."
    echo "  --headless       Run VM without a UI window."
    exit 1
}

# --- Parse args ---
[[ $# -eq 0 ]] && usage

VM_NAME="${1}"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)
            [[ -z "${2:-}" ]] && { echo "Error: --disk requires a value"; usage; }
            DISK_GB="$2"
            shift 2
            ;;
        --linux)
            GUEST_OS="linux"
            shift
            ;;
        --base)
            [[ -z "${2:-}" ]] && { echo "Error: --base requires a value"; usage; }
            BASE_IMAGE="$2"
            BASE_IMAGE_SET=true
            shift 2
            ;;
        --headless)
            HEADLESS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

[[ -z "$VM_NAME" ]] && { echo "Error: <vm-name> is required"; usage; }

# Set default base image based on guest OS (if not explicitly provided)
if [[ "$BASE_IMAGE_SET" == false ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        BASE_IMAGE="ghcr.io/cirruslabs/debian:trixie"
    else
        BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
    fi
fi

# sshpass is required for Linux provisioning (no guest agent support yet)
if [[ "$GUEST_OS" == "linux" ]]; then
    if ! command -v sshpass &>/dev/null; then
        echo "Error: 'sshpass' is required for Linux VM provisioning (no guest agent support)."
        echo "Install with: brew install esolitos/ipa/sshpass"
        exit 1
    fi
fi

HOST_USER="$(whoami)"

# --- Traps (set early so Ctrl-C is handled at any point) ---
VM_CLONED=false
INTERRUPTED=false

cleanup() {
    [[ "$VM_CLONED" != true ]] && return
    if [[ "$INTERRUPTED" == true ]]; then
        echo ""
        echo "Interrupted — cleaning up VM '$VM_NAME'..."
    else
        echo ""
        echo "Provisioning failed — cleaning up VM '$VM_NAME'..."
    fi
    tart stop "$VM_NAME" 2>/dev/null || true
    tart delete "$VM_NAME" 2>/dev/null || true
    echo "      Done."
}

trap cleanup EXIT
trap 'INTERRUPTED=true; exit 130' INT TERM

# --- Helper functions ---
# VM_IP is set during step 6; SSH-based functions only work after that.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

vm_exec() {
    if [[ "$GUEST_OS" == "linux" ]]; then
        sshpass -p admin ssh $SSH_OPTS admin@"$VM_IP" "$@"
    else
        tart exec "$VM_NAME" "$@"
    fi
}

vm_exec_user() {
    local cmd="$1"
    if [[ "$GUEST_OS" == "linux" ]]; then
        ssh $SSH_OPTS "$HOST_USER@$VM_IP" "bash -c '$cmd'"
    else
        tart exec "$VM_NAME" sudo -Hu "$HOST_USER" zsh -l -c "$cmd"
    fi
}

# --- Detect local base image ---
# Registry images contain '/' (e.g. ghcr.io/cirruslabs/...), local VMs are plain names.
LOCAL_BASE=false
if [[ "$BASE_IMAGE" != */* ]]; then
    LOCAL_BASE=true
fi

echo "=== Provision VM: $VM_NAME ==="
echo "  Guest OS   : $GUEST_OS"
echo "  Base image : $BASE_IMAGE"
echo "  Disk size  : ${DISK_GB} GB"
echo "  Headless   : $HEADLESS"
echo "  Host user  : $HOST_USER"
echo "  Local base : $LOCAL_BASE"
echo ""

# --- Prompt for password upfront (skip for local base — user already exists) ---
PASSWORD=""
if [[ "$LOCAL_BASE" == false ]]; then
    while true; do
        read -s -p "Password for new user '$HOST_USER': " PASSWORD
        echo
        read -s -p "Confirm password: " PASSWORD_CONFIRM
        echo
        if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
    echo ""
fi

# --- [1/15] Check for conflicts ---
echo "[1/15] Checking for existing VM..."
if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists. Delete it first with: tart delete $VM_NAME"
    exit 1
fi
echo "       OK — no conflict."

# --- [2/15] Pull latest base image (skip for local VMs) ---
if [[ "$BASE_IMAGE" == */* ]]; then
    echo "[2/15] Pulling latest '$BASE_IMAGE'..."
    tart pull "$BASE_IMAGE"
    echo "       Done."
else
    echo "[2/15] Using local VM '$BASE_IMAGE' as base (skipping pull)."
    if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$BASE_IMAGE"; then
        echo "Error: Local VM '$BASE_IMAGE' not found. Run 'tart list' to see available VMs."
        exit 1
    fi
fi

# --- [3/15] Clone base image ---
echo "[3/15] Cloning '$BASE_IMAGE' -> '$VM_NAME'..."
tart clone "$BASE_IMAGE" "$VM_NAME"
VM_CLONED=true
echo "       Done."

# --- [4/15] Resize disk ---
echo "[4/15] Setting disk size to ${DISK_GB} GB..."
if RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$DISK_GB" 2>&1); then
    echo "       Done."
else
    echo "       Warning: could not resize disk: $RESIZE_OUT"
    echo "       (Disks can only grow, not shrink. Continuing with base image disk size.)"
fi

# --- [5/15] Start VM ---
echo "[5/15] Starting VM..."
if [[ "$HEADLESS" == true ]]; then
    tart run "$VM_NAME" --no-graphics &
else
    tart run "$VM_NAME" &
fi
TART_PID=$!
echo "       VM started (PID $TART_PID)."

# --- [6/15] Wait for guest connectivity ---
CONNECT_TIMEOUT=120
CONNECT_START=$(date +%s)

if [[ "$GUEST_OS" == "linux" ]]; then
    # Linux: wait for IP via DHCP, then wait for SSH
    printf "[6/15] Waiting for VM IP..."
    VM_IP=""
    while [[ -z "$VM_IP" ]]; do
        CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
        if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
            printf "\n"
            echo "Error: Timed out waiting for VM IP after ${CONNECT_TIMEOUT}s."
            exit 1
        fi
        VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
        [[ -z "$VM_IP" ]] && sleep 2
    done
    printf "\r[6/15] Got VM IP: $VM_IP. Waiting for SSH...%-10s\n"

    while true; do
        CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
        if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
            echo "Error: Timed out waiting for SSH after ${CONNECT_TIMEOUT}s."
            exit 1
        fi
        printf "\r[6/15] Waiting for SSH... %ds" "$CONNECT_ELAPSED"
        if sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null; then
            break
        fi
        sleep 2
    done
    printf "\r[6/15] SSH ready.%-30s\n" ""
else
    # macOS: wait for guest agent via tart exec
    while true; do
        tart exec "$VM_NAME" true 2>/dev/null &
        PROBE_PID=$!
        for _ in 1 2 3; do
            CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
            if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
                kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
                printf "\n"
                echo "Error: Timed out waiting for guest agent after ${CONNECT_TIMEOUT}s."
                exit 1
            fi
            printf "\r[6/15] Waiting for guest agent... %ds" "$CONNECT_ELAPSED"
            if ! kill -0 "$PROBE_PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if ! kill -0 "$PROBE_PID" 2>/dev/null; then
            if wait "$PROBE_PID" 2>/dev/null; then
                break
            fi
        else
            kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
        fi
    done
    printf "\r[6/15] Guest agent ready.%-20s\n" ""
fi

# --- [7/15] Regenerate SSH host keys (cloned VMs share the base image's keys) ---
echo "[7/15] Regenerating SSH host keys..."
if [[ "$GUEST_OS" == "linux" ]]; then
    # Run as a single command string — restarting sshd kills our SSH connection,
    # so we combine everything and tolerate the connection drop.
    vm_exec "sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart sshd" || true
    # Wait for sshd to come back up with the new keys
    sleep 2
    for _ in $(seq 1 10); do
        sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null && break
        sleep 1
    done
else
    vm_exec sudo rm -f /etc/ssh/ssh_host_*
    vm_exec sudo ssh-keygen -A
    vm_exec sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
fi
echo "       Done."

# --- [8/15] Create user (skip for local base — user already exists) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[8/15] Creating user '$HOST_USER' on VM..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        PASS_HASH=$(openssl passwd -6 "$PASSWORD")
        vm_exec sudo useradd -m -s /bin/bash -G sudo -p "'$PASS_HASH'" "$HOST_USER"
        vm_exec "echo '$HOST_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$HOST_USER > /dev/null && sudo chmod 440 /etc/sudoers.d/$HOST_USER"
    else
        "$SCRIPT_DIR/create-macos-vm-user.sh" "$VM_NAME" "$HOST_USER" "$PASSWORD" --admin
    fi
    echo "       User created."
else
    echo "[8/15] Skipping user creation (local base — '$HOST_USER' already exists)."
fi

# --- [9/15] Install/update SSH public key for user ---
echo "[9/15] Installing SSH public key for '$HOST_USER'..."
SSH_PUBKEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$key_file" ]]; then
        SSH_PUBKEY=$(cat "$key_file")
        break
    fi
done
if [[ -n "$SSH_PUBKEY" ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        HOME_DIR="/home/$HOST_USER"
        vm_exec sudo mkdir -p "$HOME_DIR/.ssh"
        vm_exec sudo chmod 700 "$HOME_DIR/.ssh"
        vm_exec "echo '$SSH_PUBKEY' | sudo tee $HOME_DIR/.ssh/authorized_keys > /dev/null"
        vm_exec sudo chmod 600 "$HOME_DIR/.ssh/authorized_keys"
        vm_exec sudo chown -R "$HOST_USER:$HOST_USER" "$HOME_DIR/.ssh"
    else
        vm_exec sudo -Hu "$HOST_USER" bash -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$SSH_PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    fi
    echo "       Done."
else
    echo "       Warning: no SSH public key found in ~/.ssh — skipping."
fi

# --- [10/15] Set computer name ---
echo "[10/15] Setting computer name to '$VM_NAME'..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec sudo hostnamectl set-hostname "$VM_NAME"
else
    # LocalHostName only allows alphanumerics and hyphens (used for Bonjour .local)
    LOCAL_HOSTNAME="${VM_NAME//_/-}"
    LOCAL_HOSTNAME="${LOCAL_HOSTNAME//[^a-zA-Z0-9-]/}"
    vm_exec sudo scutil --set ComputerName "$VM_NAME"
    vm_exec sudo scutil --set HostName "$VM_NAME"
    vm_exec sudo scutil --set LocalHostName "$LOCAL_HOSTNAME"
fi
echo "       Done."

# --- [11/15] Clone or update vm-tools ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[11/15] Cloning vm-tools into VM..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec sudo apt-get update -qq
        vm_exec sudo apt-get install -y -qq git
    fi
    vm_exec_user "mkdir -p ~/dev && git clone https://github.com/deep108/vm-tools.git ~/dev/vm-tools"
    echo "        vm-tools cloned."
else
    echo "[11/15] Updating vm-tools in VM..."
    vm_exec_user "cd ~/dev/vm-tools && git pull"
    echo "        vm-tools updated."
fi

# --- [12/15] Transfer Homebrew ownership (skip for local base or Linux) ---
if [[ "$GUEST_OS" == "linux" ]]; then
    echo "[12/15] Skipping Homebrew ownership (Linux — not applicable)."
elif [[ "$LOCAL_BASE" == false ]]; then
    echo "[12/15] Checking for Homebrew..."
    if vm_exec test -d /opt/homebrew; then
        echo "        Found — transferring ownership to '$HOST_USER'..."
        vm_exec sudo chown -R "$HOST_USER":staff /opt/homebrew
        echo "        Done."
    else
        echo "        /opt/homebrew not found — skipping."
    fi
else
    echo "[12/15] Skipping Homebrew ownership (local base — already done)."
fi

# --- [13/15] Run bootstrap ---
echo "[13/15] Running bootstrap..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec_user "bash ~/dev/vm-tools/scripts/bootstrap-linux.sh"
else
    vm_exec_user "zsh -l ~/dev/vm-tools/scripts/bootstrap.sh"
fi
echo "        Bootstrap complete."

# --- [14/15] Set up VS Code serve-web (skip for local base — already configured) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[14/15] Setting up VS Code serve-web..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec env "SERVICE_USER=$HOST_USER" bash /home/$HOST_USER/dev/vm-tools/guest/setup-code-server-systemd.sh
    else
        vm_exec env "SERVICE_USER=$HOST_USER" bash ~/dev/vm-tools/guest/setup-code-server-launch-agent.sh
    fi
    echo "        Done."
else
    echo "[14/15] Skipping VS Code serve-web (local base — already configured)."
fi

# --- [15/15] Get VM IP and show summary ---
trap - EXIT INT TERM  # provisioning succeeded — don't delete the VM on exit
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || echo "<unavailable>")

# Add VM's host key to known_hosts so first SSH doesn't prompt
if [[ "$VM_IP" != "<unavailable>" ]]; then
    ssh-keyscan -H "$VM_IP" >> ~/.ssh/known_hosts 2>/dev/null
fi

echo ""
echo "========================================"
echo "  VM provisioned successfully!"
echo "========================================"
echo "  Name     : $VM_NAME"
echo "  IP       : $VM_IP"
echo "  User     : $HOST_USER (admin)"
echo ""
echo "  Connect  : ssh ${VM_IP}"
echo "========================================"
