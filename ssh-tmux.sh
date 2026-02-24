#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <vm-name> [session-name] [username]"
    echo
    echo "SSH into a Tart VM and attach or create a tmux session."
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

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

VM_NAME="$1"
SESSION="${2:-general}"
SSH_USER="${3:-$USER}"

VM_IP="$(tart ip "$VM_NAME")"

if [ -z "$VM_IP" ]; then
    echo "Error: Could not get IP for VM '$VM_NAME'. Is it running?" >&2
    exit 1
fi

echo "Connecting to $SSH_USER@$VM_IP (tmux: $SESSION)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$VM_IP" \
    -t "zsh -l -c \"tmux -CC new-session -A -s '$SESSION'\""
