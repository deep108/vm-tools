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
ADMIN_SSH_SOCKET=""

close_ssh_masters() {
    [[ -n "$ADMIN_SSH_SOCKET" ]] && \
        ssh -o ControlPath="$ADMIN_SSH_SOCKET" -O exit "admin@${VM_IP}" 2>/dev/null || true
}

cleanup() {
    [[ "$VM_CLONED" != true ]] && return
    if [[ "$INTERRUPTED" == true ]]; then
        echo ""
        echo "Interrupted — cleaning up VM '$VM_NAME'..."
    else
        echo ""
        echo "Provisioning failed — cleaning up VM '$VM_NAME'..."
    fi
    close_ssh_masters
    tart stop "$VM_NAME" 2>/dev/null || true
    sleep 2
    tart delete "$VM_NAME" 2>/dev/null || true
    echo "      Done."
}

trap cleanup EXIT
trap 'INTERRUPTED=true; exit 130' INT TERM

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

# --- Check for conflicts ---
echo "[1/8] Checking for existing VM..."
if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists. Delete it first with: tart delete $VM_NAME"
    exit 1
fi
echo "      OK — no conflict."

# --- Pull latest base image (skip for local VMs) ---
if [[ "$BASE_IMAGE" == */* ]]; then
    echo "[2/8] Pulling latest '$BASE_IMAGE'..."
    tart pull "$BASE_IMAGE"
    echo "      Done."
else
    echo "[2/8] Using local VM '$BASE_IMAGE' as base (skipping pull)."
    if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$BASE_IMAGE"; then
        echo "Error: Local VM '$BASE_IMAGE' not found. Run 'tart list' to see available VMs."
        exit 1
    fi
fi

# --- Clone base image ---
echo "[3/8] Cloning '$BASE_IMAGE' -> '$VM_NAME'..."
tart clone "$BASE_IMAGE" "$VM_NAME"
VM_CLONED=true
echo "      Done."

# --- Resize disk ---
echo "[4/8] Setting disk size to ${DISK_GB} GB..."
if RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$DISK_GB" 2>&1); then
    echo "      Done."
else
    echo "      Warning: could not resize disk: $RESIZE_OUT"
    echo "      (Disks can only grow, not shrink. Continuing with base image disk size.)"
fi

# --- Start VM ---
echo "[5/8] Starting VM..."
if [[ "$HEADLESS" == true ]]; then
    tart run "$VM_NAME" --no-graphics &
else
    tart run "$VM_NAME" &
fi
TART_PID=$!
echo "      VM started (PID $TART_PID)."

# --- Wait for IP ---
# Brief pause before polling: avoids picking up a stale cached IP from a
# recently-deleted VM with the same name (tart may return the old ARP/DHCP
# entry if queried immediately after a new VM starts).
sleep 5

VM_IP=""
IP_TIMEOUT=60
IP_START=$(date +%s)
while [[ -z "$VM_IP" ]]; do
    IP_ELAPSED=$(( $(date +%s) - IP_START ))
    if [[ $IP_ELAPSED -ge $IP_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for VM IP after ${IP_TIMEOUT}s."
        exit 1
    fi
    printf "\r[6/8] Waiting for VM IP... %ds" "$IP_ELAPSED"
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        sleep 2
    fi
done
printf "\r[6/8] IP: %-40s\n" "$VM_IP"

# --- Wait for SSH ---
# Use -G 5 (macOS TCP connection timeout) not -w 5 (idle timeout): without -G,
# nc connecting to a non-responding IP blocks for ~75s while the kernel
# retransmits SYN packets, making the counter appear to run ~15x too slow.
# Track real wall-clock time so the display stays accurate regardless of how
# long each nc attempt takes.
SSH_TIMEOUT=180
SSH_START=$(date +%s)
while true; do
    if nc -z -w 5 -G 5 "$VM_IP" 22 2>/dev/null; then
        break
    fi
    SSH_ELAPSED=$(( $(date +%s) - SSH_START ))
    if [[ $SSH_ELAPSED -ge $SSH_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for SSH after ${SSH_TIMEOUT}s."
        exit 1
    fi
    printf "\r[7/8] Waiting for SSH... %ds" "$SSH_ELAPSED"
    sleep 3
done
printf "\r[7/8] SSH is ready.%-20s\n" ""

# --- Establish SSH ControlMaster connections (authenticate once, reuse for all commands) ---
ADMIN_SSH_SOCKET=$(mktemp -u /tmp/tart-admin-XXXXXX)
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -o ControlMaster=yes -o ControlPath="$ADMIN_SSH_SOCKET" -o ControlPersist=yes \
    -f -N "admin@${VM_IP}"
export SSH_CONTROL_PATH="$ADMIN_SSH_SOCKET"  # picked up by create-tart-user2.sh

ssh_admin() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                  -o ControlMaster=no -o ControlPath="$ADMIN_SSH_SOCKET" \
                  "admin@${VM_IP}" "$@"; }
ssh_user()  { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                  "$VM_IP" "$@"; }

# --- Create user (skip for local base — user already exists) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[8/8] Creating user '$HOST_USER' on VM..."
    "$SCRIPT_DIR/create-tart-user2.sh" "$VM_NAME" "$HOST_USER" "$PASSWORD" --admin
    echo "      User created."
else
    echo "[8/8] Skipping user creation (local base — '$HOST_USER' already exists)."
fi

# --- Install/update SSH public key for user ---
echo "[+] Installing SSH public key for '$HOST_USER'..."
SSH_PUBKEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$key_file" ]]; then
        SSH_PUBKEY=$(cat "$key_file")
        break
    fi
done
if [[ -n "$SSH_PUBKEY" ]]; then
    ssh_admin "sudo -Hu '$HOST_USER' bash -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \"$SSH_PUBKEY\" > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
    echo "      Done."
else
    echo "      Warning: no SSH public key found in ~/.ssh — skipping. Guest-tools clone may fail."
fi

# --- Set computer name ---
echo "[+] Setting computer name to '$VM_NAME'..."
# LocalHostName only allows alphanumerics and hyphens (used for Bonjour .local)
LOCAL_HOSTNAME="${VM_NAME//_/-}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME//[^a-zA-Z0-9-]/}"
ssh_admin "
    sudo scutil --set ComputerName  '$VM_NAME'
    sudo scutil --set HostName      '$VM_NAME'
    sudo scutil --set LocalHostName '$LOCAL_HOSTNAME'
"
echo "      Done."


# --- Clone or update guest-tools ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[+] Cloning guest-tools into VM..."
    ssh_user "mkdir -p ~/dev && git clone https://github.com/deep108/guest-tools.git ~/dev/guest-tools"
    echo "      guest-tools cloned."
else
    echo "[+] Updating guest-tools in VM..."
    ssh_user "cd ~/dev/guest-tools && git pull"
    echo "      guest-tools updated."
fi

# --- Transfer Homebrew ownership (skip for local base — already done) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[+] Checking for Homebrew..."
    if ssh_admin "test -d /opt/homebrew"; then
        echo "      Found — transferring ownership to '$HOST_USER'..."
        ssh_admin "sudo chown -R '$HOST_USER':staff /opt/homebrew"
        echo "      Done."
    else
        echo "      /opt/homebrew not found — skipping."
    fi
fi

# --- Summary ---
close_ssh_masters
trap - EXIT INT TERM  # provisioning succeeded — don't delete the VM on exit
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
