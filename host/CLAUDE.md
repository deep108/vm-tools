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
- Linux VMs have no guest agent — use SSH via `sshpass` instead

## SSH Security Model

The git workflow (`setup-vm-git.sh`, `publish-vm-git.sh`) uses a layered SSH architecture:

- **Host→VM**: Standard SSH key auth. The host's `~/.ssh/id_ed25519.pub` is installed to the VM during provisioning. No agent forwarding.
- **VM→Host** (git only): VM generates its own dedicated key (`~/.ssh/mac-host-git`). The host's `authorized_keys` restricts this key with `command=`, `no-agent-forwarding`, `no-port-forwarding`, `no-pty` — only `git-upload-pack`/`git-receive-pack` on specific bare repos.
- **Host→GitHub**: Uses the user's own SSH key (configured in `~/.ssh/config` for `github.com`). VMs never connect to GitHub directly.
- **Remote URLs**: Both scripts use SSH URLs (`git@github.com:`) for GitHub remotes on bare repos.

## Provisioning Notes

- SSH host keys are regenerated so cloned VMs get unique identities
- Guest agent plist `WorkingDirectory` is patched from `/Users/admin` to `/var/empty`
- macOS auto-login: `sysadminctl -autologin set`; Setup Assistant: `DidSee*` flags
- VM timezone synced from host (both macOS and Linux, including local base re-provisions)
- Cleanup on failure removes VM IP from `~/.ssh/known_hosts`
