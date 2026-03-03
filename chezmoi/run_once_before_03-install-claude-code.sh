#!/bin/zsh
# chezmoi run_once_before script: Install Claude Code
# Migrated from check-dev-env.sh

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

ZSHRC="$HOME/.zshrc"
[[ ! -f "$ZSHRC" ]] && touch "$ZSHRC"

if ! command -v claude &>/dev/null; then
    if [[ -x "$HOME/.local/bin/claude" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo -e "${BLUE}Installing Claude Code...${NC}"
        curl -fsSL https://claude.ai/install.sh | bash >/dev/null
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

if command -v claude &>/dev/null; then
    claude_version=$(claude --version 2>/dev/null | awk 'NR==1' || echo "unknown")
    echo -e "${GREEN}✓${NC} Claude Code ($claude_version)"

    # Ensure ~/.local/bin is in PATH in .zshrc
    if ! grep -q '\.local/bin' "$ZSHRC"; then
        echo '' >> "$ZSHRC"
        echo '# Claude Code' >> "$ZSHRC"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZSHRC"
        echo -e "${GREEN}✓${NC} Added ~/.local/bin to PATH in ~/.zshrc"
    fi
else
    echo -e "${RED}✗${NC} Claude Code installation failed"
fi
