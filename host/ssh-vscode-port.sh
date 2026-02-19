#!/usr/bin/env bash
set -euo pipefail

# Defaults
PORT=8000
# VM_ADDRESS="tahoe-test-vm.local"
# SSH_USER="admin"
SSH_HOST="tahoe-test-vm"

usage() {
    echo "Usage: $(basename "$0") [-p PORT] [-a ADDRESS] [-u SSH_USER] [-H HOST] [-h]"
    echo
    echo "Create an SSH tunnel with port forwarding."
    echo
    echo "Options:"
    echo "  -p PORT      Local and remote port to forward (default: 8000)"
    echo "  -a ADDRESS   VM address to connect to (default: 192.168.64.2)"
    echo "  -u SSH_USER  SSH username (default: admin)"
    echo "  -H HOST      SSH config alias (overrides -a and -u)"
    echo "  -h           Show this help message"
    echo
    echo "Examples:"
    echo "  $(basename "$0") -p 8080 -a 192.168.64.5 -u myuser"
    echo "  $(basename "$0") -p 8080 -H myvm    # Uses alias from ~/.ssh/config"
    exit 0
}

port_in_use() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -i :"$port" &>/dev/null
    elif command -v ss &>/dev/null; then
        ss -tuln | grep -q ":$port "
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":$port "
    else
        # Can't check, assume it's fine
        return 1
    fi
}

while getopts ":p:a:u:H:h" opt; do
    case $opt in
        p) PORT="$OPTARG" ;;
        a) VM_ADDRESS="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        H) SSH_HOST="$OPTARG" ;;
        h) usage ;;
        :) echo "Error: -$OPTARG requires an argument" >&2; exit 1 ;;
        \?) echo "Error: Unknown option -$OPTARG" >&2; exit 1 ;;
    esac
done

# Validation
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Error: Port must be a number between 1 and 65535" >&2
    exit 1
fi

# Check if port is already in use
if port_in_use "$PORT"; then
    echo "Error: Port $PORT is already in use" >&2
    if command -v lsof &>/dev/null; then
        echo "Process using the port:" >&2
        lsof -i :"$PORT" | head -5 >&2
    fi
    exit 1
fi

# Determine SSH target
if [ -n "$SSH_HOST" ]; then
    SSH_TARGET="$SSH_HOST"
else
    if [ -z "$VM_ADDRESS" ]; then
        echo "Error: VM address cannot be empty" >&2
        exit 1
    fi
    if [ -z "$SSH_USER" ]; then
        echo "Error: SSH user cannot be empty" >&2
        exit 1
    fi
    SSH_TARGET="$SSH_USER@$VM_ADDRESS"
fi

echo "Connecting to $SSH_TARGET with port forwarding on $PORT..."
# echo "DEBUG: [${PORT}:localhost:${PORT}]" | od -c
ssh -L "${PORT}:localhost:${PORT}" "$SSH_TARGET"