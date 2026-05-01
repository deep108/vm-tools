#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
DISK_GB=""
BASE_IMAGE=""
BASE_IMAGE_SET=false
HEADLESS=false
GUEST_OS="macos"
LINUX_DISTRO="debian"
VM_NAME=""
NO_XCODE=false
XCODE_VERSION="--latest"
ANDROID=false
NON_INTERACTIVE=false
NO_SIGNING=false

# --- Usage ---
usage() {
    echo "Usage: $0 <vm-name> [--linux] [--ubuntu] [--disk <GB>] [--base <image>] [--headless] [--no-xcode] [--xcode-version <ver>] [--android] [--no-signing]"
    echo ""
    echo "  <vm-name>             Required. Name for the new Tart VM."
    echo "  --linux               Create a Linux VM (default: Debian Trixie)."
    echo "  --ubuntu              Use Ubuntu 24.04 instead of Debian (implies --linux)."
    echo "  --disk <GB>           Disk size in GB (default: 80 for macOS, 20 for Linux)."
    echo "  --base <image>        Source Tart image to clone."
    echo "  --headless            Run VM without a UI window."
    echo "  --no-xcode            Skip Xcode installation (for quick test provisions)."
    echo "  --xcode-version <ver> Xcode version to install (default: latest stable)."
    echo "  --android             Install Android dev tools (macOS: Android Studio + SDK;"
    echo "                        Linux: IntelliJ IDEA CE + SDK + XFCE desktop)."
    echo "                        Emulator runs on host — use start-android-dev.sh."
    echo "  --non-interactive     Skip prompts; use 'admin' as password (for testing)."
    echo "  --no-signing          Skip git SSH signing-key setup (default: enabled)."
    exit 1
}

# --- Parse args ---
[[ $# -eq 0 ]] && usage

VM_NAME="${1}"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)
            [[ -z "${2:-}" ]] && { echo "Error: --disk requires a value"; usage; }
            DISK_GB="$2"
            shift 2
            ;;
        --linux)
            GUEST_OS="linux"
            shift
            ;;
        --ubuntu)
            GUEST_OS="linux"
            LINUX_DISTRO="ubuntu"
            shift
            ;;
        --base)
            [[ -z "${2:-}" ]] && { echo "Error: --base requires a value"; usage; }
            BASE_IMAGE="$2"
            BASE_IMAGE_SET=true
            shift 2
            ;;
        --headless)
            HEADLESS=true
            shift
            ;;
        --no-xcode)
            NO_XCODE=true
            shift
            ;;
        --android)
            ANDROID=true
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --no-signing)
            NO_SIGNING=true
            shift
            ;;
        --xcode-version)
            [[ -z "${2:-}" ]] && { echo "Error: --xcode-version requires a value"; usage; }
            XCODE_VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

[[ -z "$VM_NAME" ]] && { echo "Error: <vm-name> is required"; usage; }

# --non-interactive can't prompt for a passphrase; signing requires one.
if [[ "$NON_INTERACTIVE" == true ]]; then
    NO_SIGNING=true
fi

# Set default disk size based on guest OS (if not explicitly provided)
if [[ -z "$DISK_GB" ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        DISK_GB=20
    else
        DISK_GB=80
    fi
fi

# Set default base image based on guest OS (if not explicitly provided)
if [[ "$BASE_IMAGE_SET" == false ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        if [[ "$LINUX_DISTRO" == "ubuntu" ]]; then
            BASE_IMAGE="ghcr.io/cirruslabs/ubuntu:24.04"
        else
            BASE_IMAGE="ghcr.io/cirruslabs/debian:trixie"
        fi
    else
        BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
    fi
fi

# sshpass is required for early provisioning (vanilla macOS and Linux have no guest agent)
if ! command -v sshpass &>/dev/null; then
    echo "Error: 'sshpass' is required for VM provisioning."
    echo "Install with: brew install esolitos/ipa/sshpass"
    exit 1
fi

# sgdisk is required for macOS disk resize (removing recovery partition from GPT)
if [[ "$GUEST_OS" == "macos" ]] && ! command -v sgdisk &>/dev/null; then
    echo "Error: 'sgdisk' is required for macOS VM disk resize."
    echo "Install with: brew install gptfdisk"
    exit 1
fi

HOST_USER="$(whoami)"

# --- Traps (set early so Ctrl-C is handled at any point) ---
VM_CLONED=false
INTERRUPTED=false

cleanup() {
    [[ "$VM_CLONED" != true ]] && return
    if [[ "$INTERRUPTED" == true ]]; then
        echo ""
        echo "Interrupted — cleaning up VM '$VM_NAME'..."
    else
        echo ""
        echo "Provisioning failed — cleaning up VM '$VM_NAME'..."
    fi
    tart stop "$VM_NAME" 2>/dev/null || true
    # Remove known_hosts entry for this VM's IP (added by ssh-keyscan in step 22,
    # or by a previous run that got the same DHCP IP).
    local ip
    ip=$(tart ip "$VM_NAME" 2>/dev/null || true)
    [[ -n "$ip" ]] && ssh-keygen -R "$ip" 2>/dev/null || true
    tart delete "$VM_NAME" 2>/dev/null || true
    echo "      Done."
}

trap cleanup EXIT
trap 'INTERRUPTED=true; exit 130' INT TERM

# --- Helper functions ---
# VM_IP is set during step 6; SSH-based functions only work after that.
SSH_BASE="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# vm_exec: password auth to admin — disable pubkey so the agent's keys don't
# exhaust MaxAuthTries before sshpass can send the password.
SSH_PASS="$SSH_BASE -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password"
# vm_exec_user: key-based auth to the provisioned user (after step 9).
SSH_KEY="$SSH_BASE -o IdentitiesOnly=yes"

vm_exec() {
    sshpass -p admin ssh $SSH_PASS admin@"$VM_IP" "$@"
}

vm_exec_user() {
    local cmd="$1"
    # Pass command via stdin (herestring) to avoid single-quote escaping issues.
    # Using -s makes the shell read commands from stdin.
    if [[ "$GUEST_OS" == "linux" ]]; then
        # Early steps (10-13) run before zsh is installed by bootstrap — use bash.
        # Post-bootstrap steps that need Homebrew/mise should use vm_exec_user_zsh.
        ssh $SSH_KEY "$HOST_USER@$VM_IP" "bash -l -s" <<< "$cmd"
    else
        # GIT_CONFIG_COUNT overrides the Xcode CLT system gitconfig's credential.helper=osxkeychain.
        # The osxkeychain helper requires a GUI session and fails over non-interactive SSH with
        # "could not read Username". Setting credential.helper to empty disables it.
        ssh $SSH_KEY "$HOST_USER@$VM_IP" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= zsh -l -s" <<< "$cmd"
    fi
}

# Like vm_exec_user but uses zsh on Linux (required for Homebrew/mise PATH).
# Only usable after bootstrap (step 13) installs zsh and chezmoi applies .zprofile.
vm_exec_user_zsh() {
    local cmd="$1"
    if [[ "$GUEST_OS" == "linux" ]]; then
        ssh $SSH_KEY "$HOST_USER@$VM_IP" "zsh -l -s" <<< "$cmd"
    else
        # macOS vm_exec_user already uses zsh
        vm_exec_user "$cmd"
    fi
}

# For commands requiring GUI/WindowServer access (tart guest agent, post-reboot only)
vm_exec_gui() {
    tart exec "$VM_NAME" "$@"
}

# --- Detect local base image ---
# Registry images contain '/' (e.g. ghcr.io/cirruslabs/...), local VMs are plain names.
LOCAL_BASE=false
if [[ "$BASE_IMAGE" != */* ]]; then
    LOCAL_BASE=true
fi

# Read base image's vm-tools metadata (if any) so we can flag non-golden bases.
BASE_GOLDEN_IMAGE=""
BASE_GOLDEN_PREPARED_AT=""
BASE_VM_TOOLS_REV=""
if [[ "$LOCAL_BASE" == true ]]; then
    BASE_META="$HOME/.tart/vms/$BASE_IMAGE/vm-tools-meta"
    if [[ -f "$BASE_META" ]]; then
        BASE_GOLDEN_IMAGE=$(grep '^golden_image=' "$BASE_META" | cut -d= -f2-)
        BASE_GOLDEN_PREPARED_AT=$(grep '^golden_prepared_at=' "$BASE_META" | cut -d= -f2-)
        BASE_VM_TOOLS_REV=$(grep '^vm_tools_rev=' "$BASE_META" | cut -d= -f2-)
    fi
fi

echo "=== Provision VM: $VM_NAME ==="
echo "  Guest OS   : ${GUEST_OS}$(if [[ "$GUEST_OS" == "linux" ]]; then echo " ($LINUX_DISTRO)"; fi)"
echo "  Base image : $BASE_IMAGE"
echo "  Disk size  : ${DISK_GB} GB"
echo "  Headless   : $HEADLESS"
echo "  Host user  : $HOST_USER"
if [[ "$LOCAL_BASE" == false ]]; then
    echo "  Local base : false"
elif [[ "$BASE_GOLDEN_IMAGE" == "true" ]]; then
    echo "  Local base : true (golden image, prepared ${BASE_GOLDEN_PREPARED_AT:-unknown}${BASE_VM_TOOLS_REV:+, vm-tools@$BASE_VM_TOOLS_REV})"
else
    echo "  Local base : true (NOT a prepared golden image — see warning below)"
fi
if [[ "$GUEST_OS" == "macos" ]]; then
    echo "  Xcode      : $(if [[ "$NO_XCODE" == true ]]; then echo "skip"; else echo "$XCODE_VERSION"; fi)"
fi
if [[ "$ANDROID" == true ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        echo "  Android    : true (IntelliJ IDEA CE + SDK + XFCE)"
    else
        echo "  Android    : true (Android Studio + SDK)"
    fi
    echo "               Emulator runs on host (start-android-dev.sh)"
fi
echo ""

if [[ "$LOCAL_BASE" == true && "$BASE_GOLDEN_IMAGE" != "true" ]]; then
    PREP_FLAG=""
    [[ "$GUEST_OS" == "linux" ]] && PREP_FLAG=" --linux"
    echo "  WARNING: base image '$BASE_IMAGE' was not prepared via prepare-golden-image.sh."
    echo "           User SSH keys (id_ed25519, signing key, mac-host-git) may be inherited"
    echo "           from the source VM, which means multiple VMs could end up sharing keys."
    echo "           For a clean start, abort (Ctrl-C) and run:"
    echo "               $SCRIPT_DIR/prepare-golden-image.sh $BASE_IMAGE$PREP_FLAG"
    echo "           ...before re-running this provision."
    echo ""
fi

# --- Prompt for credentials upfront (so provisioning can run unattended after this point,
# except for the Xcode 2FA prompt which requires interaction) ---
PASSWORD=""
APPLE_ID=""
APPLE_PASSWORD=""
SIGNING_PASSPHRASE=""
if [[ "$LOCAL_BASE" == false ]]; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        PASSWORD="admin"
        echo "Non-interactive mode: using default password."
    else
        while true; do
            read -s -p "Password for new user '$HOST_USER': " PASSWORD
            echo
            read -s -p "Confirm password: " PASSWORD_CONFIRM
            echo
            if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
                break
            else
                echo "Passwords do not match. Please try again."
            fi
        done
        if [[ "$GUEST_OS" == "macos" && "$NO_XCODE" == false ]]; then
            echo ""
            echo "Xcode installation requires an Apple ID."
            read -p "Apple ID email: " APPLE_ID
            read -s -p "Apple ID password: " APPLE_PASSWORD
            echo
        fi
    fi
    echo ""
fi

# Signing passphrase: prompt only when we'll actually generate a key. Fresh provisions
# (LOCAL_BASE=false) and clone-from-golden (LOCAL_BASE=true with golden_image=true)
# both need a fresh keygen. Re-provisioning a VM whose key already exists doesn't.
if [[ "$NO_SIGNING" == false ]]; then
    if [[ "$LOCAL_BASE" == false || "$BASE_GOLDEN_IMAGE" == "true" ]]; then
        echo "Git signing key passphrase (blank = unencrypted):"
        while true; do
            read -s -p "  Passphrase: " SIGNING_PASSPHRASE
            echo
            read -s -p "  Confirm:    " SIGNING_PASSPHRASE_CONFIRM
            echo
            if [[ "$SIGNING_PASSPHRASE" == "$SIGNING_PASSPHRASE_CONFIRM" ]]; then
                break
            else
                echo "  Passphrases do not match. Please try again."
            fi
        done
        echo ""
    fi
fi

# --- [1/23] Check for conflicts ---
echo "[1/23] Checking for existing VM..."
if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists. Delete it first with: tart delete $VM_NAME"
    exit 1
fi
echo "       OK — no conflict."

# --- [2/23] Pull latest base image (skip for local VMs) ---
if [[ "$BASE_IMAGE" == */* ]]; then
    echo "[2/23] Pulling latest '$BASE_IMAGE'..."
    tart pull "$BASE_IMAGE"
    echo "       Done."
else
    echo "[2/23] Using local VM '$BASE_IMAGE' as base (skipping pull)."
    if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$BASE_IMAGE"; then
        echo "Error: Local VM '$BASE_IMAGE' not found. Run 'tart list' to see available VMs."
        exit 1
    fi
fi

# --- [3/23] Clone base image ---
echo "[3/23] Cloning '$BASE_IMAGE' -> '$VM_NAME'..."
tart clone "$BASE_IMAGE" "$VM_NAME"
VM_CLONED=true
echo "       Done."

# --- [4/23] Resize disk (and set resources for Linux Android VMs) ---
DISK_GREW=false
DISK_IMG="$HOME/.tart/vms/$VM_NAME/disk.img"
DISK_SIZE_BEFORE=$(stat -f%z "$DISK_IMG")
echo "[4/23] Setting disk size to ${DISK_GB} GB..."
if RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$DISK_GB" 2>&1); then
    DISK_SIZE_AFTER=$(stat -f%z "$DISK_IMG")
    if [[ "$DISK_SIZE_AFTER" -gt "$DISK_SIZE_BEFORE" ]]; then
        DISK_GREW=true
        echo "       Done."
    else
        echo "       (Already ${DISK_GB} GB — no resize needed.)"
    fi
else
    echo "       Warning: could not resize disk: $RESIZE_OUT"
    echo "       (Disks can only grow, not shrink. Continuing with base image disk size.)"
fi
if [[ "$GUEST_OS" == "linux" && "$ANDROID" == true ]]; then
    echo "       Setting resources for Android dev (4 CPUs, 8 GB RAM, 1920x1200)..."
    tart set "$VM_NAME" --cpu 4 --memory 8192 --display 1920x1200
    echo "       Done."
fi

# Remove recovery partition from disk image (host-side, before boot) so the APFS container
# can grow into the space freed by tart set --disk-size. The base image layout is:
#   1=Apple_APFS_ISC | 2=Apple_APFS (container) | 3=Apple_APFS_Recovery
# diskutil refuses to erase APFS Recovery containers, so we use sgdisk to delete the
# partition entry directly from the GPT (operates on the raw file, no hdiutil needed).
# Skip entirely if disk didn't grow (golden images already have recovery removed).
if [[ "$GUEST_OS" == "macos" && "$DISK_GREW" == true ]]; then
    if [[ ! -f "$DISK_IMG" ]]; then
        echo "Error: Disk image not found at $DISK_IMG"
        exit 1
    fi
    PART_COUNT=$(sgdisk -p "$DISK_IMG" 2>/dev/null | grep -c '^ *[0-9]')
    if [[ "$PART_COUNT" -eq 3 ]]; then
        sgdisk -d 3 "$DISK_IMG"
    fi
fi

# --- [5/23] Start VM ---
echo "[5/23] Starting VM..."
TART_RUN_ARGS=("$VM_NAME")
if [[ "$HEADLESS" == true ]]; then
    TART_RUN_ARGS+=(--no-graphics)
fi
# Note: --nested no longer needed — emulator runs on host, not in VM
tart run "${TART_RUN_ARGS[@]}" &
TART_PID=$!
echo "       VM started (PID $TART_PID)."

# --- [6/23] Wait for SSH ---
CONNECT_TIMEOUT=120
CONNECT_START=$(date +%s)

printf "[6/23] Waiting for VM IP..."
VM_IP=""
while [[ -z "$VM_IP" ]]; do
    CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
    if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
        printf "\n"
        echo "Error: Timed out waiting for VM IP after ${CONNECT_TIMEOUT}s."
        exit 1
    fi
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    [[ -z "$VM_IP" ]] && sleep 2
done
printf "\r[6/23] Got VM IP: $VM_IP. Waiting for SSH...%-10s\n"

while true; do
    CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
    if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
        echo "Error: Timed out waiting for SSH after ${CONNECT_TIMEOUT}s."
        exit 1
    fi
    printf "\r[6/23] Waiting for SSH... %ds" "$CONNECT_ELAPSED"
    if sshpass -p admin ssh $SSH_PASS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null; then
        break
    fi
    sleep 2
done
printf "\r[6/23] SSH ready.%-30s\n" ""

# --- [7/23] Regenerate SSH host keys (cloned VMs share the base image's keys) ---
echo "[7/23] Regenerating SSH host keys..."
if [[ "$GUEST_OS" == "linux" ]]; then
    # Run as a single command string — restarting sshd kills our SSH connection,
    # so we combine everything and tolerate the connection drop.
    # Ubuntu uses 'ssh', Debian uses 'sshd' — try both
    vm_exec "sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && (sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh)" || true
else
    vm_exec "sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo launchctl kickstart -k system/com.openssh.sshd" || true
fi
# Wait for sshd to come back up with the new keys
sleep 2
for _ in $(seq 1 10); do
    sshpass -p admin ssh $SSH_PASS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null && break
    sleep 1
done
echo "       Done."

# Resize APFS container to fill the disk (recovery partition was removed host-side in step 4)
if [[ "$GUEST_OS" == "macos" && "$DISK_GREW" == true ]]; then
    vm_exec "yes | sudo diskutil repairDisk disk0"
    vm_exec "APFS=\$(diskutil list physical disk0 | grep 'Apple_APFS ' | grep -v ISC | awk '{print \$NF}') && \
        [ -n \"\$APFS\" ] && sudo diskutil apfs resizeContainer \"\$APFS\" 0"
fi

# --- [8/23] Create user (skip for local base — user already exists) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[8/23] Creating user '$HOST_USER' on VM..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        PASS_HASH=$(openssl passwd -6 "$PASSWORD")
        vm_exec sudo useradd -m -s /bin/bash -G sudo -p "'$PASS_HASH'" "$HOST_USER"
        vm_exec "echo '$HOST_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$HOST_USER > /dev/null && sudo chmod 440 /etc/sudoers.d/$HOST_USER"
    else
        # Fetch version strings before user creation (sysadminctl disrupts admin SSH)
        VM_BUILD=$(vm_exec "sw_vers -buildVersion")
        VM_VERSION=$(vm_exec "sw_vers -productVersion")
        # Run everything in a single SSH session — sysadminctl disrupts the admin
        # account's SSH auth, so subsequent vm_exec calls would fail.
        vm_exec "sudo sysadminctl -addUser '$HOST_USER' -fullName '$HOST_USER' -password '$PASSWORD' -admin && \
            echo '$HOST_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$HOST_USER > /dev/null && \
            sudo chmod 440 /etc/sudoers.d/$HOST_USER && \
            sudo -Hu '$HOST_USER' bash -c '
                defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true
                defaults write com.apple.SetupAssistant DidSeePrivacy -bool true
                defaults write com.apple.SetupAssistant DidSeeSiriSetup -bool true
                defaults write com.apple.SetupAssistant DidSeeAccessibility -bool true
                defaults write com.apple.SetupAssistant DidSeeAppearanceSetup -bool true
                defaults write com.apple.SetupAssistant DidSeeScreenTime -bool true
                defaults write com.apple.SetupAssistant DidSeeiCloudLoginForStorageServices -bool true
                defaults write com.apple.SetupAssistant DidSeeTouchIDSetup -bool true
                defaults write com.apple.SetupAssistant DidSeeLockdownMode -bool true
                defaults write com.apple.SetupAssistant DidSeeTermsOfAddress -bool true
                defaults write com.apple.SetupAssistant LastSeenCloudProductVersion $VM_VERSION
                defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion $VM_BUILD
                defaults write com.apple.SetupAssistant LastSeenDiagnosticsProductVersion $VM_VERSION
                defaults write com.apple.SetupAssistant LastSeenSiriProductVersion $VM_VERSION
                defaults write com.apple.SetupAssistant LastPreLoginTasksPerformedBuild $VM_BUILD
                defaults write com.apple.SetupAssistant LastPreLoginTasksPerformedVersion $VM_VERSION
                defaults write com.apple.SetupAssistant MiniBuddyShouldLaunchToResumeSetup -bool false
                defaults write com.apple.SetupAssistant selectedFDEEscrowType -string DeclinedFDE
                defaults write NSGlobalDomain AppleInterfaceStyle Dark
            '"
    fi
    echo "       User created."
else
    echo "[8/23] Skipping user creation (local base — '$HOST_USER' already exists)."
fi

# --- [9/23] Install/update SSH public key for user ---
if [[ "$LOCAL_BASE" == true ]]; then
    echo "[9/23] Skipping SSH key install (local base — key already in place)."
else
    echo "[9/23] Installing SSH public key for '$HOST_USER'..."
    SSH_PUBKEY=""
    for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        if [[ -f "$key_file" ]]; then
            SSH_PUBKEY=$(cat "$key_file")
            break
        fi
    done
    if [[ -n "$SSH_PUBKEY" ]]; then
        if [[ "$GUEST_OS" == "linux" ]]; then
            # Use sshpass with the new user's password — admin SSH can become
            # unreliable after useradd on Debian (same pattern as macOS below).
            HOME_DIR="/home/$HOST_USER"
            for _ in $(seq 1 15); do
                sshpass -p "$PASSWORD" ssh $SSH_PASS -o ConnectTimeout=2 "$HOST_USER@$VM_IP" true 2>/dev/null && break
                sleep 2
            done
            sshpass -p "$PASSWORD" ssh $SSH_PASS "$HOST_USER@$VM_IP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$SSH_PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        else
            # Use sshpass with the new user's password — after sysadminctl creates a user,
            # admin SSH may become temporarily unreliable on macOS.
            HOME_DIR="/Users/$HOST_USER"
            # Wait for the new user's SSH to become available
            for _ in $(seq 1 15); do
                sshpass -p "$PASSWORD" ssh $SSH_PASS -o ConnectTimeout=2 "$HOST_USER@$VM_IP" true 2>/dev/null && break
                sleep 2
            done
            sshpass -p "$PASSWORD" ssh $SSH_PASS "$HOST_USER@$VM_IP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$SSH_PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        fi
        echo "       Done."
    else
        echo "       Warning: no SSH public key found in ~/.ssh — skipping."
    fi
fi

# --- [10/23] Set computer name and timezone ---
echo "[10/23] Setting computer name to '$VM_NAME'..."
HOST_TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec_user "sudo hostnamectl set-hostname '$VM_NAME'"
    vm_exec_user "sudo timedatectl set-timezone '$HOST_TZ'"
else
    # LocalHostName only allows alphanumerics and hyphens (used for Bonjour .local)
    LOCAL_HOSTNAME="${VM_NAME//_/-}"
    LOCAL_HOSTNAME="${LOCAL_HOSTNAME//[^a-zA-Z0-9-]/}"
    vm_exec_user "sudo scutil --set ComputerName '$VM_NAME'"
    vm_exec_user "sudo scutil --set HostName '$VM_NAME'"
    vm_exec_user "sudo scutil --set LocalHostName '$LOCAL_HOSTNAME'"
    vm_exec_user "sudo systemsetup -settimezone '$HOST_TZ'" 2>/dev/null
fi
echo "       Done (timezone: $HOST_TZ)."

# Generate outbound SSH keypair so the VM can SSH to GitHub, Hetzner, etc.
# Idempotent: preserves an existing key on local-base re-provisions.
echo "        Ensuring outbound SSH keypair (id_ed25519) exists..."
vm_exec_user "[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C '$HOST_USER@$VM_NAME'"

# --- [11/23] Install Homebrew and git ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[11/23] Installing Homebrew and git..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec_user "sudo apt-get update -qq"
        vm_exec_user "sudo apt-get install -y -qq git"
    else
        # Vanilla macOS has no git and no Homebrew. The Homebrew installer auto-detects
        # the missing Xcode CLT and installs it (which provides git, clang, make, etc.).
        # Retry once — the Homebrew CDN/GitHub can occasionally hiccup.
        vm_exec_user "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | NONINTERACTIVE=1 /bin/bash" || {
            echo "        Homebrew install failed — retrying in 5s..."
            sleep 5
            vm_exec_user "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | NONINTERACTIVE=1 /bin/bash"
        }
    fi
    echo "        Done."
else
    echo "[11/23] Skipping Homebrew/git install (local base)."
fi

# --- [12/23] Clone or update vm-tools ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[12/23] Cloning vm-tools into VM..."
    vm_exec_user "mkdir -p ~/dev && git clone https://github.com/deep108/vm-tools.git ~/dev/vm-tools"
    echo "        Done."
else
    echo "[12/23] Updating vm-tools in VM..."
    vm_exec_user "cd ~/dev/vm-tools && git pull"
    echo "        Done."
fi

# --- [13/23] Run bootstrap ---
echo "[13/23] Running bootstrap..."

# Propagate git identity from host before bootstrap so user.name / user.email
# don't need to be hardcoded in dotfiles. Idempotent: if host has no global
# git identity (rare), guest user can configure it later.
HOST_GIT_NAME=$(git config --global user.name 2>/dev/null || true)
HOST_GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
if [[ -n "$HOST_GIT_NAME" && -n "$HOST_GIT_EMAIL" ]]; then
    echo "        Propagating git identity from host: $HOST_GIT_NAME <$HOST_GIT_EMAIL>"
    vm_exec_user "git config --global user.name '$HOST_GIT_NAME'"
    vm_exec_user "git config --global user.email '$HOST_GIT_EMAIL'"
else
    echo "        Host has no global git identity; skipping (configure later via 'git config --global')"
fi

if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec_user "bash ~/dev/vm-tools/scripts/bootstrap-linux.sh"
else
    vm_exec_user "~/dev/vm-tools/scripts/bootstrap.sh"
fi
echo "        Bootstrap complete."

# Strip Gatekeeper quarantine from apps installed by brew cask (avoids "downloaded from the internet" dialogs)
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    vm_exec_user "sudo xattr -dr com.apple.quarantine /Applications/Visual\ Studio\ Code.app /Applications/iTerm.app 2>/dev/null" || true
    # Clean up Homebrew download cache from bootstrap installs
    vm_exec_user "brew cleanup --prune=all"
fi

# --- [14/23] Set up git SSH signing key ---
if [[ "$NO_SIGNING" == true ]]; then
    echo "[14/23] Skipping git SSH signing setup (--no-signing)."
else
    echo "[14/23] Setting up git SSH signing key..."
    # Run keygen only on paths where we prompted for a passphrase upfront —
    # fresh provisions or golden-image clones (where the source's signing key
    # was cleaned by prepare-golden-image.sh). LOCAL_BASE re-provisions skip
    # keygen and rely on the existing key. The empty-passphrase case (user
    # chose unencrypted) still runs keygen with -N ''.
    if [[ "$LOCAL_BASE" == false || "$BASE_GOLDEN_IMAGE" == "true" ]]; then
        # NOTE: passing the passphrase via -N momentarily exposes it on the VM's
        # process list. Acceptable for a single-user dev VM.
        vm_exec_user "[ -f ~/.ssh/id_ed25519_signing ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_signing -N '$SIGNING_PASSPHRASE' -C '$HOST_USER@$VM_NAME (git-signing)'"
    fi
    # Verify the key exists before writing config that references it.
    if vm_exec_user "test -f ~/.ssh/id_ed25519_signing"; then
        vm_exec_user "git config --global gpg.format ssh"
        vm_exec_user "git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub"
        vm_exec_user "git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers"
        # Rewrite allowed_signers from current user.email + signing pubkey, so an
        # updated email flows through on re-provision.
        vm_exec_user 'mkdir -p ~/.config/git && \
            EMAIL=$(git config --global user.email) && \
            PUBKEY=$(cat ~/.ssh/id_ed25519_signing.pub) && \
            echo "$EMAIL $PUBKEY" > ~/.config/git/allowed_signers'
        echo "        Done."
    else
        echo "        WARNING: signing key missing on VM and no passphrase to generate one."
        echo "                 Skipping git config. To set up signing later, run on the VM:"
        echo "                   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_signing -C '$HOST_USER@$VM_NAME (git-signing)'"
        echo "                 ...then re-run this provision."
    fi
fi

# --- [15/23] Install Xcode (macOS only, fresh provision, skip with --no-xcode) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false && "$NO_XCODE" == false ]]; then
    echo "[15/23] Installing Xcode..."
    # Pre-tap manually: brew's internal git doesn't inherit GIT_CONFIG_COUNT,
    # so the osxkeychain credential helper fails over SSH. Direct git clone works.
    # Tap is XcodesOrg/made (repo: XcodesOrg/homebrew-made).
    vm_exec_user "mkdir -p /opt/homebrew/Library/Taps/xcodesorg && git clone https://github.com/XcodesOrg/homebrew-made /opt/homebrew/Library/Taps/xcodesorg/homebrew-made"
    vm_exec_user "brew install xcodes aria2"
    # Use ssh -t for pseudo-TTY so Apple 2FA prompts flow through to the host terminal.
    # xcodes uses XCODES_USERNAME/XCODES_PASSWORD env vars for non-interactive auth.
    # Must run with sudo: xcodes uses its own privilege escalation (not sudo) for finishing
    # steps, which prompts for password and ignores sudoers. Running as root avoids this.
    # -E preserves XCODES_* env vars through sudo.
    ssh -t $SSH_KEY "$HOST_USER@$VM_IP" \
        "XCODES_USERNAME='$APPLE_ID' XCODES_PASSWORD='$APPLE_PASSWORD' zsh -l -c 'sudo -E xcodes install $XCODE_VERSION --experimental-unxip'"
    # Fix ownership: sudo -E runs as root with user's HOME, leaving root-owned cache files
    vm_exec_user "sudo chown -R \$(whoami) ~/Library/Application\ Support/com.robotsandpencils.xcodes 2>/dev/null" || true
    # Point xcode-select to the installed Xcode (xcodes names it Xcode-<ver>.app)
    vm_exec_user "sudo xcode-select -s /Applications/Xcode-*.app/Contents/Developer"
    vm_exec_user "sudo xcodebuild -license accept"
    vm_exec_user "sudo xcodebuild -runFirstLaunch"
    vm_exec_user "brew install cocoapods swiftlint swiftformat"
    # Clean up Xcode download cache (~7-12GB .xip file) and Homebrew cache
    vm_exec_user "rm -rf ~/Library/Application\ Support/com.robotsandpencils.xcodes"
    vm_exec_user "brew cleanup --prune=all"
    echo "        Xcode installed."
elif [[ "$GUEST_OS" == "macos" && "$NO_XCODE" == true ]]; then
    echo "[15/23] Skipping Xcode installation (--no-xcode)."
else
    echo "[15/23] Skipping Xcode installation (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [16/23] Install Android SDK (fresh provision, opt-in with --android) ---
if [[ "$LOCAL_BASE" == false && "$ANDROID" == true && "$GUEST_OS" == "macos" ]]; then
    echo "[16/23] Installing Android development tools (macOS)..."
    # Install Java via mise (used by sdkmanager, Gradle, Firebase emulators)
    # Android Studio bundles its own JDK internally — this Java is for CLI tools
    vm_exec_user "mise use -g java@temurin-21"
    vm_exec_user "brew install --cask android-studio"
    # Strip Gatekeeper quarantine from Android Studio
    vm_exec_user "sudo xattr -dr com.apple.quarantine /Applications/Android\ Studio.app 2>/dev/null" || true
    # Download Android command-line tools (avoids brew android-commandlinetools which pulls openjdk)
    vm_exec_user "export ANDROID_HOME=\$HOME/Library/Android/sdk && \
        mkdir -p \$ANDROID_HOME/cmdline-tools && \
        curl -fsSL https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip -o /tmp/cmdtools.zip && \
        unzip -qo /tmp/cmdtools.zip -d \$ANDROID_HOME/cmdline-tools && \
        mv \$ANDROID_HOME/cmdline-tools/cmdline-tools \$ANDROID_HOME/cmdline-tools/latest && \
        rm /tmp/cmdtools.zip"
    # Accept licenses and install SDK components
    vm_exec_user "export ANDROID_HOME=\$HOME/Library/Android/sdk && \
        export JAVA_HOME=\$(mise where java) && \
        yes | \$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses && \
        \$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager \
            'platform-tools' \
            'emulator' \
            'platforms;android-35' \
            'platforms;android-36' \
            'build-tools;35.0.0' \
            'build-tools;36.0.0' \
            'system-images;android-36;google_apis;arm64-v8a'"
    echo "        Done."
elif [[ "$LOCAL_BASE" == false && "$ANDROID" == true && "$GUEST_OS" == "linux" ]]; then
    echo "[16/23] Installing Android development tools (Linux)..."
    # Emulator runs on the host (Apple Silicon has no nested virt for macOS VMs,
    # and Cuttlefish in Linux VMs is too slow). This installs SDK + IDE for building
    # and editing; use start-android-dev.sh on the host for the emulator + ADB bridge.

    # --- System packages (XFCE desktop, x86_64 compat for SDK tools, unzip) ---
    echo "        Installing XFCE and dependencies..."
    vm_exec_user "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        xfce4 xfce4-terminal lightdm lightdm-gtk-greeter dbus-x11 qemu-user-static binfmt-support unzip"

    # --- x86_64 multiarch (Android SDK tools are x86_64-only on Linux) ---
    # Pin existing ARM64 sources so they don't try to fetch amd64 packages,
    # then add archive.ubuntu.com as amd64 source for the x86_64 runtime libs.
    echo "        Setting up x86_64 multiarch for Android tools..."
    vm_exec_user "sudo sed -i '/^Types: deb\$/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources && \
        sudo dpkg --add-architecture amd64 && \
        echo 'deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse' | \
            sudo tee /etc/apt/sources.list.d/amd64.list > /dev/null && \
        sudo apt-get update -qq && \
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libc6:amd64 libstdc++6:amd64 zlib1g:amd64"
    echo "        x86_64 multiarch configured."

    # Configure LightDM as default display manager + autologin
    vm_exec_user "sudo mkdir -p /etc/lightdm/lightdm.conf.d && \
        printf '[Seat:*]\nautologin-user=$HOST_USER\nautologin-user-timeout=0\nautologin-session=xfce\ngreeter-session=lightdm-gtk-greeter\n' | \
        sudo tee /etc/lightdm/lightdm.conf.d/50-autologin.conf > /dev/null && \
        echo '/usr/sbin/lightdm' | sudo tee /etc/X11/default-display-manager > /dev/null"
    echo "        XFCE installed."

    # --- Java via mise ---
    echo "        Installing Java (Temurin 21)..."
    vm_exec_user_zsh "mise use -g java@temurin-21"
    # Symlink to /usr/lib/jvm so IntelliJ auto-detects it (mise path is non-standard)
    vm_exec_user_zsh "sudo mkdir -p /usr/lib/jvm && sudo ln -sf \$(mise where java) /usr/lib/jvm/temurin-21"
    echo "        Java installed."

    # --- Desktop session environment ---
    # IntelliJ and other GUI apps launched from XFCE don't inherit mise's shell setup.
    # Write ~/.xsessionrc so JAVA_HOME, ANDROID_HOME, and PATH are set for the entire X session.
    vm_exec_user_zsh "JAVA_DIR=\$(mise where java) && \
        cat > \$HOME/.xsessionrc << XSESS
export JAVA_HOME=\$JAVA_DIR
export ANDROID_HOME=\$HOME/Android/Sdk
export PATH=\$JAVA_DIR/bin:\$HOME/Android/Sdk/platform-tools:\$HOME/Android/Sdk/cmdline-tools/latest/bin:\\\$PATH
XSESS"
    echo "        Desktop environment configured."

    # --- IntelliJ IDEA Community Edition (native ARM64) ---
    echo "        Installing IntelliJ IDEA CE..."
    # Fetch the latest ARM64 tar.gz URL from JetBrains data services
    # Key is "linuxARM64" (not "linux" — that's x86_64)
    IDEA_URL=$(curl -fsSL 'https://data.services.jetbrains.com/products/releases?code=IIC&latest=true&type=release' \
        | grep -o '"linuxARM64":{"link":"[^"]*"' | head -1 | grep -o 'https://[^"]*')
    if [[ -z "$IDEA_URL" ]]; then
        echo "        Error: Could not determine IntelliJ IDEA CE ARM64 download URL."
        exit 1
    fi
    echo "        Downloading from: $IDEA_URL"
    vm_exec_user "curl -fSL --retry 3 --retry-delay 5 '$IDEA_URL' -o /tmp/idea.tar.gz && \
        sudo tar -xzf /tmp/idea.tar.gz -C /opt && \
        sudo mv /opt/idea-IC-* /opt/idea-IC && \
        sudo ln -sf /opt/idea-IC/bin/idea /usr/local/bin/idea && \
        rm /tmp/idea.tar.gz"
    # Desktop entry for XFCE application menu
    IDEA_DESKTOP="[Desktop Entry]
Name=IntelliJ IDEA CE
Exec=/opt/idea-IC/bin/idea %f
Icon=/opt/idea-IC/bin/idea.svg
Type=Application
Categories=Development;IDE;
Terminal=false
StartupWMClass=jetbrains-idea-ce"
    vm_exec_user "echo '$IDEA_DESKTOP' | sudo tee /usr/share/applications/idea-ce.desktop > /dev/null"
    echo "        IntelliJ IDEA CE installed."

    # --- Android command-line tools ---
    echo "        Installing Android SDK..."
    vm_exec_user "export ANDROID_HOME=\$HOME/Android/Sdk && \
        mkdir -p \$ANDROID_HOME/cmdline-tools && \
        curl -fSL --retry 3 --retry-delay 5 https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o /tmp/cmdtools.zip && \
        unzip -qo /tmp/cmdtools.zip -d \$ANDROID_HOME/cmdline-tools && \
        mv \$ANDROID_HOME/cmdline-tools/cmdline-tools \$ANDROID_HOME/cmdline-tools/latest && \
        rm /tmp/cmdtools.zip"

    # Accept licenses and install SDK components (needs mise for JAVA_HOME).
    vm_exec_user_zsh "export ANDROID_HOME=\$HOME/Android/Sdk && \
        export JAVA_HOME=\$(mise where java) && \
        yes | \$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses && \
        \$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager \
            'platform-tools' \
            'platforms;android-35' \
            'platforms;android-36' \
            'build-tools;35.0.0' \
            'build-tools;36.0.0'"
    echo "        Android SDK installed."
    echo "        Done."
elif [[ "$ANDROID" != true ]]; then
    echo "[16/23] Skipping Android (--android not specified)."
else
    echo "[16/23] Skipping Android (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [17/23] Install tart-guest-agent (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[17/23] Installing tart-guest-agent..."
    # Pre-tap manually (same osxkeychain workaround as step 14)
    vm_exec_user "mkdir -p /opt/homebrew/Library/Taps/cirruslabs && git clone https://github.com/cirruslabs/homebrew-cli /opt/homebrew/Library/Taps/cirruslabs/homebrew-cli"
    vm_exec_user "brew install tart-guest-agent"
    # The brew formula only installs the binary — no launchd plists.
    # Fetch official plists from cirruslabs/macos-image-templates so we track upstream changes.
    # Two components: LaunchDaemon (tart exec) + LaunchAgent (clipboard, user session).
    PLIST_BASE="https://raw.githubusercontent.com/cirruslabs/macos-image-templates/main/data"
    vm_exec_user "curl -fsSL $PLIST_BASE/tart-guest-daemon.plist | sudo tee /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist > /dev/null"
    # Fix WorkingDirectory in agent plist: upstream hardcodes /Users/admin, patch in pipeline
    vm_exec_user "curl -fsSL $PLIST_BASE/tart-guest-agent.plist | sed s,/Users/admin,/var/empty, | sudo tee /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist > /dev/null"
    echo "        Done."
else
    echo "[17/23] Skipping tart-guest-agent (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [18/23] Set up VS Code serve-web (skip for local base — already configured) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[18/23] Setting up VS Code serve-web..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec_user "SERVICE_USER=$HOST_USER bash ~/dev/vm-tools/guest/setup-code-server-systemd.sh"
    else
        vm_exec_user "SERVICE_USER=$HOST_USER bash ~/dev/vm-tools/guest/setup-code-server-launch-agent.sh"
    fi
    echo "        Done."
else
    echo "[18/23] Skipping VS Code serve-web (local base — already configured)."
fi

# --- [19/23] Reboot VM and verify (macOS: guest agent; Linux Android: LightDM) ---
if [[ "$GUEST_OS" == "linux" && "$LOCAL_BASE" == false && "$ANDROID" == true ]]; then
    echo "[19/23] Rebooting Linux VM for LightDM..."
    vm_exec_user "sudo reboot" || true
    # Wait for SSH to come back (no guest agent on Linux)
    REBOOT_TIMEOUT=120
    REBOOT_START=$(date +%s)
    sleep 5  # give it time to actually go down
    while true; do
        REBOOT_ELAPSED=$(( $(date +%s) - REBOOT_START ))
        if [[ $REBOOT_ELAPSED -ge $REBOOT_TIMEOUT ]]; then
            printf "\n"
            echo "Error: Timed out waiting for SSH after reboot (${REBOOT_TIMEOUT}s)."
            exit 1
        fi
        printf "\r[19/23] Waiting for SSH after reboot... %ds" "$REBOOT_ELAPSED"
        if ssh $SSH_KEY -o ConnectTimeout=2 "$HOST_USER@$VM_IP" true 2>/dev/null; then
            break
        fi
        sleep 2
    done
    printf "\r[19/23] SSH ready after reboot.%-30s\n" ""
elif [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[19/23] Rebooting VM..."
    # Reboot via SSH — connection will drop, which is expected
    vm_exec_user "sudo /sbin/reboot" || true
    # Wait for guest agent to come back (verifies tart-guest-agent works for future use)
    REBOOT_TIMEOUT=180
    REBOOT_START=$(date +%s)
    while true; do
        tart exec "$VM_NAME" true 2>/dev/null &
        PROBE_PID=$!
        for _ in 1 2 3; do
            REBOOT_ELAPSED=$(( $(date +%s) - REBOOT_START ))
            if [[ $REBOOT_ELAPSED -ge $REBOOT_TIMEOUT ]]; then
                kill -9 "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
                printf "\n"
                echo "Error: Timed out waiting for guest agent after reboot (${REBOOT_TIMEOUT}s)."
                # Diagnose via SSH (VM may be up but guest agent not running)
                echo "        Diagnosing via SSH..."
                echo "        Console user: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "stat -f '%Su' /dev/console" 2>/dev/null || echo 'SSH failed')"
                echo "        Guest agent process: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "pgrep -l tart-guest-agent" 2>/dev/null || echo 'not running')"
                echo "        LaunchDaemon plist: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "ls -la /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist" 2>/dev/null || echo 'missing')"
                echo "        LaunchAgent plist: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "ls -la /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist" 2>/dev/null || echo 'missing')"
                echo "        Daemon log: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "tail -5 /tmp/tart-guest-daemon.log" 2>/dev/null || echo 'no log')"
                echo "        Agent log: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "tail -5 /tmp/tart-guest-agent.log" 2>/dev/null || echo 'no log')"
                exit 1
            fi
            printf "\r[19/23] Waiting for guest agent after reboot... %ds" "$REBOOT_ELAPSED"
            if ! kill -0 "$PROBE_PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if ! kill -0 "$PROBE_PID" 2>/dev/null; then
            if wait "$PROBE_PID" 2>/dev/null; then
                break
            fi
        else
            kill -9 "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
        fi
    done
    printf "\r[19/23] Guest agent ready after reboot.%-20s\n" ""
else
    echo "[19/23] Skipping reboot (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [20/23] Set auto-login user (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[20/23] Setting auto-login user to '$HOST_USER'..."
    # sysadminctl -autologin fails over SSH (error:22, XPC not accessible). Must use tart exec
    # (native macOS context via guest agent). The daemon needs a full boot cycle to establish
    # the Virtio channel, so this runs after the reboot in step 17.
    vm_exec_gui sudo sysadminctl -autologin set -userName "$HOST_USER" -password "$PASSWORD"
    echo "        Done."
else
    echo "[20/23] Skipping auto-login setup (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [21/23] Reboot VM for auto-login to take effect (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[21/23] Rebooting VM for auto-login to take effect..."
    # Reboot via direct SSH — vm_exec_user herestring can silently fail,
    # and tart exec can hang when guest agent dies mid-reboot
    ssh $SSH_KEY "$HOST_USER@$VM_IP" "sudo /sbin/reboot" || true
    REBOOT_TIMEOUT=180
    REBOOT_START=$(date +%s)
    while true; do
        tart exec "$VM_NAME" true 2>/dev/null &
        PROBE_PID=$!
        for _ in 1 2 3; do
            REBOOT_ELAPSED=$(( $(date +%s) - REBOOT_START ))
            if [[ $REBOOT_ELAPSED -ge $REBOOT_TIMEOUT ]]; then
                kill -9 "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
                printf "\n"
                echo "Error: Timed out waiting for guest agent after reboot (${REBOOT_TIMEOUT}s)."
                exit 1
            fi
            printf "\r[21/23] Waiting for guest agent after reboot... %ds" "$REBOOT_ELAPSED"
            if ! kill -0 "$PROBE_PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if ! kill -0 "$PROBE_PID" 2>/dev/null; then
            if wait "$PROBE_PID" 2>/dev/null; then
                break
            fi
        else
            kill -9 "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
        fi
    done
    printf "\r[21/23] Guest agent ready after reboot.%-20s\n" ""
    # Verify auto-login: the created user should now be the console user
    LOGGED_IN_USER=$(vm_exec_gui stat -f '%Su' /dev/console 2>/dev/null || true)
    if [[ "$LOGGED_IN_USER" == "$HOST_USER" ]]; then
        echo "        Verified: '$HOST_USER' is the auto-login user."
    else
        echo "        Warning: expected '$HOST_USER' but console user is '${LOGGED_IN_USER:-unknown}'."
    fi
else
    echo "[21/23] Skipping reboot (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [22/23] Configure iTerm2 font (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[22/23] Configuring iTerm2 default font..."
    ITERM_PLIST="/Users/${HOST_USER}/Library/Preferences/com.googlecode.iterm2.plist"
    # Launch iTerm2 to generate default preferences, then quit (requires GUI/WindowServer)
    vm_exec_gui open -a iTerm
    ITERM_WAIT=0
    while ! vm_exec_gui test -f "$ITERM_PLIST" 2>/dev/null; do
        if [[ $ITERM_WAIT -ge 30 ]]; then
            echo "        Warning: timed out waiting for iTerm2 plist — skipping font config."
            vm_exec_gui pkill -x iTerm2 2>/dev/null || true
            break
        fi
        sleep 1
        ITERM_WAIT=$((ITERM_WAIT + 1))
    done
    if vm_exec_gui test -f "$ITERM_PLIST" 2>/dev/null; then
        # iTerm2 writes preferences on quit — kill gracefully so it saves, then edit the plist.
        # SIGTERM triggers a clean shutdown; no confirmation dialog on a fresh launch with no sessions.
        sleep 2
        vm_exec_gui killall -TERM iTerm2 2>/dev/null || true
        sleep 2  # let it save and exit
        if vm_exec_gui bash -c "/usr/libexec/PlistBuddy -c \"Print ':New Bookmarks':0:'Normal Font'\" '$ITERM_PLIST'" &>/dev/null; then
            vm_exec_gui bash -c "/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks':0:'Normal Font' 'MesloLGMDZNFM-Regular 12'\" '$ITERM_PLIST'"
            vm_exec_gui bash -c "/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks':0:'Scrollback Lines' 100000\" '$ITERM_PLIST'"
            echo "        Done (font: MesloLGMDZ Nerd Font Mono 12, scrollback: 100000)."
        else
            echo "        Warning: 'New Bookmarks' not found in plist — skipping font config."
        fi
    fi
else
    echo "[22/23] Skipping iTerm2 config (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [23/23] Get VM IP and show summary ---
echo "[23/23] Provisioning complete."
trap - EXIT INT TERM  # provisioning succeeded — don't delete the VM on exit
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || echo "<unavailable>")

# Add VM's host key to known_hosts so first SSH doesn't prompt
if [[ "$VM_IP" != "<unavailable>" ]]; then
    ssh-keygen -R "$VM_IP" 2>/dev/null || true
    ssh-keyscan -H "$VM_IP" >> ~/.ssh/known_hosts 2>/dev/null
fi

# Write VM metadata for downstream scripts (resize-vm-disk.sh, prepare-golden-image.sh, etc.).
# Lives next to disk.img so it travels with the VM under tart clone.
META_FILE="$HOME/.tart/vms/$VM_NAME/vm-tools-meta"
VM_TOOLS_REV=$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo "unknown")
META_LINUX_DISTRO=""
[[ "$GUEST_OS" == "linux" ]] && META_LINUX_DISTRO="$LINUX_DISTRO"
cat > "$META_FILE" <<EOF
guest_os=$GUEST_OS
linux_distro=$META_LINUX_DISTRO
vm_tools_rev=$VM_TOOLS_REV
provisioned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
golden_image=false
golden_prepared_at=
EOF

echo ""
echo "========================================"
echo "  VM provisioned successfully!"
echo "========================================"
echo "  Name     : $VM_NAME"
echo "  IP       : $VM_IP"
echo "  User     : $HOST_USER (admin)"
echo ""
echo "  Connect  : ssh ${VM_IP}"
echo "========================================"
