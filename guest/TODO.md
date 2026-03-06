# vm-tools TODO

## Remote VSCode Setup
- [ ] Complete remote VSCode setup
  - [x] Key auto repeat settings (delay and speed)
  - [ ] Decide if auth is needed (probably yes)
  - [x] Extensions list (manage via chezmoi — run_once_before_04)
    - [x] C/C++
    - [x] Claude Code
    - [x] Monokai theme
    - [x] Peacock
    - [x] Prettier
    - [x] VSCode Neovim
    - [x] GitHub Copilot
  - [x] Settings (manage via chezmoi — dot_vscode/data/User/settings.json)
    - [x] Autosave off
    - [x] Theme (Monokai Pro)
    - [x] Mono fonts (SF Mono)
    - [x] Disable minimap
    - [x] AI Chat features kept enabled (GitHub Copilot)
  - [x] Add code-server install/config to check-dev-env.sh
    - [x] Brewfile
    - [x] Config code-server (port, auth)
    - [x] Start code-server (LaunchDaemon via provision-vm.sh step 14)

## Starship Setup
- [x] Setup on host
- [x] Make a prompt that clearly indicates it's running remote/guest VM (teal powerline pill badge with hostname)
- [x] Config with chezmoi (dot_config/starship.toml.tmpl)

## Chezmoi run_once_ Migration
- [x] Create run_once_before scripts (macos-defaults, brew packages, Claude Code)
- [x] Move scripts into `deep108/dotfiles-dev` chezmoi repo
- [x] Add `.chezmoi.toml.tmpl` with host/guest auto-detection
- [x] Add shell config templates (`.zprofile`, `.zshrc`) as chezmoi-managed files
- [x] Create `scripts/bootstrap.sh` (Homebrew + chezmoi + `chezmoi init --apply --force`)
- [x] Create `check-dev-tool-updates` script with host/guest package lists
- [x] Test full `chezmoi init --apply` on a fresh VM
- [x] Add VS Code extensions/settings to chezmoi
- [x] Add starship config to chezmoi

## iTerm2 Setup
- [x] Install via Homebrew cask (both host and guest)
- [ ] Automate font setting (MesloLGMDZ Nerd Font) — currently manual per machine
  - Options: Dynamic Profiles JSON, or PlistBuddy to patch existing profile
  - Location: `~/Library/Application Support/iTerm2/DynamicProfiles/`

## Golden Base Image
- [x] Create golden image and test cloning from it
- [x] Verify Claude Code auth persists across clones
- [x] Document cleanup steps before snapshotting (prepare-golden-image.sh)

## Investigate `tart exec`
- [x] Test `tart exec` as replacement for `ssh_admin()` in provision-vm.sh
- [x] Verify sudo support and environment context
- [x] Check if it eliminates need for SSH wait loop during provisioning
- [x] Rewrite provision-vm.sh and create-tart-user2.sh to use `tart exec`
- [x] Add SSH host key regeneration for cloned VMs
- [x] Auto-add VM host key to known_hosts
