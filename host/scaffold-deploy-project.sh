#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pick-vm.sh
source "$SCRIPT_DIR/lib/pick-vm.sh"

# --- Defaults ---
VM_NAME=""
PROJECT=""
FORCE=false

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [<project>] [--vm <name>] [--force]

Scaffolds the deploy-project template into ~/dev/<project> on a Tart VM.
Prompts for any missing config, runs sed substitutions remotely, appends to
.gitignore, and runs git init if needed.

Defaults:
  VM           : a Tart VM whose name matches <project>; otherwise picker.
  Domain       : <project>.deepdevelopment.com
  Admin user   : \$USER (host's username)
  GAR region   : us-west1
  GAR repo     : <project>

Positional:
  <project>    Project name (lowercase + hyphens). Prompted if omitted.

Flags:
  --vm <name>  Override the project-name → VM match.
  --force      Overwrite an existing scaffolded project (bin/, config/, .kamal/).
  -h, --help   Show this help.

This script doesn't depend on bridge-vm-git.sh and can run before or after
that's been set up. It also doesn't touch Hetzner; the templated
bin/bootstrap-server handles per-project Hetzner setup later.
EOF
    exit 1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)
            [[ -z "${2:-}" ]] && { echo "Error: --vm requires a value"; usage; }
            VM_NAME="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$PROJECT" ]]; then
                PROJECT="$1"
                shift
            else
                echo "Unexpected positional argument: $1"
                usage
            fi
            ;;
    esac
done

HOST_USER="$(whoami)"

# Helper: get a VM's state from `tart list`, or empty if not found.
vm_state() {
    tart list 2>/dev/null | awk -v name="$1" '$1=="local" && $2==name {print $NF; exit}'
}

# --- Prompt for project name if not given ---
if [[ -z "$PROJECT" ]]; then
    read -r -p "Project name: " PROJECT
fi
if ! [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Error: project name must be lowercase alphanumeric + hyphens, starting with letter/digit."
    exit 1
fi

# --- Resolve VM: --vm > project-name match > picker ---
if [[ -z "$VM_NAME" ]]; then
    matched_state="$(vm_state "$PROJECT")"
    if [[ -n "$matched_state" ]]; then
        VM_NAME="$PROJECT"
        echo "Found Tart VM '$VM_NAME' matching project name (state: $matched_state)."
    fi
fi
if [[ -z "$VM_NAME" ]]; then
    echo "No Tart VM matches project name '$PROJECT'. Pick one:"
    pick_vm "running"
fi

# --- Ensure VM is running (offer to start if not) ---
state="$(vm_state "$VM_NAME")"
if [[ -z "$state" ]]; then
    echo "Error: VM '$VM_NAME' not found."
    exit 1
fi
if [[ "$state" != "running" ]]; then
    echo "VM '$VM_NAME' is currently $state."
    read -r -p "Start it now via run-vm.sh? [Y/n] " ans
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        echo "Aborted. Start the VM and re-run."
        exit 0
    fi
    "$SCRIPT_DIR/run-vm.sh" "$VM_NAME"
fi

VM_IP="$(tart ip "$VM_NAME" 2>/dev/null || true)"
if [[ -z "$VM_IP" ]]; then
    echo "Error: could not get IP for VM '$VM_NAME'."
    exit 1
fi

# --- SSH helper ---
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10"
vm_ssh() { ssh $SSH_OPTS "$HOST_USER@$VM_IP" "$@"; }

if ! vm_ssh true 2>/dev/null; then
    echo "Error: cannot SSH to $HOST_USER@$VM_IP"
    exit 1
fi

if ! vm_ssh "test -d ~/dev/vm-tools/templates/deploy-project"; then
    echo "Error: ~/dev/vm-tools/templates/deploy-project not found on VM."
    echo "  Run on the VM: cd ~/dev/vm-tools && git pull"
    exit 1
fi

# --- Prompt for inputs (with defaults) ---
echo ""
read -r -p "Hetzner host IP: " HETZNER_HOST
read -r -p "Domain [${PROJECT}.deepdevelopment.com]: " DOMAIN
DOMAIN="${DOMAIN:-${PROJECT}.deepdevelopment.com}"
read -r -p "Admin user on Hetzner [${HOST_USER}]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-$HOST_USER}"
read -r -p "GCP project ID: " GCP_PROJECT
read -r -p "GAR region [us-west1]: " GAR_REGION
GAR_REGION="${GAR_REGION:-us-west1}"
read -r -p "GAR repo name [${PROJECT}]: " GAR_REPO
GAR_REPO="${GAR_REPO:-$PROJECT}"

# --- Validate (anything that lands in `sed` must not contain shell-special chars) ---
[[ "$HETZNER_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || { echo "Error: Hetzner host must be an IPv4 address."; exit 1; }
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] \
    || { echo "Error: domain has invalid characters."; exit 1; }
[[ "$ADMIN_USER" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] \
    || { echo "Error: admin user has invalid characters."; exit 1; }
[[ "$GCP_PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] \
    || { echo "Error: GCP project ID format invalid (6-30 lowercase chars + hyphens)."; exit 1; }
[[ "$GAR_REGION" =~ ^[a-z0-9-]+$ ]] \
    || { echo "Error: GAR region has invalid characters."; exit 1; }
[[ "$GAR_REPO" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || { echo "Error: GAR repo has invalid characters."; exit 1; }

# --- Summary + confirm ---
echo ""
echo "=== Scaffold deploy project ==="
echo "  VM           : $VM_NAME ($VM_IP)"
echo "  Project      : $PROJECT"
echo "  Path on VM   : ~/dev/$PROJECT"
echo "  Hetzner host : $HETZNER_HOST"
echo "  Domain       : $DOMAIN"
echo "  Admin user   : $ADMIN_USER"
echo "  GCP project  : $GCP_PROJECT"
echo "  GAR region   : $GAR_REGION"
echo "  GAR repo     : $GAR_REPO"
[[ "$FORCE" == true ]] && echo "  Force        : true (will overwrite scaffolded files)"
echo ""
read -r -p "Proceed? [Y/n] " confirm
[[ "$confirm" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# --- Existing-scaffold + uncommitted-changes checks ---
if vm_ssh "test -e ~/dev/$PROJECT/bin/bootstrap-server"; then
    if [[ "$FORCE" != true ]]; then
        echo "Error: ~/dev/$PROJECT is already scaffolded (bin/bootstrap-server exists)."
        echo "       Pass --force to overwrite the templated files."
        exit 1
    fi
fi

if vm_ssh "test -d ~/dev/$PROJECT/.git"; then
    if vm_ssh "cd ~/dev/$PROJECT && git status --porcelain | grep -q ."; then
        echo ""
        echo "WARNING: ~/dev/$PROJECT has uncommitted changes."
        echo "         Scaffolding will append to .gitignore and add new files alongside."
        read -r -p "Continue anyway? [y/N] " ans2
        [[ ! "$ans2" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
    fi
fi

# --- Run scaffolding on VM ---
echo ""
echo "[1/4] Creating project directory..."
vm_ssh "mkdir -p ~/dev/$PROJECT"

echo "[2/4] Copying templates and substituting placeholders..."
# Single combined remote bash -c so we control glob expansion + handle errors
# in one place (vs. shipping each step as its own ssh round-trip).
vm_ssh "bash -c 'set -e
cd ~/dev/$PROJECT
cp -r ~/dev/vm-tools/templates/deploy-project/bin .
cp -r ~/dev/vm-tools/templates/deploy-project/config .
cp -r ~/dev/vm-tools/templates/deploy-project/.kamal .
files=(bin/bootstrap-server bin/deploy config/deploy.yml)
sed -i \"s|__PROJECT__|$PROJECT|g\" \"\${files[@]}\"
sed -i \"s|__HETZNER_HOST__|$HETZNER_HOST|g\" \"\${files[@]}\"
sed -i \"s|__DOMAIN__|$DOMAIN|g\" \"\${files[@]}\"
sed -i \"s|__ADMIN_USER__|$ADMIN_USER|g\" \"\${files[@]}\"
sed -i \"s|__GCP_PROJECT__|$GCP_PROJECT|g\" \"\${files[@]}\"
sed -i \"s|__GAR_REGION__|$GAR_REGION|g\" \"\${files[@]}\"
sed -i \"s|__GAR_REPO__|$GAR_REPO|g\" \"\${files[@]}\"
chmod +x bin/bootstrap-server bin/deploy
touch .gitignore
if ! grep -qxF \".kamal/secrets\" .gitignore; then
    cat ~/dev/vm-tools/templates/deploy-project/.gitignore.append >> .gitignore
fi'"

echo "[3/4] Initializing git repo (if not already)..."
vm_ssh "cd ~/dev/$PROJECT && [ -d .git ] || git init -q"

echo "[4/4] Done."
echo ""
echo "Next steps (run on the VM):"
echo "  1. ssh $HOST_USER@$VM_IP"
echo "  2. cd ~/dev/$PROJECT"
echo "  3. Encrypt the GCP service-account JSON key as .kamal/secrets.age"
echo "       (see ~/dev/vm-tools/templates/deploy-project/README.md \"Set up secrets\")"
echo "  4. Add Dockerfile + app code"
echo "  5. bin/bootstrap-server          # one-time per (project, server)"
echo "  6. git tag -s v0.1.0 -m '...' && git verify-tag v0.1.0 && bin/deploy v0.1.0"
