# Guest Tools TODO

## Remote VSCode Setup
- [ ] Complete remote VSCode setup
  - [x] Key auto repeat settings (delay and speed)
  - [ ] Decide if auth is needed (probably yes)
  - [ ] Extensions list
    - [ ] C/C++
    - [ ] Claude Code
    - [ ] Monokai theme
    - [ ] Peacock
    - [ ] Prettier
    - [ ] VSCode Neovim
  - [ ] Settings
    - [ ] Autosave off
    - [ ] Theme
    - [ ] Mono fonts install/auth
    - [ ] Disable VSCode AI Chat features/UI
  - [ ] Chezmoi to setup extensions and settings
  - [x] Add code-server install/config to check-dev-env.sh
    - [x] Brewfile
    - [x] Config code-server (port, auth)
    - [ ] Start code-server

## Starship Setup
- [ ] Setup on host
- [ ] Make a prompt that clearly indicates it's running remote
- [ ] Config with Chezmoi

## Chezmoi Configuration
- [ ] `~/.config/code-server/config.yaml`
  - [ ] bind-addr: 0.0.0.0:8080
  - [ ] password: (set securely)
- [ ] `~/dev/Brewfile`
  - [ ] code-server

## Chezmoi run_once_ Migration
- [x] Create `run_once_before_01-install-homebrew.sh`
- [x] Create `run_once_before_02-install-brew-packages.sh`
- [x] Create `run_once_before_03-install-claude-code.sh`
- [ ] Move scripts into actual chezmoi dotfiles repo (e.g. `deep108/dotfiles`)
- [ ] Add shell config templates (`.zprofile`, `.zshrc`) as chezmoi-managed files
- [ ] Add VS Code extensions/settings to chezmoi
- [ ] Add starship config to chezmoi
- [ ] Test full `chezmoi init --apply` on a fresh VM

## Golden Base Image
- [ ] Create golden image: `provision-vm.sh golden-dev-base`, run check-dev-env.sh + chezmoi inside
- [ ] Test cloning from golden: `provision-vm.sh my-project --base golden-dev-base`
- [ ] Document cleanup steps before snapshotting (clear history, remove instance SSH keys)

## Investigate `tart exec`
- [ ] Test `tart exec` as replacement for `ssh_admin()` in provision-vm.sh
- [ ] Verify sudo support and environment context
- [ ] Check if it eliminates need for SSH wait loop during provisioning
