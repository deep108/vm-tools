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
