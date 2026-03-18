# Guest Tools

Utilities for macOS and Linux guest VMs. Handles VS Code serve-web setup, macOS configuration, and legacy bootstrap scripts.

> **Note:** Most tool installation is now handled by [chezmoi](https://github.com/deep108/dotfiles-dev) via the bootstrap scripts in `scripts/`. The scripts in this directory are supplementary.

## Quick Start

Guest VMs are typically provisioned automatically via `host/provision-vm.sh`, which handles everything end-to-end. For manual setup:

```bash
# macOS VM
zsh -l ~/dev/vm-tools/scripts/bootstrap.sh

# Linux VM
bash ~/dev/vm-tools/scripts/bootstrap-linux.sh
```

Bootstrap installs Homebrew + chezmoi, then chezmoi installs all tools (starship, tmux, neovim, mise, VS Code, etc.).

## Scripts

### VS Code Serve-Web

Set up VS Code as a web service accessible from the host browser:

```bash
# macOS (LaunchDaemon)
sudo ./setup-code-server-launch-agent.sh

# Linux (systemd)
./setup-code-server-systemd.sh

# Manual (foreground)
./vscode-web-serve.sh

# Access at http://<vm-ip>:18000
```

Environment variables: `BIND_HOST` (default: `0.0.0.0`), `BIND_PORT` (default: `18000`), `SERVICE_USER` (default: current user).

### macOS Configuration

```bash
./macos-initial-setup.sh    # Disable press-and-hold for key repeat
./unlock-keychain.sh        # Unlock login keychain
```

## Requirements

- macOS or Linux (Debian)
- Internet connection (for Homebrew/tool downloads)
- No other dependencies — bootstrap scripts install everything

## Terminal Font

The starship prompt uses powerline glyphs for the VM name badge. Set your host terminal (iTerm2) font to **MesloLGMDZ Nerd Font** — installed automatically via Homebrew on macOS VMs. Linux VMs are headless; the font only needs to be on the host.

## Installed Tools (via chezmoi)

Both macOS and Linux guest VMs get the same core tools via Homebrew:

| Tool | Purpose |
|------|---------|
| mise | Version manager (node, python, etc.) |
| starship | Shell prompt with VM name badge |
| tmux | Terminal multiplexer |
| neovim | Editor (also used by VS Code Neovim extension) |
| jq | JSON processor |
| wget | HTTP downloader |
| tree | Directory visualization |
| htop | Interactive process viewer |
| watch | Repeat commands periodically |
| VS Code | IDE (brew cask on macOS, apt on Linux) |

Brew-over-OS (newer than what ships with macOS/Debian): curl, openssl, git, rsync.

macOS guests additionally get iTerm2 and MesloLGMDZ Nerd Font via brew casks.
