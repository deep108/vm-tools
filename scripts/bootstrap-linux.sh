#!/bin/bash
# Bootstrap a new Linux (Debian) VM: install essential packages
# Usage: ./bootstrap-linux.sh

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
    neovim \
    unzip \
    zsh

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

# Install VS Code extensions
echo -e "${BLUE}Installing VS Code extensions...${NC}"
extensions=(
    ms-vscode.cpptools
    anthropics.claude-code
    monokai.theme-monokai-pro-vscode
    johnpapa.vscode-peacock
    esbenp.prettier-vscode
    asvetliakov.vscode-neovim
    github.copilot
    github.copilot-chat
)
for ext in "${extensions[@]}"; do
    code --install-extension "$ext" --force 2>/dev/null || echo "  Warning: failed to install $ext"
done

echo -e "${BLUE}Upgrading packages...${NC}"
sudo apt-get upgrade -y

echo -e "${GREEN}Bootstrap complete${NC}"
