#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <vm-name> <script-path> [username]"
    echo
    echo "SSH into a Tart VM and execute a script on the guest."
    echo
    echo "Arguments:"
    echo "  vm-name      Name of the Tart VM"
    echo "  script-path  Path to the script on the guest VM"
    echo "  username     SSH username (default: current user \$USER)"
    echo
    echo "Examples:"
    echo "  $(basename "$0") my-vm ~/guest-tools/devenv.sh"
    echo "  $(basename "$0") my-vm ~/projects/myapp/scripts/devenv.sh admin"
    exit 0
}

if [ $# -lt 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

VM_NAME="$1"
SCRIPT_PATH="$2"
SSH_USER="${3:-$USER}"

VM_IP="$(tart ip "$VM_NAME")"

if [ -z "$VM_IP" ]; then
    echo "Error: Could not get IP for VM '$VM_NAME'. Is it running?" >&2
    exit 1
fi

echo "Connecting to $SSH_USER@$VM_IP and running '$SCRIPT_PATH'..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$VM_IP" \
    -t "zsh -l '$SCRIPT_PATH'"
