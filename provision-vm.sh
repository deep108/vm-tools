#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
DISK_GB=75
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
HEADLESS=false
VM_NAME=""
GIT_CREDENTIAL_TTL=$((15 * 24 * 60 * 60))  # 15 days in seconds

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

echo "=== Provision VM: $VM_NAME ==="
echo "  Base image : $BASE_IMAGE"
echo "  Disk size  : ${DISK_GB} GB"
echo "  Headless   : $HEADLESS"
echo "  Host user  : $HOST_USER"
echo ""

# --- Prompt for password upfront ---
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

read -s -p "GitHub token (for cloning guest-tools): " GITHUB_TOKEN
echo
echo ""

# --- Check for conflicts ---
echo "[1/7] Checking for existing VM..."
if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists. Delete it first with: tart delete $VM_NAME"
    exit 1
fi
echo "      OK — no conflict."

# --- Clone base image ---
echo "[2/7] Cloning '$BASE_IMAGE' -> '$VM_NAME'..."
tart clone "$BASE_IMAGE" "$VM_NAME"
VM_CLONED=true
echo "      Done."

# --- Resize disk ---
echo "[3/7] Setting disk size to ${DISK_GB} GB..."
if RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$DISK_GB" 2>&1); then
    echo "      Done."
else
    echo "      Warning: could not resize disk: $RESIZE_OUT"
    echo "      (Disks can only grow, not shrink. Continuing with base image disk size.)"
fi

# --- Start VM ---
echo "[4/7] Starting VM..."
if [[ "$HEADLESS" == true ]]; then
    tart run "$VM_NAME" --no-graphics &
else
    tart run "$VM_NAME" &
fi
TART_PID=$!
echo "      VM started (PID $TART_PID)."

# --- Wait for IP ---
VM_IP=""
IP_TIMEOUT=30
IP_ELAPSED=0
while [[ -z "$VM_IP" ]]; do
    if [[ $IP_ELAPSED -ge $IP_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for VM IP after ${IP_TIMEOUT}s."
        exit 1
    fi
    printf "\r[5/7] Waiting for VM IP... %ds" "$IP_ELAPSED"
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        sleep 2
        IP_ELAPSED=$((IP_ELAPSED + 2))
    fi
done
printf "\r[5/7] IP: %-40s\n" "$VM_IP"

# --- Wait for SSH ---
SSH_TIMEOUT=120
SSH_ELAPSED=0
while true; do
    if nc -z -w 5 "$VM_IP" 22 2>/dev/null; then
        break
    fi
    if [[ $SSH_ELAPSED -ge $SSH_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for SSH after ${SSH_TIMEOUT}s."
        exit 1
    fi
    printf "\r[6/7] Waiting for SSH... %ds" "$SSH_ELAPSED"
    sleep 5
    SSH_ELAPSED=$((SSH_ELAPSED + 5))
done
printf "\r[6/7] SSH is ready.%-20s\n" ""

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

# --- Create user ---
echo "[7/7] Creating user '$HOST_USER' on VM..."
"$SCRIPT_DIR/create-tart-user2.sh" "$VM_NAME" "$HOST_USER" "$PASSWORD" --admin
echo "      User created."

# --- Install SSH public key for new user ---
echo "[+] Installing SSH public key for '$HOST_USER'..."
SSH_PUBKEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$key_file" ]]; then
        SSH_PUBKEY=$(cat "$key_file")
        break
    fi
done
if [[ -n "$SSH_PUBKEY" ]]; then
    ssh_admin "sudo -u '$HOST_USER' bash -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \"$SSH_PUBKEY\" > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
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

# --- Configure git credential cache ---
echo "[+] Configuring git credential cache (${GIT_CREDENTIAL_TTL}s)..."
ssh_user "git config --global credential.helper 'cache --timeout=${GIT_CREDENTIAL_TTL}'"
echo "      Done."

# --- Clone guest-tools ---
echo "[+] Cloning guest-tools into VM..."
ssh_user "mkdir -p ~/dev \
     && git clone https://${GITHUB_TOKEN}@github.com/deep108/guest-tools.git ~/dev/guest-tools \
     && git -C ~/dev/guest-tools remote set-url origin https://github.com/deep108/guest-tools.git"
echo "      guest-tools cloned."

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
