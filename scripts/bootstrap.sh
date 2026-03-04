#!/bin/zsh
# Bootstrap a new machine: install Homebrew + chezmoi, then apply dotfiles
# Usage: ./bootstrap.sh

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
echo -e "${GREEN}✓${NC} Homebrew ($(brew --version 2>/dev/null | awk 'NR==1{print $2}'))"

# Install chezmoi via brew
if ! command -v chezmoi &>/dev/null; then
    echo -e "${BLUE}Installing chezmoi...${NC}"
    brew install chezmoi
fi
echo -e "${GREEN}✓${NC} chezmoi ($(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d 'v,'))"

# Init and apply dotfiles
echo -e "${BLUE}Applying dotfiles...${NC}"
chezmoi init --apply --force deep108/dotfiles-dev

# Upgrade all brew-managed packages to latest
echo -e "${BLUE}Upgrading brew packages...${NC}"
brew upgrade
echo -e "${GREEN}✓${NC} All packages up to date"

echo -e "${GREEN}✓${NC} Bootstrap complete"
