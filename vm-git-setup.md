# VM Git Setup — Secure Host/Guest Workflow

## Why

The goal is to keep GitHub credentials **only on the host Mac**, so that a compromised Tart VM (e.g. via a malicious VSCode extension or npm package) cannot push to GitHub or cause damage beyond the VM itself.

## How It Works

```
GitHub <──(host credentials only)──> Bare repo on host <──(SSH, restricted key)──> VM working clone
```

- The VM pushes to a **bare repo on the host** — not directly to GitHub
- The host bare repo has GitHub as its `origin` and is the only machine that can push there
- The VM's SSH key is restricted via `authorized_keys` to only run git operations on that one specific repo — no shell access, no access to other repos

## What is a Bare Repo

A bare repo is a git database with no working tree (no checked-out files). It's what git servers (GitHub, GitLab) use internally. Key properties:
- You can push to it safely (no working tree conflicts)
- It can have a remote (e.g. `origin` pointing to GitHub)
- You can still run `git log`, `git diff`, `git show` etc. on it

## Setup Steps (What Actually Worked)

### 1. Create the bare repo on the host

```bash
# If you already have the repo cloned locally, clone from that:
git clone --bare ~/dev/deep-habits-rn ~/dev/repos/deep-habits-rn.git

# Then add GitHub as origin:
cd ~/dev/repos/deep-habits-rn.git
git remote add origin https://github.com/deep108/deep-habits-rn.git
```

### 2. Generate a dedicated SSH key in the VM

```bash
ssh-keygen -t ed25519 -f ~/.ssh/host_git -C "tart-vm-git"
cat ~/.ssh/host_git.pub  # copy this
```

### 3. Create a git access wrapper script on the host

Create `~/bin/git-access.sh`:

```bash
#!/bin/bash
REPO="/Users/daviddeepdev/dev/repos/deep-habits-rn.git"
case "$SSH_ORIGINAL_COMMAND" in
  "git-upload-pack '$REPO'")
    exec git-upload-pack "$REPO"
    ;;
  "git-receive-pack '$REPO'")
    exec git-receive-pack "$REPO"
    ;;
  *)
    echo "Access denied: $SSH_ORIGINAL_COMMAND"
    exit 1
    ;;
esac
```

```bash
chmod +x ~/bin/git-access.sh
```

This allows clone and push to that one repo only. Any other command is denied.

### 4. Add the VM's public key to the host's authorized_keys

In `~/.ssh/authorized_keys` on the host, add one line:

```
command="/Users/daviddeepdev/bin/git-access.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...vm-public-key...
```

### 5. Configure SSH in the VM

`~/.ssh/config` in the VM:

```
Host mac-host
  HostName 192.168.66.1
  User daviddeepdev
  IdentityFile ~/.ssh/host_git
```

Note: Tart's host gateway IP is `192.168.66.1`. Verify with `netstat -rn | grep default` from the VM.

Note: Remote Login must be enabled on the host — System Settings → General → Sharing → Remote Login → On

### 6. Clone from the bare repo in the VM

```bash
git clone ssh://mac-host/Users/daviddeepdev/dev/repos/deep-habits-rn.git ~/dev/deep-habits-rn
```

Use `ssh://` URL format (not SCP-style `mac-host:/path`) — this is what worked.

## Day-to-Day Workflow

**Normal development in the VM:**
```bash
git add .
git commit -m "..."
git push origin main   # goes to bare repo on host, NOT GitHub
```

**Review changes on the host before publishing:**
```bash
cd ~/dev/repos/deep-habits-rn.git

git log origin/main..main --oneline   # commits pending push to GitHub
git diff origin/main..main            # full diff

# To browse actual files:
git worktree add /tmp/review main
open /tmp/review
git worktree remove /tmp/review
```

**Publish to GitHub from the host:**
```bash
cd ~/dev/repos/deep-habits-rn.git
git push origin main
```

**Pull GitHub updates into the bare repo (so VM can fetch them):**
```bash
cd ~/dev/repos/deep-habits-rn.git
git fetch origin
# Then in the VM:
git pull
```

## Adding More Repos Later

1. Create another bare repo on the host
2. Add new `case` entries to `~/bin/git-access.sh` for the new repo's path
