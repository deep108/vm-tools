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
    unzip

echo -e "${BLUE}Upgrading packages...${NC}"
sudo apt-get upgrade -y

echo -e "${GREEN}Bootstrap complete${NC}"
