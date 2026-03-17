# host-tools

Scripts for managing macOS and Linux VMs using **Tart** (Apple Silicon), provisioning dev environments, and secure git workflows between host and guest. All scripts run on the **host machine**.

## Key Conventions

- `set -euo pipefail` in all scripts
- Color codes: `RED`, `GREEN`, `YELLOW`, `BLUE`, `NC` (reset)
- Scripts with optional VM name argument use `lib/pick-vm.sh` for interactive selection
- Steps that can fail on re-run should be idempotent (check-then-act pattern with yellow `!` for skipped, green `✓` for done)

## tart exec Gotchas

- Runs as `admin` user (passwordless sudo). For user context: `sudo -Hu <user> zsh -l -c '...'`
- Does NOT support `--` separator — treats it as the command name
- Minimal PATH excludes `/sbin` — use full paths (e.g., `/sbin/reboot`)
- Can hang when VM reboots (guest agent dies) — run reboot in background subshell with timeout
- Only used post-reboot for GUI commands (`open`, `osascript`) and guest agent verification
- Early provisioning uses SSH via `sshpass` for both macOS and Linux (vanilla image has no guest agent)

## SSH Security Model

The git workflow (`bridge-vm-git.sh`) uses a layered SSH architecture:

- **Host→VM**: Standard SSH key auth. The host's `~/.ssh/id_ed25519.pub` is installed to the VM during provisioning. No agent forwarding.
- **VM→Host** (git only): VM generates its own dedicated key (`~/.ssh/mac-host-git`). The host's `authorized_keys` restricts this key with `command=`, `no-agent-forwarding`, `no-port-forwarding`, `no-pty` — only `git-upload-pack`/`git-receive-pack` on specific bare repos.
- **Host→GitHub**: Uses the user's own SSH key (configured in `~/.ssh/config` for `github.com`). VMs never connect to GitHub directly.
- **Remote URLs**: Both scripts use SSH URLs (`git@github.com:`) for GitHub remotes on bare repos.

## Provisioning Notes

- Base image: `macos-tahoe-vanilla` (clean macOS with SSH + passwordless sudo, no Homebrew or guest agent)
- All early provisioning uses SSH via `sshpass -p admin` (both macOS and Linux)
- `sysadminctl -addUser` disrupts admin SSH auth — all step 8 macOS commands run in a single SSH session, then subsequent steps use the new user's key-based auth
- SSH options split: `SSH_PASS` (password auth, PubkeyAuthentication=no) for admin, `SSH_KEY` (key auth, IdentitiesOnly=yes) for user
- Homebrew installed fresh (auto-installs Xcode CLT, providing git); no ownership transfer needed
- `GIT_CONFIG_COUNT` env vars in `vm_exec_user` disable osxkeychain credential helper (fails over non-interactive SSH)
- Brew taps (`xcodesorg/made`, `cirruslabs/cli`) are pre-cloned via direct `git clone` — brew's internal git doesn't inherit `GIT_CONFIG_COUNT`, so `brew tap` fails with credential helper errors
- Xcode installed via `sudo -E xcodes install` with `--experimental-unxip`; credentials via `XCODES_USERNAME`/`XCODES_PASSWORD` env vars; `--no-xcode` to skip, `--xcode-version` to pin
- `xcode-select -s` pointed to installed Xcode app (xcodes names it `Xcode-<ver>.app`)
- tart-guest-agent installed via brew; requires two launchd plists (from `cirruslabs/macos-image-templates`): LaunchDaemon (`--run-daemon`, handles `tart exec`) + LaunchAgent (`--run-agent`, handles clipboard)
- SSH host keys are regenerated so cloned VMs get unique identities
- macOS auto-login: manual `/etc/kcpassword` XOR encoding + loginwindow plist (`sysadminctl -autologin` fails over SSH with error:22)
- Gatekeeper quarantine stripped from VS Code and iTerm2 after bootstrap
- VM timezone synced from host (both macOS and Linux, including local base re-provisions)
- Reboot triggered via SSH; guest agent verified via `tart exec` after reboot
- GUI commands (iTerm2 `open`/`osascript`) use `vm_exec_gui` (tart exec) post-reboot
- Cleanup on failure removes VM IP from `~/.ssh/known_hosts`
