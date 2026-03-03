#!/bin/bash
set -euo pipefail

# Pure icon transformation: overlays text onto an .icns file and outputs a new .icns
# Usage: update-icon.sh <input.icns> <output.icns> <text> [base-font-size]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_SCRIPT="$SCRIPT_DIR/iconoverlay.swift"

if [ ! -f "$SWIFT_SCRIPT" ]; then
    echo "Error: iconoverlay.swift not found in $SCRIPT_DIR" >&2
    exit 1
fi

INPUT_ICON="${1:-}"
OUTPUT_ICON="${2:-}"
TEXT="${3:-}"
BASE_FONT_SIZE="${4:-72}"

if [ -z "$INPUT_ICON" ] || [ -z "$OUTPUT_ICON" ] || [ -z "$TEXT" ]; then
    echo "Usage: $(basename "$0") <input.icns> <output.icns> <text> [base-font-size]"
    echo ""
    echo "Overlays text onto an .icns file."
    echo ""
    echo "Arguments:"
    echo "  input.icns      Source .icns file"
    echo "  output.icns     Output .icns file (can be same as input)"
    echo "  text            Text to overlay on the icon"
    echo "  base-font-size  Font size for 512px icons (default: 72)"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") original.icns labeled.icns 'my-vm'"
    echo "  $(basename "$0") original.icns labeled.icns 'my-vm' 96"
    exit 1
fi

if [ ! -f "$INPUT_ICON" ]; then
    echo "Error: Input file not found: $INPUT_ICON" >&2
    exit 1
fi

swift "$SWIFT_SCRIPT" "$INPUT_ICON" "$OUTPUT_ICON" "$TEXT" "$BASE_FONT_SIZE"
