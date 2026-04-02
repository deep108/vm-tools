#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/pick-vm.sh"

# --- Defaults ---
GUEST_OS=""
GUEST_OS_EXPLICIT=false
VM_NAME=""
SSH_USER="$USER"
SIZE_GB=""
SSH_TIMEOUT=120

# --- State tracking ---
WE_STOPPED_VM=false
WE_STARTED_VM=false
TART_PID=""

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") [<vm-name>] [--disk <GB>] [--linux] [--user <username>]"
    echo ""
    echo "Resize a Tart VM's disk and expand the guest filesystem."
    echo "Works on running or stopped VMs (macOS and Linux)."
    echo ""
    echo "If run with no arguments, interactively selects a VM, prompts for"
    echo "the new size, and confirms the detected OS type."
    echo ""
    echo "  <vm-name>          Name of the Tart VM (if omitted, presents a list)."
    echo "  --disk <GB>        Target disk size in GB (can only grow)."
    echo "  --linux            VM is a Linux guest (default: auto-detect)."
    echo "  --user <username>  SSH username (default: \$USER)."
    exit 1
}

# --- Cleanup ---
cleanup() {
    if [[ "$WE_STARTED_VM" == true && -n "$VM_NAME" ]]; then
        echo "Stopping VM '$VM_NAME' (cleanup)..."
        tart stop "$VM_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- SSH helper ---
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes"

vm_ssh() {
    ssh $SSH_OPTS "$SSH_USER@$VM_IP" "$@"
}

# --- Wait for IP + SSH ---
wait_for_ssh() {
    local start_time
    start_time=$(date +%s)

    printf "Waiting for VM IP..."
    VM_IP=""
    while [[ -z "$VM_IP" ]]; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $SSH_TIMEOUT ]]; then
            printf "\n"
            echo "Error: Timed out waiting for VM IP after ${SSH_TIMEOUT}s."
            exit 1
        fi
        VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
        [[ -z "$VM_IP" ]] && sleep 2
    done
    printf "\rGot VM IP: %s%-20s\n" "$VM_IP" ""

    printf "Waiting for SSH..."
    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $SSH_TIMEOUT ]]; then
            printf "\n"
            echo "Error: Timed out waiting for SSH after ${SSH_TIMEOUT}s."
            exit 1
        fi
        printf "\rWaiting for SSH... %ds" "$elapsed"
        if vm_ssh true 2>/dev/null; then
            break
        fi
        sleep 2
    done
    printf "\rSSH ready.%-30s\n" ""
}

# --- Start VM headless ---
start_vm_headless() {
    local args=(run "$VM_NAME" --no-graphics --no-clipboard)
    echo "Starting '$VM_NAME' headless for guest resize..."
    tart "${args[@]}" &>/dev/null &
    TART_PID=$!
    disown "$TART_PID"
    WE_STARTED_VM=true
    wait_for_ssh
}

# --- Interactive VM picker with disk info ---
pick_vm_with_disk() {
    local vms=()

    while IFS= read -r line; do
        local source name disk_gb size_gb state
        source=$(echo "$line" | awk '{print $1}')
        [[ "$source" != "local" ]] && continue

        name=$(echo "$line" | awk '{print $2}')
        disk_gb=$(echo "$line" | awk '{print $3}')
        size_gb=$(echo "$line" | awk '{print $4}')
        state=$(echo "$line" | awk '{print $NF}')

        vms+=("$name|$disk_gb|$size_gb|$state")
    done < <(tart list 2>/dev/null | tail -n +2)

    if [[ ${#vms[@]} -eq 0 ]]; then
        echo "No local VMs found."
        exit 1
    fi

    echo "Local VMs:"
    printf "  %-4s %-30s %6s %6s   %s\n" "#" "Name" "Disk" "Used" "State"
    printf "  %-4s %-30s %6s %6s   %s\n" "---" "----" "----" "----" "-----"
    local i=1
    for entry in "${vms[@]}"; do
        IFS='|' read -r name disk_gb size_gb state <<< "$entry"
        printf "  %-4s %-30s %4s GB %4s GB   %s\n" "$i)" "$name" "$disk_gb" "$size_gb" "$state"
        ((i++))
    done
    echo ""

    local choice
    read -r -p "Select VM [1-${#vms[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#vms[@]} ]]; then
        echo "Invalid selection."
        exit 1
    fi

    local selected="${vms[$((choice - 1))]}"
    VM_NAME="${selected%%|*}"
}

# --- Parse args ---
if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
    VM_NAME="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)
            [[ -z "${2:-}" ]] && { echo "Error: --disk requires a value"; usage; }
            SIZE_GB="$2"
            shift 2
            ;;
        --linux)
            GUEST_OS="linux"
            GUEST_OS_EXPLICIT=true
            shift
            ;;
        --user)
            [[ -z "${2:-}" ]] && { echo "Error: --user requires a value"; usage; }
            SSH_USER="$2"
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

# --- Validate SIZE_GB if provided on command line ---
if [[ -n "$SIZE_GB" ]]; then
    if ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || [[ "$SIZE_GB" -le 0 ]]; then
        echo "Error: --disk must be a positive integer (GB)."
        exit 1
    fi
fi

# --- Pick VM if not specified ---
if [[ -z "$VM_NAME" ]]; then
    pick_vm_with_disk
fi

# --- Look up VM ---
VM_LINE=$(tart list 2>/dev/null | awk -v name="$VM_NAME" 'NR>1 && $2==name')
if [[ -z "$VM_LINE" ]]; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi

STATE=$(echo "$VM_LINE" | awk '{print $NF}')
CURRENT_DISK_GB=$(echo "$VM_LINE" | awk '{print $3}')
CURRENT_USED_GB=$(echo "$VM_LINE" | awk '{print $4}')

# --- Auto-detect guest OS ---
if [[ -z "$GUEST_OS" ]]; then
    if [[ "$CURRENT_DISK_GB" -lt 25 ]] 2>/dev/null; then
        GUEST_OS="linux"
    else
        GUEST_OS="macos"
    fi
fi

# --- Interactive: prompt for size if not specified ---
if [[ -z "$SIZE_GB" ]]; then
    # Use Finder's free space (includes purgeable/reclaimable space, which macOS
    # will free on demand). This matches what Finder's Get Info shows and is more
    # accurate for sparse APFS disk images than df's conservative number.
    HOST_FREE_BYTES=$(osascript -e 'tell application "Finder" to get free space of startup disk' 2>/dev/null || true)
    if [[ -n "$HOST_FREE_BYTES" ]]; then
        HOST_FREE_GB=$(python3 -c "print(int(${HOST_FREE_BYTES} / 1073741824))")
    else
        # Fallback to df (excludes purgeable space)
        HOST_FREE_GB=$(df -g "$HOME/.tart/vms/" 2>/dev/null | tail -1 | awk '{print $4}')
    fi
    echo ""
    echo "  VM:         $VM_NAME ($STATE)"
    echo "  Disk:       ${CURRENT_DISK_GB} GB (${CURRENT_USED_GB} GB used)"
    echo "  Host free:  ${HOST_FREE_GB} GB"
    echo ""
    while true; do
        read -r -p "New disk size in GB (must be > ${CURRENT_DISK_GB}): " SIZE_GB
        if ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || [[ "$SIZE_GB" -le 0 ]]; then
            echo "Please enter a positive integer."
            continue
        fi
        if [[ "$SIZE_GB" -le "$CURRENT_DISK_GB" ]]; then
            echo "Must be larger than current size (${CURRENT_DISK_GB} GB). Tart can only grow disks."
            continue
        fi
        growth=$(( SIZE_GB - CURRENT_DISK_GB ))
        if [[ -n "$HOST_FREE_GB" && "$growth" -gt "$HOST_FREE_GB" ]]; then
            echo "Warning: This will add ${growth} GB but only ${HOST_FREE_GB} GB is free on the host."
            read -r -p "Continue anyway? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || continue
        fi
        break
    done
fi

# --- Interactive: confirm OS type if not explicit ---
if [[ "$GUEST_OS_EXPLICIT" == false ]]; then
    echo ""
    read -r -p "Detected OS: ${GUEST_OS}. Correct? [Y/n] " os_confirm
    if [[ "$os_confirm" =~ ^[Nn]$ ]]; then
        if [[ "$GUEST_OS" == "macos" ]]; then
            GUEST_OS="linux"
        else
            GUEST_OS="macos"
        fi
        echo "Changed to: ${GUEST_OS}"
    fi
fi

# --- Validate size vs current (for CLI path) ---
if [[ "$SIZE_GB" -le "$CURRENT_DISK_GB" ]]; then
    echo "Error: Target size (${SIZE_GB} GB) must be larger than current size (${CURRENT_DISK_GB} GB)."
    echo "       (Tart can only grow disks, not shrink them.)"
    exit 1
fi

echo "Resizing '$VM_NAME' (${GUEST_OS}) from ${CURRENT_DISK_GB} GB to ${SIZE_GB} GB..."

# --- Step 1: Resize virtual disk (host-side) ---
DISK_IMG="$HOME/.tart/vms/$VM_NAME/disk.img"

resize_disk() {
    local disk_size_before disk_size_after
    disk_size_before=$(stat -f%z "$DISK_IMG")
    if ! RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$SIZE_GB" 2>&1); then
        echo "$RESIZE_OUT"
        return 1
    fi
    disk_size_after=$(stat -f%z "$DISK_IMG")
    if [[ "$disk_size_after" -le "$disk_size_before" ]]; then
        echo "Disk image did not grow — already at target size."
        exit 0
    fi
}

if ! resize_disk; then
    if [[ "$STATE" == "running" ]]; then
        echo "Failed to resize disk on running VM."
        read -r -p "Stop the VM and retry? [y/N] " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            echo "Stopping '$VM_NAME'..."
            tart stop "$VM_NAME"
            WE_STOPPED_VM=true
            STATE="stopped"
            resize_disk
        else
            exit 1
        fi
    else
        echo "Error: Failed to resize disk."
        exit 1
    fi
fi
echo "Virtual disk resized to ${SIZE_GB} GB."

# --- Step 2: Remove macOS recovery partition (stopped VMs only) ---
if [[ "$GUEST_OS" == "macos" && "$STATE" != "running" ]]; then
    if ! command -v sgdisk &>/dev/null; then
        echo "Warning: sgdisk not found (install with: brew install gptfdisk)."
        echo "         Skipping recovery partition removal — guest resize may fail."
    else
        PART_COUNT=$(sgdisk -p "$DISK_IMG" 2>/dev/null | grep -c '^ *[0-9]' || true)
        if [[ "$PART_COUNT" -eq 3 ]]; then
            echo "Removing macOS recovery partition..."
            sgdisk -d 3 "$DISK_IMG"
            echo "Recovery partition removed."
        fi
    fi
fi

# --- Step 3: Ensure VM is running & SSH-accessible ---
VM_IP=""
if [[ "$STATE" == "running" ]]; then
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        echo "Error: Could not get IP for running VM."
        exit 1
    fi
    echo "VM is running at $VM_IP."
elif [[ "$STATE" == "suspended" ]]; then
    echo "VM is suspended — stopping first to avoid resuming with changed disk..."
    tart stop "$VM_NAME" 2>/dev/null || true
    WE_STOPPED_VM=true
    start_vm_headless
else
    # stopped (or we stopped it)
    start_vm_headless
fi

# --- Step 4: Guest-side filesystem expansion ---
expand_guest_macos() {
    echo "Expanding macOS APFS container..."
    vm_ssh "yes | sudo diskutil repairDisk disk0" || true
    if ! vm_ssh 'APFS=$(diskutil list physical disk0 | grep "Apple_APFS " | grep -v ISC | awk "{print \$NF}") && [ -n "$APFS" ] && sudo diskutil apfs resizeContainer "$APFS" 0'; then
        return 1
    fi
}

expand_guest_linux() {
    echo "Expanding Linux filesystem..."
    vm_ssh "command -v growpart >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq cloud-guest-utils; }" || {
        echo "Error: Could not install growpart."
        exit 1
    }
    vm_ssh "sudo growpart /dev/vda 1"
    vm_ssh 'FSTYPE=$(lsblk -no FSTYPE /dev/vda1 | head -1); if [ "$FSTYPE" = "xfs" ]; then sudo xfs_growfs /; else sudo resize2fs /dev/vda1; fi'
}

if [[ "$GUEST_OS" == "macos" ]]; then
    if ! expand_guest_macos; then
        echo ""
        echo "Guest-side APFS resize failed."
        if [[ "$WE_STOPPED_VM" == false && "$WE_STARTED_VM" == false ]]; then
            # VM was already running — offer to stop, fix recovery partition, and retry
            echo "This may be because the recovery partition still exists."
            read -r -p "Stop the VM, remove recovery partition, and retry? [y/N] " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                echo "Stopping '$VM_NAME'..."
                tart stop "$VM_NAME"
                WE_STOPPED_VM=true

                if ! command -v sgdisk &>/dev/null; then
                    echo "Error: sgdisk not found (install with: brew install gptfdisk)."
                    exit 1
                fi

                PART_COUNT=$(sgdisk -p "$DISK_IMG" 2>/dev/null | grep -c '^ *[0-9]' || true)
                if [[ "$PART_COUNT" -eq 3 ]]; then
                    echo "Removing recovery partition..."
                    sgdisk -d 3 "$DISK_IMG"
                fi

                start_vm_headless
                if ! expand_guest_macos; then
                    echo "Error: Guest-side resize failed after recovery partition removal."
                    exit 1
                fi
            else
                exit 1
            fi
        else
            echo "Error: Guest-side APFS resize failed."
            exit 1
        fi
    fi
else
    expand_guest_linux
fi

# --- Step 5: Verify ---
echo ""
echo "Disk resize complete."
echo ""
vm_ssh "df -h /"

# --- Step 6: Cleanup ---
# The EXIT trap handles stopping the VM if WE_STARTED_VM is true.
# If VM was originally running and we didn't stop it, leave it running.
if [[ "$WE_STARTED_VM" == true ]]; then
    echo ""
    echo "VM was not running before resize — stopping it now."
    # The trap will handle this, but we do it explicitly for the message.
    tart stop "$VM_NAME" 2>/dev/null || true
    WE_STARTED_VM=false  # Prevent trap from double-stopping
fi
