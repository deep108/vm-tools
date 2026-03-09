# vm-tools TODO

## Remote VSCode Setup
- [x] Key auto repeat settings (delay and speed)
- [ ] Decide if auth is needed for serve-web (probably yes)
- [x] Extensions list (manage via chezmoi — run_once_before_04)
- [x] Settings (manage via chezmoi — dot_vscode/data/User/settings.json)
- [x] VS Code serve-web service (LaunchDaemon on macOS, systemd on Linux)

## Starship Setup
- [x] Setup on host and guest
- [x] Teal powerline pill badge with VM hostname (macOS and Linux)
- [x] Config with chezmoi (dot_config/starship.toml.tmpl)

## Chezmoi run_once_ Migration
- [x] Create run_once_before scripts (macos-defaults, brew packages, Claude Code, VS Code extensions)
- [x] Add `.chezmoi.toml.tmpl` with host/guest auto-detection (macOS + Linux)
- [x] Shell config templates (`.zprofile`, `.zshrc`) with OS-aware Homebrew paths
- [x] Create `scripts/bootstrap.sh` (macOS) and `scripts/bootstrap-linux.sh` (Linux)
- [x] Create `check-dev-tool-updates` script with host/guest package lists
- [x] Test full `chezmoi init --apply` on fresh macOS and Linux VMs

## Linux VM Support
- [x] Add `--linux` flag to provision-vm.sh
- [x] SSH-based provisioning (sshpass, no guest agent on Linux)
- [x] bootstrap-linux.sh with Homebrew + chezmoi
- [x] Unified brew formulae on both platforms (mise, starship, tmux, neovim, jq)
- [x] VS Code via apt (casks are macOS-only)
- [x] systemd service for VS Code serve-web
- [x] UTF-8 locale configuration for powerline glyphs
- [x] setup-vm-git.sh Linux compatibility (ip route auto-detection)
- [ ] check-dev-tool-updates Linux testing

## iTerm2 Setup
- [x] Install via Homebrew cask (both host and guest macOS)
- [x] Automate font setting (MesloLGMDZ Nerd Font) — PlistBuddy in provision-vm.sh step 17/18

## Golden Base Image
- [x] Create golden image and test cloning from it
- [x] Verify Claude Code auth persists across clones
- [x] Document cleanup steps (prepare-golden-image.sh)

## macOS VM Auto-Login & First-Boot
- [x] Auto-login provisioned user via `sysadminctl -autologin set`
- [x] Pre-dismiss Setup Assistant dialogs (DidSee* flags)
- [x] Dark mode default (`NSGlobalDomain AppleInterfaceStyle Dark`)
- [x] Patch tart-guest-agent LaunchAgent WorkingDirectory (`/Users/admin` → `/var/empty`)
- [x] Reboot VM after auto-login setup and verify logged-in user
- [x] Sync timezone from host
- [ ] Automate wallpaper setting (desktoppr or similar — osascript requires Finder permissions)
