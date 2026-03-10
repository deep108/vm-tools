#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
DISK_GB=75
BASE_IMAGE=""
BASE_IMAGE_SET=false
HEADLESS=false
GUEST_OS="macos"
VM_NAME=""

# --- Usage ---
usage() {
    echo "Usage: $0 <vm-name> [--linux] [--disk <GB>] [--base <image>] [--headless]"
    echo ""
    echo "  <vm-name>        Required. Name for the new Tart VM."
    echo "  --linux          Create a Linux VM (default: Debian Bookworm)."
    echo "  --disk <GB>      Disk size in GB (default: 75)."
    echo "  --base <image>   Source Tart image to clone."
    echo "  --headless       Run VM without a UI window."
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
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

[[ -z "$VM_NAME" ]] && { echo "Error: <vm-name> is required"; usage; }

# Set default base image based on guest OS (if not explicitly provided)
if [[ "$BASE_IMAGE_SET" == false ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        BASE_IMAGE="ghcr.io/cirruslabs/debian:trixie"
    else
        BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
    fi
fi

# sshpass is required for Linux provisioning (no guest agent support yet)
if [[ "$GUEST_OS" == "linux" ]]; then
    if ! command -v sshpass &>/dev/null; then
        echo "Error: 'sshpass' is required for Linux VM provisioning (no guest agent support)."
        echo "Install with: brew install esolitos/ipa/sshpass"
        exit 1
    fi
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
    # Remove known_hosts entry for this VM's IP (added by ssh-keyscan in step 17,
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
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

vm_exec() {
    if [[ "$GUEST_OS" == "linux" ]]; then
        sshpass -p admin ssh $SSH_OPTS admin@"$VM_IP" "$@"
    else
        tart exec "$VM_NAME" "$@"
    fi
}

vm_exec_user() {
    local cmd="$1"
    if [[ "$GUEST_OS" == "linux" ]]; then
        ssh $SSH_OPTS "$HOST_USER@$VM_IP" "bash -c '$cmd'"
    else
        tart exec "$VM_NAME" sudo -Hu "$HOST_USER" zsh -l -c "$cmd"
    fi
}

# --- Detect local base image ---
# Registry images contain '/' (e.g. ghcr.io/cirruslabs/...), local VMs are plain names.
LOCAL_BASE=false
if [[ "$BASE_IMAGE" != */* ]]; then
    LOCAL_BASE=true
fi

echo "=== Provision VM: $VM_NAME ==="
echo "  Guest OS   : $GUEST_OS"
echo "  Base image : $BASE_IMAGE"
echo "  Disk size  : ${DISK_GB} GB"
echo "  Headless   : $HEADLESS"
echo "  Host user  : $HOST_USER"
echo "  Local base : $LOCAL_BASE"
echo ""

# --- Prompt for password upfront (skip for local base — user already exists) ---
PASSWORD=""
if [[ "$LOCAL_BASE" == false ]]; then
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
    echo ""
fi

# --- [1/18] Check for conflicts ---
echo "[1/18] Checking for existing VM..."
if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists. Delete it first with: tart delete $VM_NAME"
    exit 1
fi
echo "       OK — no conflict."

# --- [2/18] Pull latest base image (skip for local VMs) ---
if [[ "$BASE_IMAGE" == */* ]]; then
    echo "[2/18] Pulling latest '$BASE_IMAGE'..."
    tart pull "$BASE_IMAGE"
    echo "       Done."
else
    echo "[2/18] Using local VM '$BASE_IMAGE' as base (skipping pull)."
    if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$BASE_IMAGE"; then
        echo "Error: Local VM '$BASE_IMAGE' not found. Run 'tart list' to see available VMs."
        exit 1
    fi
fi

# --- [3/18] Clone base image ---
echo "[3/18] Cloning '$BASE_IMAGE' -> '$VM_NAME'..."
tart clone "$BASE_IMAGE" "$VM_NAME"
VM_CLONED=true
echo "       Done."

# --- [4/18] Resize disk ---
echo "[4/18] Setting disk size to ${DISK_GB} GB..."
if RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$DISK_GB" 2>&1); then
    echo "       Done."
else
    echo "       Warning: could not resize disk: $RESIZE_OUT"
    echo "       (Disks can only grow, not shrink. Continuing with base image disk size.)"
fi

# --- [5/18] Start VM ---
echo "[5/18] Starting VM..."
if [[ "$HEADLESS" == true ]]; then
    tart run "$VM_NAME" --no-graphics &
else
    tart run "$VM_NAME" &
fi
TART_PID=$!
echo "       VM started (PID $TART_PID)."

# --- [6/18] Wait for guest connectivity ---
CONNECT_TIMEOUT=120
CONNECT_START=$(date +%s)

if [[ "$GUEST_OS" == "linux" ]]; then
    # Linux: wait for IP via DHCP, then wait for SSH
    printf "[6/18] Waiting for VM IP..."
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
    printf "\r[6/18] Got VM IP: $VM_IP. Waiting for SSH...%-10s\n"

    while true; do
        CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
        if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
            echo "Error: Timed out waiting for SSH after ${CONNECT_TIMEOUT}s."
            exit 1
        fi
        printf "\r[6/18] Waiting for SSH... %ds" "$CONNECT_ELAPSED"
        if sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null; then
            break
        fi
        sleep 2
    done
    printf "\r[6/18] SSH ready.%-30s\n" ""
else
    # macOS: wait for guest agent via tart exec
    while true; do
        tart exec "$VM_NAME" true 2>/dev/null &
        PROBE_PID=$!
        for _ in 1 2 3; do
            CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
            if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
                kill -9 "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
                printf "\n"
                echo "Error: Timed out waiting for guest agent after ${CONNECT_TIMEOUT}s."
                exit 1
            fi
            printf "\r[6/18] Waiting for guest agent... %ds" "$CONNECT_ELAPSED"
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
    printf "\r[6/18] Guest agent ready.%-20s\n" ""
fi

# --- [7/18] Regenerate SSH host keys (cloned VMs share the base image's keys) ---
echo "[7/18] Regenerating SSH host keys..."
if [[ "$GUEST_OS" == "linux" ]]; then
    # Run as a single command string — restarting sshd kills our SSH connection,
    # so we combine everything and tolerate the connection drop.
    vm_exec "sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart sshd" || true
    # Wait for sshd to come back up with the new keys
    sleep 2
    for _ in $(seq 1 10); do
        sshpass -p admin ssh $SSH_OPTS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null && break
        sleep 1
    done
else
    vm_exec sudo rm -f /etc/ssh/ssh_host_*
    vm_exec sudo ssh-keygen -A
    vm_exec sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
fi
echo "       Done."

# --- [8/18] Create user (skip for local base — user already exists) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[8/18] Creating user '$HOST_USER' on VM..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        PASS_HASH=$(openssl passwd -6 "$PASSWORD")
        vm_exec sudo useradd -m -s /bin/bash -G sudo -p "'$PASS_HASH'" "$HOST_USER"
        vm_exec "echo '$HOST_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$HOST_USER > /dev/null && sudo chmod 440 /etc/sudoers.d/$HOST_USER"
    else
        "$SCRIPT_DIR/create-macos-vm-user.sh" "$VM_NAME" "$HOST_USER" "$PASSWORD" --admin
        vm_exec bash -c "echo '$HOST_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$HOST_USER > /dev/null && sudo chmod 440 /etc/sudoers.d/$HOST_USER"
        # Pre-dismiss macOS Setup Assistant dialogs (Siri, iCloud, privacy, etc.)
        VM_BUILD=$(vm_exec sw_vers -buildVersion)
        VM_VERSION=$(vm_exec sw_vers -productVersion)
        vm_exec sudo -Hu "$HOST_USER" bash -c "
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
            defaults write com.apple.SetupAssistant LastSeenCloudProductVersion '$VM_VERSION'
            defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion '$VM_BUILD'
            defaults write com.apple.SetupAssistant LastSeenDiagnosticsProductVersion '$VM_VERSION'
            defaults write com.apple.SetupAssistant LastSeenSiriProductVersion '$VM_VERSION'
            defaults write com.apple.SetupAssistant LastPreLoginTasksPerformedBuild '$VM_BUILD'
            defaults write com.apple.SetupAssistant LastPreLoginTasksPerformedVersion '$VM_VERSION'
            defaults write com.apple.SetupAssistant MiniBuddyShouldLaunchToResumeSetup -bool false
            defaults write com.apple.SetupAssistant selectedFDEEscrowType -string DeclinedFDE
            defaults write NSGlobalDomain AppleInterfaceStyle Dark
        "
    fi
    echo "       User created."
else
    echo "[8/18] Skipping user creation (local base — '$HOST_USER' already exists)."
fi

# --- [9/18] Install/update SSH public key for user ---
echo "[9/18] Installing SSH public key for '$HOST_USER'..."
SSH_PUBKEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$key_file" ]]; then
        SSH_PUBKEY=$(cat "$key_file")
        break
    fi
done
if [[ -n "$SSH_PUBKEY" ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        HOME_DIR="/home/$HOST_USER"
        vm_exec sudo mkdir -p "$HOME_DIR/.ssh"
        vm_exec sudo chmod 700 "$HOME_DIR/.ssh"
        vm_exec "echo '$SSH_PUBKEY' | sudo tee $HOME_DIR/.ssh/authorized_keys > /dev/null"
        vm_exec sudo chmod 600 "$HOME_DIR/.ssh/authorized_keys"
        vm_exec sudo chown -R "$HOST_USER:$HOST_USER" "$HOME_DIR/.ssh"
    else
        vm_exec sudo -Hu "$HOST_USER" bash -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$SSH_PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    fi
    echo "       Done."
else
    echo "       Warning: no SSH public key found in ~/.ssh — skipping."
fi

# --- [10/18] Set computer name and timezone ---
echo "[10/18] Setting computer name to '$VM_NAME'..."
HOST_TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec sudo hostnamectl set-hostname "$VM_NAME"
    vm_exec sudo timedatectl set-timezone "$HOST_TZ"
else
    # LocalHostName only allows alphanumerics and hyphens (used for Bonjour .local)
    LOCAL_HOSTNAME="${VM_NAME//_/-}"
    LOCAL_HOSTNAME="${LOCAL_HOSTNAME//[^a-zA-Z0-9-]/}"
    vm_exec sudo scutil --set ComputerName "$VM_NAME"
    vm_exec sudo scutil --set HostName "$VM_NAME"
    vm_exec sudo scutil --set LocalHostName "$LOCAL_HOSTNAME"
    vm_exec sudo systemsetup -settimezone "$HOST_TZ" 2>/dev/null
fi
echo "       Done (timezone: $HOST_TZ)."

# --- [11/18] Clone or update vm-tools ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[11/18] Cloning vm-tools into VM..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec sudo apt-get update -qq
        vm_exec sudo apt-get install -y -qq git
    fi
    vm_exec_user "mkdir -p ~/dev && git clone https://github.com/deep108/vm-tools.git ~/dev/vm-tools"
    echo "        vm-tools cloned."
else
    echo "[11/18] Updating vm-tools in VM..."
    vm_exec_user "cd ~/dev/vm-tools && git pull"
    echo "        vm-tools updated."
fi

# --- [12/18] Transfer Homebrew ownership (skip for local base or Linux) ---
if [[ "$GUEST_OS" == "linux" ]]; then
    echo "[12/18] Skipping Homebrew ownership (Linux — user installs brew during bootstrap)."
elif [[ "$LOCAL_BASE" == false ]]; then
    echo "[12/18] Checking for Homebrew..."
    if vm_exec test -d /opt/homebrew; then
        echo "        Found — transferring ownership to '$HOST_USER'..."
        vm_exec sudo chown -R "$HOST_USER":staff /opt/homebrew
        echo "        Done."
    else
        echo "        /opt/homebrew not found — skipping."
    fi
else
    echo "[12/18] Skipping Homebrew ownership (local base — already done)."
fi

# --- [13/18] Run bootstrap ---
echo "[13/18] Running bootstrap..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec_user "bash ~/dev/vm-tools/scripts/bootstrap-linux.sh"
else
    vm_exec_user "zsh -l ~/dev/vm-tools/scripts/bootstrap.sh"
fi
echo "        Bootstrap complete."

# --- [14/18] Set up VS Code serve-web (skip for local base — already configured) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[14/18] Setting up VS Code serve-web..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec_user "SERVICE_USER=$HOST_USER bash ~/dev/vm-tools/guest/setup-code-server-systemd.sh"
    else
        vm_exec env "SERVICE_USER=$HOST_USER" bash ~/dev/vm-tools/guest/setup-code-server-launch-agent.sh
    fi
    echo "        Done."
else
    echo "[14/18] Skipping VS Code serve-web (local base — already configured)."
fi

# --- [15/18] Set auto-login user (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[15/18] Setting auto-login user to '$HOST_USER'..."
    vm_exec sudo sysadminctl -autologin set -userName "$HOST_USER" -password "$PASSWORD"
    # Fix tart-guest-agent LaunchAgent: WorkingDirectory is hardcoded to /Users/admin
    # which causes issues when a different user is auto-logged in. Change to /var/empty.
    vm_exec sudo sed -i '' 's|/Users/admin|/var/empty|' /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
    echo "        Done."
else
    echo "[15/18] Skipping auto-login setup (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [16/18] Reboot VM and wait for guest agent (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[16/18] Rebooting VM for auto-login to take effect..."
    # tart exec can hang when the VM reboots (guest agent dies mid-connection),
    # so run it with a timeout. The command will either complete or be killed — both are fine.
    ( tart exec "$VM_NAME" sudo /sbin/reboot &>/dev/null & sleep 5; kill $! 2>/dev/null ) 2>/dev/null || true
    # Wait for guest agent to come back (same probe loop as step 6)
    REBOOT_TIMEOUT=120
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
            printf "\r[16/18] Waiting for guest agent after reboot... %ds" "$REBOOT_ELAPSED"
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
    printf "\r[16/18] Guest agent ready after reboot.%-20s\n" ""
    # Verify the auto-login user is correct
    LOGGED_IN_USER=$(tart exec "$VM_NAME" stat -f '%Su' /dev/console 2>/dev/null || true)
    if [[ "$LOGGED_IN_USER" == "$HOST_USER" ]]; then
        echo "        Verified: '$HOST_USER' is the logged-in user."
    else
        echo "        Warning: expected '$HOST_USER' but console user is '${LOGGED_IN_USER:-unknown}'."
    fi
else
    echo "[16/18] Skipping reboot (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [17/18] Configure iTerm2 font (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[17/18] Configuring iTerm2 default font..."
    ITERM_PLIST="/Users/${HOST_USER}/Library/Preferences/com.googlecode.iterm2.plist"
    # Strip Gatekeeper quarantine so iTerm2 can launch without a dialog
    vm_exec sudo xattr -dr com.apple.quarantine /Applications/iTerm.app 2>/dev/null || true
    # Launch iTerm2 to generate default preferences, then quit
    vm_exec open -a iTerm
    ITERM_WAIT=0
    while ! vm_exec test -f "$ITERM_PLIST" 2>/dev/null; do
        if [[ $ITERM_WAIT -ge 30 ]]; then
            echo "        Warning: timed out waiting for iTerm2 plist — skipping font config."
            vm_exec osascript -e 'quit app "iTerm"' 2>/dev/null || true
            break
        fi
        sleep 1
        ITERM_WAIT=$((ITERM_WAIT + 1))
    done
    if vm_exec test -f "$ITERM_PLIST" 2>/dev/null; then
        sleep 2  # let iTerm2 finish writing defaults
        vm_exec osascript -e 'quit app "iTerm"' 2>/dev/null || true
        sleep 1
        vm_exec bash -c "/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks':0:'Normal Font' 'MesloLGMDZNFM-Regular 12'\" '$ITERM_PLIST'"
        vm_exec bash -c "/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks':0:'Scrollback Lines' 100000\" '$ITERM_PLIST'"
        echo "        Done (font: MesloLGMDZ Nerd Font Mono 12, scrollback: 100000)."
    fi
else
    echo "[17/18] Skipping iTerm2 config (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [18/18] Get VM IP and show summary ---
trap - EXIT INT TERM  # provisioning succeeded — don't delete the VM on exit
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || echo "<unavailable>")

# Add VM's host key to known_hosts so first SSH doesn't prompt
if [[ "$VM_IP" != "<unavailable>" ]]; then
    ssh-keygen -R "$VM_IP" 2>/dev/null || true
    ssh-keyscan -H "$VM_IP" >> ~/.ssh/known_hosts 2>/dev/null
fi

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
