# VM Git Setup — Secure Host/Guest Workflow

## Automated Setup

Use `setup-vm-git.sh` to automate the entire workflow below:

```bash
# Clone an existing GitHub repo into a VM (GitHub → bare repo → VM clone)
host/setup-vm-git.sh <vm-name> <github-shorthand>
host/setup-vm-git.sh <vm-name> deep108/my-repo --clone-dir custom-name

# Publish a VM repo to a new GitHub repo (VM repo → bare repo → GitHub)
host/publish-vm-git.sh <vm-name> deep108/new-repo
host/publish-vm-git.sh <vm-name> deep108/new-repo --repo-dir my-local-dir --public

# Remove setup for a VM
host/teardown-vm-git.sh <vm-name>
```

Both scripts handle bare repo creation, SSH key generation, host key pinning, and authorized_keys configuration. They auto-detect the host gateway IP from the VM's default route (`ip route` on Linux, `route -n get` on macOS). All steps are idempotent — safe to re-run after partial failures.

## Why

The goal is to keep GitHub credentials **only on the host Mac**, so that a compromised Tart VM (e.g. via a malicious VSCode extension or npm package) cannot push to GitHub or cause damage beyond the VM itself.

## How It Works

```
GitHub <--(host credentials only)--> Bare repo on host <--(SSH, restricted key)--> VM working clone
```

- The VM pushes to a **bare repo on the host** — not directly to GitHub
- The host bare repo has GitHub as its `origin` and is the only machine that can push there
- The VM's SSH key is restricted via `authorized_keys` to only run git operations on that one specific repo — no shell access, no access to other repos

## What is a Bare Repo

A bare repo is a git database with no working tree (no checked-out files). It's what git servers (GitHub, GitLab) use internally. Key properties:
- You can push to it safely (no working tree conflicts)
- It can have a remote (e.g. `origin` pointing to GitHub)
- You can still run `git log`, `git diff`, `git show` etc. on it

## Manual Setup Steps

If you prefer to set things up manually (or need to understand what `setup-vm-git.sh` does):

### 1. Create the bare repo on the host

```bash
mkdir -p ~/dev/repos
git clone --bare https://github.com/deep108/my-repo.git ~/dev/repos/my-repo.git
```

### 2. Generate a dedicated SSH key in the VM

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mac-host-git -C "tart-vm-git-<vm-name>"
cat ~/.ssh/mac-host-git.pub  # copy this
```

### 3. Create a git access wrapper script on the host

Create `~/.local/bin/git-vm-<vm-name>.sh`:

```bash
#!/bin/bash
REPO="/Users/youruser/dev/repos/my-repo.git"
case "$SSH_ORIGINAL_COMMAND" in
  "git-upload-pack '$REPO'")  exec git-upload-pack "$REPO" ;;
  "git-receive-pack '$REPO'")  exec git-receive-pack "$REPO" ;;
  *)
    echo "Access denied: $SSH_ORIGINAL_COMMAND" >&2
    exit 1
    ;;
esac
```

### 4. Add the VM's public key to the host's authorized_keys

```
command="/Users/youruser/.local/bin/git-vm-<vm-name>.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...
```

### 5. Seed the host's SSH public key into the VM

This pins the host identity so the VM won't connect to an impersonator:

```bash
# On the host — read the public key and push it to the VM's known_hosts:
HOST_KEY=$(awk '{print $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub)
ssh <vm-user>@<vm-ip> "mkdir -p ~/.ssh && echo '<host-gateway-ip> ${HOST_KEY}' >> ~/.ssh/known_hosts"
```

### 6. Configure SSH in the VM

`~/.ssh/config` in the VM:

```
Host mac-host
  HostName <host-gateway-ip>
  User youruser
  IdentityFile ~/.ssh/mac-host-git
  StrictHostKeyChecking yes
```

Host gateway IP: auto-detected by `setup-vm-git.sh`, or find manually:
- macOS VM: `route -n get default | awk '/gateway:/{print $2}'`
- Linux VM: `ip route show default | awk '/default/{print $3}'`

Note: Remote Login must be enabled on the host — System Settings > General > Sharing > Remote Login > On

### 7. Clone from the bare repo in the VM

```bash
git clone ssh://mac-host/Users/youruser/dev/repos/my-repo.git ~/dev/my-repo
```

Use `ssh://` URL format (not SCP-style `mac-host:/path`).

## Day-to-Day Workflow

**Normal development in the VM:**
```bash
git add .
git commit -m "..."
git push origin main   # goes to bare repo on host, NOT GitHub
```

**Review changes on the host before publishing:**
```bash
cd ~/dev/repos/my-repo.git

git log origin/main..main --oneline   # commits pending push to GitHub
git diff origin/main..main            # full diff

# To browse actual files:
git worktree add /tmp/review main
open /tmp/review
git worktree remove /tmp/review
```

**Publish to GitHub from the host:**
```bash
cd ~/dev/repos/my-repo.git
git push origin main
```

**Pull GitHub updates into the bare repo (so VM can fetch them):**
```bash
cd ~/dev/repos/my-repo.git
git fetch origin
# Then in the VM:
git pull
```

## Adding More Repos Later

Run `setup-vm-git.sh` again with the new repo — it appends case entries to the existing wrapper script:

```bash
host/setup-vm-git.sh <vm-name> deep108/another-repo
```
