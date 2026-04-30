# Automation Roadmap

Steps that were manual during reader-buddy's first deploy (April 2026). Captured here for future automation work, prioritized by how often they'll repeat.

For context on the deploy architecture itself, see [`deploy-architecture.md`](deploy-architecture.md).

## One-off manual TODOs (existing infra)

- [ ] **reader-buddy GAR cleanup policies** — set up via GCP console at https://console.cloud.google.com/artifacts/docker/reader-buddy-494902/us-west1/reader-buddy: keep-most-recent 10 tagged, delete tagged older than 90d, delete untagged older than 7d. We declined to set these at registry creation. Without them, GAR storage will accumulate over time.

## Inventory of manual steps

| Step | Frequency | Currently |
|------|-----------|-----------|
| Generate dev VM's outbound SSH keypair (`id_ed25519`) | Per-VM | Manual `ssh-keygen` |
| Add dev VM's pubkey to Hetzner authorized_keys | Per-(VM, Hetzner-box) | SSH-pipe trick from host |
| NOPASSWD sudo on Hetzner for admin user | Per-Hetzner-box | Manual one-liner |
| Generate signing key + configure SSH signing + allowed_signers | Per-VM | Manual multi-step |
| GCP project + Artifact Registry repo creation | Per-project (or per-server-tier) | Web console |
| Service account + repo-level IAM + JSON key | Per-project | Web console |
| Encrypt `.kamal/secrets.age` with age | Per-project | Manual `age -p` |
| Template substitution into project repo (cp + sed) | Per-project | Manual recipe in template README |
| Configure GAR cleanup policies (keep-N + age-based) | Per-project | Web console, easy to forget |
| Tag + verify-tag + deploy | Per-deploy | Already minimal |

## Tier 1 — high ROI, quick wins

**Do these first.** Each is small, independent, immediately useful for the next dev VM rebuild and the next project.

### 1.1 `provision-vm.sh`: generate dev VM's own `id_ed25519`

Currently, only the host's pubkey gets installed for *inbound* SSH. The VM has no outbound keypair — anything that needs to SSH out (Hetzner, GitHub, etc.) requires manually generating one.

**Change**: in `provision-vm.sh`, after user creation, generate `id_ed25519` if absent.

```bash
vm_exec_user "[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C \"\$(whoami)@\$(hostname)\""
```

~5 lines. Idempotent. Place near where the host's pubkey gets installed.

### 1.2 `provision-vm.sh`: signing key + SSH signing setup

Generates a passphrase-protected signing key, configures git to use SSH-based signing, sets up `allowed_signers`. One-time per VM, interactive (passphrase prompt).

**Change**: add a new step (probably `[12c/22]` or similar) that:

1. Generates `~/.ssh/id_ed25519_signing` with `ssh-keygen` (interactive — user provides passphrase)
2. `git config --global gpg.format ssh`
3. `git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub`
4. Writes `~/.config/git/allowed_signers` using the email already propagated from host
5. `git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers`

Add `--no-signing` flag to skip on VMs that won't deploy from. Default = enabled.

Pseudocode skeleton:

```bash
if [[ "$NO_SIGNING" == false ]]; then
    echo "[12c/22] Setting up git SSH signing key..."
    vm_exec_user "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_signing \
        -C '\$(whoami)@\$(hostname) (git-signing)'"
    # ... configure git, write allowed_signers
fi
```

Note: the signing key is generated *fresh* per VM and never propagated. Each new VM gets its own. The pubkey gets added to `allowed_signers` on that VM. If you sign on multiple VMs, each VM's pubkey needs to be in each `allowed_signers` (or added to a shared one in the dotfiles). Consider this when scaling to multiple dev VMs.

### 1.3 `vm-tools/host/scaffold-deploy-project.sh <project>`

Replaces the manual cp + sed substitution recipe currently in the template README. Host-side script that runs the substitution remotely on the dev VM.

**Inputs** (interactive prompts, with sensible defaults):
- Project name
- Hetzner host IP
- Domain (default: `<project>.deepdevelopment.com`)
- GCP project ID
- GAR region (default: `us-west1`)
- GAR repo name (default: same as project)

**What it does**:
1. SSH to dev VM
2. `mkdir ~/dev/<project>`
3. Copy templates from `~/dev/vm-tools/templates/deploy-project/`
4. Run sed substitutions
5. `git init` if needed
6. Print the next steps (set up GAR, encrypt secrets, etc.)

~50 lines of bash. Idempotent.

## Tier 2 — high value, more work

**Do these when you're spinning up project #2** (or whenever you find yourself repeating the manual GAR setup).

### 2.1 `vm-tools/host/setup-gar-project.sh`

Automates the GAR setup that's currently web-console clicks. Requires `gcloud` CLI (install via `brew install --cask gcloud-cli`).

```bash
gcloud artifacts repositories create <repo> \
    --project=<gcp-project> \
    --repository-format=docker \
    --location=<region>

gcloud iam service-accounts create kamal-deploy-<project> \
    --project=<gcp-project>

gcloud artifacts repositories add-iam-policy-binding <repo> \
    --project=<gcp-project> \
    --location=<region> \
    --member=serviceAccount:kamal-deploy-<project>@<gcp-project>.iam.gserviceaccount.com \
    --role=roles/artifactregistry.writer

gcloud iam service-accounts keys create /tmp/key.json \
    --iam-account=kamal-deploy-<project>@<gcp-project>.iam.gserviceaccount.com

# Set cleanup policies so the registry doesn't accumulate forever:
#   - Keep most-recent 10 tagged versions (rollback room)
#   - Delete tagged versions older than 90 days
#   - Delete untagged versions (build orphans) older than 7 days
# These can be specified as a JSON file passed via `--policies` to
# `gcloud artifacts repositories set-cleanup-policies`. Example structure:
#   [{"name": "keep-recent-10", "action": {"type": "Keep"},
#     "mostRecentVersions": {"keepCount": 10}},
#    {"name": "delete-old-tagged", "action": {"type": "Delete"},
#     "condition": {"tagState": "TAGGED", "olderThan": "7776000s"}},
#    {"name": "delete-untagged", "action": {"type": "Delete"},
#     "condition": {"tagState": "UNTAGGED", "olderThan": "604800s"}}]

# Base64 + pipe to dev VM, encrypt with age, shred local
B64=$(base64 -i /tmp/key.json | tr -d '\n')
ssh "$VM" "cat > ~/dev/<project>/.kamal/secrets" <<EOF
KAMAL_REGISTRY_PASSWORD=$B64
EOF
ssh "$VM" "cd ~/dev/<project> && age -p < .kamal/secrets > .kamal/secrets.age && shred -u .kamal/secrets"
shred -u /tmp/key.json
```

Adds a dependency (`gcloud`), but for personal use spinning up multiple projects, it pays back fast.

### 2.2 `vm-tools/host/bridge-hetzner-server.sh <vm-name> <hetzner-alias>`

One-time per (dev VM, Hetzner box) — registers the dev VM's SSH key in Hetzner's `authorized_keys` for the admin user. Replaces the manual SSH-pipe trick.

```bash
ssh "$VM" "cat ~/.ssh/id_ed25519.pub" | ssh "$HETZNER" "cat >> ~/.ssh/authorized_keys"
ssh "$VM" "ssh -o StrictHostKeyChecking=accept-new daviddeepdev@$HETZNER_IP echo OK"
```

~15 lines. Worth it if you'll have multiple dev VMs or Hetzner boxes.

## Tier 3 — defer or skip

- **`harden-hetzner.sh`** — write when provisioning Hetzner box #2 (per existing deferral)
- **DNS automation** (Cloudflare API) — one A record per project; manual is fine until ~5 projects
- **NOPASSWD setup** — small enough that automating it isn't worth it; once per Hetzner box
- **`hcloud` CLI for Hetzner provisioning** — only worth it at ~3+ servers (per existing deferral)

## Order of execution

When you come back to this:

1. Tier 1.1 first (smallest, lowest risk, immediately useful)
2. Tier 1.2 (signing key — saves ~5 manual steps per VM)
3. Tier 1.3 (scaffolding script — saves the long sed dance)
4. *Then evaluate*: does Tier 2.1 (GAR automation) still feel painful enough to do? If yes, install gcloud and write that script. If no, defer.

Each Tier 1 item is ~30-60 minutes of work plus testing. Tier 2.1 is ~1-2 hours including gcloud setup.

## Notes from the manual run that informed this list

- **Kamal does not run `docker login` on the build machine** — only on the deploy target. `bin/bootstrap-server` and `bin/deploy` handle dev-VM-side login. (See [feedback memory](../../.claude/projects/-Users-daviddeepdev-dev-vm-tools/memory/feedback_kamal_docker_login.md).)
- **Fine-grained PATs don't yet support ghcr.io.** Classic PAT scoping was too broad for the threat model, hence the GAR pivot.
- **GCP service-account keys must be IAM-bound at the *repo* level**, not project level — otherwise the SA can write to all repos in the project, which defeats the scoping.
