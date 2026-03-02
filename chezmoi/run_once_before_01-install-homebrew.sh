#!/bin/zsh
# chezmoi run_once_before script: Install and configure Homebrew
# Migrated from check-dev-env.sh

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Install or locate Homebrew
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

brew_version=$(brew --version 2>/dev/null | awk 'NR==1{print $2}')
echo -e "${GREEN}✓${NC} Homebrew ($brew_version)"

# Ensure Homebrew shellenv is in .zprofile (Apple Silicon login shells)
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    ZPROFILE="$HOME/.zprofile"
    if [[ ! -f "$ZPROFILE" ]] || ! grep -q 'brew shellenv' "$ZPROFILE"; then
        echo '' >> "$ZPROFILE"
        echo '# Homebrew' >> "$ZPROFILE"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$ZPROFILE"
        echo -e "${GREEN}✓${NC} Added Homebrew shellenv to ~/.zprofile"
    fi
fi
