#!/bin/zsh
# check-dev-env.sh
# Machine-level bootstrap — verifies and installs core development tools.
# Run once on a new Mac to provision your development environment.

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SHELL_CONFIG_UPDATED=false

# === Argument handling ===

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: check-dev-env.sh [--check-updates] [--help]"
    echo
    echo "Machine-level bootstrap — verifies and installs core development tools."
    echo "Run once on a new Mac to provision your development environment."
    echo
    echo "Checks: Homebrew, mise, chezmoi, starship, tmux, VS Code, Neovim, Claude Code"
    echo
    echo "Options:"
    echo "  --check-updates  Check for and interactively apply brew updates (mise, chezmoi, starship, tmux, neovim)"
    echo "  --help           Show this help message"
    exit 0
fi

# === Helpers ===

# Check if tmux is currently running (used for update safety warnings)
check_tmux_running() {
    if [[ -n "${TMUX:-}" ]]; then
        return 0
    fi
    if command -v tmux >/dev/null 2>&1; then
        if tmux list-sessions >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# === Main ===

echo -e "${BLUE}Checking development environment...${NC}\n"

# === 1. Homebrew ===

if ! command -v brew &>/dev/null; then
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        echo -e "${BLUE}Installing Homebrew...${NC}"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
brew_version=$(brew --version 2>/dev/null | head -1 | awk '{print $2}')
echo -e "${GREEN}✓${NC} Homebrew ($brew_version)"

# Ensure Homebrew shellenv is in .zprofile (needed for Apple Silicon login shells)
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    ZPROFILE="$HOME/.zprofile"
    if [[ ! -f "$ZPROFILE" ]] || ! grep -q 'brew shellenv' "$ZPROFILE"; then
        echo '' >> "$ZPROFILE"
        echo '# Homebrew' >> "$ZPROFILE"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$ZPROFILE"
        echo -e "${GREEN}✓${NC} Added Homebrew shellenv to ~/.zprofile"
        SHELL_CONFIG_UPDATED=true
    fi
fi

# === 2. mise ===

ZSHRC="$HOME/.zshrc"
if [[ ! -f "$ZSHRC" ]]; then
    touch "$ZSHRC"
fi

if ! command -v mise &>/dev/null; then
    echo -e "${BLUE}Installing mise...${NC}"
    brew install mise
fi
mise_version=$(mise --version 2>/dev/null | awk '{print $1}')
echo -e "${GREEN}✓${NC} mise ($mise_version)"

# Ensure mise activation is in .zshrc for future shell sessions
if ! grep -q 'mise activate' "$ZSHRC"; then
    echo '' >> "$ZSHRC"
    echo '# mise (tool version manager)' >> "$ZSHRC"
    echo 'eval "$(mise activate zsh)"' >> "$ZSHRC"
    echo -e "${GREEN}✓${NC} Added mise activation to ~/.zshrc"
    SHELL_CONFIG_UPDATED=true
fi

# === 3. Machine tools ===

echo -e "\n${BLUE}Installing/verifying machine tools...${NC}"

# chezmoi (dotfile manager)
if ! command -v chezmoi &>/dev/null; then
    echo -e "${BLUE}Installing chezmoi...${NC}"
    brew install chezmoi
fi
chezmoi_version=$(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d 'v,' || echo "unknown")
echo -e "${GREEN}✓${NC} chezmoi ($chezmoi_version)"

# starship (prompt)
if ! command -v starship &>/dev/null; then
    echo -e "${BLUE}Installing starship...${NC}"
    brew install starship
fi
starship_version=$(starship --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
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
nvim_version=$(nvim --version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v' || echo "unknown")
echo -e "${GREEN}✓${NC} Neovim ($nvim_version)"

# === 4. Claude Code ===

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
    claude_version=$(claude --version 2>/dev/null | head -1 || echo "unknown")
    echo -e "${GREEN}✓${NC} Claude Code ($claude_version)"

    # Ensure ~/.local/bin is in PATH in .zshrc
    if ! grep -q '\.local/bin' "$ZSHRC"; then
        echo '' >> "$ZSHRC"
        echo '# Claude Code' >> "$ZSHRC"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$ZSHRC"
        echo -e "${GREEN}✓${NC} Added ~/.local/bin to PATH in ~/.zshrc"
        SHELL_CONFIG_UPDATED=true
    fi
else
    echo -e "${RED}✗${NC} Claude Code installation failed"
fi

# === Update checking ===

check_for_updates() {
    echo -e "\n${BLUE}Checking for updates...${NC}"

    # brew updates — packages managed by this script
    local brew_outdated
    brew_outdated=$(brew outdated 2>/dev/null | grep -E "^(mise|chezmoi|starship|tmux|neovim)" || true)
    if [[ -n "$brew_outdated" ]]; then
        echo -e "${YELLOW}brew updates available:${NC}"
        echo "$brew_outdated"
        echo
        # Collect package names first so interactive read doesn't fight the here-string
        local brew_pkgs=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            brew_pkgs+=("$(echo "$line" | awk '{print $1}')")
        done <<< "$brew_outdated"
        for pkg in "${brew_pkgs[@]}"; do
            # Safety block: skip tmux update if a session is active
            if [[ "$pkg" == "tmux" ]] && check_tmux_running; then
                echo -e "  ${YELLOW}⚠ Skipping tmux — exit all tmux sessions first${NC}"
                continue
            fi
            printf "  Update %s? [y/N] " "$pkg"
            local answer
            read -r answer < /dev/tty || true
            if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
                brew upgrade "$pkg"
            fi
        done
    else
        echo -e "${GREEN}✓${NC} Homebrew packages up to date"
    fi
}

if [[ "${1:-}" == "--check-updates" ]]; then
    check_for_updates
fi

echo -e "\n${GREEN}✓ Development environment ready${NC}"

if [[ "$SHELL_CONFIG_UPDATED" == "true" ]]; then
    echo -e "\n${YELLOW}NOTE:${NC} Shell config was updated. Restart your terminal for changes to take effect."
fi
