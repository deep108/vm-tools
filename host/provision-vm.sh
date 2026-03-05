#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
DISK_GB=75
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
HEADLESS=false
VM_NAME=""

# --- Usage ---
usage() {
    echo "Usage: $0 <vm-name> [--disk <GB>] [--base <image>] [--headless]"
    echo ""
    echo "  <vm-name>        Required. Name for the new Tart VM."
    echo "  --disk <GB>      Disk size in GB (default: 75)."
    echo "  --base <image>   Source Tart image to clone (default: tahoe-base)."
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
        --base)
            [[ -z "${2:-}" ]] && { echo "Error: --base requires a value"; usage; }
            BASE_IMAGE="$2"
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
vm_exec() {
    tart exec "$VM_NAME" "$@"
}

vm_exec_user() {
    local cmd="$1"
    tart exec "$VM_NAME" sudo -Hu "$HOST_USER" zsh -l -c "$cmd"
}

# --- Detect local base image ---
# Registry images contain '/' (e.g. ghcr.io/cirruslabs/...), local VMs are plain names.
LOCAL_BASE=false
if [[ "$BASE_IMAGE" != */* ]]; then
    LOCAL_BASE=true
fi

echo "=== Provision VM: $VM_NAME ==="
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

# --- [6/15] Wait for guest agent ---
# tart exec blocks for a long time when the agent isn't up, so we run each
# probe in the background, tick the counter every second, and kill the probe
# after a few seconds if it hasn't finished.
AGENT_TIMEOUT=120
AGENT_START=$(date +%s)
while true; do
    tart exec "$VM_NAME" true 2>/dev/null &
    PROBE_PID=$!
    for _ in 1 2 3; do
        AGENT_ELAPSED=$(( $(date +%s) - AGENT_START ))
        if [[ $AGENT_ELAPSED -ge $AGENT_TIMEOUT ]]; then
            kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
            printf "\n"
            echo "Error: Timed out waiting for guest agent after ${AGENT_TIMEOUT}s."
            exit 1
        fi
        printf "\r[6/15] Waiting for guest agent... %ds" "$AGENT_ELAPSED"
        if ! kill -0 "$PROBE_PID" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    # Check if probe finished
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
        if wait "$PROBE_PID" 2>/dev/null; then
            break  # agent responded
        fi
    else
        # Still running — kill it and retry
        kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
    fi
done
printf "\r[6/15] Guest agent ready.%-20s\n" ""

# --- [7/15] Regenerate SSH host keys (cloned VMs share the base image's keys) ---
echo "[7/15] Regenerating SSH host keys..."
vm_exec sudo rm -f /etc/ssh/ssh_host_*
vm_exec sudo ssh-keygen -A
vm_exec sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
echo "       Done."

# --- [8/15] Create user (skip for local base — user already exists) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[8/15] Creating user '$HOST_USER' on VM..."
    "$SCRIPT_DIR/create-macos-vm-user.sh" "$VM_NAME" "$HOST_USER" "$PASSWORD" --admin
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
    vm_exec sudo -Hu "$HOST_USER" bash -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$SSH_PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    echo "       Done."
else
    echo "       Warning: no SSH public key found in ~/.ssh — skipping."
fi

# --- [10/15] Set computer name ---
echo "[10/15] Setting computer name to '$VM_NAME'..."
# LocalHostName only allows alphanumerics and hyphens (used for Bonjour .local)
LOCAL_HOSTNAME="${VM_NAME//_/-}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME//[^a-zA-Z0-9-]/}"
vm_exec sudo scutil --set ComputerName "$VM_NAME"
vm_exec sudo scutil --set HostName "$VM_NAME"
vm_exec sudo scutil --set LocalHostName "$LOCAL_HOSTNAME"
echo "       Done."

# --- [11/15] Clone or update vm-tools ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[11/15] Cloning vm-tools into VM..."
    vm_exec_user "mkdir -p ~/dev && git clone https://github.com/deep108/vm-tools.git ~/dev/vm-tools"
    echo "        vm-tools cloned."
else
    echo "[11/15] Updating vm-tools in VM..."
    vm_exec_user "cd ~/dev/vm-tools && git pull"
    echo "        vm-tools updated."
fi

# --- [12/15] Transfer Homebrew ownership (skip for local base — already done) ---
if [[ "$LOCAL_BASE" == false ]]; then
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

# --- [13/15] Run bootstrap (installs Homebrew via brew, chezmoi, applies dotfiles) ---
echo "[13/15] Running bootstrap..."
vm_exec_user "zsh -l ~/dev/vm-tools/scripts/bootstrap.sh"
echo "        Bootstrap complete."

# --- [14/15] Set up VS Code serve-web LaunchDaemon (skip for local base — already configured) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[14/15] Setting up VS Code serve-web..."
    vm_exec env "SERVICE_USER=$HOST_USER" bash ~/dev/vm-tools/guest/setup-code-server-launch-agent.sh
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
