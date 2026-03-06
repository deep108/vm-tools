#!/bin/bash
# Bootstrap a new Linux (Debian) VM: install prerequisites + chezmoi, then apply dotfiles
# Usage: ./bootstrap-linux.sh
#
# This is the Linux equivalent of bootstrap.sh (macOS).
# Mirrors the macOS flow: install package manager prerequisites + chezmoi,
# then chezmoi handles all tool installation (neovim, starship, mise, etc.)

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Install prerequisites that chezmoi scripts need to run
echo -e "${BLUE}Installing prerequisites...${NC}"
sudo apt-get update
sudo apt-get install -y \
    curl \
    git \
    wget \
    gpg \
    zsh

# Set zsh as default shell (chezmoi scripts use #!/bin/zsh)
if [[ "$(basename "$SHELL")" != "zsh" ]]; then
    echo -e "${BLUE}Setting default shell to zsh...${NC}"
    sudo chsh -s /usr/bin/zsh "$USER"
fi

# Install chezmoi
if ! command -v chezmoi &>/dev/null; then
    echo -e "${BLUE}Installing chezmoi...${NC}"
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
fi
echo -e "${GREEN}chezmoi ($(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d 'v,'))${NC}"

# Init and apply dotfiles (installs all tools: neovim, starship, mise, VS Code, etc.)
echo -e "${BLUE}Applying dotfiles...${NC}"
chezmoi init --apply --force deep108/dotfiles-dev

# Upgrade all apt packages to latest
echo -e "${BLUE}Upgrading packages...${NC}"
sudo apt-get upgrade -y

echo -e "${GREEN}Bootstrap complete${NC}"
