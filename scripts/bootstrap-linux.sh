#!/bin/bash
# Bootstrap a new Linux (Debian) VM: install prerequisites + Homebrew + chezmoi, then apply dotfiles
# Usage: ./bootstrap-linux.sh
#
# This is the Linux equivalent of bootstrap.sh (macOS).
# Mirrors the macOS flow: install Homebrew + chezmoi via brew,
# then chezmoi handles all tool installation via brew formulae.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Install prerequisites for Homebrew and chezmoi scripts
echo -e "${BLUE}Installing prerequisites...${NC}"
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    curl \
    file \
    git \
    procps \
    wget \
    gpg \
    zsh

# Set zsh as default shell
if [[ "$(basename "$SHELL")" != "zsh" ]]; then
    echo -e "${BLUE}Setting default shell to zsh...${NC}"
    sudo chsh -s /usr/bin/zsh "$USER"
fi

# Install or locate Homebrew
if ! command -v brew &>/dev/null; then
    if [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    else
        echo -e "${BLUE}Installing Homebrew...${NC}"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
fi
echo -e "${GREEN}✓${NC} Homebrew ($(brew --version 2>/dev/null | awk 'NR==1{print $2}'))"

# Install chezmoi via brew
if ! command -v chezmoi &>/dev/null; then
    echo -e "${BLUE}Installing chezmoi...${NC}"
    brew install chezmoi
fi
echo -e "${GREEN}✓${NC} chezmoi ($(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d 'v,'))"

# Init and apply dotfiles (installs all tools via brew: neovim, starship, mise, etc.)
echo -e "${BLUE}Applying dotfiles...${NC}"
chezmoi init --apply --force deep108/dotfiles-dev

# Upgrade all packages to latest
echo -e "${BLUE}Upgrading packages...${NC}"
brew upgrade
sudo apt-get upgrade -y

echo -e "${GREEN}✓${NC} Bootstrap complete"
