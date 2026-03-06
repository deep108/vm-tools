#!/bin/bash
# Bootstrap a new Linux (Debian) VM: install base packages, chezmoi, then apply dotfiles
# Usage: ./bootstrap-linux.sh
#
# This is the Linux equivalent of bootstrap.sh (macOS).
# Installs essential packages via apt, then hands off to chezmoi for
# everything else (shell config, starship, VS Code extensions, etc.)

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Updating package lists...${NC}"
sudo apt-get update

echo -e "${BLUE}Installing essential packages...${NC}"
sudo apt-get install -y \
    build-essential \
    curl \
    git \
    tmux \
    unzip \
    zsh

# Install neovim from GitHub releases (Debian Bookworm ships 0.7.2,
# but vscode-neovim extension requires >= 0.9.0)
if ! command -v nvim &>/dev/null; then
    echo -e "${BLUE}Installing neovim from GitHub releases...${NC}"
    curl -sL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.tar.gz | sudo tar xzf - -C /usr/local --strip-components=1
fi

# Set zsh as default shell
if [[ "$(basename "$SHELL")" != "zsh" ]]; then
    echo -e "${BLUE}Setting default shell to zsh...${NC}"
    sudo chsh -s /usr/bin/zsh "$USER"
fi

# Install VS Code from Microsoft's apt repo
if ! command -v code &>/dev/null; then
    echo -e "${BLUE}Installing VS Code...${NC}"
    sudo apt-get install -y wget gpg
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/packages.microsoft.gpg > /dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y code
fi

# Install starship (not in Debian repos — download binary to /usr/local/bin)
if ! command -v starship &>/dev/null; then
    echo -e "${BLUE}Installing starship...${NC}"
    curl -sS https://starship.rs/install.sh | sudo sh -s -- -y
fi

# Install mise (not in Debian repos — official installer puts it in ~/.local/bin)
if ! command -v mise &>/dev/null; then
    echo -e "${BLUE}Installing mise...${NC}"
    curl https://mise.run | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# Install chezmoi
if ! command -v chezmoi &>/dev/null; then
    echo -e "${BLUE}Installing chezmoi...${NC}"
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
fi
echo -e "${GREEN}chezmoi ($(chezmoi --version 2>/dev/null | awk '{print $3}' | tr -d 'v,'))${NC}"

# Init and apply dotfiles (installs remaining tools: starship, mise, extensions, etc.)
echo -e "${BLUE}Applying dotfiles...${NC}"
chezmoi init --apply --force deep108/dotfiles-dev

echo -e "${BLUE}Upgrading packages...${NC}"
sudo apt-get upgrade -y

echo -e "${GREEN}Bootstrap complete${NC}"
