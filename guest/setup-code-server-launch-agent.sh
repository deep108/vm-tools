#!/bin/bash
set -euo pipefail

# Configuration
BIND_HOST="${BIND_HOST:-0.0.0.0}"
BIND_PORT="${BIND_PORT:-18000}"
SERVICE_USER="${SERVICE_USER:-$(whoami)}"
SERVICE_LABEL="com.user.vscode.serve-web"

# Find the code binary
find_code_binary() {
    local candidates=(
        "/usr/local/bin/code"
        "/opt/homebrew/bin/code"
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    )
    
    for path in "${candidates[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    # Try which as fallback
    if command -v code &>/dev/null; then
        command -v code
        return 0
    fi
    
    echo "Error: Could not find 'code' binary" >&2
    return 1
}

CODE_BINARY="${CODE_BINARY:-$(find_code_binary)}"
PLIST_PATH="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"

echo "Setting up VS Code serve-web as LaunchDaemon..."
echo "  Binary: $CODE_BINARY"
echo "  User: $SERVICE_USER"
echo "  Bind: $BIND_HOST:$BIND_PORT"

# Unload existing service if present
if sudo launchctl list | grep -q "$SERVICE_LABEL"; then
    echo "Stopping existing service..."
    sudo launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# Create the plist
sudo tee "$PLIST_PATH" > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${CODE_BINARY}</string>
        <string>serve-web</string>
        <string>--host</string>
        <string>${BIND_HOST}</string>
        <string>--port</string>
        <string>${BIND_PORT}</string>
        <string>--server-data-dir</string>
        <string>.vscode</string>
        <string>--without-connection-token</string>
        <string>--accept-server-license-terms</string>
    </array>

    <key>UserName</key>
    <string>${SERVICE_USER}</string>

    <key>WorkingDirectory</key>
    <string>/Users/${SERVICE_USER}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/var/log/vscode-serve-web.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/vscode-serve-web.err</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/${SERVICE_USER}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

# Set correct ownership and permissions
sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"

# Create log files with correct permissions
sudo touch /var/log/vscode-serve-web.log /var/log/vscode-serve-web.err
sudo chown "$SERVICE_USER" /var/log/vscode-serve-web.log /var/log/vscode-serve-web.err

# Load the service
sudo launchctl load "$PLIST_PATH"

# Verify the service started successfully
echo ""
echo "Verifying service..."
sleep 2

status_line=$(sudo launchctl list | grep "$SERVICE_LABEL" || true)

if [[ -z "$status_line" ]]; then
    echo "✗ Service failed to load — not found in launchctl list"
    echo "  Check plist: $PLIST_PATH"
    exit 1
fi

pid=$(echo "$status_line" | awk '{print $1}')
exit_code=$(echo "$status_line" | awk '{print $2}')

if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$exit_code" == "0" ]]; then
    echo "✓ VS Code serve-web installed and running (PID $pid)"
else
    echo "✗ Service loaded but process is not running (last exit code: $exit_code)"
    echo ""
    echo "Last error log output:"
    tail -10 /var/log/vscode-serve-web.err 2>/dev/null || echo "  (no error log found)"
    exit 1
fi

echo ""
echo "Useful commands:"
echo "  Status:  sudo launchctl list | grep $SERVICE_LABEL"
echo "  Stop:    sudo launchctl unload $PLIST_PATH"
echo "  Start:   sudo launchctl load $PLIST_PATH"
echo "  Logs:    tail -f /var/log/vscode-serve-web.log"
echo ""
echo "Access at: http://localhost:$BIND_PORT"