#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pick-vm.sh"

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") [<vm-name>]"
    echo ""
    echo "Gracefully stop a running Tart VM (30s timeout, then force)."
    echo "If <vm-name> is omitted, presents a list of running local VMs."
    exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

VM_NAME="${1:-}"

# --- Pick VM if not specified ---
if [[ -z "$VM_NAME" ]]; then
    pick_vm "running"
fi

# --- Verify VM exists ---
if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi

# --- Check VM is running ---
STATE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $NF}')
if [[ "$STATE" != "running" ]]; then
    echo "VM '$VM_NAME' is not running (state: $STATE)."
    exit 0
fi

# --- Stop VM ---
echo "Stopping '$VM_NAME'..."
tart stop "$VM_NAME"
echo "Stopped."
