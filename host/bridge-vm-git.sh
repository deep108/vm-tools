#!/bin/bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Dynamic step counter ---
STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo "[${STEP_NUM}] $1"
}

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <vm-name> <github-shorthand> [--repo-dir <name>] [--host-ip <ip>] [--public]"
    echo ""
    echo "  Bridge a git repo between a VM, a host bare repo, and GitHub."
    echo "  Detects what already exists and does only what's needed."
    echo ""
    echo "  <vm-name>            Tart VM name"
    echo "  <github-shorthand>   e.g. deep108/my-repo  (→ git@github.com:...)"
    echo "  --repo-dir <name>    Dir name inside ~/dev/ in the VM (default: repo name from shorthand)"
    echo "                       Accepts bare name (my-repo) or full path (~/dev/my-repo)"
    echo "  --host-ip <ip>       Host gateway IP as seen from VM (default: auto-detect)"
    echo "  --public             Create a public GitHub repo (default: private, only matters if creating)"
    exit 1
}

[[ $# -lt 2 ]] && usage
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

VM_NAME="$1"
GITHUB_SHORTHAND="$2"
shift 2

# --- Parse optional args ---
REPO_DIR=""
HOST_IP=""
HOST_IP_EXPLICIT=false
GITHUB_VISIBILITY="--private"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)
            [[ -z "${2:-}" ]] && { echo "Error: --repo-dir requires a value"; usage; }
            REPO_DIR="$2"
            shift 2
            ;;
        --host-ip)
            [[ -z "${2:-}" ]] && { echo "Error: --host-ip requires a value"; usage; }
            HOST_IP="$2"
            HOST_IP_EXPLICIT=true
            shift 2
            ;;
        --public)
            GITHUB_VISIBILITY="--public"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# --- Derived values ---
REPO_NAME="${GITHUB_SHORTHAND##*/}"
# Normalise --repo-dir: accept ~/dev/foo, /abs/path/foo, or bare "foo"
REPO_DIR="${REPO_DIR:-$REPO_NAME}"
REPO_DIR="${REPO_DIR%/}"          # strip trailing slash
REPO_DIR="${REPO_DIR##*/}"        # keep only the basename
HOST_USER="$(whoami)"
BARE_REPO_PATH="$HOME/dev/repos/${REPO_NAME}.git"
WRAPPER_SCRIPT="$HOME/.local/bin/git-vm-${VM_NAME}.sh"
GITHUB_URL="git@github.com:${GITHUB_SHORTHAND}.git"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
VM_USER="$HOST_USER"
VM_IP=""
VM_SSH_SOCKET=""

# --- VM SSH helper ---
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

# ─────────────────────────────────────────────
# Phase 1: Get VM IP, open ControlMaster, detect state
# ─────────────────────────────────────────────
step "Getting VM IP for '${VM_NAME}'..."
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

# Open ControlMaster connection
VM_SSH_SOCKET=$(mktemp -u /tmp/bridge-vm-git-XXXXXX)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o LogLevel=ERROR \
    -o ControlMaster=yes -o ControlPath="$VM_SSH_SOCKET" -o ControlPersist=yes \
    -f -N "${VM_USER}@${VM_IP}"

# Auto-detect host IP
if [[ "$HOST_IP_EXPLICIT" != true ]]; then
    HOST_IP=$(ssh_vm "GW=\$(ip route show default 2>/dev/null | awk '/default/{print \$3}'); [ -n \"\$GW\" ] && echo \"\$GW\" || route -n get default 2>/dev/null | awk '/gateway:/{print \$2}'" || true)
    if [[ -z "$HOST_IP" ]]; then
        HOST_IP="192.168.66.1"
        echo -e "      ${YELLOW}! Could not auto-detect host IP — falling back to ${HOST_IP}${NC}"
    else
        echo -e "      ${GREEN}✓ Host IP (auto-detected): ${HOST_IP}${NC}"
    fi
fi

# Detect state
HAS_GITHUB=false
HAS_BARE=false
HAS_VM_REPO=false
BARE_IS_EMPTY=false

# GitHub repo?
if command -v gh &>/dev/null; then
    if gh repo view "$GITHUB_SHORTHAND" &>/dev/null; then
        HAS_GITHUB=true
    fi
else
    # No gh CLI — try SSH probe to see if repo exists
    if git ls-remote --exit-code "$GITHUB_URL" HEAD &>/dev/null; then
        HAS_GITHUB=true
    fi
fi

# Host bare repo?
if [[ -d "$BARE_REPO_PATH" ]]; then
    HAS_BARE=true
fi

# VM working copy?
VM_REPO_EXISTS=$(ssh_vm "test -d ~/dev/${REPO_DIR}/.git && echo yes || echo no")
if [[ "$VM_REPO_EXISTS" == "yes" ]]; then
    HAS_VM_REPO=true
fi

echo ""
echo "=== bridge-vm-git: ${VM_NAME} ↔ ${GITHUB_SHORTHAND} ==="
echo "  Repo dir  : ~/dev/${REPO_DIR}"
echo "  Bare repo : ${BARE_REPO_PATH}"
echo "  GitHub    : ${GITHUB_URL}"
echo "  Host IP   : ${HOST_IP}"
echo ""
echo "  State:"
echo -e "    GitHub repo   : $(if $HAS_GITHUB; then echo -e "${GREEN}exists${NC}"; else echo -e "${YELLOW}missing${NC}"; fi)"
echo -e "    Host bare repo: $(if $HAS_BARE; then echo -e "${GREEN}exists${NC}"; else echo -e "${YELLOW}missing${NC}"; fi)"
echo -e "    VM working copy: $(if $HAS_VM_REPO; then echo -e "${GREEN}exists${NC}"; else echo -e "${YELLOW}missing${NC}"; fi)"
echo ""

# ─────────────────────────────────────────────
# Phase 2: Ensure GitHub repo exists
# ─────────────────────────────────────────────
step "Ensuring GitHub repo exists..."
if $HAS_GITHUB; then
    echo -e "      ${YELLOW}! GitHub repo '${GITHUB_SHORTHAND}' already exists — skipping.${NC}"
else
    if ! command -v gh &>/dev/null; then
        echo -e "  ${RED}✗ GitHub repo doesn't exist and 'gh' CLI is not installed.${NC}" >&2
        echo "    Either create the repo manually, or install gh: brew install gh" >&2
        exit 1
    fi
    GH_AUTH_OUTPUT=$(gh auth status 2>&1) || {
        echo -e "  ${RED}✗ GitHub CLI is not authenticated.${NC}" >&2
        echo "$GH_AUTH_OUTPUT" | sed 's/^/    /' >&2
        echo "    Fix: gh auth login" >&2
        exit 1
    }
    GH_CREATE_OUTPUT=$(gh repo create "$GITHUB_SHORTHAND" ${GITHUB_VISIBILITY} 2>&1) || {
        echo -e "  ${RED}✗ Failed to create GitHub repo.${NC}" >&2
        echo "$GH_CREATE_OUTPUT" | sed 's/^/    /' >&2
        if echo "$GH_CREATE_OUTPUT" | grep -qi "auth\|login\|token\|credential\|403\|401"; then
            echo "    This looks like an authentication issue. Try: gh auth login" >&2
        elif echo "$GH_CREATE_OUTPUT" | grep -qi "not found\|404"; then
            echo "    The owner '${GITHUB_SHORTHAND%%/*}' may not exist or you may lack permission." >&2
        elif echo "$GH_CREATE_OUTPUT" | grep -qi "scope\|permission\|insufficient"; then
            echo "    Your token may lack the 'repo' scope. Try: gh auth refresh -s repo" >&2
        fi
        exit 1
    }
    echo -e "      ${GREEN}✓ Created GitHub repo (${GITHUB_VISIBILITY#--}).${NC}"
    HAS_GITHUB=true
fi

# ─────────────────────────────────────────────
# Phase 3: Ensure bare repo exists on host
# ─────────────────────────────────────────────
step "Ensuring bare repo exists on host..."
BARE_JUST_CREATED=false
if $HAS_BARE; then
    echo -e "      ${YELLOW}! Bare repo already exists — skipping.${NC}"
    # Ensure origin remote is correct
    CURRENT_ORIGIN=$(git -C "$BARE_REPO_PATH" remote get-url origin 2>/dev/null || true)
    if [[ -z "$CURRENT_ORIGIN" ]]; then
        git -C "$BARE_REPO_PATH" remote add origin "$GITHUB_URL"
        echo -e "      ${GREEN}✓ Added origin remote: ${GITHUB_URL}${NC}"
    elif [[ "$CURRENT_ORIGIN" != "$GITHUB_URL" ]]; then
        git -C "$BARE_REPO_PATH" remote set-url origin "$GITHUB_URL"
        echo -e "      ${YELLOW}! Updated origin: ${CURRENT_ORIGIN} → ${GITHUB_URL}${NC}"
    else
        echo -e "      ${GREEN}✓ origin is already correct.${NC}"
    fi
else
    mkdir -p "$(dirname "$BARE_REPO_PATH")"
    # If GitHub has content, clone --bare; otherwise init --bare
    GITHUB_HAS_CONTENT=false
    if $HAS_GITHUB; then
        if git ls-remote --exit-code "$GITHUB_URL" HEAD &>/dev/null; then
            GITHUB_HAS_CONTENT=true
        fi
    fi
    if $GITHUB_HAS_CONTENT; then
        git clone --bare "$GITHUB_URL" "$BARE_REPO_PATH"
        echo -e "      ${GREEN}✓ Cloned bare repo from GitHub.${NC}"
    else
        git init --bare "$BARE_REPO_PATH"
        git -C "$BARE_REPO_PATH" remote add origin "$GITHUB_URL"
        echo -e "      ${GREEN}✓ Initialized empty bare repo with origin → GitHub.${NC}"
    fi
    BARE_JUST_CREATED=true
    HAS_BARE=true
fi

# Ensure bare repo has upstream tracking for its branches
BARE_BRANCHES=$(git -C "$BARE_REPO_PATH" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)
if [[ -n "$BARE_BRANCHES" ]]; then
    while IFS= read -r branch; do
        BARE_UPSTREAM=$(git -C "$BARE_REPO_PATH" config "branch.${branch}.remote" 2>/dev/null || true)
        if [[ -z "$BARE_UPSTREAM" ]]; then
            if git -C "$BARE_REPO_PATH" rev-parse --verify "origin/${branch}" &>/dev/null; then
                git -C "$BARE_REPO_PATH" branch "${branch}" --set-upstream-to="origin/${branch}"
            fi
        fi
    done <<< "$BARE_BRANCHES"
fi

# ─────────────────────────────────────────────
# Phase 4: Ensure wrapper script has entries for this repo
# ─────────────────────────────────────────────
step "Setting up git access wrapper script..."
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
  # Additional repos appended above by bridge-vm-git.sh
esac
echo "Access denied: \$SSH_ORIGINAL_COMMAND" >&2
exit 1
EOF
    chmod +x "$WRAPPER_SCRIPT"
    echo -e "      ${GREEN}✓ Created ${WRAPPER_SCRIPT}.${NC}"
fi

# ─────────────────────────────────────────────
# Phase 5: Check host Remote Login
# ─────────────────────────────────────────────
step "Checking host Remote Login (SSH on port 22)..."
if ! nc -z localhost 22 2>/dev/null; then
    echo -e "  ${RED}✗ Host SSH is not accessible on port 22.${NC}" >&2
    echo "    Enable: System Settings → General → Sharing → Remote Login → On" >&2
    exit 1
fi
echo -e "      ${GREEN}✓ Remote Login is enabled.${NC}"

# ─────────────────────────────────────────────
# Phase 6: SSH plumbing
# ─────────────────────────────────────────────

# 6a: Generate SSH key in VM
step "Generating SSH key in VM (if needed)..."
KEY_EXISTS=$(ssh_vm "test -f ~/.ssh/mac-host-git && echo yes || echo no")
if [[ "$KEY_EXISTS" == "yes" ]]; then
    echo -e "      ${YELLOW}! Key ~/.ssh/mac-host-git already exists — skipping.${NC}"
else
    ssh_vm "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f ~/.ssh/mac-host-git -C 'tart-vm-git-${VM_NAME}' -N ''"
    echo -e "      ${GREEN}✓ Generated ~/.ssh/mac-host-git.${NC}"
fi

# 6b: Configure 'mac-host' SSH alias in VM
step "Configuring SSH host 'mac-host' in VM..."
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
        ssh_vm "awk '/^Host mac-host/{skip=1;next} skip && /^Host /{skip=0} !skip{print}' \
            ~/.ssh/config > /tmp/.ssh_config_new && mv /tmp/.ssh_config_new ~/.ssh/config"
    fi
    ssh_vm "mkdir -p ~/.ssh && cat >> ~/.ssh/config && chmod 600 ~/.ssh/config" << SSHCONF

Host mac-host
  HostName ${HOST_IP}
  User ${HOST_USER}
  IdentityFile ~/.ssh/mac-host-git
  StrictHostKeyChecking yes
SSHCONF
    echo -e "      ${GREEN}✓ 'Host mac-host' configured in VM's ~/.ssh/config.${NC}"
else
    echo -e "      ${YELLOW}! 'Host mac-host' already correct (${HOST_IP}) — skipping.${NC}"
fi

# 6c: Seed host SSH public key into VM known_hosts
step "Seeding host SSH key into VM's known_hosts..."
HOST_SSH_PUBKEY=$(awk '{print $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub)
if [[ -z "$HOST_SSH_PUBKEY" ]]; then
    echo -e "  ${RED}✗ Could not read /etc/ssh/ssh_host_ed25519_key.pub.${NC}" >&2
    exit 1
fi

KNOWN_HOSTS_LINE="${HOST_IP} ${HOST_SSH_PUBKEY}"
EXISTING_HOST_KEY=$(ssh_vm "grep -F '${HOST_IP}' ~/.ssh/known_hosts 2>/dev/null || true")
if [[ -n "$EXISTING_HOST_KEY" ]]; then
    if echo "$EXISTING_HOST_KEY" | grep -qF "$HOST_SSH_PUBKEY"; then
        echo -e "      ${YELLOW}! Host key already in VM's known_hosts — skipping.${NC}"
    else
        echo -e "      ${YELLOW}! Stale host key found — replacing.${NC}"
        ssh_vm "sed -i.bak '/^${HOST_IP} /d' ~/.ssh/known_hosts && echo '${KNOWN_HOSTS_LINE}' >> ~/.ssh/known_hosts"
        echo -e "      ${GREEN}✓ Updated host key in VM's known_hosts.${NC}"
    fi
else
    ssh_vm "mkdir -p ~/.ssh && echo '${KNOWN_HOSTS_LINE}' >> ~/.ssh/known_hosts"
    echo -e "      ${GREEN}✓ Seeded host key into VM's known_hosts.${NC}"
fi

# 6d: Authorize VM key on host
step "Authorizing VM key in host's ~/.ssh/authorized_keys..."
VM_PUBKEY=$(ssh_vm "cat ~/.ssh/mac-host-git.pub")
if [[ -z "$VM_PUBKEY" ]]; then
    echo -e "  ${RED}✗ Could not read ~/.ssh/mac-host-git.pub from VM.${NC}" >&2
    exit 1
fi

mkdir -p "$(dirname "$AUTHORIZED_KEYS")"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

if grep -qF "$VM_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
    echo -e "      ${YELLOW}! VM's key already in authorized_keys — skipping.${NC}"
else
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

# 6e: Test VM → host SSH connectivity
step "Testing VM → host SSH connectivity..."
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
# Phase 7: Configure git identity in VM
# ─────────────────────────────────────────────
step "Configuring git identity in VM..."

HOST_GIT_NAME=$(git config --global user.name 2>/dev/null || true)
HOST_GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)

VM_GIT_NAME=$(ssh_vm "git config --global user.name 2>/dev/null || true")
VM_GIT_EMAIL=$(ssh_vm "git config --global user.email 2>/dev/null || true")

if [[ -n "$VM_GIT_NAME" && -n "$VM_GIT_EMAIL" && "$VM_GIT_NAME" == "$HOST_GIT_NAME" && "$VM_GIT_EMAIL" == "$HOST_GIT_EMAIL" ]]; then
    echo -e "      ${YELLOW}! Git identity already configured (${VM_GIT_NAME} <${VM_GIT_EMAIL}>) — skipping.${NC}"
else
    echo "      Host git identity: ${HOST_GIT_NAME:-<not set>} <${HOST_GIT_EMAIL:-<not set>}>"
    read -p "      user.name [${HOST_GIT_NAME}]: " INPUT_NAME
    GIT_NAME="${INPUT_NAME:-$HOST_GIT_NAME}"
    read -p "      user.email [${HOST_GIT_EMAIL}]: " INPUT_EMAIL
    GIT_EMAIL="${INPUT_EMAIL:-$HOST_GIT_EMAIL}"

    if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
        echo -e "  ${RED}✗ Both user.name and user.email are required.${NC}" >&2
        exit 1
    fi

    ssh_vm "git config --global user.name '${GIT_NAME}'"
    ssh_vm "git config --global user.email '${GIT_EMAIL}'"
    echo -e "      ${GREEN}✓ Git identity set: ${GIT_NAME} <${GIT_EMAIL}>${NC}"
fi

# ─────────────────────────────────────────────
# Phase 8: Ensure VM has a working copy
# ─────────────────────────────────────────────
step "Ensuring VM has a working copy..."
BARE_URL="ssh://mac-host${BARE_REPO_PATH}"

if $HAS_VM_REPO; then
    # Check for uncommitted changes
    DIRTY=$(ssh_vm "git -C ~/dev/${REPO_DIR} status --short 2>/dev/null | head -20 || true")
    if [[ -n "$DIRTY" ]]; then
        echo -e "      ${YELLOW}! Uncommitted changes in VM repo:${NC}"
        echo "$DIRTY" | while IFS= read -r line; do echo "        $line"; done
    fi
    # Ensure remote points at bare repo
    EXISTING_ORIGIN=$(ssh_vm "git -C ~/dev/${REPO_DIR} remote get-url origin 2>/dev/null || true")
    if [[ -z "$EXISTING_ORIGIN" ]]; then
        ssh_vm "git -C ~/dev/${REPO_DIR} remote add origin '${BARE_URL}'"
        echo -e "      ${GREEN}✓ Added origin → ${BARE_URL}${NC}"
    elif [[ "$EXISTING_ORIGIN" == "$BARE_URL" ]]; then
        echo -e "      ${YELLOW}! origin already set to bare repo — skipping.${NC}"
    else
        echo -e "      ${YELLOW}! origin is currently '${EXISTING_ORIGIN}'.${NC}"
        read -p "      Replace with '${BARE_URL}'? [y/N] " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            ssh_vm "git -C ~/dev/${REPO_DIR} remote set-url origin '${BARE_URL}'"
            echo -e "      ${GREEN}✓ Updated origin → ${BARE_URL}${NC}"
        else
            echo "      Keeping existing origin. You may need to push/pull manually."
        fi
    fi
else
    ssh_vm "mkdir -p ~/dev && git clone '${BARE_URL}' ~/dev/${REPO_DIR}"
    echo -e "      ${GREEN}✓ Cloned to ~/dev/${REPO_DIR} (upstream tracking set by clone).${NC}"
fi

# Ensure upstream tracking is set for the current branch (idempotent)
VM_BRANCH=$(ssh_vm "git -C ~/dev/${REPO_DIR} symbolic-ref --short HEAD 2>/dev/null || true")
if [[ -n "$VM_BRANCH" ]]; then
    VM_UPSTREAM=$(ssh_vm "git -C ~/dev/${REPO_DIR} config branch.${VM_BRANCH}.remote 2>/dev/null || true")
    if [[ -z "$VM_UPSTREAM" ]]; then
        # Only set upstream if the branch exists on the remote
        if ssh_vm "git -C ~/dev/${REPO_DIR} rev-parse --verify origin/${VM_BRANCH} &>/dev/null"; then
            ssh_vm "git -C ~/dev/${REPO_DIR} branch --set-upstream-to=origin/${VM_BRANCH} ${VM_BRANCH}"
            echo -e "      ${GREEN}✓ Set upstream: ${VM_BRANCH} → origin/${VM_BRANCH}${NC}"
        fi
    fi
fi

# ─────────────────────────────────────────────
# Phase 9: Sync data if needed
# ─────────────────────────────────────────────
# If VM had commits and bare was just created, push VM → bare → GitHub
if $HAS_VM_REPO && $BARE_JUST_CREATED; then
    step "Syncing: VM → bare repo → GitHub..."

    # Detect default branch
    DEFAULT_BRANCH=$(ssh_vm "git -C ~/dev/${REPO_DIR} symbolic-ref --short HEAD 2>/dev/null || echo main")
    echo "      Default branch: ${DEFAULT_BRANCH}"

    # Push VM → bare repo
    echo "      Pushing VM → bare repo on host..."
    ssh_vm "git -C ~/dev/${REPO_DIR} push -u --all origin && git -C ~/dev/${REPO_DIR} push --tags origin"
    echo -e "      ${GREEN}✓ Pushed to bare repo (upstream set).${NC}"

    # Push bare repo → GitHub
    echo "      Pushing bare repo → GitHub..."
    GIT_PUSH_OUTPUT=$(git -C "$BARE_REPO_PATH" push -u --all origin 2>&1) || {
        echo -e "  ${RED}✗ Failed to push to GitHub.${NC}" >&2
        echo "$GIT_PUSH_OUTPUT" | sed 's/^/    /' >&2
        if echo "$GIT_PUSH_OUTPUT" | grep -qi "auth\|denied\|403\|401\|credential\|could not read\|permission denied\|publickey"; then
            echo "    SSH authentication to GitHub failed." >&2
            echo "    Check: ssh -T git@github.com" >&2
            echo "    Or push manually: git -C ${BARE_REPO_PATH} push --all origin" >&2
        fi
        exit 1
    }
    git -C "$BARE_REPO_PATH" push --tags origin 2>/dev/null || true
    echo -e "      ${GREEN}✓ Pushed to GitHub.${NC}"
fi

# ─────────────────────────────────────────────
# Phase 10: Summary
# ─────────────────────────────────────────────
# Detect branch for summary
DEFAULT_BRANCH=$(ssh_vm "git -C ~/dev/${REPO_DIR} symbolic-ref --short HEAD 2>/dev/null || echo main")

echo ""
echo "========================================"
echo -e "  ${GREEN}Bridge complete!${NC}"
echo "========================================"
echo "  VM repo   : ~/dev/${REPO_DIR}"
echo "  Bare repo : ${BARE_REPO_PATH}"
echo "  GitHub    : https://github.com/${GITHUB_SHORTHAND}"
echo ""
echo "  Day-to-day workflow:"
echo ""
echo "  In the VM (push work to host):"
echo "    git -C ~/dev/${REPO_DIR} push origin ${DEFAULT_BRANCH}"
echo ""
echo "  On the host (review before publishing):"
echo "    git -C ${BARE_REPO_PATH} log origin/${DEFAULT_BRANCH}..${DEFAULT_BRANCH} --oneline"
echo "    git -C ${BARE_REPO_PATH} diff origin/${DEFAULT_BRANCH}..${DEFAULT_BRANCH}"
echo ""
echo "  On the host (publish to GitHub):"
echo "    git -C ${BARE_REPO_PATH} push origin ${DEFAULT_BRANCH}"
echo ""
echo "  On the host (pull GitHub updates for VM to fetch):"
echo "    git -C ${BARE_REPO_PATH} fetch origin"
echo "========================================"
