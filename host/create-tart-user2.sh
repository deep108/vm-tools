#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage:"
    echo "  $0 <vm-name> <username> [password]       Create a user"
    echo "  $0 -d <vm-name> <username>               Delete a user"
    echo ""
    echo "Options:"
    echo "  -d, --delete    Delete the specified user instead of creating"
    exit 1
}

DELETE_MODE=false

# Check for delete flag
if [[ "${1:-}" == "-d" || "${1:-}" == "--delete" ]]; then
    DELETE_MODE=true
    shift
fi

VM_NAME="${1:-}"
TARGET_USER="${2:-}"
PASSWORD="${3:-}"

[[ -z "$VM_NAME" || -z "$TARGET_USER" ]] && usage

# Get VM IP (assumes VM is already running)
VM_IP=$(tart ip "$VM_NAME" 2>/dev/null) || {
    echo "Error: Could not get IP for VM '$VM_NAME'. Is it running?"
    exit 1
}

# Helper function to run SSH commands with proper error handling
run_ssh() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "admin@${VM_IP}" "$@"
}

# --- DELETE MODE ---
if [[ "$DELETE_MODE" == true ]]; then
    read -p "Are you sure you want to delete user '$TARGET_USER' on $VM_NAME? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    echo "Deleting user '$TARGET_USER' on $VM_NAME ($VM_IP)..."
    
    if run_ssh "sudo sysadminctl -deleteUser '$TARGET_USER'" 2>&1; then
        echo "User '$TARGET_USER' deleted successfully."
    else
        echo "Warning: Delete command returned an error (user may not have existed)."
    fi
    exit 0
fi

# --- CREATE MODE ---

# Check if user already exists
echo "Checking if user '$TARGET_USER' already exists..."
if run_ssh "id '$TARGET_USER'" &>/dev/null; then
    echo "Error: User '$TARGET_USER' already exists on the VM."
    echo "Delete the user first with: $0 -d $VM_NAME $TARGET_USER"
    exit 1
fi

# Check for leftover home directory
if run_ssh "test -d '/Users/$TARGET_USER'" &>/dev/null; then
    echo "Warning: Home directory /Users/$TARGET_USER already exists (leftover from previous user?)."
    read -p "Delete it before proceeding? [y/N]: " DELETE_HOME
    if [[ "$DELETE_HOME" =~ ^[Yy]$ ]]; then
        run_ssh "sudo rm -rf '/Users/$TARGET_USER'"
        echo "Removed leftover home directory."
    else
        echo "Aborted. Please manually resolve the leftover directory."
        exit 1
    fi
fi

# Prompt for password if not provided
if [[ -z "$PASSWORD" ]]; then
    while true; do
        read -s -p "Password for new user '$TARGET_USER': " PASSWORD
        echo
        read -s -p "Confirm password: " PASSWORD_CONFIRM
        echo
        
        if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
fi

# Prompt for optional full name
read -p "Full name (leave blank to use '$TARGET_USER'): " FULL_NAME
FULL_NAME="${FULL_NAME:-$TARGET_USER}"

# Prompt for admin privileges
read -p "Make user an admin? [y/N]: " MAKE_ADMIN
ADMIN_FLAG=""
if [[ "$MAKE_ADMIN" =~ ^[Yy]$ ]]; then
    ADMIN_FLAG="-admin"
fi

echo "Creating user '$TARGET_USER' on $VM_NAME ($VM_IP)..."

# Create the user via SSH with verbose output
if OUTPUT=$(run_ssh "sudo sysadminctl -addUser '$TARGET_USER' -fullName '$FULL_NAME' -password '$PASSWORD' $ADMIN_FLAG" 2>&1); then
    echo "User '$TARGET_USER' created successfully."
    [[ -n "$ADMIN_FLAG" ]] && echo "  - Admin privileges: yes" || echo "  - Admin privileges: no"
    echo "  - Full name: $FULL_NAME"
else
    echo "Error creating user. Output:"
    echo "$OUTPUT"
    exit 1
fi

# Verify the user was actually created
if run_ssh "id '$TARGET_USER'" &>/dev/null; then
    echo "Verified: User exists on system."
else
    echo "Warning: User creation may have failed - user not found in system."
    exit 1
fi