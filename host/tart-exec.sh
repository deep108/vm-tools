#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pick-vm.sh"

usage() {
    echo "Usage: $(basename "$0") [<vm-name>] [--user <username>] <command> [args...]"
    echo
    echo "Execute a command on a running Tart VM via the Virtio guest agent."
    echo "If <vm-name> is omitted, presents a list of running local VMs."
    echo
    echo "By default, commands run as the admin user. Use --user to run as a"
    echo "specific user with a full login shell (zsh -l), which provides the"
    echo "correct PATH (Homebrew, mise, etc.)."
    echo
    echo "Arguments:"
    echo "  vm-name      Name of the Tart VM"
    echo "  --user NAME  Run command as NAME via sudo -Hu (with zsh -l)"
    echo "  command      Command to execute on the guest"
    echo
    echo "Examples:"
    echo "  $(basename "$0") my-vm whoami"
    echo "  $(basename "$0") my-vm sudo brew update"
    echo "  $(basename "$0") my-vm --user david 'cd ~/dev/myapp && mise install'"
    echo "  $(basename "$0") my-vm --user david ~/dev/vm-tools/scripts/bootstrap.sh"
    exit 0
}

[[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]] && usage

# If the first arg is --user or looks like a command (not a VM name),
# pick the VM interactively. Otherwise, treat it as the VM name.
if [[ $# -eq 0 ]]; then
    usage
elif [[ "$1" == "--user" ]]; then
    pick_vm "running"
else
    VM_NAME="$1"
    shift
fi

TARGET_USER=""
if [[ "${1:-}" == "--user" ]]; then
    [[ -z "${2:-}" ]] && { echo "Error: --user requires a username"; usage; }
    TARGET_USER="$2"
    shift 2
fi

[[ $# -eq 0 ]] && { echo "Error: no command specified"; usage; }

if [[ -n "$TARGET_USER" ]]; then
    # Run as the specified user with a login shell for full PATH
    tart exec "$VM_NAME" sudo -Hu "$TARGET_USER" zsh -l -c "$*"
else
    tart exec "$VM_NAME" "$@"
fi
