#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 <vm-name>"
    exit 1
fi

VM_NAME="$1"

if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi

STATE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $NF}')

# Capture IP before stopping — tart ip only works while the VM is running.
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)

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
