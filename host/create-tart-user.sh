#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <vm-name> <username> [password]"
    echo "Options are prompted interactively."
    exit 1
}

VM_NAME="${1:-}"
NEW_USER="${2:-}"
PASSWORD="${3:-}"

[[ -z "$VM_NAME" || -z "$NEW_USER" ]] && usage

# Prompt for password if not provided
if [[ -z "$PASSWORD" ]]; then
    read -s -p "Password for new user '$NEW_USER': " PASSWORD
    echo
fi

# Prompt for optional full name
read -p "Full name (leave blank to use '$NEW_USER'): " FULL_NAME
FULL_NAME="${FULL_NAME:-$NEW_USER}"

# Prompt for admin privileges
read -p "Make user an admin? [y/N]: " MAKE_ADMIN
ADMIN_FLAG=""
if [[ "$MAKE_ADMIN" =~ ^[Yy]$ ]]; then
    ADMIN_FLAG="-admin"
fi

# Get VM IP (assumes VM is already running)
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null) || {
    echo "Error: Could not get IP for VM '$VM_NAME'. Is it running?"
    exit 1
}

echo "Creating user '$NEW_USER' on $VM_NAME ($VM_IP)..."

# Create the user via SSH
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "admin@${VM_IP}" \
    "sudo sysadminctl -addUser '$NEW_USER' -fullName '$FULL_NAME' -password '$PASSWORD' $ADMIN_FLAG"

echo "User '$NEW_USER' created successfully."
[[ -n "$ADMIN_FLAG" ]] && echo "  - Admin privileges: yes" || echo "  - Admin privileges: no"
echo "  - Full name: $FULL_NAME"

# ```

# **Example session:**
# ```
# $ ./create-tart-user.sh my-vm devuser
# Password for new user 'devuser': 
# Full name (leave blank to use 'devuser'): Jane Developer
# Make user an admin? [y/N]: n
# Creating user 'devuser' on my-vm (192.168.64.5)...
# User 'devuser' created successfully.
#   - Admin privileges: no
#   - Full name: Jane Developer