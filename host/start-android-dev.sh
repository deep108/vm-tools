#!/bin/bash
set -euo pipefail

# Start the host-side Android emulator and optionally bridge ADB to a VM.
#
# Architecture: The emulator runs natively on the host (Apple Silicon requires
# Hypervisor.framework, which is unavailable in VMs). The AI coding agent runs
# in a sandbox (sandbox-runtime) or VM for isolation. This script bridges them.
#
# Modes:
#   --emulator-only   Start emulator + ADB server (for sandbox-runtime / Option 2)
#   --bridge <vm>     Start emulator + ADB server + socat bridge to VM (for Tart VM / Option 1)
#   --device          Use physical device instead of emulator (for Option 3)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
MODE="emulator-only"
VM_NAME=""
METRO_PORT=8081
AVD_NAME=""
DEVICE_MODE=false
WIPE_DATA=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Usage ---
usage() {
    echo "Usage: $(basename "$0") [options]"
    echo ""
    echo "Start host-side Android emulator/device and optionally bridge to a sandboxed environment."
    echo ""
    echo "Modes:"
    echo "  --emulator-only       Start emulator + ADB (default). For use with sandbox-runtime."
    echo "  --bridge <vm-name>    Start emulator + bridge ADB/Metro ports to a Tart VM."
    echo "  --device              Use a connected physical device instead of the emulator."
    echo ""
    echo "Options:"
    echo "  --avd <name>          AVD name to launch (default: auto-detect or first available)."
    echo "  --metro-port <port>   Metro bundler port to bridge (default: 8081)."
    echo "  --wipe                Wipe emulator data before starting."
    echo "  -h, --help            Show this help."
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                           # Start emulator for sandbox-runtime"
    echo "  $(basename "$0") --bridge my-android-vm    # Bridge to Tart VM"
    echo "  $(basename "$0") --device                  # Use physical device"
    exit 1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --emulator-only)
            MODE="emulator-only"
            shift
            ;;
        --bridge)
            MODE="bridge"
            [[ -z "${2:-}" ]] && { echo "Error: --bridge requires a VM name"; usage; }
            VM_NAME="$2"
            shift 2
            ;;
        --device)
            MODE="device"
            DEVICE_MODE=true
            shift
            ;;
        --avd)
            [[ -z "${2:-}" ]] && { echo "Error: --avd requires a name"; usage; }
            AVD_NAME="$2"
            shift 2
            ;;
        --metro-port)
            [[ -z "${2:-}" ]] && { echo "Error: --metro-port requires a value"; usage; }
            METRO_PORT="$2"
            shift 2
            ;;
        --wipe)
            WIPE_DATA=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# --- Locate Android SDK ---
if [[ -n "${ANDROID_HOME:-}" ]]; then
    SDK_DIR="$ANDROID_HOME"
elif [[ -d "$HOME/Library/Android/sdk" ]]; then
    SDK_DIR="$HOME/Library/Android/sdk"
else
    echo -e "${RED}Error: Android SDK not found. Set ANDROID_HOME or install Android Studio.${NC}"
    exit 1
fi

ADB="$SDK_DIR/platform-tools/adb"
EMULATOR="$SDK_DIR/emulator/emulator"

if [[ ! -x "$ADB" ]]; then
    echo -e "${RED}Error: adb not found at $ADB${NC}"
    exit 1
fi

# --- Cleanup handler ---
# In bridge mode, clean up socat on exit. In emulator-only/device mode, leave
# the emulator running — the user manages its lifecycle via `adb emu kill`.
SOCAT_PID=""
EMULATOR_PID=""
cleanup() {
    if [[ -n "$SOCAT_PID" ]]; then
        echo ""
        echo -e "${YELLOW}Shutting down socat bridge...${NC}"
        kill "$SOCAT_PID" 2>/dev/null && echo "  Stopped socat (PID $SOCAT_PID)"
    fi
}
trap cleanup EXIT

# --- Device mode ---
if [[ "$DEVICE_MODE" == true ]]; then
    echo -e "${BLUE}=== Physical Device Mode ===${NC}"
    echo ""

    # Check for connected devices
    DEVICES=$("$ADB" devices | grep -v "^List" | grep -v "^$" | grep "device$" || true)
    if [[ -z "$DEVICES" ]]; then
        echo -e "${YELLOW}No devices connected. Checking for wireless devices...${NC}"
        echo ""
        echo "To connect a device:"
        echo "  1. Enable Developer Options on the device"
        echo "  2. Enable Wireless debugging"
        echo "  3. Run: $ADB pair <ip>:<port>    (from the pairing dialog)"
        echo "  4. Run: $ADB connect <ip>:<port>  (from the wireless debugging screen)"
        echo ""
        echo "Or connect via USB and enable USB debugging."
        exit 1
    fi

    echo -e "${GREEN}Connected devices:${NC}"
    "$ADB" devices -l | grep "device " || true
    echo ""

    # Set up adb reverse for Metro
    echo "Setting up adb reverse for Metro (port $METRO_PORT)..."
    "$ADB" reverse tcp:"$METRO_PORT" tcp:"$METRO_PORT"
    echo -e "${GREEN}Done. Metro on localhost:$METRO_PORT will be accessible from the device.${NC}"
    echo ""
    echo "Start Metro in your project: npx react-native start"
    echo "Deploy: npx react-native run-android"
    echo ""
    echo "Screen mirror (optional): scrcpy"
    exit 0
fi

# --- Emulator mode ---
if [[ ! -x "$EMULATOR" ]]; then
    echo -e "${RED}Error: emulator not found at $EMULATOR${NC}"
    echo "Install via: sdkmanager 'emulator' 'system-images;android-36;google_apis;arm64-v8a'"
    exit 1
fi

# Auto-detect AVD if not specified
if [[ -z "$AVD_NAME" ]]; then
    AVD_NAME=$("$EMULATOR" -list-avds 2>/dev/null | head -1)
    if [[ -z "$AVD_NAME" ]]; then
        echo -e "${RED}Error: No AVDs found. Create one first:${NC}"
        echo "  $SDK_DIR/cmdline-tools/latest/bin/avdmanager create avd \\"
        echo "    -n Pixel_8 -k 'system-images;android-36;google_apis;arm64-v8a' -d pixel_8"
        exit 1
    fi
fi

echo -e "${BLUE}=== Android Dev Environment ===${NC}"
echo "  Mode     : $MODE"
echo "  AVD      : $AVD_NAME"
echo "  SDK      : $SDK_DIR"
if [[ "$MODE" == "bridge" ]]; then
    echo "  VM       : $VM_NAME"
    echo "  Metro    : port $METRO_PORT (bridged to VM)"
fi
echo ""

# Check if emulator is already running
if "$ADB" devices 2>/dev/null | grep -q "emulator-"; then
    echo -e "${YELLOW}Emulator already running.${NC}"
    "$ADB" devices -l | grep "emulator-" || true
else
    # Start emulator
    EMULATOR_ARGS=(-avd "$AVD_NAME" -no-snapshot-load)
    if [[ "$WIPE_DATA" == true ]]; then
        EMULATOR_ARGS+=(-wipe-data)
    fi

    echo "Starting emulator ($AVD_NAME)..."
    "$EMULATOR" "${EMULATOR_ARGS[@]}" &>/dev/null &
    EMULATOR_PID=$!

    # Wait for emulator to boot
    echo -n "Waiting for device..."
    "$ADB" wait-for-device
    # Wait for boot to complete
    BOOT_TIMEOUT=120
    BOOT_START=$(date +%s)
    while true; do
        BOOT_ELAPSED=$(( $(date +%s) - BOOT_START ))
        if [[ $BOOT_ELAPSED -ge $BOOT_TIMEOUT ]]; then
            echo ""
            echo -e "${RED}Error: Emulator boot timed out after ${BOOT_TIMEOUT}s.${NC}"
            exit 1
        fi
        BOOT_PROP=$("$ADB" shell getprop sys.boot_completed 2>/dev/null || true)
        if [[ "$BOOT_PROP" == "1" ]]; then
            break
        fi
        printf "\rWaiting for boot... %ds" "$BOOT_ELAPSED"
        sleep 2
    done
    printf "\r${GREEN}Emulator booted.%-30s${NC}\n" ""
fi

# --- Bridge mode: set up port forwarding to VM ---
if [[ "$MODE" == "bridge" ]]; then
    # Get VM IP
    VM_IP=$(tart ip "$VM_NAME" 2>/dev/null || true)
    if [[ -z "$VM_IP" ]]; then
        echo -e "${RED}Error: Could not get IP for VM '$VM_NAME'. Is it running?${NC}"
        echo "Start it with: run-vm.sh $VM_NAME --linux --gui"
        exit 1
    fi
    echo "VM IP: $VM_IP"

    # Set up adb reverse so the emulator app can reach Metro on the host
    # Then socat bridges host:METRO_PORT → VM:METRO_PORT
    echo "Setting up ADB reverse (emulator → host:$METRO_PORT)..."
    "$ADB" reverse tcp:"$METRO_PORT" tcp:"$METRO_PORT"

    echo "Starting socat bridge (host:$METRO_PORT → VM:$METRO_PORT)..."
    # socat listens on host METRO_PORT, forwards to VM METRO_PORT
    # Only start if nothing is already listening on the port
    if lsof -i :"$METRO_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo -e "${YELLOW}Port $METRO_PORT already in use — skipping socat (Metro may be running locally).${NC}"
    else
        socat TCP-LISTEN:"$METRO_PORT",fork,reuseaddr TCP:"$VM_IP":"$METRO_PORT" &
        SOCAT_PID=$!
        echo -e "${GREEN}Socat bridge running (PID $SOCAT_PID).${NC}"
    fi

    echo ""
    echo -e "${GREEN}=== Bridge Ready ===${NC}"
    echo ""
    echo "In the VM ($VM_NAME):"
    echo "  1. Start Metro:  npx react-native start --host 0.0.0.0"
    echo "  2. Build APK:    npx react-native build-android --mode=debug"
    echo "  3. Install APK:  ANDROID_ADB_SERVER_ADDRESS=$(ipconfig getifaddr en0 2>/dev/null || echo '<host-ip>') adb install app/build/outputs/apk/debug/app-debug.apk"
    echo ""
    echo "Or set in the VM's shell:"
    echo "  export ANDROID_ADB_SERVER_ADDRESS=$(ipconfig getifaddr en0 2>/dev/null || echo '<host-ip>')"
    echo "  export REACT_NATIVE_PACKAGER_HOSTNAME=0.0.0.0"
    echo ""
    echo "Press Ctrl+C to stop."
    wait
else
    # Emulator-only mode (for sandbox-runtime or direct host development)
    echo ""
    echo -e "${GREEN}=== Emulator Ready ===${NC}"
    echo ""
    echo "The emulator is running. Start your development environment:"
    echo ""
    echo "  Sandbox (recommended):"
    echo "    claude --sandbox --allowLocalBinding"
    echo ""
    echo "  Direct:"
    echo "    cd <your-rn-project>"
    echo "    npx react-native start        # Metro bundler"
    echo "    npx react-native run-android   # Build + deploy"
    echo ""
    echo "ADB reverse for Metro:"
    "$ADB" reverse tcp:"$METRO_PORT" tcp:"$METRO_PORT" >/dev/null 2>&1 || true
    echo "  localhost:$METRO_PORT → emulator (set)"
    echo ""
    echo "Emulator PID: ${EMULATOR_PID:-<already running>}"
    echo "Stop emulator: $ADB emu kill"
fi
