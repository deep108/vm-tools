#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pick-vm.sh"

# --- Defaults ---
GUI=false
GUEST_OS="macos"
VM_NAME=""
SSH_USER="$USER"
SSH_TIMEOUT=120

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") [<vm-name>] [--linux] [--gui] [--user <username>] [--timeout <seconds>]"
    echo ""
    echo "Start a Tart VM in suspendable mode and wait until it is SSH-reachable."
    echo "If <vm-name> is omitted, presents a list of stopped/suspended local VMs."
    echo ""
    echo "  <vm-name>            Name of the Tart VM to run."
    echo "  --linux              VM is a Linux guest (default: macOS)."
    echo "  --gui                Show the VM window with clipboard sharing."
    echo "                       (Default: headless, no clipboard.)"
    echo "  --user <username>    SSH username to test connectivity (default: \$USER)."
    echo "  --timeout <seconds>  SSH wait timeout in seconds (default: 120)."
    exit 1
}

# --- Parse args ---
# First non-flag argument is the VM name
if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
    VM_NAME="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --linux)
            GUEST_OS="linux"
            shift
            ;;
        --gui)
            GUI=true
            shift
            ;;
        --user)
            [[ -z "${2:-}" ]] && { echo "Error: --user requires a value"; usage; }
            SSH_USER="$2"
            shift 2
            ;;
        --timeout)
            [[ -z "${2:-}" ]] && { echo "Error: --timeout requires a value"; usage; }
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# --- Pick VM if not specified ---
if [[ -z "$VM_NAME" ]]; then
    pick_vm "stopped,suspended"
fi

# --- Verify VM exists and is not running ---
if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi

STATE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $NF}')
if [[ "$STATE" == "running" ]]; then
    echo "Error: VM '$VM_NAME' is already running."
    exit 1
fi

# --- Build tart run command ---
TART_ARGS=(run "$VM_NAME" --suspendable)

if [[ "$GUI" != true ]]; then
    TART_ARGS+=(--no-graphics --no-clipboard)
fi
# Note: --suspendable already disables audio, so --no-audio is not needed

# --- Start VM ---
echo "Starting '$VM_NAME' (${GUEST_OS}, $(if [[ "$GUI" == true ]]; then echo "GUI"; else echo "headless"; fi), suspendable)..."
tart "${TART_ARGS[@]}" &
TART_PID=$!
echo "VM started (PID $TART_PID)."

# --- Wait for IP ---
START_TIME=$(date +%s)
VM_IP=""

printf "Waiting for VM IP..."
while [[ -z "$VM_IP" ]]; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $SSH_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for VM IP after ${SSH_TIMEOUT}s."
        exit 1
    fi
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        sleep 2
    fi
done
printf "\rGot VM IP: %s%-20s\n" "$VM_IP" ""

# --- Wait for SSH ---
printf "Waiting for SSH..."
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ $ELAPSED -ge $SSH_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for SSH after ${SSH_TIMEOUT}s."
        exit 1
    fi
    printf "\rWaiting for SSH... %ds" "$ELAPSED"
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           -o ConnectTimeout=2 -o BatchMode=yes \
           "$SSH_USER@$VM_IP" true 2>/dev/null; then
        break
    fi
    sleep 2
done
printf "\rSSH ready.%-30s\n" ""

# --- Gather VM info ---
TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

# Get VM disk size
DISK_SIZE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $4}')

# Get hostname from guest
VM_HOSTNAME=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=5 "$SSH_USER@$VM_IP" hostname 2>/dev/null || echo "<unknown>")

echo ""
echo "VM is ready."
echo "  Name     : $VM_NAME"
echo "  OS       : $GUEST_OS"
echo "  IP       : $VM_IP"
echo "  Hostname : $VM_HOSTNAME"
echo "  User     : $SSH_USER"
echo "  Disk     : ${DISK_SIZE:-<unknown>}"
echo "  PID      : $TART_PID"
echo "  Ready in : ${TOTAL_ELAPSED}s"
echo ""
echo "Connect:  ssh $SSH_USER@$VM_IP"
echo "Suspend:  tart suspend $VM_NAME"
echo "Stop:     tart stop $VM_NAME"
