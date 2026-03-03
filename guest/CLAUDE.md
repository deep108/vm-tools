# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Guest Tools is a collection of macOS development utilities for VMs, fresh installs, and ephemeral environments. The scripts are self-contained with minimal dependencies beyond core macOS and Homebrew.

**Target use case:** Quickly bootstrap a development-ready macOS environment from scratch (e.g., new VM, clean install, guest machine).

## Repository Structure

```
guest-tools/
├── scripts/
│   ├── check-dev-env.sh              # Machine-level bootstrap & update manager
│   ├── setup-code-server-launch-agent.sh  # VS Code serve-web daemon installer
│   ├── vscode-web-serve.sh           # VS Code serve-web manual launcher
│   ├── macos-initial-setup.sh        # macOS key repeat config
│   └── unlock-keychain.sh            # Keychain unlock helper
├── CLAUDE.md                          # This file
└── TODO.md                            # Project task list
```

## Scripts

### `check-dev-env.sh` — Machine-level bootstrap

**Purpose:** Verify and install core development tools on a new Mac.

**What it manages:**
- Homebrew (auto-install, Intel + Apple Silicon paths)
- mise (auto-install via brew, add activation to `.zshrc`)
- chezmoi, starship, tmux, neovim (check/warn if missing)
- VS Code (check `/Applications`)
- Claude Code (auto-install via curl, add to PATH)

**Usage:**
```bash
./scripts/check-dev-env.sh              # Check and install missing tools
./scripts/check-dev-env.sh --check-updates  # Interactive per-package brew update prompts
./scripts/check-dev-env.sh --help       # Show usage
```

**Update behavior (`--check-updates`):**
- Shows outdated brew packages (filtered to: mise, chezmoi, starship, tmux, neovim)
- Prompts case-by-case: `Update <pkg>? [y/N]`
- Safety guard: skips tmux if inside a tmux session
- Does NOT check mise-managed tools (this is machine-level, not project-level)

**Key patterns:**
- Detects Homebrew on both Intel (`/usr/local/bin/brew`) and Apple Silicon (`/opt/homebrew/bin/brew`)
- Auto-installs Homebrew if missing
- Adds Homebrew shellenv to `.zprofile` (login shell)
- Adds mise activation to `.zshrc` (interactive shell)
- Uses `read < /dev/tty` for interactive prompts to avoid stdin conflicts with heredoc loops
- `set -euo pipefail` throughout

### `setup-code-server-launch-agent.sh` — VS Code serve-web daemon

**Purpose:** Install VS Code serve-web as a LaunchDaemon (system-level service).

**Features:**
- Auto-detects VS Code binary location (brew, `/Applications`, `~/Applications`)
- Creates `/Library/LaunchDaemons/com.user.vscode.serve-web.plist`
- Runs at boot, auto-restarts on crash
- Logs to `/var/log/vscode-serve-web.{log,err}`

**Environment variables:**
- `BIND_HOST` (default: `0.0.0.0`)
- `BIND_PORT` (default: `8000`)
- `SERVICE_USER` (default: current user)
- `CODE_BINARY` (optional: override auto-detection)

**Usage:**
```bash
# Default (0.0.0.0:8000)
sudo ./scripts/setup-code-server-launch-agent.sh

# Custom port
BIND_PORT=9000 sudo ./scripts/setup-code-server-launch-agent.sh
```

### `vscode-web-serve.sh` — Manual launcher

**Purpose:** One-liner to start VS Code serve-web manually (foreground process).

**Usage:**
```bash
./scripts/vscode-web-serve.sh
# Access at http://localhost:8000
```

### `macos-initial-setup.sh` — macOS config

**Purpose:** Disable press-and-hold for key repeat (enables Vim-style navigation).

**Usage:**
```bash
./scripts/macos-initial-setup.sh
```

**What it does:**
```bash
defaults write -g ApplePressAndHoldEnabled -bool false
```

### `unlock-keychain.sh` — Keychain helper

**Purpose:** Unlock the login keychain (useful for automation workflows).

**Usage:**
```bash
./scripts/unlock-keychain.sh
```

## Development Guidelines

### Code Style
- Use `zsh` for all scripts (shebang: `#!/bin/zsh`)
- `set -euo pipefail` for safety (fail on errors, undefined vars, pipe failures)
- Color codes for output: `RED`, `GREEN`, `YELLOW`, `BLUE`, `NC` (no color)
- Consistent messaging:
  - `✓` (green) for success/installed
  - `!` (yellow) for warnings/optional tools
  - `✗` (red) for errors/failures

### Interactive Prompts
- Always use `read < /dev/tty` to avoid stdin conflicts when looping over heredocs
- Collect items into arrays first, THEN loop for interactive prompts:
  ```bash
  local items=()
  while IFS= read -r line; do
      items+=("$line")
  done <<< "$some_list"
  for item in "${items[@]}"; do
      read -r answer < /dev/tty || true
  done
  ```

### Avoiding SIGPIPE Errors
- Under `set -o pipefail`, `head -1` can cause SIGPIPE (exit 141)
- Use `awk 'NR==1{...}'` instead of `head -1 | awk`
- Example:
  ```bash
  # Bad (SIGPIPE risk)
  java --version 2>/dev/null | head -1 | awk '{print $2}'

  # Good (no SIGPIPE)
  java --version 2>/dev/null | awk 'NR==1{print $2}'
  ```

### Safety Guards
- **tmux updates:** Check `check_tmux_running()` before prompting to update tmux — skip with warning if inside a session
- **Homebrew paths:** Always check both `/opt/homebrew/bin/brew` (Apple Silicon) and `/usr/local/bin/brew` (Intel)
- **Shell config files:** Use `touch` before appending to ensure file exists

### Testing
- Run scripts on a fresh macOS VM or clean install when possible
- Test both Intel and Apple Silicon paths (or mock the conditions)
- Verify `--help` output is accurate and complete
- For interactive prompts, test with piped input (`echo "n" | script`) to ensure `/dev/tty` reads work correctly

## Common Patterns

### Homebrew Detection
```bash
if ! command -v brew &>/dev/null; then
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        echo "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
fi
```

### Shell Config Updates
```bash
ZSHRC="$HOME/.zshrc"
if [[ ! -f "$ZSHRC" ]]; then
    touch "$ZSHRC"
fi
if ! grep -q 'mise activate' "$ZSHRC"; then
    echo '' >> "$ZSHRC"
    echo '# mise' >> "$ZSHRC"
    echo 'eval "$(mise activate zsh)"' >> "$ZSHRC"
    SHELL_CONFIG_UPDATED=true
fi
```

### Interactive Update Prompts
```bash
local pkgs=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkgs+=("$(echo "$line" | awk '{print $1}')")
done <<< "$outdated_list"

for pkg in "${pkgs[@]}"; do
    printf "  Update %s? [y/N] " "$pkg"
    local answer
    read -r answer < /dev/tty || true
    if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
        brew upgrade "$pkg"
    fi
done
```

## Relationship to Other Projects

This repo is **machine-level** — it installs and configures core development tools that are independent of any specific project.

For **project-specific** setup (e.g., deep-habits), use the project's own `scripts/check-dev-env.sh` which handles:
- mise-managed project tools (node, java, firebase)
- Project-specific Brewfile dependencies
- Xcode and iOS Simulator runtimes
- Firebase emulators
- Project-specific safety guards (e.g., skip java/firebase updates if emulators running)

The two scripts are intentionally separate and self-contained to avoid cross-directory dependencies.

## Contributing

When modifying scripts:
1. Preserve self-contained nature — no dependencies on external files or sibling repos
2. Test on a fresh macOS environment when possible
3. Update `--help` output if changing command-line interface
4. Follow existing code style and patterns
5. Add safety guards for destructive or risky operations
