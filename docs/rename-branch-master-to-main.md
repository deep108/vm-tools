# Renaming `master` to `main` (Guest/Host/GitHub)

When a bridged repo (set up by `bridge-vm-git.sh`) still uses `master` as its primary branch, follow these steps to rename it to `main` across all three layers.

Work from the outside in: GitHub first, then the host bare repo, then the guest clone.

## 1. GitHub

Go to the repo on GitHub: **Settings > General > Default branch** and rename `master` to `main`.

GitHub renames the branch server-side, preserves all history, and sets up a redirect from `master` to `main`.

## 2. Host bare repo

```bash
cd ~/dev/repos/<repo>.git

# Pull the renamed branch from GitHub
git fetch origin

# Rename the local branch
git branch -m master main

# Update HEAD to point to main
git symbolic-ref HEAD refs/heads/main

# Fix the upstream tracking reference (bare repos don't have
# remote-tracking branches, so git branch -u won't work here)
git config branch.main.merge refs/heads/main
```

Verify it looks right:

```bash
git config branch.main.merge    # should say refs/heads/main
git symbolic-ref HEAD            # should say refs/heads/main
git push                         # should work with no errors
```

## 3. Guest clone

```bash
cd ~/dev/<repo>

# Fetch the renamed branch from the host bare repo
git fetch origin

# Rename the local branch
git branch -m master main

# Update upstream tracking
git branch -u origin/main main

# Update the default remote HEAD
git remote set-head origin main
```

Verify:

```bash
git status    # should say "On branch main" with correct tracking
git pull      # should work
git push      # should work
```

## Other clones

Anyone else with a clone of the repo needs to run the same steps as the guest clone (step 3).

## Cleaning up the old remote branch

If `master` still exists on GitHub after the rename (e.g., the rename didn't delete it), remove it from the host:

```bash
cd ~/dev/repos/<repo>.git
git push origin --delete master
```
