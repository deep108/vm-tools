# vm-tools TODO

## Open

- [ ] Add `IdentitiesOnly yes` to host→VM SSH calls (ssh-tmux, ssh-run, provision-vm) so SSH doesn't offer the GitHub key during VM auth handshakes. Cosmetic hardening — not a security risk, but avoids unnecessary key negotiation.
- [ ] Remove admin account after provisioning (plan at `.claude/plans/remove-admin-account-after-provisioning.md`)
- [ ] Decide if auth is needed for VS Code serve-web (probably yes)
- [ ] check-dev-tool-updates Linux testing
- [ ] Automate wallpaper setting (desktoppr or similar — osascript requires Finder permissions)
- [ ] Repo-scoped GitHub credentials for bridge-vm-git.sh — deploy keys are the viable option (fine-grained PATs can't be created programmatically). Two approaches: host deploy key (keeps bare repo review gate) or VM deploy key (simpler, direct push, but loses review gate). Limitation: SSH git only, one key per repo.
- [ ] Check for ownership side effects from `sudo xcodes install` (Xcode app owned by root instead of user — may be fine since `/Applications` is typically root-owned)

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
- [x] Switch to macos-tahoe-vanilla base image (SSH-based provisioning, Xcode install, brew from scratch, guest agent via brew)
