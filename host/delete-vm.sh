#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $(basename "$0") <vm-name> [--keep-git]"
    echo ""
    echo "  <vm-name>    Tart VM name to delete"
    echo "  --keep-git   Skip teardown of git setup (authorized_keys, wrapper script)"
    exit 1
}

[[ $# -lt 1 || "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

VM_NAME="$1"
shift

KEEP_GIT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-git)
            KEEP_GIT=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi

STATE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $NF}')

# Capture IP before stopping — tart ip only works while the VM is running.
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)

# Run git teardown before stopping the VM (teardown is host-only, VM state doesn't matter).
WRAPPER_SCRIPT="$HOME/.local/bin/git-vm-${VM_NAME}.sh"
if [[ "$KEEP_GIT" != true && -f "$WRAPPER_SCRIPT" ]]; then
    "$SCRIPT_DIR/teardown-vm-git.sh" "$VM_NAME"
    echo ""
fi

if [[ "$STATE" == "running" ]]; then
    echo "Stopping '$VM_NAME'..."
    tart stop "$VM_NAME"
    sleep 2
fi

echo "Deleting '$VM_NAME'..."
tart delete "$VM_NAME"

# Remove the VM's IP from known_hosts so a future VM at the same IP doesn't
# trigger "REMOTE HOST IDENTIFICATION HAS CHANGED" on direct SSH connections.
# (setup-vm-git.sh uses UserKnownHostsFile=/dev/null so it's unaffected either way.)
if [[ -n "$VM_IP" ]]; then
    ssh-keygen -R "$VM_IP" 2>/dev/null && echo "Removed $VM_IP from ~/.ssh/known_hosts." || true
fi

echo "Done."
