#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <vm-name> [--user <username>] <command> [args...]"
    echo
    echo "Execute a command on a running Tart VM via the Virtio guest agent."
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

if [[ $# -lt 2 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

VM_NAME="$1"
shift

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
