#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pick-vm.sh"

# --- Defaults ---
GUI=""  # empty = auto (macOS: GUI, Linux: headless)
SUSPENDABLE=false
NESTED=false
GUEST_OS="macos"
VM_NAME=""
SSH_USER="$USER"
SSH_TIMEOUT=120

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") [<vm-name>] [--linux] [--gui] [--headless] [--suspendable] [--nested] [--user <username>] [--timeout <seconds>]"
    echo ""
    echo "Start a Tart VM and wait until it is SSH-reachable."
    echo "If <vm-name> is omitted, presents a list of stopped/suspended local VMs."
    echo ""
    echo "  <vm-name>            Name of the Tart VM to run."
    echo "  --linux              VM is a Linux guest (default: macOS)."
    echo "  --gui                Show the VM window with clipboard sharing."
    echo "  --headless           Run without graphics or clipboard."
    echo "                       (Default: macOS = GUI, Linux = headless.)"
    echo "  --suspendable        Enable suspendable mode (macOS only; disables audio)."
    echo "  --nested             Enable nested virtualization (exposes /dev/kvm to Linux guests)."
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
        --headless)
            GUI=false
            shift
            ;;
        --suspendable)
            SUSPENDABLE=true
            shift
            ;;
        --nested)
            NESTED=true
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
VM_LINE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name')
if [[ -z "$VM_LINE" ]]; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi

STATE=$(echo "$VM_LINE" | awk '{print $NF}')
if [[ "$STATE" == "running" ]]; then
    echo "Error: VM '$VM_NAME' is already running."
    exit 1
fi

# --- Auto-detect guest OS from disk size ---
# HACK: tart doesn't expose the guest OS type. Cirrus Labs base images use 50GB disks
# for macOS and 20GB for Linux, and our provisioning preserves these defaults. We use
# a 25GB threshold to guess: disk < 25GB → Linux, else macOS. The --linux flag still
# works as an explicit override. This will break if someone creates a small macOS image
# or a large (>= 25GB) Linux image, but it covers all standard Cirrus Labs bases.
if [[ "$GUEST_OS" == "macos" ]]; then
    DISK_GB=$(echo "$VM_LINE" | awk '{print $3}')
    if [[ "$DISK_GB" -lt 25 ]] 2>/dev/null; then
        GUEST_OS="linux"
    fi
fi

# --- Default GUI mode based on guest OS (if not explicitly set) ---
if [[ -z "$GUI" ]]; then
    if [[ "$GUEST_OS" == "macos" ]]; then
        GUI=true
    else
        GUI=false
    fi
fi

# --- Warn about suspendable mode ---
if [[ "$SUSPENDABLE" == true && "$GUEST_OS" != "macos" ]]; then
    echo "Warning: --suspendable is only supported on macOS VMs. Ignoring."
    SUSPENDABLE=false
fi
if [[ "$SUSPENDABLE" == true ]]; then
    echo "Warning: Suspendable mode disables audio."
fi

# --- Build tart run command ---
TART_ARGS=(run "$VM_NAME")
if [[ "$SUSPENDABLE" == true ]]; then
    TART_ARGS+=(--suspendable)
fi

if [[ "$GUI" != true ]]; then
    TART_ARGS+=(--no-graphics --no-clipboard)
fi
if [[ "$NESTED" == true ]]; then
    TART_ARGS+=(--nested)
fi
# Note: --suspendable (macOS only) disables audio, so --no-audio is not needed when suspendable

# --- Start VM ---
RUN_MODE="$(if [[ "$GUI" == true ]]; then echo "GUI"; else echo "headless"; fi)"
[[ "$NESTED" == true ]] && RUN_MODE+=", nested"
[[ "$SUSPENDABLE" == true ]] && RUN_MODE+=", suspendable"
echo "Starting '$VM_NAME' (${GUEST_OS}, ${RUN_MODE})..."
tart "${TART_ARGS[@]}" &>/dev/null &
TART_PID=$!
disown $TART_PID
echo "VM started (PID $TART_PID)."

# --- Wait for IP ---
START_TIME=$(date +%s)
VM_IP=""

printf "Waiting for VM IP..."
while [[ -z "$VM_IP" ]]; do
    if ! kill -0 "$TART_PID" 2>/dev/null; then
        printf "\n"
        echo "Error: tart process died (PID $TART_PID). VM failed to start."
        exit 1
    fi
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
    if ! kill -0 "$TART_PID" 2>/dev/null; then
        printf "\n"
        echo "Error: tart process died (PID $TART_PID). VM crashed during startup."
        exit 1
    fi
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

# Get VM disk size (re-read tart list since VM is now running)
DISK_SIZE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name {print $3 " GB"}')

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
[[ "$SUSPENDABLE" == true ]] && echo "Suspend:  tart suspend $VM_NAME"
echo "Stop:     tart stop $VM_NAME"
