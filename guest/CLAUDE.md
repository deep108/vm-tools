# guest-tools

Scripts that run inside guest VMs (macOS and Linux). These handle VS Code serve-web setup, macOS-specific configuration, and legacy bootstrap utilities.

Most guest-side tool installation is now handled by **chezmoi** (via `deep108/dotfiles-dev`), not scripts in this directory. The bootstrap scripts in `scripts/` install Homebrew + chezmoi, then chezmoi's `run_once_before_` scripts handle all tool installation.

## Files

| File | Purpose |
|------|---------|
| `setup-code-server-launch-agent.sh` | Install VS Code serve-web as a macOS LaunchDaemon |
| `setup-code-server-systemd.sh` | Install VS Code serve-web as a Linux systemd service |
| `vscode-web-serve.sh` | Start VS Code serve-web manually (foreground) |
| `macos-initial-setup.sh` | macOS key repeat config (legacy; now in chezmoi `run_once_before_00`) |
| `check-dev-env.sh` | Legacy bootstrap script (superseded by chezmoi flow) |
| `unlock-keychain.sh` | Keychain unlock helper (macOS only) |

## VS Code Serve-Web

Both scripts set up VS Code `serve-web` as a system service, binding to `0.0.0.0:8000`:

```bash
# macOS (LaunchDaemon)
sudo ./setup-code-server-launch-agent.sh

# Linux (systemd)
./setup-code-server-systemd.sh
```

Environment variables: `BIND_HOST`, `BIND_PORT`, `SERVICE_USER`, `CODE_BINARY`.

## Development Guidelines

### Code Style
- Use `#!/bin/bash` for scripts that must work on both macOS and Linux
- Use `#!/bin/zsh` only for macOS-specific scripts
- `set -euo pipefail` for strict error handling
- Color codes: `RED`, `GREEN`, `YELLOW`, `BLUE`, `NC`

### Homebrew Paths
Scripts that need brew must handle all three paths:
- `/opt/homebrew/bin/brew` (macOS Apple Silicon)
- `/usr/local/bin/brew` (macOS Intel)
- `/home/linuxbrew/.linuxbrew/bin/brew` (Linux)

### SIGPIPE Avoidance
Under `set -o pipefail`, `head -1` can cause SIGPIPE (exit 141). Use `awk 'NR==1{...}'` instead.

## Relationship to Dotfiles

The `deep108/dotfiles-dev` chezmoi repo handles:
- Shell configs (`.zprofile`, `.zshrc`) with OS-aware templates
- Tool installation via `run_once_before_` scripts (brew packages, Claude Code, VS Code extensions)
- VS Code settings and neovim paths
- Starship prompt config with VM name badge
- `check-dev-tool-updates` interactive update script

The chezmoi `.chezmoi.toml.tmpl` auto-detects the environment:
- macOS: checks `sysctl hw.model` for `VirtualMac` prefix (guest vs host)
- Linux: always treated as guest
