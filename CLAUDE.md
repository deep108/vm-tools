# host-tools

Scripts and utilities for managing macOS virtual machines using **Tart** (Apple Silicon VM manager), provisioning development environments, and creating native macOS app shims for VS Code running in VMs.

All scripts run on the **host machine**. For scripts that run inside a guest VM, see the companion `guest-tools` repo.

## Overview

This toolset covers the full VM provisioning lifecycle:
1. Host machine setup (`Brewfile`)
2. VM provisioning from a base image (`provision-vm.sh`)
3. VM user creation (`create-tart-user2.sh`)
4. VM deletion (`delete-vm.sh`)
5. VS Code web access via app shim (`setup-vscode-webapp.sh`)
6. Icon customization (`update-icon.sh`, `iconoverlay.swift`)

## Files

| File | Purpose |
|------|---------|
| `Brewfile` | Homebrew packages for the host machine; apply with `brew bundle` |
| `provision-vm.sh` | Full VM bootstrap: clone base image, resize disk, create user, install SSH key, set computer name, configure git, clone guest-tools, transfer Homebrew ownership |
| `delete-vm.sh` | Stop (if running) and delete a Tart VM |
| `create-tart-user.sh` | Basic script to create a user on a running Tart VM |
| `create-tart-user2.sh` | Enhanced version with CREATE/DELETE modes, `--admin` flag, and non-interactive mode |
| `host-provisioning-jobs.txt` | Manual one-time host setup tasks (e.g. `mkdir -p ~/.ssh/sockets`) |
| `iconoverlay.swift` | Swift utility that overlays text onto `.icns` icon files |
| `setup-vscode-webapp.sh` | Creates a standalone macOS `.app` shim for VS Code in a VM |
| `ssh-tmux.sh` | SSH into a Tart VM and attach or create a named tmux session (iTerm2 CC mode) |
| `ssh-run.sh` | SSH into a Tart VM and execute a script on the guest |
| `update-icon.sh` | Wrapper around `iconoverlay.swift` to apply text labels to icons |

## Requirements

- macOS with Apple Silicon (M1/M2/M3)
- Tart (`brew install tart`)
- Google Chrome (for `app_mode_loader` used by `setup-vscode-webapp.sh`)
- Swift (standard on macOS)
- Standard macOS tools: `sips`, `iconutil`, `codesign`, `curl`, `ssh`

## Common Tasks

### Provision a new VM
```bash
./provision-vm.sh <vm-name>                        # clone from cirruslabs base, 75 GB disk
./provision-vm.sh <vm-name> --disk 100             # custom disk size
./provision-vm.sh <vm-name> --base <image>         # custom base image
./provision-vm.sh <vm-name> --headless             # no UI window
```
Prompts for: VM user password, GitHub token (for guest-tools clone).
Requires an SSH key pair on the host (`~/.ssh/id_ed25519`) for passwordless VM access.

After provisioning, SSH into the VM and run guest-tools scripts manually (e.g. `check-dev-env.sh`, `setup-code-server-launch-agent.sh`) to complete dev environment setup.

### Delete a VM
```bash
./delete-vm.sh <vm-name>    # stops if running, then deletes
```

### Create a user on a VM
```bash
# create-tart-user2.sh is preferred
./create-tart-user2.sh <vm-name> <username>
./create-tart-user2.sh -d <vm-name> <username>   # delete user
```

### SSH into a VM
```bash
./ssh-tmux.sh <vm-name>                        # attach or create 'general' tmux session
./ssh-tmux.sh <vm-name> <session-name>         # named session
./ssh-tmux.sh <vm-name> <session-name> <user>  # custom username

./ssh-run.sh <vm-name> <script-path>           # run a guest-side script
./ssh-run.sh <vm-name> ~/guest-tools/devenv.sh # e.g. devenv setup
```

### Set up VS Code webapp shim
```bash
./setup-vscode-webapp.sh <vm-name>
# Installs to ~/Applications/VSCode VMs/<vm-name>.app
```

### Apply text overlay to an icon
```bash
./update-icon.sh input.icns output.icns "Label Text"
```

### Install host packages
```bash
brew bundle
```

## Notes

- Shell scripts use `set -euo pipefail` for strict error handling.
- `provision-vm.sh` uses SSH ControlMaster for the `admin@` account to avoid repeated password prompts; the new user account uses key-based auth after the SSH key is installed.
- `provision-vm.sh` configures `git credential cache` (15-day TTL) on the guest; first `git` operation after a reboot will prompt for the GitHub token.
- The cirruslabs `macos-tahoe-base` image ships with Homebrew at `/opt/homebrew` owned by `admin`; `provision-vm.sh` transfers ownership to the new user so Homebrew works without sudo.
- `create-tart-user2.sh` is the production-ready version; prefer it over `create-tart-user.sh`.
- SSH connections disable `StrictHostKeyChecking` for VM access (expected — VM IPs change).
- `ssh-tmux.sh` uses `tmux -CC` for iTerm2 native tmux integration; guest devenv scripts should do the same when attaching.
- SSH scripts use `zsh -l` to ensure Homebrew PATH is available on the guest.
- `setup-vscode-webapp.sh` depends on `update-icon.sh` and `iconoverlay.swift` being in the same directory.
- `iconoverlay.swift` is compiled at runtime via `swiftc`; no pre-build step needed.
