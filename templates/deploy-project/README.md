# Deploy-project template

Templates for setting up a new hosted-app project that follows the architecture in [`docs/deploy-architecture.md`](../../docs/deploy-architecture.md): single-VM deploy from the dev VM, signed git tags, age-encrypted secrets, per-project kamal user on Hetzner, GAR-backed image storage with a narrowly-scoped service account.

## What's in here

| Path | Purpose |
|------|---------|
| `bin/bootstrap-server` | One-time-per-server setup: creates kamal-`<project>` user on Hetzner, removes admin from docker group, runs `docker login`, runs `kamal setup` |
| `bin/deploy` | Daily-driver deploy: decrypt secrets, `docker login`, run `kamal deploy` against a signed tag |
| `config/deploy.yml` | Kamal config skeleton (GAR-style registry, builder.remote) |
| `.kamal/secrets.example` | Documents which env vars the app needs at runtime |
| `.gitignore.append` | Lines to add to your project's `.gitignore` |

What this template does NOT include:

- `Dockerfile` — language-specific, the project provides its own
- `app/` — the actual application code
- `pyproject.toml` / `package.json` / `go.mod` — language-specific build config

## Prerequisites (do these once before instantiating)

1. **Hetzner box already provisioned** with the admin user (`provision-vm.sh` handles this), accepting the dev VM's SSH key, with NOPASSWD sudo, ports 22/80/443 open, Docker installed, and DNS pointing your domain at the box.
2. **GCP project + Artifact Registry repo** created. See `docs/deploy-architecture.md` for the canonical setup. Note the project ID, region, and repo name.
3. **GCP service account** scoped to ONLY the Artifact Registry repo (Repository-level IAM, role `Artifact Registry Writer`). Download the JSON key.

## Instantiate for a new project

Run on the dev VM where the project repo lives. Replace `<project>` with your project name (lowercase, hyphenated — used in script paths, kamal user names, container names).

```bash
PROJECT="<project>"
HETZNER_HOST="<ip-of-target-server>"      # e.g. 5.78.183.19
DOMAIN="${PROJECT}.deepdevelopment.com"   # whatever hostname you'll point at this app
ADMIN_USER="$USER"                         # whoever provision-vm.sh created on Hetzner
GCP_PROJECT="<gcp-project-id>"             # e.g. reader-buddy-494902
GAR_REGION="us-west1"                      # whatever GAR region you used
GAR_REPO="<artifact-registry-repo-name>"   # e.g. reader-buddy

cd ~/dev/<project>
cp -r ~/dev/vm-tools/templates/deploy-project/{bin,config,.kamal} .
cat ~/dev/vm-tools/templates/deploy-project/.gitignore.append >> .gitignore
chmod +x bin/bootstrap-server bin/deploy

# Substitute placeholders
files=(bin/bootstrap-server bin/deploy config/deploy.yml)
sed -i "s|__PROJECT__|${PROJECT}|g" "${files[@]}"
sed -i "s|__HETZNER_HOST__|${HETZNER_HOST}|g" "${files[@]}"
sed -i "s|__DOMAIN__|${DOMAIN}|g" "${files[@]}"
sed -i "s|__ADMIN_USER__|${ADMIN_USER}|g" "${files[@]}"
sed -i "s|__GCP_PROJECT__|${GCP_PROJECT}|g" "${files[@]}"
sed -i "s|__GAR_REGION__|${GAR_REGION}|g" "${files[@]}"
sed -i "s|__GAR_REPO__|${GAR_REPO}|g" "${files[@]}"
```

## Set up secrets (once)

Convert the GCP service-account JSON key into the secrets format. Replace `<path>` with the path to your downloaded key:

```bash
B64=$(base64 -i <path-to-key.json> | tr -d '\n')
cat > .kamal/secrets <<EOF
KAMAL_REGISTRY_PASSWORD=$B64
EOF
chmod 600 .kamal/secrets

# Encrypt with age (you'll be prompted for a passphrase)
age -p < .kamal/secrets > .kamal/secrets.age
shred -u .kamal/secrets

# Delete the original JSON key from disk — it's now safely encrypted in .kamal/secrets.age
shred -u <path-to-key.json>
```

The `.kamal/secrets.age` file gets committed; the plaintext `.kamal/secrets` is gitignored and only exists transiently during deploy (created by `bin/deploy`, shredded on exit).

## First deploy

Once your `Dockerfile` and `app/` exist:

```bash
bin/bootstrap-server      # one-time per (project, server)
```

This creates the kamal user on Hetzner, runs `docker login` on the dev VM, runs `kamal setup`, ships the first deploy.

## Daily deploys

```bash
# After committing your changes:
git tag -s v0.1.x -m "..."
git push <remote> v0.1.x
git verify-tag v0.1.x && bin/deploy v0.1.x
```

The `verify-tag` step is typed explicitly rather than baked into `bin/deploy`, so a compromised script can't skip the check.

## Rotating the GCP service account key

To rotate the key (recommended every ~90 days):

1. In the GCP console, generate a new JSON key for the same service account.
2. Optionally delete the old key from the GCP console (revokes the old credentials).
3. On the dev VM:
   ```bash
   B64=$(base64 -i <path-to-new-key.json> | tr -d '\n')
   cat > .kamal/secrets <<EOF
   KAMAL_REGISTRY_PASSWORD=$B64
   EOF
   age -p < .kamal/secrets > .kamal/secrets.age
   shred -u .kamal/secrets
   shred -u <path-to-new-key.json>
   ```
4. Commit the updated `.kamal/secrets.age`.
