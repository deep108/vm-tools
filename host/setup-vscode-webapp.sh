#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TART_VM_NAME="${1:-}"
PORT=8000

if [ -z "$TART_VM_NAME" ]; then
    echo "Usage: $(basename "$0") <tart-vm-name>" >&2
    exit 1
fi

# Get the VM's IP address via tart
echo "Getting IP for VM '$TART_VM_NAME'..."
VM_IP=$(tart ip "$TART_VM_NAME")

if [ -z "$VM_IP" ]; then
    echo "Error: Could not get IP for VM '$TART_VM_NAME'" >&2
    exit 1
fi

echo "VM IP: $VM_IP"

# Fetch the manifest path from the HTML, then find the largest icon
BASE_URL="http://${VM_IP}:${PORT}"
echo "Fetching manifest from $BASE_URL..."

MANIFEST_PATH=$(curl -fsSL "$BASE_URL/" | grep -o 'href="[^"]*manifest\.json"' | head -1 | sed 's/href="//;s/"//')

if [ -z "$MANIFEST_PATH" ]; then
    echo "Error: Could not find manifest path in VS Code server HTML" >&2
    exit 1
fi

MANIFEST_BASE="${MANIFEST_PATH%/*}"
MANIFEST_URL="${BASE_URL}${MANIFEST_PATH}"

# Pick the largest icon from the manifest (sort by size, take the biggest)
ICON_SRC=$(curl -fsSL "$MANIFEST_URL" | grep -o '"src": *"[^"]*"' | tail -1 | sed 's/"src": *"//;s/"//')

if [ -z "$ICON_SRC" ]; then
    echo "Error: Could not find icon in manifest" >&2
    exit 1
fi

# Download the PNG icon
ICON_URL="${BASE_URL}${MANIFEST_BASE}/${ICON_SRC}"
PNG_FILE="${SCRIPT_DIR}/${TART_VM_NAME}.png"

echo "Downloading icon from $ICON_URL..."
if ! curl -fsSL -o "$PNG_FILE" "$ICON_URL"; then
    echo "Error: Failed to download icon from $ICON_URL" >&2
    exit 1
fi

ICON_SIZE=$(sips -g pixelWidth "$PNG_FILE" 2>/dev/null | tail -1 | awk '{print $2}')
echo "Saved ${ICON_SIZE}x${ICON_SIZE} icon to $PNG_FILE"

# Convert PNG to .icns via iconset
echo "Converting PNG to .icns..."
ICONSET_DIR=$(mktemp -d)/icon.iconset
mkdir -p "$ICONSET_DIR"

# Generate all standard iconset sizes from the source PNG
declare -a SIZES=(16 32 64 128 256 512)
for size in "${SIZES[@]}"; do
    sips -z "$size" "$size" "$PNG_FILE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PNG_FILE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

ICNS_FILE="${SCRIPT_DIR}/${TART_VM_NAME}.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"
rm -rf "$(dirname "$ICONSET_DIR")"

echo "Created $ICNS_FILE"

# Overlay the VM name onto the icon
echo "Overlaying text '$TART_VM_NAME'..."
LABELED_ICNS="${SCRIPT_DIR}/${TART_VM_NAME}-labeled.icns"
"$SCRIPT_DIR/update-icon.sh" "$ICNS_FILE" "$LABELED_ICNS" "$TART_VM_NAME"

echo "Created $LABELED_ICNS"

# Create the .app bundle using Chrome's app_mode_loader
APP_NAME="VSCode - ${TART_VM_NAME}"
APP_DIR="$HOME/Applications/VSCode VMs"
APP_PATH="${APP_DIR}/${APP_NAME}.app"
VSCODE_URL="http://${VM_IP}:${PORT}/"

# Generate a stable app ID from the VM name (Chrome uses 32-char lowercase strings)
APP_ID=$(echo -n "vscode-vm-${TART_VM_NAME}" | shasum -a 256 | cut -c1-32)

# Find Chrome's app_mode_loader
APP_MODE_LOADER=$(find "/Applications/Google Chrome.app/Contents/Frameworks" -name "app_mode_loader" | sort -V | tail -1)
if [ -z "$APP_MODE_LOADER" ]; then
    echo "Error: Could not find Chrome's app_mode_loader" >&2
    exit 1
fi

# Get Chrome version from the framework path
CHROME_VERSION=$(echo "$APP_MODE_LOADER" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')

echo "Creating app bundle at $APP_PATH..."
mkdir -p "$APP_DIR"
rm -rf "$APP_PATH"

# Build the .app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Chrome's app_mode_loader as the executable
cp "$APP_MODE_LOADER" "$APP_PATH/Contents/MacOS/app_mode_loader"

# Copy our labeled icon
cp "$LABELED_ICNS" "$APP_PATH/Contents/Resources/app.icns"

# Create Info.plist matching Chrome's web app shim format
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>app_mode_loader</string>
	<key>CFBundleIconFile</key>
	<string>app.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.google.Chrome.app.${APP_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string></string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>${CHROME_VERSION}</string>
	<key>CrAppModeShortcutID</key>
	<string>${APP_ID}</string>
	<key>CrAppModeShortcutName</key>
	<string>${APP_NAME}</string>
	<key>CrAppModeShortcutURL</key>
	<string>${VSCODE_URL}</string>
	<key>CrAppModeUserDataDir</key>
	<string>${HOME}/Library/Application Support/Google/Chrome/-/Web Applications/_crx_${APP_ID}</string>
	<key>CrBundleIdentifier</key>
	<string>com.google.Chrome</string>
	<key>CrBundleVersion</key>
	<string>${CHROME_VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>NSAppleScriptEnabled</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Ad-hoc sign matching Chrome's own shim style
codesign --force --sign - "$APP_PATH"

# Touch to refresh Finder icon cache
touch "$APP_PATH"

echo "Created $APP_PATH"
