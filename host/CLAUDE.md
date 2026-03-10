# host-tools

Scripts for managing macOS and Linux virtual machines using **Tart** (Apple Silicon VM manager), provisioning development environments, and setting up secure git workflows between host and guest.

All scripts run on the **host machine**.

## Overview

This toolset covers the full VM provisioning lifecycle:
1. Host machine setup (`Brewfile`)
2. VM provisioning from a base image (`provision-vm.sh`) — supports both macOS and Linux (Debian)
3. VM user creation (`create-macos-vm-user.sh`)
4. VM lifecycle: run (`run-vm.sh`), stop (`stop-vm.sh`), suspend (`suspend-vm.sh`), delete (`delete-vm.sh`)
5. Secure git workflow between host and VM (`setup-vm-git.sh`, `teardown-vm-git.sh`)
6. VS Code web access via app shim (`setup-vscode-webapp.sh`)
7. Icon customization (`update-icon.sh`, `iconoverlay.swift`)

## Files

| File | Purpose |
|------|---------|
| `Brewfile` | Homebrew packages for the host machine; apply with `brew bundle` |
| `provision-vm.sh` | Full VM bootstrap (macOS and Linux): clone, resize, start, create user, install tools, set up VS Code serve-web, configure auto-login, dark mode, iTerm2 font, reboot and verify |
| `run-vm.sh` | Start a VM in suspendable mode (headless by default), wait for SSH, print connection info |
| `stop-vm.sh` | Gracefully stop a running VM (30s timeout, then force) |
| `suspend-vm.sh` | Suspend a running VM (requires `--suspendable` start) |
| `delete-vm.sh` | Stop (if running) and delete a Tart VM |
| `create-macos-vm-user.sh` | Create/delete a user on a running macOS VM via `tart exec`; supports `--admin` flag |
| `tart-exec.sh` | Run a command on a running VM via `tart exec`; supports `--user` for user-context execution |
| `prepare-golden-image.sh` | Clean instance-specific state from a running VM and stop it, preparing it as a golden base image |
| `setup-vm-git.sh` | Set up secure git workflow: bare repo on host, restricted SSH key, VM clone (works with macOS and Linux VMs) |
| `teardown-vm-git.sh` | Remove git workflow setup for a VM (authorized_keys entry, wrapper script entries) |
| `lib/pick-vm.sh` | Shared helper: interactive VM picker filtered by state (sourced by run/stop/suspend scripts) |
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
| Timezone | `systemsetup -settimezone` | `timedatectl` |
| Homebrew | Pre-installed, ownership transferred | Installed by user during bootstrap |
| VS Code service | LaunchDaemon (launchd) | systemd unit |
| Bootstrap script | `scripts/bootstrap.sh` | `scripts/bootstrap-linux.sh` |
| Auto-login | `sysadminctl -autologin` + reboot | N/A |
| Setup Assistant | Pre-dismissed via `defaults write` | N/A |
| Dark mode | Set via `NSGlobalDomain AppleInterfaceStyle` | N/A |
| iTerm2 font | PlistBuddy (MesloLGMDZ Nerd Font) | N/A (headless) |

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

### Run, stop, and suspend a VM
```bash
./run-vm.sh                            # pick from stopped/suspended VMs
./run-vm.sh <vm-name>                  # start specific VM (headless, suspendable)
./run-vm.sh <vm-name> --gui            # start with GUI window + clipboard
./run-vm.sh <vm-name> --linux          # Linux guest
./stop-vm.sh                           # pick from running VMs
./stop-vm.sh <vm-name>                 # stop specific VM
./suspend-vm.sh                        # pick from running VMs
./suspend-vm.sh <vm-name>             # suspend specific VM
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
- `tart exec` has a minimal PATH that excludes `/sbin` — use full paths for commands like `/sbin/reboot`.
- `tart exec` can hang when the VM reboots (guest agent dies mid-connection) — run reboot commands in a background subshell with a timeout.
- Linux VMs use SSH for all guest communication during provisioning. `sshpass` is required (cirruslabs images use admin/admin credentials).
- SSH host keys are regenerated during provisioning so cloned VMs get unique keys.
- The tart-guest-agent LaunchAgent plist has `WorkingDirectory` hardcoded to `/Users/admin`. Provisioning patches this to `/var/empty` so it works under any auto-login user.
- macOS auto-login is configured via `sysadminctl -autologin set` (handles both loginwindow pref and kcpasswd).
- macOS Setup Assistant dialogs are pre-dismissed by writing `DidSee*` flags to `com.apple.SetupAssistant` before first GUI login.
- VM timezone is synced from the host during provisioning (both macOS and Linux, including local base re-provisions).
- `setup-vm-git.sh` auto-detects the host gateway IP from the VM's default route (uses `ip route` on Linux, `route -n get` on macOS).
- `ssh-tmux.sh` uses `tmux -CC` for iTerm2 native tmux integration.
- Cleanup on failure removes the VM's IP from `~/.ssh/known_hosts` to avoid stale entries.
