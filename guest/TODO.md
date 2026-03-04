# vm-tools TODO

## Remote VSCode Setup
- [ ] Complete remote VSCode setup
  - [x] Key auto repeat settings (delay and speed)
  - [ ] Decide if auth is needed (probably yes)
  - [ ] Extensions list (manage via chezmoi)
    - [ ] C/C++
    - [ ] Claude Code
    - [ ] Monokai theme
    - [ ] Peacock
    - [ ] Prettier
    - [ ] VSCode Neovim
  - [ ] Settings (manage via chezmoi)
    - [ ] Autosave off
    - [ ] Theme
    - [ ] Mono fonts install/auth
    - [ ] Disable VSCode AI Chat features/UI
  - [x] Add code-server install/config to check-dev-env.sh
    - [x] Brewfile
    - [x] Config code-server (port, auth)
    - [ ] Start code-server

## Starship Setup
- [ ] Setup on host
- [ ] Make a prompt that clearly indicates it's running remote/guest VM
- [ ] Config with chezmoi

## Chezmoi run_once_ Migration
- [x] Create run_once_before scripts (macos-defaults, brew packages, Claude Code)
- [x] Move scripts into `deep108/dotfiles-dev` chezmoi repo
- [x] Add `.chezmoi.toml.tmpl` with host/guest auto-detection
- [x] Add shell config templates (`.zprofile`, `.zshrc`) as chezmoi-managed files
- [x] Create `scripts/bootstrap.sh` (Homebrew + chezmoi + `chezmoi init --apply --force`)
- [x] Create `check-dev-tool-updates` script with host/guest package lists
- [x] Test full `chezmoi init --apply` on a fresh VM
- [ ] Add VS Code extensions/settings to chezmoi
- [ ] Add starship config to chezmoi

## Golden Base Image
- [x] Create golden image and test cloning from it
- [x] Verify Claude Code auth persists across clones
- [ ] Document cleanup steps before snapshotting (clear history, remove instance SSH keys)

## Investigate `tart exec`
- [ ] Test `tart exec` as replacement for `ssh_admin()` in provision-vm.sh
- [ ] Verify sudo support and environment context
- [ ] Check if it eliminates need for SSH wait loop during provisioning
