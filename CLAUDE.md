# vm-tools

Scripts and utilities for managing macOS virtual machines using **Tart** (Apple Silicon VM manager), provisioning development environments, and creating native macOS app shims for VS Code running in VMs.

## Directory Structure

```
vm-tools/
├── host/    ← scripts that run on the host machine
├── guest/   ← scripts that run inside a guest VM (placeholder for future)
└── CLAUDE.md
```

All current scripts are host-side tools. None require execution inside a VM.

## Overview

This toolset covers the full VM provisioning lifecycle:
1. Host machine setup (`host/Brewfile`)
2. VM user creation (`host/create-tart-user2.sh`)
3. VS Code web access via app shim (`host/setup-vscode-webapp.sh`) or SSH tunnel (`host/ssh-vscode-port.sh`)
4. Icon customization (`host/update-icon.sh`, `host/iconoverlay.swift`)

## host/ Files

| File | Purpose |
|------|---------|
| `Brewfile` | Homebrew packages for the host machine; apply with `brew bundle` |
| `create-tart-user.sh` | Basic script to create a user on a running Tart VM |
| `create-tart-user2.sh` | Enhanced version with CREATE/DELETE modes and better validation |
| `host-provisioning-jobs.txt` | Manual one-time host setup tasks (e.g. `mkdir -p ~/.ssh/sockets`) |
| `iconoverlay.swift` | Swift utility that overlays text onto `.icns` icon files |
| `setup-vscode-webapp.sh` | Creates a standalone macOS `.app` shim for VS Code in a VM |
| `ssh-vscode-port.sh` | Sets up an SSH tunnel with port forwarding to VS Code in a VM |
| `update-icon.sh` | Wrapper around `iconoverlay.swift` to apply text labels to icons |

## guest/ Files

_(empty — add scripts here that are intended to run inside a guest VM)_

## Requirements

- macOS with Apple Silicon (M1/M2/M3)
- Tart (`brew install tart`)
- Google Chrome (for `app_mode_loader` used by `setup-vscode-webapp.sh`)
- Swift (standard on macOS)
- Standard macOS tools: `sips`, `iconutil`, `codesign`, `curl`, `ssh`

## Common Tasks

### Create a user on a VM
```bash
# create-tart-user2.sh is preferred
./host/create-tart-user2.sh <vm-name> <username>
./host/create-tart-user2.sh -d <vm-name> <username>   # delete user
```

### Set up VS Code webapp shim
```bash
./host/setup-vscode-webapp.sh <vm-name>
# Installs to ~/Applications/VSCode VMs/<vm-name>.app
```

### SSH tunnel to VS Code
```bash
./host/ssh-vscode-port.sh -H <ssh-alias>          # use SSH config alias
./host/ssh-vscode-port.sh -p 8080 <vm-name>       # custom port
```

### Apply text overlay to an icon
```bash
./host/update-icon.sh input.icns output.icns "Label Text"
```

### Install host packages
```bash
brew bundle --file=host/Brewfile
```

## Notes

- Shell scripts use `set -euo pipefail` for strict error handling.
- `create-tart-user2.sh` is the production-ready version; prefer it over `create-tart-user.sh`.
- SSH connections disable `StrictHostKeyChecking` for VM access (expected — VM IPs change).
- `setup-vscode-webapp.sh` depends on `update-icon.sh` and `iconoverlay.swift` being in the same directory (`host/`).
- `iconoverlay.swift` is compiled at runtime via `swiftc`; no pre-build step needed.
