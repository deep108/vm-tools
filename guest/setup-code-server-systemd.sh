#!/bin/bash
set -euo pipefail

# Configuration
BIND_HOST="${BIND_HOST:-0.0.0.0}"
BIND_PORT="${BIND_PORT:-18000}"
SERVICE_USER="${SERVICE_USER:-$(whoami)}"
SERVICE_NAME="vscode-serve-web"

# Find the code binary
find_code_binary() {
    local candidates=(
        "/usr/bin/code"
        "/usr/local/bin/code"
    )

    for path in "${candidates[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    if command -v code &>/dev/null; then
        command -v code
        return 0
    fi

    echo "Error: Could not find 'code' binary" >&2
    return 1
}

CODE_BINARY="${CODE_BINARY:-$(find_code_binary)}"
USER_HOME=$(eval echo "~$SERVICE_USER")

echo "Setting up VS Code serve-web as systemd service..."
echo "  Binary: $CODE_BINARY"
echo "  User: $SERVICE_USER"
echo "  Bind: $BIND_HOST:$BIND_PORT"

# Stop existing service if present
if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Stopping existing service..."
    sudo systemctl stop "$SERVICE_NAME"
fi

# Create the systemd unit file
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null << EOF
[Unit]
Description=VS Code serve-web
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${CODE_BINARY} serve-web --host ${BIND_HOST} --port ${BIND_PORT} --server-data-dir .vscode --without-connection-token --accept-server-license-terms
Restart=always
RestartSec=5
WorkingDirectory=${USER_HOME}
Environment=HOME=${USER_HOME}

[Install]
WantedBy=multi-user.target
EOF

# Reload, enable, and start
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"

# Verify
echo ""
echo "Verifying service..."
sleep 2

if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    PID=$(sudo systemctl show "$SERVICE_NAME" --property=MainPID --value)
    echo "VS Code serve-web installed and running (PID $PID)"
else
    echo "Service failed to start."
    echo ""
    echo "Journal output:"
    sudo journalctl -u "$SERVICE_NAME" --no-pager -n 10
    exit 1
fi

echo ""
echo "Useful commands:"
echo "  Status:  sudo systemctl status $SERVICE_NAME"
echo "  Stop:    sudo systemctl stop $SERVICE_NAME"
echo "  Start:   sudo systemctl start $SERVICE_NAME"
echo "  Logs:    sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "Access at: http://localhost:$BIND_PORT"
