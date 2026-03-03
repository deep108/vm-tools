# Guest Tools

macOS development utilities for VMs, fresh installs, and ephemeral environments. Self-contained scripts that quickly bootstrap a development-ready macOS system.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/yourusername/guest-tools.git
cd guest-tools

# Run machine-level bootstrap
./scripts/check-dev-env.sh

# Check for and apply updates
./scripts/check-dev-env.sh --check-updates
```

## Scripts

### `check-dev-env.sh` — Machine-Level Bootstrap

Verifies and installs core development tools on a new Mac.

**What it installs/checks:**
- **Homebrew** (auto-install for both Intel and Apple Silicon)
- **mise** (version manager, auto-install via brew)
- **chezmoi** (dotfile manager, warn if missing)
- **starship** (shell prompt, warn if missing)
- **tmux** (terminal multiplexer, warn if missing)
- **Neovim** (editor, warn if missing)
- **VS Code** (checks `/Applications`)
- **Claude Code** (auto-install via curl)

**Usage:**
```bash
./scripts/check-dev-env.sh              # Check/install tools
./scripts/check-dev-env.sh --check-updates  # Interactive update prompts
./scripts/check-dev-env.sh --help       # Show usage
```

**Update workflow (`--check-updates`):**
- Shows outdated brew packages (mise, chezmoi, starship, tmux, neovim)
- Prompts per-package: `Update <pkg>? [y/N]`
- Safety: automatically skips tmux if you're inside a tmux session

### `setup-code-server-launch-agent.sh` — VS Code Web Server

Installs VS Code `serve-web` as a macOS LaunchDaemon (system service).

**Features:**
- Auto-detects VS Code binary location
- Runs at boot, auto-restarts on crash
- Configurable bind address and port

**Usage:**
```bash
# Default (0.0.0.0:8000)
sudo ./scripts/setup-code-server-launch-agent.sh

# Custom port
BIND_PORT=9000 sudo ./scripts/setup-code-server-launch-agent.sh

# Access at http://localhost:8000
```

**Environment variables:**
- `BIND_HOST` (default: `0.0.0.0`)
- `BIND_PORT` (default: `8000`)
- `SERVICE_USER` (default: current user)

### `vscode-web-serve.sh` — VS Code Web (Manual)

One-liner to start VS Code `serve-web` manually (foreground process).

```bash
./scripts/vscode-web-serve.sh
# Access at http://localhost:8000
```

### `macos-initial-setup.sh` — macOS Configuration

Disables press-and-hold for key repeat (enables Vim-style key navigation).

```bash
./scripts/macos-initial-setup.sh
```

### `unlock-keychain.sh` — Keychain Helper

Unlocks the login keychain (useful for automation workflows).

```bash
./scripts/unlock-keychain.sh
```

## Requirements

- macOS (tested on macOS 14+)
- Internet connection (for Homebrew/tool downloads)
- No other dependencies — scripts auto-install what they need

## Design Philosophy

**Self-contained:** Each script works independently with no external dependencies beyond core macOS and Homebrew (which gets auto-installed).

**Minimal assumptions:** Works from a completely fresh macOS install. No sibling repos, config files, or pre-existing tools required.

**Safe by default:**
- Interactive prompts for updates (not automatic)
- Safety guards (e.g., won't update tmux while you're in a tmux session)
- Verbose output showing exactly what's happening

**Machine-level focus:** These tools set up your _machine_, not your _project_. For project-specific setup (node versions, Firebase tools, etc.), use your project's own setup scripts.

## Use Cases

- **Fresh Mac setup:** Run `check-dev-env.sh` on a new machine to get development tools installed
- **VM provisioning:** Bootstrap macOS VMs quickly with consistent tooling
- **Remote development:** Use `setup-code-server-launch-agent.sh` to access VS Code from any browser
- **CI/CD environments:** Automated setup of macOS build agents

## Contributing

Contributions welcome! Please:
- Keep scripts self-contained (no external dependencies)
- Follow existing code style (`set -euo pipefail`, color codes, `--help` flag)
- Test on a fresh macOS install when possible
- Update documentation (README, CLAUDE.md, `--help` output)

## License

MIT
