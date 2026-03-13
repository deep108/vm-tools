# guest-tools

Scripts that run inside guest VMs (macOS and Linux). Mostly VS Code serve-web setup and legacy utilities.

Most guest-side tool installation is handled by **chezmoi** (`deep108/dotfiles-dev`), not scripts in this directory.

## Conventions

- `#!/bin/bash` for cross-platform scripts; `#!/bin/zsh` only for macOS-specific
- `set -euo pipefail` for strict error handling
- Under `set -o pipefail`, `head -1` can cause SIGPIPE (exit 141) — use `awk 'NR==1{...}'` instead

### Homebrew Paths

Scripts that need brew must handle all three paths:
- `/opt/homebrew/bin/brew` (macOS Apple Silicon)
- `/usr/local/bin/brew` (macOS Intel)
- `/home/linuxbrew/.linuxbrew/bin/brew` (Linux)

## Relationship to Dotfiles

The `deep108/dotfiles-dev` chezmoi repo handles shell configs, tool installation (`run_once_before_` scripts), VS Code settings, starship prompt, and `check-dev-tool-updates`.

Chezmoi auto-detects environment via `.chezmoi.toml.tmpl`:
- macOS: `sysctl hw.model` — `VirtualMac` prefix means guest
- Linux: always treated as guest
