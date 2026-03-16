# vm-tools TODO

## Open

- [ ] Add `IdentitiesOnly yes` to host→VM SSH calls (ssh-tmux, ssh-run, provision-vm) so SSH doesn't offer the GitHub key during VM auth handshakes. Cosmetic hardening — not a security risk, but avoids unnecessary key negotiation.
- [ ] Remove admin account after provisioning (plan at `.claude/plans/remove-admin-account-after-provisioning.md`)
- [ ] Decide if auth is needed for VS Code serve-web (probably yes)
- [ ] check-dev-tool-updates Linux testing
- [ ] Automate wallpaper setting (desktoppr or similar — osascript requires Finder permissions)

## Done

- [x] Remote VS Code setup (key repeat, extensions, settings, serve-web service)
- [x] Starship prompt with VM name badge (host + guest, chezmoi-managed)
- [x] Chezmoi run_once_ migration (macOS defaults, brew, Claude Code, VS Code, bootstrap scripts, check-dev-tool-updates)
- [x] Linux VM support (provisioning, bootstrap, brew formulae, VS Code apt, systemd, locale, setup-vm-git)
- [x] iTerm2 automated font + scrollback config (PlistBuddy in provision-vm.sh)
- [x] Golden base image workflow (prepare-golden-image.sh, Claude Code auth persists)
- [x] macOS auto-login, Setup Assistant, dark mode, guest agent patch, timezone sync
- [x] publish-vm-git.sh (reverse of setup-vm-git: VM repo → bare repo → new GitHub repo)
- [x] Merge setup-vm-git.sh and publish-vm-git.sh into bridge-vm-git.sh (state-detecting unified script)
- [x] Interactive VM picker for ssh-tmux, ssh-run, tart-exec, run/stop/suspend/delete-vm
- [x] SSH URLs for GitHub remotes in setup-vm-git and publish-vm-git
