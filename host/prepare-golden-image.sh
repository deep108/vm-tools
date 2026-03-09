#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <vm-name> [--linux]"
    echo
    echo "Prepare a running VM to be used as a golden base image."
    echo
    echo "Cleans up instance-specific state (shell history, SSH host keys,"
    echo "caches, logs) then stops the VM. After this, the VM is ready to"
    echo "be cloned with: provision-vm.sh <new-vm> [--linux] --base <vm-name>"
    echo
    echo "  --linux    The VM is running Linux (default: macOS)."
    echo "             Uses SSH instead of tart exec (no guest agent on Linux)."
    exit 0
}

if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

VM_NAME="$1"
shift

GUEST_OS="macos"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --linux)
            GUEST_OS="linux"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

HOST_USER="$(whoami)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# On Linux all guest communication goes over SSH (no Virtio guest agent).
# vm_ssh runs a command as HOST_USER (key-based auth, NOPASSWD sudo available).
VM_IP=""
if [[ "$GUEST_OS" == "linux" ]]; then
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        echo "Error: Cannot get IP for VM '$VM_NAME'. Is it running?"
        exit 1
    fi
fi

vm_ssh() {
    ssh $SSH_OPTS "$HOST_USER@$VM_IP" "$@"
}

# --- Verify connectivity ---
if [[ "$GUEST_OS" == "linux" ]]; then
    if ! vm_ssh true 2>/dev/null; then
        echo "Error: Cannot SSH into VM '$VM_NAME' at $VM_IP as '$HOST_USER'."
        echo "       Ensure the VM is running and your SSH public key is installed."
        exit 1
    fi
else
    if ! tart exec "$VM_NAME" true 2>/dev/null; then
        echo "Error: Cannot reach guest agent for VM '$VM_NAME'. Is it running?"
        exit 1
    fi
fi

# --- Detect the non-admin user ---
# macOS: scan /Users; Linux: it's always HOST_USER (set during provisioning).
VM_USER=""
if [[ "$GUEST_OS" == "linux" ]]; then
    VM_USER="$HOST_USER"
else
    VM_USER=$(tart exec "$VM_NAME" ls /Users \
        | grep -v -E '^(admin|Shared|\.localized)$' \
        | head -1 || true)
fi

echo "=== Preparing golden image: $VM_NAME ==="
echo "  Guest OS : $GUEST_OS"
[[ -n "$VM_IP" ]] && echo "  VM IP    : $VM_IP"
[[ -n "$VM_USER" ]] && echo "  User     : $VM_USER"
echo ""

# --- [1/7] Shell history ---
echo "[1/7] Clearing shell history..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_ssh "rm -f ~/.bash_history ~/.zsh_history"
    vm_ssh "sudo bash -c 'rm -f /home/admin/.bash_history /home/admin/.zsh_history'"
else
    tart exec "$VM_NAME" rm -f ~/.zsh_history ~/.bash_history
    tart exec "$VM_NAME" sudo rm -f /Users/admin/.zsh_history /Users/admin/.bash_history
fi
echo "      Done."

# --- [2/7] SSH host keys (will be regenerated on clone by provision-vm.sh) ---
echo "[2/7] Removing SSH host keys..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_ssh "sudo bash -c 'rm -f /etc/ssh/ssh_host_*'"
else
    tart exec "$VM_NAME" sudo rm -f /etc/ssh/ssh_host_*
fi
echo "      Done."

# --- [3/7] SSH known_hosts ---
echo "[3/7] Clearing SSH known_hosts..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_ssh "rm -f ~/.ssh/known_hosts"
    vm_ssh "sudo bash -c 'rm -f /home/admin/.ssh/known_hosts'"
else
    tart exec "$VM_NAME" rm -f ~/.ssh/known_hosts
    tart exec "$VM_NAME" sudo rm -f /Users/admin/.ssh/known_hosts
fi
echo "      Done."

# --- [4/7] Package manager / Homebrew cache ---
echo "[4/7] Cleaning caches..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_ssh "sudo bash -c 'apt-get clean -qq && apt-get autoremove -y -qq'" 2>/dev/null || true
    # Homebrew may have been installed during bootstrap
    vm_ssh "bash -l -c 'command -v brew &>/dev/null && brew cleanup --prune=all 2>/dev/null || true'" || true
else
    tart exec "$VM_NAME" zsh -l -c 'brew cleanup --prune=all 2>/dev/null' || true
fi
echo "      Done."

# --- [5/7] System logs ---
echo "[5/7] Clearing system logs..."
if [[ "$GUEST_OS" == "linux" ]]; then
    # Rotate and vacuum systemd journal; remove common log files.
    vm_ssh "sudo bash -c 'journalctl --rotate 2>/dev/null; journalctl --vacuum-time=1s 2>/dev/null'" || true
    vm_ssh "sudo bash -c 'rm -rf /var/log/*.log /var/log/*.1 /var/log/apt/*.log 2>/dev/null'" || true
    vm_ssh "sudo bash -c 'rm -rf /tmp/*'" || true
else
    tart exec "$VM_NAME" sudo rm -rf /var/log/asl/*.asl
    tart exec "$VM_NAME" sudo rm -rf /Library/Logs/DiagnosticReports/*
    tart exec "$VM_NAME" sudo rm -rf /tmp/*
fi
echo "      Done."

# --- [6/7] DHCP leases ---
echo "[6/7] Clearing DHCP leases..."
if [[ "$GUEST_OS" == "linux" ]]; then
    # Cover both dhclient and NetworkManager lease locations (Debian Trixie uses NM).
    vm_ssh "sudo bash -c 'rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null'" || true
    vm_ssh "sudo bash -c 'rm -f /var/lib/NetworkManager/*.lease /var/lib/NetworkManager/internal*.lease 2>/dev/null'" || true
else
    tart exec "$VM_NAME" sudo rm -f /var/db/dhcpclient/leases/* 2>/dev/null || true
fi
echo "      Done."

# --- [7/7] Stop VM ---
echo "[7/7] Stopping VM..."
tart stop "$VM_NAME"
echo "      Done."

echo ""
echo "========================================"
echo "  Golden image ready: $VM_NAME"
echo "========================================"
echo "  Clone with:"
if [[ "$GUEST_OS" == "linux" ]]; then
    echo "    ./provision-vm.sh <new-vm> --linux --base $VM_NAME"
else
    echo "    ./provision-vm.sh <new-vm> --base $VM_NAME"
fi
echo "========================================"
