#!/bin/bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") <vm-name> [--remove-repos]"
    echo ""
    echo "  <vm-name>        Tart VM name"
    echo "  --remove-repos   Also delete bare repos from ~/dev/repos/ (default: leave in place)"
    exit 1
}

[[ $# -lt 1 ]] && usage
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

VM_NAME="$1"
shift

REMOVE_REPOS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove-repos)
            REMOVE_REPOS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

HOST_USER="$(whoami)"
WRAPPER_SCRIPT="$HOME/.local/bin/git-vm-${VM_NAME}.sh"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

# --- Check wrapper script exists ---
if [[ ! -f "$WRAPPER_SCRIPT" ]]; then
    echo -e "  ${YELLOW}! No git wrapper script found for VM '${VM_NAME}'.${NC}"
    echo "    Expected: ${WRAPPER_SCRIPT}"
    echo "    Nothing to tear down."
    exit 0
fi

# --- Read covered repos from wrapper script ---
REPOS=$(grep "exec git-upload-pack" "$WRAPPER_SCRIPT" | grep -o "'[^']*'" | tr -d "'" || true)

TOTAL_STEPS=3
[[ "$REMOVE_REPOS" == true ]] && TOTAL_STEPS=4

echo ""
echo "=== teardown-vm-git: ${VM_NAME} ==="
echo "  Wrapper  : ${WRAPPER_SCRIPT}"
if [[ -n "$REPOS" ]]; then
    echo "  Repos    :"
    while IFS= read -r repo; do echo "    - ${repo}"; done <<< "$REPOS"
fi
echo ""

# ─────────────────────────────────────────────
# [1/N] Check VM for pending changes
# ─────────────────────────────────────────────
# Sends a self-contained script to the VM via bash -s stdin.
# ${REPO_NAME} is expanded locally (host value); all \$var are escaped so
# they're evaluated on the remote side.
echo "[1/${TOTAL_STEPS}] Checking VM '${VM_NAME}' for pending changes..."
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
VM_HAS_ISSUES=false

if [[ -z "$VM_IP" ]]; then
    echo -e "      ${YELLOW}! VM is not running — cannot check for uncommitted changes.${NC}"
    echo "        Make sure all changes are committed and pushed before deleting the VM."
elif [[ -z "$REPOS" ]]; then
    echo -e "      ${YELLOW}! No repos configured — skipping VM check.${NC}"
else
    echo -e "      ${GREEN}✓ VM is running (${VM_IP}).${NC}"
    while IFS= read -r bare_repo; do
        REPO_NAME=$(basename "$bare_repo" .git)
        VM_SSH_EXIT=0
        VM_OUTPUT=$(ssh \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o LogLevel=ERROR \
            "${HOST_USER}@${VM_IP}" "bash -s" 2>/dev/null <<VMSCRIPT
REPO="${REPO_NAME}"
# Collect git dirs into a temp file to avoid pipe subshell variable scoping.
TMPFILE=\$(mktemp /tmp/git-check-XXXXXX)
find ~/dev -maxdepth 3 -name .git -type d 2>/dev/null > "\$TMPFILE"
EXIT_CODE=0
FOUND=0
while IFS= read -r gd; do
    rd=\$(dirname "\$gd")
    origin=\$(git -C "\$rd" remote get-url origin 2>/dev/null || true)
    printf '%s' "\$origin" | grep -qF "\$REPO" || continue
    FOUND=1
    dirty=\$(git -C "\$rd" status --short 2>/dev/null | head -20 || true)
    ahead=\$(git -C "\$rd" log --oneline '@{u}..HEAD' 2>/dev/null | head -10 || true)
    if [ -n "\$dirty" ] || [ -n "\$ahead" ]; then
        printf '! %s\n' "\$rd"
        [ -n "\$dirty" ] && printf '  uncommitted:\n' && printf '%s\n' "\$dirty" | sed 's/^/    /'
        [ -n "\$ahead" ] && printf '  not yet pushed to bare repo:\n' && printf '%s\n' "\$ahead" | sed 's/^/    /'
        EXIT_CODE=1
    else
        printf 'ok %s\n' "\$rd"
    fi
done < "\$TMPFILE"
rm -f "\$TMPFILE"
[ "\$FOUND" -eq 0 ] && printf 'notfound\n'
exit \$EXIT_CODE
VMSCRIPT
        ) || VM_SSH_EXIT=$?

        if [[ -z "$VM_OUTPUT" && $VM_SSH_EXIT -ne 0 ]]; then
            echo -e "      ${YELLOW}! Could not connect to VM to check '${REPO_NAME}'.${NC}"
        else
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                case "$line" in
                    '! '*)    echo -e "      ${YELLOW}${line}${NC}" ;;
                    '  '*)    echo "      ${line}" ;;
                    'ok '*)   echo -e "      ${GREEN}✓ ${line#ok } (clean)${NC}" ;;
                    notfound) echo "      No clone of '${REPO_NAME}' found in ~/dev" ;;
                    *)        echo "      ${line}" ;;
                esac
            done <<< "$VM_OUTPUT"
        fi
        if [[ $VM_SSH_EXIT -eq 1 ]]; then
            VM_HAS_ISSUES=true
        fi
    done <<< "$REPOS"

    if [[ "$VM_HAS_ISSUES" == true ]]; then
        echo ""
        echo -e "      ${YELLOW}! Pending changes found in VM. Commit and push before deleting.${NC}"
    fi
fi

# ─────────────────────────────────────────────
# [2/N] Remove authorized_keys entry
# ─────────────────────────────────────────────
echo "[2/${TOTAL_STEPS}] Removing authorized_keys entry for VM '${VM_NAME}'..."
if [[ ! -f "$AUTHORIZED_KEYS" ]] || ! grep -q "^# VM: ${VM_NAME}$" "$AUTHORIZED_KEYS" 2>/dev/null; then
    echo -e "      ${YELLOW}! No entry found for VM '${VM_NAME}' — skipping.${NC}"
else
    python3 -c "
lines = open('${AUTHORIZED_KEYS}').readlines()
out, skip = [], False
for line in lines:
    if skip:
        skip = False
        continue
    if line.rstrip() == '# VM: ${VM_NAME}':
        if out and out[-1].strip() == '':
            out.pop()
        skip = True
        continue
    out.append(line)
open('${AUTHORIZED_KEYS}', 'w').write(''.join(out))
"
    echo -e "      ${GREEN}✓ Removed authorized_keys entry.${NC}"
fi

# ─────────────────────────────────────────────
# [3/N] Remove wrapper script
# ─────────────────────────────────────────────
echo "[3/${TOTAL_STEPS}] Removing wrapper script..."
rm "$WRAPPER_SCRIPT"
echo -e "      ${GREEN}✓ Removed ${WRAPPER_SCRIPT}.${NC}"

# ─────────────────────────────────────────────
# [4/N] Remove bare repos (if --remove-repos)
# ─────────────────────────────────────────────
if [[ "$REMOVE_REPOS" == true ]]; then
    echo "[4/${TOTAL_STEPS}] Removing bare repos..."
    if [[ -z "$REPOS" ]]; then
        echo -e "      ${YELLOW}! No repos found in wrapper script — skipping.${NC}"
    else
        REPOS_SKIPPED=false
        while IFS= read -r repo; do
            if [[ ! -d "$repo" ]]; then
                echo -e "      ${YELLOW}! ${repo} not found — skipping.${NC}"
                continue
            fi
            # Check for commits the VM pushed to the bare repo but that haven't
            # been pushed to GitHub yet. Uses local remote-tracking refs only
            # (no network needed — avoids blocking on GitHub availability).
            UNPUSHED=$(git -C "$repo" log --oneline refs/heads --not refs/remotes 2>/dev/null || true)
            if [[ -n "$UNPUSHED" ]]; then
                COUNT=$(echo "$UNPUSHED" | awk 'END{print NR}')
                echo -e "      ${YELLOW}! ${repo}${NC}"
                echo    "        ${COUNT} commit(s) not yet pushed to GitHub:"
                echo "$UNPUSHED" | awk 'NR<=5{print "          " $0} NR==6{print "          ..."}'
                echo -e "        ${RED}✗ Skipping — push first, then re-run --remove-repos:${NC}"
                echo    "          git -C ${repo} push origin main"
                REPOS_SKIPPED=true
            else
                rm -rf "$repo"
                echo -e "      ${GREEN}✓ Removed ${repo}.${NC}"
            fi
        done <<< "$REPOS"
        if [[ "$REPOS_SKIPPED" == true ]]; then
            echo ""
            echo -e "      ${YELLOW}! Some repos were skipped. Push pending commits, then re-run with --remove-repos.${NC}"
        fi
    fi
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "========================================"
echo -e "  ${GREEN}Teardown complete.${NC}"
echo "========================================"
if [[ -n "$REPOS" && "$REMOVE_REPOS" != true ]]; then
    echo "  Bare repos left in place:"
    while IFS= read -r repo; do echo "    ${repo}"; done <<< "$REPOS"
    echo "  Re-run with --remove-repos to delete them."
fi
echo "========================================"
