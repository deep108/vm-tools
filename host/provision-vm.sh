#!/bin/bash
set -euo pipefail

# --- Defaults ---
DISK_GB=75
BASE_IMAGE=""
BASE_IMAGE_SET=false
HEADLESS=false
GUEST_OS="macos"
VM_NAME=""
NO_XCODE=false
XCODE_VERSION="--latest"

# --- Usage ---
usage() {
    echo "Usage: $0 <vm-name> [--linux] [--disk <GB>] [--base <image>] [--headless] [--no-xcode] [--xcode-version <ver>]"
    echo ""
    echo "  <vm-name>             Required. Name for the new Tart VM."
    echo "  --linux               Create a Linux VM (default: Debian Bookworm)."
    echo "  --disk <GB>           Disk size in GB (default: 75)."
    echo "  --base <image>        Source Tart image to clone."
    echo "  --headless            Run VM without a UI window."
    echo "  --no-xcode            Skip Xcode installation (for quick test provisions)."
    echo "  --xcode-version <ver> Xcode version to install (default: latest stable)."
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
        --no-xcode)
            NO_XCODE=true
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

# Set default base image based on guest OS (if not explicitly provided)
if [[ "$BASE_IMAGE_SET" == false ]]; then
    if [[ "$GUEST_OS" == "linux" ]]; then
        BASE_IMAGE="ghcr.io/cirruslabs/debian:trixie"
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
    # Remove known_hosts entry for this VM's IP (added by ssh-keyscan in step 20,
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
    if [[ "$GUEST_OS" == "linux" ]]; then
        ssh $SSH_KEY "$HOST_USER@$VM_IP" "bash -c '$cmd'"
    else
        # GIT_CONFIG_COUNT overrides the Xcode CLT system gitconfig's credential.helper=osxkeychain.
        # The osxkeychain helper requires a GUI session and fails over non-interactive SSH with
        # "could not read Username". Setting credential.helper to empty disables it.
        ssh $SSH_KEY "$HOST_USER@$VM_IP" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= zsh -l -c '$cmd'"
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

echo "=== Provision VM: $VM_NAME ==="
echo "  Guest OS   : $GUEST_OS"
echo "  Base image : $BASE_IMAGE"
echo "  Disk size  : ${DISK_GB} GB"
echo "  Headless   : $HEADLESS"
echo "  Host user  : $HOST_USER"
echo "  Local base : $LOCAL_BASE"
if [[ "$GUEST_OS" == "macos" ]]; then
    echo "  Xcode      : $(if [[ "$NO_XCODE" == true ]]; then echo "skip"; else echo "$XCODE_VERSION"; fi)"
fi
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

# --- [1/20] Check for conflicts ---
echo "[1/20] Checking for existing VM..."
if tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists. Delete it first with: tart delete $VM_NAME"
    exit 1
fi
echo "       OK — no conflict."

# --- [2/20] Pull latest base image (skip for local VMs) ---
if [[ "$BASE_IMAGE" == */* ]]; then
    echo "[2/20] Pulling latest '$BASE_IMAGE'..."
    tart pull "$BASE_IMAGE"
    echo "       Done."
else
    echo "[2/20] Using local VM '$BASE_IMAGE' as base (skipping pull)."
    if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$BASE_IMAGE"; then
        echo "Error: Local VM '$BASE_IMAGE' not found. Run 'tart list' to see available VMs."
        exit 1
    fi
fi

# --- [3/20] Clone base image ---
echo "[3/20] Cloning '$BASE_IMAGE' -> '$VM_NAME'..."
tart clone "$BASE_IMAGE" "$VM_NAME"
VM_CLONED=true
echo "       Done."

# --- [4/20] Resize disk ---
echo "[4/20] Setting disk size to ${DISK_GB} GB..."
if RESIZE_OUT=$(tart set "$VM_NAME" --disk-size "$DISK_GB" 2>&1); then
    echo "       Done."
else
    echo "       Warning: could not resize disk: $RESIZE_OUT"
    echo "       (Disks can only grow, not shrink. Continuing with base image disk size.)"
fi

# --- [5/20] Start VM ---
echo "[5/20] Starting VM..."
if [[ "$HEADLESS" == true ]]; then
    tart run "$VM_NAME" --no-graphics &
else
    tart run "$VM_NAME" &
fi
TART_PID=$!
echo "       VM started (PID $TART_PID)."

# --- [6/20] Wait for SSH ---
CONNECT_TIMEOUT=120
CONNECT_START=$(date +%s)

printf "[6/20] Waiting for VM IP..."
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
printf "\r[6/20] Got VM IP: $VM_IP. Waiting for SSH...%-10s\n"

while true; do
    CONNECT_ELAPSED=$(( $(date +%s) - CONNECT_START ))
    if [[ $CONNECT_ELAPSED -ge $CONNECT_TIMEOUT ]]; then
        echo "Error: Timed out waiting for SSH after ${CONNECT_TIMEOUT}s."
        exit 1
    fi
    printf "\r[6/20] Waiting for SSH... %ds" "$CONNECT_ELAPSED"
    if sshpass -p admin ssh $SSH_PASS -o ConnectTimeout=2 admin@"$VM_IP" true 2>/dev/null; then
        break
    fi
    sleep 2
done
printf "\r[6/20] SSH ready.%-30s\n" ""

# --- [7/20] Regenerate SSH host keys (cloned VMs share the base image's keys) ---
echo "[7/20] Regenerating SSH host keys..."
if [[ "$GUEST_OS" == "linux" ]]; then
    # Run as a single command string — restarting sshd kills our SSH connection,
    # so we combine everything and tolerate the connection drop.
    vm_exec "sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart sshd" || true
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

# --- [8/20] Create user (skip for local base — user already exists) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[8/20] Creating user '$HOST_USER' on VM..."
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
    echo "[8/20] Skipping user creation (local base — '$HOST_USER' already exists)."
fi

# --- [9/20] Install/update SSH public key for user ---
echo "[9/20] Installing SSH public key for '$HOST_USER'..."
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

# --- [10/20] Set computer name and timezone ---
echo "[10/20] Setting computer name to '$VM_NAME'..."
HOST_TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec "sudo hostnamectl set-hostname '$VM_NAME'"
    vm_exec "sudo timedatectl set-timezone '$HOST_TZ'"
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

# --- [11/20] Install Homebrew and git ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[11/20] Installing Homebrew and git..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec "sudo apt-get update -qq"
        vm_exec "sudo apt-get install -y -qq git"
    else
        # Vanilla macOS has no git and no Homebrew. The Homebrew installer auto-detects
        # the missing Xcode CLT and installs it (which provides git, clang, etc.).
        # The Homebrew installer auto-detects the missing Xcode CLT and installs it
        # (which provides git, clang, make, etc.).
        vm_exec_user "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | NONINTERACTIVE=1 /bin/bash"
    fi
    echo "        Done."
else
    echo "[11/20] Skipping Homebrew/git install (local base)."
fi

# --- [12/20] Clone or update vm-tools ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[12/20] Cloning vm-tools into VM..."
    vm_exec_user "mkdir -p ~/dev && git clone https://github.com/deep108/vm-tools.git ~/dev/vm-tools"
    echo "        Done."
else
    echo "[12/20] Updating vm-tools in VM..."
    vm_exec_user "cd ~/dev/vm-tools && git pull"
    echo "        Done."
fi

# --- [13/20] Run bootstrap ---
echo "[13/20] Running bootstrap..."
if [[ "$GUEST_OS" == "linux" ]]; then
    vm_exec_user "bash ~/dev/vm-tools/scripts/bootstrap-linux.sh"
else
    vm_exec_user "~/dev/vm-tools/scripts/bootstrap.sh"
fi
echo "        Bootstrap complete."

# Strip Gatekeeper quarantine from apps installed by brew cask (avoids "downloaded from the internet" dialogs)
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    vm_exec_user "sudo xattr -dr com.apple.quarantine /Applications/Visual\ Studio\ Code.app /Applications/iTerm.app 2>/dev/null" || true
fi

# --- [14/20] Install Xcode (macOS only, fresh provision, skip with --no-xcode) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false && "$NO_XCODE" == false ]]; then
    echo "[14/20] Installing Xcode..."
    # Pre-tap manually: brew's internal git doesn't inherit GIT_CONFIG_COUNT,
    # so the osxkeychain credential helper fails over SSH. Direct git clone works.
    # Tap is XcodesOrg/made (repo: XcodesOrg/homebrew-made).
    vm_exec_user "mkdir -p \$(brew --prefix)/Library/Taps/xcodesorg && git clone https://github.com/XcodesOrg/homebrew-made \$(brew --prefix)/Library/Taps/xcodesorg/homebrew-made"
    vm_exec_user "brew install xcodes aria2"
    echo "        Xcode installation requires an Apple ID."
    read -p "        Apple ID email: " APPLE_ID
    read -s -p "        Apple ID password: " APPLE_PASSWORD
    echo ""
    # Use ssh -t for pseudo-TTY so Apple 2FA prompts flow through to the host terminal.
    # xcodes uses XCODES_USERNAME/XCODES_PASSWORD env vars for non-interactive auth.
    # Run xcodes with sudo to avoid interactive password prompts during install finalization.
    # Passwordless sudo is already configured; -E preserves XCODES_* env vars.
    ssh -t $SSH_KEY "$HOST_USER@$VM_IP" \
        "XCODES_USERNAME='$APPLE_ID' XCODES_PASSWORD='$APPLE_PASSWORD' zsh -l -c 'sudo -E xcodes install $XCODE_VERSION --experimental-unxip'"
    # Point xcode-select to the installed Xcode (xcodes names it Xcode-<ver>.app)
    vm_exec_user "sudo xcode-select -s /Applications/Xcode-*.app/Contents/Developer"
    vm_exec_user "sudo xcodebuild -license accept"
    vm_exec_user "sudo xcodebuild -runFirstLaunch"
    vm_exec_user "brew install cocoapods swiftlint swiftformat"
    echo "        Xcode installed."
elif [[ "$GUEST_OS" == "macos" && "$NO_XCODE" == true ]]; then
    echo "[14/20] Skipping Xcode installation (--no-xcode)."
else
    echo "[14/20] Skipping Xcode installation (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [15/20] Install tart-guest-agent (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[15/20] Installing tart-guest-agent..."
    # Pre-tap manually (same osxkeychain workaround as step 14)
    vm_exec_user "mkdir -p \$(brew --prefix)/Library/Taps/cirruslabs && git clone https://github.com/cirruslabs/homebrew-cli \$(brew --prefix)/Library/Taps/cirruslabs/homebrew-cli"
    vm_exec_user "brew install tart-guest-agent"
    # The brew formula only installs the binary — no launchd plists.
    # Two components are needed (see cirruslabs/macos-image-templates):
    #   1. LaunchDaemon (--run-daemon): system-level, runs at boot, handles tart exec
    #   2. LaunchAgent (--run-agent): user-level, runs at login, handles clipboard etc.
    vm_exec_user "sudo tee /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist > /dev/null" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.cirruslabs.tart-guest-daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/tart-guest-agent</string>
        <string>--run-daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>/var/empty</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/tart-guest-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tart-guest-daemon.log</string>
</dict>
</plist>
PLIST
    vm_exec_user "sudo tee /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist > /dev/null" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.cirruslabs.tart-guest-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/tart-guest-agent</string>
        <string>--run-agent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>/var/empty</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
        <key>TERM</key>
        <string>xterm-256color</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/tart-guest-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tart-guest-agent.log</string>
</dict>
</plist>
PLIST
    echo "        Done."
else
    echo "[15/20] Skipping tart-guest-agent (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [16/20] Set up VS Code serve-web (skip for local base — already configured) ---
if [[ "$LOCAL_BASE" == false ]]; then
    echo "[16/20] Setting up VS Code serve-web..."
    if [[ "$GUEST_OS" == "linux" ]]; then
        vm_exec_user "SERVICE_USER=$HOST_USER bash ~/dev/vm-tools/guest/setup-code-server-systemd.sh"
    else
        vm_exec_user "SERVICE_USER=$HOST_USER bash ~/dev/vm-tools/guest/setup-code-server-launch-agent.sh"
    fi
    echo "        Done."
else
    echo "[16/20] Skipping VS Code serve-web (local base — already configured)."
fi

# --- [17/20] Set auto-login user (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[17/20] Setting auto-login user to '$HOST_USER'..."
    # sysadminctl -autologin fails over SSH (SACSetAutoLoginPassword error:22) — the XPC
    # service isn't fully accessible outside a GUI session. Set auto-login manually:
    # 1) loginwindow plist: set autoLoginUser
    # 2) /etc/kcpassword: XOR-encode password with Apple's known key
    vm_exec_user "sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser '$HOST_USER'"
    # Generate kcpassword: XOR the password with Apple's fixed key, pad to 12-byte boundary
    KCPASSWD=$(python3 -c "
import sys
key = [0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f]
pw = sys.argv[1].encode('utf-8')
# Pad password with null bytes to next 12-byte boundary
pad_len = 12 - (len(pw) % 12) if len(pw) % 12 != 0 else 12
pw = pw + b'\x00' * pad_len
result = bytes([pw[i] ^ key[i % len(key)] for i in range(len(pw))])
sys.stdout.write(result.hex())
" "$PASSWORD")
    ssh $SSH_KEY "$HOST_USER@$VM_IP" "echo '$KCPASSWD' | xxd -r -p | sudo tee /etc/kcpassword > /dev/null && sudo chmod 600 /etc/kcpassword"
    echo "        Done."
else
    echo "[17/20] Skipping auto-login setup (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [18/20] Reboot VM and verify guest agent (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[18/20] Rebooting VM for auto-login to take effect..."
    # Reboot via SSH — connection will drop, which is expected
    vm_exec_user "sudo /sbin/reboot" || true
    # Wait for guest agent to come back (verifies tart-guest-agent works for future use)
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
                # Diagnose via SSH (VM may be up but guest agent not running)
                echo "        Diagnosing via SSH..."
                echo "        Console user: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "stat -f '%Su' /dev/console" 2>/dev/null || echo 'SSH failed')"
                echo "        Guest agent process: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "pgrep -l tart-guest-agent" 2>/dev/null || echo 'not running')"
                echo "        LaunchAgent plist: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "ls -la /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist" 2>/dev/null || echo 'missing')"
                echo "        Agent log: $(ssh $SSH_KEY "$HOST_USER@$VM_IP" "tail -5 /var/log/tart-guest-agent.log" 2>/dev/null || echo 'no log')"
                exit 1
            fi
            printf "\r[18/20] Waiting for guest agent after reboot... %ds" "$REBOOT_ELAPSED"
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
    printf "\r[18/20] Guest agent ready after reboot.%-20s\n" ""
    # Verify the auto-login user is correct
    LOGGED_IN_USER=$(vm_exec_gui stat -f '%Su' /dev/console 2>/dev/null || true)
    if [[ "$LOGGED_IN_USER" == "$HOST_USER" ]]; then
        echo "        Verified: '$HOST_USER' is the logged-in user."
    else
        echo "        Warning: expected '$HOST_USER' but console user is '${LOGGED_IN_USER:-unknown}'."
    fi
else
    echo "[18/20] Skipping reboot (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [19/20] Configure iTerm2 font (macOS only, fresh provision) ---
if [[ "$GUEST_OS" == "macos" && "$LOCAL_BASE" == false ]]; then
    echo "[19/20] Configuring iTerm2 default font..."
    ITERM_PLIST="/Users/${HOST_USER}/Library/Preferences/com.googlecode.iterm2.plist"
    # Strip Gatekeeper quarantine so iTerm2 can launch without a dialog
    # Launch iTerm2 to generate default preferences, then quit (requires GUI/WindowServer)
    vm_exec_gui open -a iTerm
    ITERM_WAIT=0
    while ! vm_exec_gui test -f "$ITERM_PLIST" 2>/dev/null; do
        if [[ $ITERM_WAIT -ge 30 ]]; then
            echo "        Warning: timed out waiting for iTerm2 plist — skipping font config."
            vm_exec_gui osascript -e 'quit app "iTerm"' 2>/dev/null || true
            break
        fi
        sleep 1
        ITERM_WAIT=$((ITERM_WAIT + 1))
    done
    if vm_exec_gui test -f "$ITERM_PLIST" 2>/dev/null; then
        sleep 2  # let iTerm2 finish writing defaults
        vm_exec_gui osascript -e 'quit app "iTerm"' 2>/dev/null || true
        sleep 1
        vm_exec_gui bash -c "/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks':0:'Normal Font' 'MesloLGMDZNFM-Regular 12'\" '$ITERM_PLIST'"
        vm_exec_gui bash -c "/usr/libexec/PlistBuddy -c \"Set ':New Bookmarks':0:'Scrollback Lines' 100000\" '$ITERM_PLIST'"
        echo "        Done (font: MesloLGMDZ Nerd Font Mono 12, scrollback: 100000)."
    fi
else
    echo "[19/20] Skipping iTerm2 config (${GUEST_OS}${LOCAL_BASE:+, local base})."
fi

# --- [20/20] Get VM IP and show summary ---
echo "[20/20] Provisioning complete."
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
