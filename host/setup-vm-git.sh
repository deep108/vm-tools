#!/bin/bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_STEPS=10

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <vm-name> <github-shorthand> [--clone-dir <name>] [--host-ip <ip>]"
    echo ""
    echo "  <vm-name>            Tart VM name"
    echo "  <github-shorthand>   e.g. deep108/deep-habits-rn  (→ https://github.com/...)"
    echo "  --clone-dir <name>   Clone dir name inside VM (default: repo name)"
    echo "  --host-ip <ip>       Host gateway IP as seen from VM (default: auto-detect)"
    exit 1
}

[[ $# -lt 2 ]] && usage
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

VM_NAME="$1"
GITHUB_SHORTHAND="$2"
shift 2

# --- Parse optional args ---
CLONE_DIR=""
HOST_IP=""
HOST_IP_EXPLICIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clone-dir)
            [[ -z "${2:-}" ]] && { echo "Error: --clone-dir requires a value"; usage; }
            CLONE_DIR="$2"
            shift 2
            ;;
        --host-ip)
            [[ -z "${2:-}" ]] && { echo "Error: --host-ip requires a value"; usage; }
            HOST_IP="$2"
            HOST_IP_EXPLICIT=true
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# --- Derived values ---
REPO_NAME="${GITHUB_SHORTHAND##*/}"
CLONE_DIR="${CLONE_DIR:-$REPO_NAME}"
HOST_USER="$(whoami)"
BARE_REPO_PATH="$HOME/dev/repos/${REPO_NAME}.git"
WRAPPER_SCRIPT="$HOME/.local/bin/git-vm-${VM_NAME}.sh"
GITHUB_URL="https://github.com/${GITHUB_SHORTHAND}.git"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
VM_USER="$HOST_USER"
VM_IP=""
VM_SSH_SOCKET=""

# --- VM SSH helper ---
# Before step 4: falls back to a plain connection (warning may appear once).
# After step 4: VM_SSH_SOCKET is set; all calls reuse the ControlMaster silently.
ssh_vm() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR \
        ${VM_SSH_SOCKET:+-o ControlMaster=no -o ControlPath="$VM_SSH_SOCKET"} \
        "${VM_USER}@${VM_IP}" "$@"
}

close_vm_ssh() {
    [[ -n "${VM_SSH_SOCKET}" ]] && \
        ssh -o ControlPath="$VM_SSH_SOCKET" -O exit "${VM_USER}@${VM_IP}" 2>/dev/null || true
}
trap close_vm_ssh EXIT

echo ""
echo "=== setup-vm-git: ${VM_NAME} ← ${GITHUB_SHORTHAND} ==="
echo "  Bare repo : ${BARE_REPO_PATH}"
echo "  VM clone  : ~/dev/${CLONE_DIR}"
echo "  GitHub    : ${GITHUB_URL}"
echo "  Host IP   : ${HOST_IP:-(auto-detect after step 4)}"
echo ""

# ─────────────────────────────────────────────
# Preflight: report existing state for this VM
# ─────────────────────────────────────────────
PREFLIGHT_FOUND=false
if [[ -f "$AUTHORIZED_KEYS" ]] && grep -q "^# VM: ${VM_NAME}$" "$AUTHORIZED_KEYS" 2>/dev/null; then
    echo -e "  ${YELLOW}! authorized_keys has an existing entry for VM '${VM_NAME}'.${NC}"
    echo "    Will be replaced if the VM's SSH key has changed (e.g. VM was recreated)."
    PREFLIGHT_FOUND=true
fi
if [[ -f "$WRAPPER_SCRIPT" ]]; then
    echo -e "  ${YELLOW}! Wrapper script already exists: ${WRAPPER_SCRIPT}${NC}"
    COVERED=$(grep "exec git-upload-pack" "$WRAPPER_SCRIPT" \
        | grep -o "'[^']*'" | tr -d "'" 2>/dev/null || true)
    if [[ -n "$COVERED" ]]; then
        echo "    Currently covers:"
        while IFS= read -r r; do echo "      - ${r}"; done <<< "$COVERED"
    fi
    PREFLIGHT_FOUND=true
fi
if [[ "$PREFLIGHT_FOUND" == true ]]; then
    echo ""
fi

# ─────────────────────────────────────────────
# [1/10] Create bare repo on host
# ─────────────────────────────────────────────
echo "[1/${TOTAL_STEPS}] Creating bare repo on host..."
if [[ -d "$BARE_REPO_PATH" ]]; then
    echo -e "      ${YELLOW}! Bare repo already exists — skipping clone.${NC}"
    CURRENT_ORIGIN=$(git -C "$BARE_REPO_PATH" remote get-url origin 2>/dev/null || true)
    if [[ -z "$CURRENT_ORIGIN" ]]; then
        git -C "$BARE_REPO_PATH" remote add origin "$GITHUB_URL"
        echo -e "      ${GREEN}✓ Added origin remote: ${GITHUB_URL}${NC}"
    elif [[ "$CURRENT_ORIGIN" != "$GITHUB_URL" ]]; then
        echo -e "      ${YELLOW}! origin is '${CURRENT_ORIGIN}' (expected '${GITHUB_URL}') — leaving unchanged.${NC}"
    else
        echo -e "      ${GREEN}✓ origin is already correct.${NC}"
    fi
else
    mkdir -p "$(dirname "$BARE_REPO_PATH")"
    git clone --bare "$GITHUB_URL" "$BARE_REPO_PATH"
    echo -e "      ${GREEN}✓ Cloned bare repo from GitHub.${NC}"
fi

# ─────────────────────────────────────────────
# [2/10] Create/update wrapper script on host
# ─────────────────────────────────────────────
echo "[2/${TOTAL_STEPS}] Setting up git access wrapper script..."
mkdir -p "$(dirname "$WRAPPER_SCRIPT")"

UPLOAD_LINE="  \"git-upload-pack '${BARE_REPO_PATH}'\")  exec git-upload-pack '${BARE_REPO_PATH}' ;;"
RECEIVE_LINE="  \"git-receive-pack '${BARE_REPO_PATH}'\")  exec git-receive-pack '${BARE_REPO_PATH}' ;;"

if [[ -f "$WRAPPER_SCRIPT" ]]; then
    if grep -qF "git-upload-pack '${BARE_REPO_PATH}'" "$WRAPPER_SCRIPT"; then
        echo -e "      ${YELLOW}! Case entries for '${REPO_NAME}' already present — skipping.${NC}"
    else
        awk -v u="$UPLOAD_LINE" -v r="$RECEIVE_LINE" \
            '/^esac$/ { print u; print r } { print }' \
            "$WRAPPER_SCRIPT" > "${WRAPPER_SCRIPT}.tmp" \
            && mv "${WRAPPER_SCRIPT}.tmp" "$WRAPPER_SCRIPT"
        echo -e "      ${GREEN}✓ Appended case entries for '${REPO_NAME}'.${NC}"
    fi
else
    cat > "$WRAPPER_SCRIPT" << EOF
#!/bin/bash
case "\$SSH_ORIGINAL_COMMAND" in
${UPLOAD_LINE}
${RECEIVE_LINE}
  # Additional repos appended above by setup-vm-git.sh
esac
echo "Access denied: \$SSH_ORIGINAL_COMMAND" >&2
exit 1
EOF
    chmod +x "$WRAPPER_SCRIPT"
    echo -e "      ${GREEN}✓ Created ${WRAPPER_SCRIPT}.${NC}"
fi

# ─────────────────────────────────────────────
# [3/10] Check host Remote Login
# ─────────────────────────────────────────────
echo "[3/${TOTAL_STEPS}] Checking host Remote Login (SSH on port 22)..."
if ! nc -z localhost 22 2>/dev/null; then
    echo -e "  ${RED}✗ Host SSH is not accessible on port 22.${NC}" >&2
    echo "    Enable: System Settings → General → Sharing → Remote Login → On" >&2
    exit 1
fi
echo -e "      ${GREEN}✓ Remote Login is enabled.${NC}"

# ─────────────────────────────────────────────
# [4/10] Get VM IP
# ─────────────────────────────────────────────
echo "[4/${TOTAL_STEPS}] Getting VM IP for '${VM_NAME}'..."
if ! tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_NAME"; then
    echo -e "  ${RED}✗ VM '${VM_NAME}' does not exist.${NC}" >&2
    exit 1
fi
VM_IP=""
IP_TIMEOUT=30
IP_ELAPSED=0
while [[ -z "$VM_IP" ]]; do
    if [[ $IP_ELAPSED -ge $IP_TIMEOUT ]]; then
        printf "\n"
        echo -e "  ${RED}✗ Timed out waiting for VM IP after ${IP_TIMEOUT}s.${NC}" >&2
        echo "    Is the VM running? Start it with: tart run ${VM_NAME}" >&2
        exit 1
    fi
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        printf "\r      Waiting for VM IP... %ds" "$IP_ELAPSED"
        sleep 2
        IP_ELAPSED=$((IP_ELAPSED + 2))
    fi
done
[[ $IP_ELAPSED -gt 0 ]] && printf "\n"
echo -e "      ${GREEN}✓ VM IP: ${VM_IP}${NC}"

# One TCP handshake; all subsequent ssh_vm calls reuse this master connection.
VM_SSH_SOCKET=$(mktemp -u /tmp/setup-vm-git-XXXXXX)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o LogLevel=ERROR \
    -o ControlMaster=yes -o ControlPath="$VM_SSH_SOCKET" -o ControlPersist=yes \
    -f -N "${VM_USER}@${VM_IP}"

if [[ "$HOST_IP_EXPLICIT" != true ]]; then
    echo "      Detecting host IP from VM's default route..."
    HOST_IP=$(ssh_vm "ip route show default 2>/dev/null | awk '/default/{print \$3}' || route -n get default 2>/dev/null | awk '/gateway:/{print \$2}'" || true)
    if [[ -z "$HOST_IP" ]]; then
        HOST_IP="192.168.66.1"
        echo -e "      ${YELLOW}! Could not auto-detect host IP — falling back to ${HOST_IP}${NC}"
    else
        echo -e "      ${GREEN}✓ Host IP (auto-detected): ${HOST_IP}${NC}"
    fi
fi

# ─────────────────────────────────────────────
# [5/10] Generate SSH key in VM (if needed)
# ─────────────────────────────────────────────
echo "[5/${TOTAL_STEPS}] Generating SSH key in VM (if needed)..."
KEY_EXISTS=$(ssh_vm "test -f ~/.ssh/mac-host-git && echo yes || echo no")
if [[ "$KEY_EXISTS" == "yes" ]]; then
    echo -e "      ${YELLOW}! Key ~/.ssh/mac-host-git already exists — skipping.${NC}"
else
    ssh_vm "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f ~/.ssh/mac-host-git -C 'tart-vm-git-${VM_NAME}' -N ''"
    echo -e "      ${GREEN}✓ Generated ~/.ssh/mac-host-git.${NC}"
fi

# ─────────────────────────────────────────────
# [6/10] Configure 'mac-host' SSH alias in VM
# ─────────────────────────────────────────────
echo "[6/${TOTAL_STEPS}] Configuring SSH host 'mac-host' in VM (if needed)..."
EXISTING_HOSTIP=$(ssh_vm "awk '/^Host mac-host/{f=1} f && /^  HostName/{print \$2; exit}' ~/.ssh/config 2>/dev/null || true")
HAS_STRICT=$(ssh_vm "awk '/^Host mac-host/{f=1} f && /StrictHostKeyChecking/{print \"yes\"; exit} f && /^Host /{exit}' ~/.ssh/config 2>/dev/null || true")

NEED_WRITE=false
if [[ -z "$EXISTING_HOSTIP" ]]; then
    NEED_WRITE=true
elif [[ "$EXISTING_HOSTIP" != "$HOST_IP" ]]; then
    echo -e "      ${YELLOW}! HostName stale (${EXISTING_HOSTIP} → ${HOST_IP}) — rewriting block.${NC}"
    NEED_WRITE=true
elif [[ "$HAS_STRICT" != "yes" ]]; then
    echo "      Missing StrictHostKeyChecking — rewriting block."
    NEED_WRITE=true
fi

if [[ "$NEED_WRITE" == true ]]; then
    if [[ -n "$EXISTING_HOSTIP" ]]; then
        # Remove the stale block before appending the fresh one.
        # awk: when we hit 'Host mac-host' set skip; when we later hit another
        # 'Host ...' line clear skip (and print that line); print all non-skipped lines.
        ssh_vm "awk '/^Host mac-host/{skip=1;next} skip && /^Host /{skip=0} !skip{print}' \
            ~/.ssh/config > /tmp/.ssh_config_new && mv /tmp/.ssh_config_new ~/.ssh/config"
    fi
    ssh_vm "mkdir -p ~/.ssh && cat >> ~/.ssh/config && chmod 600 ~/.ssh/config" << SSHCONF

Host mac-host
  HostName ${HOST_IP}
  User ${HOST_USER}
  IdentityFile ~/.ssh/mac-host-git
  StrictHostKeyChecking accept-new
SSHCONF
    echo -e "      ${GREEN}✓ 'Host mac-host' configured in VM's ~/.ssh/config.${NC}"
else
    echo -e "      ${YELLOW}! 'Host mac-host' already correct (${HOST_IP}) — skipping.${NC}"
fi

# ─────────────────────────────────────────────
# [7/10] Read VM's public key
# ─────────────────────────────────────────────
echo "[7/${TOTAL_STEPS}] Reading VM's public key..."
VM_PUBKEY=$(ssh_vm "cat ~/.ssh/mac-host-git.pub")
if [[ -z "$VM_PUBKEY" ]]; then
    echo -e "  ${RED}✗ Could not read ~/.ssh/mac-host-git.pub from VM.${NC}" >&2
    exit 1
fi
echo -e "      ${GREEN}✓ Got VM public key.${NC}"

# ─────────────────────────────────────────────
# [8/10] Authorize VM key on host
# ─────────────────────────────────────────────
echo "[8/${TOTAL_STEPS}] Authorizing VM key in host's ~/.ssh/authorized_keys..."
mkdir -p "$(dirname "$AUTHORIZED_KEYS")"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

if grep -qF "$VM_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
    echo -e "      ${YELLOW}! VM's key already in authorized_keys — skipping.${NC}"
else
    # Remove any stale entry for this VM name (VM was recreated or previous run failed
    # partway through — either way the old key is now wrong).
    if grep -q "^# VM: ${VM_NAME}$" "$AUTHORIZED_KEYS" 2>/dev/null; then
        echo -e "      ${YELLOW}! Removing stale entry for VM '${VM_NAME}'.${NC}"
        python3 -c "
lines = open('${AUTHORIZED_KEYS}').readlines()
out, skip = [], False
for line in lines:
    if skip:
        skip = False
        continue
    if line.rstrip() == '# VM: ${VM_NAME}':
        skip = True
        continue
    out.append(line)
open('${AUTHORIZED_KEYS}', 'w').write(''.join(out))
"
    fi
    {
        echo ""
        echo "# VM: ${VM_NAME}"
        echo "command=\"${WRAPPER_SCRIPT}\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${VM_PUBKEY}"
    } >> "$AUTHORIZED_KEYS"
    echo -e "      ${GREEN}✓ Added restricted key entry for VM '${VM_NAME}'.${NC}"
fi

# ─────────────────────────────────────────────
# [9/10] Test VM → host SSH connectivity
# ─────────────────────────────────────────────
echo "[9/${TOTAL_STEPS}] Testing VM → host SSH connectivity..."
if ssh_vm "nc -z -w 5 ${HOST_IP} 22 2>/dev/null"; then
    echo -e "      ${GREEN}✓ VM can reach host on port 22.${NC}"
else
    echo -e "  ${RED}✗ VM cannot reach ${HOST_IP}:22.${NC}" >&2
    echo "    Check: Is Remote Login enabled on the host?" >&2
    echo "    Enable: System Settings → General → Sharing → Remote Login → On" >&2
    echo "    Also check: Is --host-ip ${HOST_IP} correct?" >&2
    exit 1
fi

# ─────────────────────────────────────────────
# [10/10] Clone repo in VM
# ─────────────────────────────────────────────
echo "[10/${TOTAL_STEPS}] Cloning repo in VM (if needed)..."
CLONE_EXISTS=$(ssh_vm "test -d ~/dev/${CLONE_DIR}/.git && echo yes || echo no")
if [[ "$CLONE_EXISTS" == "yes" ]]; then
    echo -e "      ${YELLOW}! ~/dev/${CLONE_DIR} already exists — skipping.${NC}"
else
    CLONE_URL="ssh://mac-host${BARE_REPO_PATH}"
    ssh_vm "mkdir -p ~/dev && git clone '${CLONE_URL}' ~/dev/${CLONE_DIR}"
    echo -e "      ${GREEN}✓ Cloned to ~/dev/${CLONE_DIR}.${NC}"
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "========================================"
echo -e "  ${GREEN}Setup complete!${NC}"
echo "========================================"
echo "  VM clone  : ~/dev/${CLONE_DIR}"
echo "  Bare repo : ${BARE_REPO_PATH}"
echo "  GitHub    : ${GITHUB_URL}"
echo ""
echo "  Day-to-day workflow:"
echo ""
echo "  In the VM (push work to host):"
echo "    git -C ~/dev/${CLONE_DIR} push origin main"
echo ""
echo "  On the host (review before publishing):"
echo "    git -C ${BARE_REPO_PATH} log origin/main..main --oneline"
echo "    git -C ${BARE_REPO_PATH} diff origin/main..main"
echo ""
echo "  On the host (publish to GitHub):"
echo "    git -C ${BARE_REPO_PATH} push origin main"
echo ""
echo "  On the host (pull GitHub updates for VM to fetch):"
echo "    git -C ${BARE_REPO_PATH} fetch origin"
echo "========================================"
