# host-tools

Scripts for managing macOS and Linux virtual machines using **Tart** (Apple Silicon VM manager), provisioning development environments, and setting up secure git workflows between host and guest.

All scripts run on the **host machine**.

## Overview

This toolset covers the full VM provisioning lifecycle:
1. Host machine setup (`Brewfile`)
2. VM provisioning from a base image (`provision-vm.sh`) — supports both macOS and Linux (Debian)
3. VM user creation (`create-macos-vm-user.sh`)
4. VM deletion (`delete-vm.sh`)
5. Secure git workflow between host and VM (`setup-vm-git.sh`, `teardown-vm-git.sh`)
6. VS Code web access via app shim (`setup-vscode-webapp.sh`)
7. Icon customization (`update-icon.sh`, `iconoverlay.swift`)

## Files

| File | Purpose |
|------|---------|
| `Brewfile` | Homebrew packages for the host machine; apply with `brew bundle` |
| `provision-vm.sh` | Full VM bootstrap (macOS and Linux): clone, resize, start, create user, install tools, set up VS Code serve-web |
| `delete-vm.sh` | Stop (if running) and delete a Tart VM |
| `create-macos-vm-user.sh` | Create/delete a user on a running macOS VM via `tart exec`; supports `--admin` flag |
| `tart-exec.sh` | Run a command on a running VM via `tart exec`; supports `--user` for user-context execution |
| `prepare-golden-image.sh` | Clean instance-specific state from a running VM and stop it, preparing it as a golden base image |
| `setup-vm-git.sh` | Set up secure git workflow: bare repo on host, restricted SSH key, VM clone (works with macOS and Linux VMs) |
| `teardown-vm-git.sh` | Remove git workflow setup for a VM (authorized_keys entry, wrapper script entries) |
| `ssh-tmux.sh` | SSH into a Tart VM and attach or create a named tmux session (iTerm2 CC mode) |
| `ssh-run.sh` | SSH into a Tart VM and execute a script on the guest |
| `setup-vscode-webapp.sh` | Creates a standalone macOS `.app` shim for VS Code in a VM |
| `iconoverlay.swift` | Swift utility that overlays text onto `.icns` icon files |
| `update-icon.sh` | Wrapper around `iconoverlay.swift` to apply text labels to icons |
| `host-provisioning-jobs.txt` | Manual one-time host setup tasks |

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- Tart (`brew install tart`)
- `sshpass` for Linux VM provisioning (`brew install esolitos/ipa/sshpass`)
- Google Chrome (for `setup-vscode-webapp.sh`)
- Swift (standard on macOS)
- Standard macOS tools: `sips`, `iconutil`, `codesign`, `curl`, `ssh`

## macOS vs Linux VM Provisioning

`provision-vm.sh` supports both guest OS types with a transport abstraction:

| Aspect | macOS VM | Linux VM (`--linux`) |
|--------|----------|---------------------|
| Base image | `ghcr.io/cirruslabs/macos-tahoe-base:latest` | `ghcr.io/cirruslabs/debian:trixie` |
| Guest communication | `tart exec` (Virtio guest agent) | SSH via `sshpass` (no guest agent) |
| Connectivity wait | Poll `tart exec ... true` | Poll `tart ip` then SSH |
| User creation | `create-macos-vm-user.sh` | `useradd` + sudoers.d |
| Hostname | `scutil --set` | `hostnamectl` |
| Homebrew | Pre-installed, ownership transferred | Installed by user during bootstrap |
| VS Code service | LaunchDaemon (launchd) | systemd unit |
| Bootstrap script | `scripts/bootstrap.sh` | `scripts/bootstrap-linux.sh` |

Both paths converge on the same dotfiles via chezmoi, which auto-detects the OS and installs the same brew formulae (mise, starship, tmux, neovim, jq) on both platforms.

## Common Tasks

### Provision a new VM
```bash
# macOS VM (default)
./provision-vm.sh <vm-name>
./provision-vm.sh <vm-name> --disk 100
./provision-vm.sh <vm-name> --base <image>
./provision-vm.sh <vm-name> --headless

# Linux VM
./provision-vm.sh <vm-name> --linux
./provision-vm.sh <vm-name> --linux --headless
```

### Set up git workflow for a VM
```bash
./setup-vm-git.sh <vm-name> deep108/my-repo
./setup-vm-git.sh <vm-name> deep108/my-repo --clone-dir custom-name
./setup-vm-git.sh <vm-name> deep108/my-repo --host-ip 192.168.66.1

# Remove git setup
./teardown-vm-git.sh <vm-name>
```

### Delete a VM
```bash
./delete-vm.sh <vm-name>
```

### Prepare a golden base image
```bash
./provision-vm.sh macos-vm-base
# SSH in, verify everything works
./prepare-golden-image.sh macos-vm-base
./provision-vm.sh my-dev-vm --base macos-vm-base
```

### Run commands on a macOS VM
```bash
./tart-exec.sh <vm-name> whoami
./tart-exec.sh <vm-name> --user david 'mise install'
```

### SSH into a VM
```bash
./ssh-tmux.sh <vm-name>                        # tmux session (iTerm2 CC mode)
./ssh-tmux.sh <vm-name> <session-name>         # named session
./ssh-run.sh <vm-name> <script-path>           # run a guest script
```

## Notes

- Shell scripts use `set -euo pipefail` for strict error handling.
- `tart exec` (macOS VMs only) runs as the `admin` user with passwordless sudo. For user-context commands, use `sudo -Hu <user> zsh -l -c '...'`.
- `tart exec` does NOT support the `--` argument separator.
- Linux VMs use SSH for all guest communication during provisioning. `sshpass` is required (cirruslabs images use admin/admin credentials).
- SSH host keys are regenerated during provisioning so cloned VMs get unique keys.
- `setup-vm-git.sh` auto-detects the host gateway IP from the VM's default route (uses `ip route` on Linux, `route -n get` on macOS).
- `ssh-tmux.sh` uses `tmux -CC` for iTerm2 native tmux integration.
