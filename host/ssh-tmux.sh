#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pick-vm.sh"

usage() {
    echo "Usage: $(basename "$0") [<vm-name>] [session-name] [username]"
    echo
    echo "SSH into a Tart VM and attach or create a tmux session."
    echo "If <vm-name> is omitted, presents a list of running local VMs."
    echo
    echo "Arguments:"
    echo "  vm-name       Name of the Tart VM"
    echo "  session-name  tmux session name (default: general)"
    echo "  username      SSH username (default: current user \$USER)"
    echo
    echo "Examples:"
    echo "  $(basename "$0") my-vm"
    echo "  $(basename "$0") my-vm devenv"
    echo "  $(basename "$0") my-vm general admin"
    exit 0
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

VM_NAME="${1:-}"
if [ -n "$VM_NAME" ]; then
    shift
    SESSION="${1:-general}"
    SSH_USER="${2:-$USER}"
else
    pick_vm "running"
    SESSION="general"
    SSH_USER="$USER"
fi

VM_IP="$(tart ip "$VM_NAME")"

if [ -z "$VM_IP" ]; then
    echo "Error: Could not get IP for VM '$VM_NAME'. Is it running?" >&2
    exit 1
fi

echo "Connecting to $SSH_USER@$VM_IP (tmux: $SESSION)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$VM_IP" \
    -t "zsh -l -c \"tmux -CC new-session -A -s '$SESSION'\""
