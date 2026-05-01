# Automation Roadmap

Steps that were manual during reader-buddy's first deploy (April 2026). Captured here for future automation work, prioritized by how often they'll repeat.

For context on the deploy architecture itself, see [`deploy-architecture.md`](deploy-architecture.md).

## One-off manual TODOs (existing infra)

- [x] **reader-buddy GAR cleanup policies** — applied + enforcing (2026-04-30): `keep-recent-10`, `delete-old-tagged` (>90d), `delete-untagged` (>7d). Set via `gcloud artifacts repositories set-cleanup-policies reader-buddy --location=us-west1 --no-dry-run --policy=<file>`.

## Inventory of manual steps

| Step | Frequency | Currently |
|------|-----------|-----------|
| Generate dev VM's outbound SSH keypair (`id_ed25519`) | Per-VM | **Automated** (`provision-vm.sh`, after step 10) |
| Add dev VM's pubkey to Hetzner authorized_keys | Per-(VM, Hetzner-box) | SSH-pipe trick from host |
| NOPASSWD sudo on Hetzner for admin user | Per-Hetzner-box | Manual one-liner |
| Generate signing key + configure SSH signing + allowed_signers | Per-VM | **Automated** (`provision-vm.sh`, step 14; `--no-signing` to skip) |
| GCP project + Artifact Registry repo creation | Per-project (or per-server-tier) | Web console |
| Service account + repo-level IAM + JSON key | Per-project | Web console |
| Encrypt `.kamal/secrets.age` with age | Per-project | Manual `age -p` |
| Template substitution into project repo (cp + sed) | Per-project | Manual recipe in template README |
| Configure GAR cleanup policies (keep-N + age-based) | Per-project | Manual `gcloud artifacts repositories set-cleanup-policies` (template policy in 2.1) |
| Tag + verify-tag + deploy | Per-deploy | Already minimal |

## Tier 1 — high ROI, quick wins

**Do these first.** Each is small, independent, immediately useful for the next dev VM rebuild and the next project.

### 1.1 `provision-vm.sh`: generate dev VM's own `id_ed25519` — **Done**

Placed after step 10 (so the hostname is set; the key comment reads `<user>@<vm-name>`). Idempotent via `[ -f ~/.ssh/id_ed25519 ] ||`.

### 1.2 `provision-vm.sh`: signing key + SSH signing setup — **Done**

Implemented as step `[14/23]`, after the bootstrap step. Passphrase prompted upfront alongside password/Apple ID, passed to `ssh-keygen -N`. Idempotent (`[ -f ~/.ssh/id_ed25519_signing ] ||`). Writes `~/.config/git/allowed_signers` from current `user.email` + signing pubkey on every run, so an updated email flows through on re-provision.

Flags: `--no-signing` to skip; `--non-interactive` implies `--no-signing` (no way to prompt for a passphrase). Skipped key generation on `LOCAL_BASE` re-provisions when no passphrase prompt happened (key was preserved); generation runs on golden-image clones (key was cleaned by `prepare-golden-image.sh`).

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
# Pass a JSON file via `--policy` to `gcloud artifacts repositories
# set-cleanup-policies` (add `--no-dry-run` to enforce immediately).
# Day-form durations ("90d", "7d") are accepted on input — the API
# normalizes to seconds on read, but our source-of-truth stays human-readable.
#   [{"name": "keep-recent-10", "action": {"type": "Keep"},
#     "mostRecentVersions": {"keepCount": 10}},
#    {"name": "delete-old-tagged", "action": {"type": "Delete"},
#     "condition": {"tagState": "TAGGED", "olderThan": "90d"}},
#    {"name": "delete-untagged", "action": {"type": "Delete"},
#     "condition": {"tagState": "UNTAGGED", "olderThan": "7d"}}]

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

1. ~~Tier 1.1~~ — Done.
2. ~~Tier 1.2~~ — Done.
3. Tier 1.3 (scaffolding script — saves the long sed dance)
4. *Then evaluate*: does Tier 2.1 (GAR automation) still feel painful enough to do? `gcloud` is now installed on the host (used for the GAR cleanup-policy fix), so that lift is smaller.

Each Tier 1 item is ~30-60 minutes of work plus testing. Tier 2.1 is ~1-2 hours including gcloud setup.

## Notes from the manual run that informed this list

- **Kamal does not run `docker login` on the build machine** — only on the deploy target. `bin/bootstrap-server` and `bin/deploy` handle dev-VM-side login. (See [feedback memory](../../.claude/projects/-Users-daviddeepdev-dev-vm-tools/memory/feedback_kamal_docker_login.md).)
- **Fine-grained PATs don't yet support ghcr.io.** Classic PAT scoping was too broad for the threat model, hence the GAR pivot.
- **GCP service-account keys must be IAM-bound at the *repo* level**, not project level — otherwise the SA can write to all repos in the project, which defeats the scoping.
