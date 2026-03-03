#!/bin/zsh
# chezmoi run_once_before script: Install dev tools via Homebrew
# Migrated from check-dev-env.sh

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure brew is on PATH
if ! command -v brew &>/dev/null; then
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

ZSHRC="$HOME/.zshrc"
[[ ! -f "$ZSHRC" ]] && touch "$ZSHRC"

# mise (tool version manager)
if ! command -v mise &>/dev/null; then
    echo -e "${BLUE}Installing mise...${NC}"
    brew install mise
fi
mise_version=$(mise --version 2>/dev/null | awk '{print $1}')
echo -e "${GREEN}✓${NC} mise ($mise_version)"

if ! grep -q 'mise activate' "$ZSHRC"; then
    echo '' >> "$ZSHRC"
    echo '# mise (tool version manager)' >> "$ZSHRC"
    echo 'eval "$(mise activate zsh)"' >> "$ZSHRC"
    echo -e "${GREEN}✓${NC} Added mise activation to ~/.zshrc"
fi

# chezmoi
if ! command -v chezmoi &>/dev/null; then
    echo -e "${BLUE}Installing chezmoi...${NC}"
    brew install chezmoi
fi
chezmoi_version=$(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d 'v,' || echo "unknown")
echo -e "${GREEN}✓${NC} chezmoi ($chezmoi_version)"

# starship
if ! command -v starship &>/dev/null; then
    echo -e "${BLUE}Installing starship...${NC}"
    brew install starship
fi
starship_version=$(starship --version 2>/dev/null | awk 'NR==1{print $2}' || echo "unknown")
echo -e "${GREEN}✓${NC} starship ($starship_version)"

# tmux
if ! command -v tmux &>/dev/null; then
    echo -e "${BLUE}Installing tmux...${NC}"
    brew install tmux
fi
tmux_version=$(tmux -V 2>/dev/null | awk '{print $2}')
echo -e "${GREEN}✓${NC} tmux ($tmux_version)"

# VS Code
if ! [ -d "/Applications/Visual Studio Code.app" ]; then
    echo -e "${BLUE}Installing VS Code...${NC}"
    brew install --cask visual-studio-code
fi
vscode_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "/Applications/Visual Studio Code.app/Contents/Info.plist" 2>/dev/null || echo "unknown")
echo -e "${GREEN}✓${NC} VS Code ($vscode_version)"

# Neovim
if ! command -v nvim &>/dev/null; then
    echo -e "${BLUE}Installing neovim...${NC}"
    brew install neovim
fi
nvim_version=$(nvim --version 2>/dev/null | awk 'NR==1{print $2}' | tr -d 'v' || echo "unknown")
echo -e "${GREEN}✓${NC} Neovim ($nvim_version)"
