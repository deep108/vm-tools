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
| `provision-vm.sh` | Full VM bootstrap: clone base image, resize disk, create user, install SSH key, set computer name, clone vm-tools, transfer Homebrew ownership, run bootstrap, set up VS Code serve-web |
| `delete-vm.sh` | Stop (if running) and delete a Tart VM |
| `create-tart-user2.sh` | Create/delete a user on a running VM via `tart exec`; supports `--admin` flag and non-interactive mode |
| `tart-exec.sh` | Run a command on a running VM via `tart exec`; supports `--user` for user-context execution with login shell |
| `prepare-golden-image.sh` | Clean instance-specific state from a running VM and stop it, preparing it as a golden base image for cloning |
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
Prompts for: VM user password.
Requires an SSH key pair on the host (`~/.ssh/id_ed25519`) for passwordless VM access.

Steps performed (all guest commands use `tart exec` via Virtio guest agent — no SSH required):
1. Check for existing VM name conflict
2. Pull latest base image (`tart pull`)
3. Clone base image
4. Resize disk
5. Start VM
6. Wait for guest agent
7. Regenerate SSH host keys (so cloned VMs get unique keys)
8. Create user (via `create-tart-user2.sh`)
9. Install host SSH public key for the new user
10. Set computer name / hostname
11. Clone vm-tools into `~/dev/vm-tools`
12. Transfer Homebrew ownership from `admin` to the new user
13. Run bootstrap (Homebrew, chezmoi, dotfiles)
14. Set up VS Code serve-web LaunchDaemon
15. Get VM IP, add host key to `known_hosts`, show summary

### Delete a VM
```bash
./delete-vm.sh <vm-name>    # stops if running, then deletes
```

### Prepare a golden base image
```bash
# 1. Provision a VM from registry base
./provision-vm.sh macos-vm-base

# 2. SSH in, verify everything works

# 3. Clean up and stop (clears history, SSH keys, caches, logs)
./prepare-golden-image.sh macos-vm-base

# 4. Clone from it
./provision-vm.sh my-dev-vm --base macos-vm-base
```

### Run commands on a VM
```bash
./tart-exec.sh <vm-name> whoami                              # run as admin
./tart-exec.sh <vm-name> sudo brew update                    # admin with sudo
./tart-exec.sh <vm-name> --user david 'mise install'         # run as user (login shell)
./tart-exec.sh <vm-name> --user david ~/dev/vm-tools/scripts/bootstrap.sh
```

### Create a user on a VM
```bash
./create-tart-user2.sh <vm-name> <username>
./create-tart-user2.sh -d <vm-name> <username>   # delete user
```

### SSH into a VM
```bash
./ssh-tmux.sh <vm-name>                        # attach or create 'general' tmux session
./ssh-tmux.sh <vm-name> <session-name>         # named session
./ssh-tmux.sh <vm-name> <session-name> <user>  # custom username

./ssh-run.sh <vm-name> <script-path>           # run a guest-side script via SSH
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
- `provision-vm.sh` and `create-tart-user2.sh` use `tart exec` (Virtio guest agent / gRPC) for all guest commands — no SSH needed during provisioning. This bypasses networking entirely and eliminates the IP/SSH wait loops.
- `tart exec` runs as the `admin` user (which has passwordless sudo). For user-context commands, `provision-vm.sh` uses `sudo -Hu <user> zsh -l -c '...'` to get the full login shell environment (Homebrew PATH, etc.).
- `tart exec` does NOT support the `--` argument separator — it treats `--` as the command name.
- SSH host keys are regenerated during provisioning so cloned VMs get unique keys; the new key is auto-added to the host's `known_hosts`.
- The cirruslabs `macos-tahoe-base` image ships with Homebrew at `/opt/homebrew` owned by `admin`; `provision-vm.sh` transfers ownership to the new user so Homebrew works without sudo.
- `tart-exec.sh` is the general-purpose wrapper for running commands on a VM; use `--user` for commands that need the user's login shell environment.
- `ssh-tmux.sh` uses `tmux -CC` for iTerm2 native tmux integration; guest devenv scripts should do the same when attaching.
- `setup-vscode-webapp.sh` depends on `update-icon.sh` and `iconoverlay.swift` being in the same directory.
- `iconoverlay.swift` is compiled at runtime via `swiftc`; no pre-build step needed.
