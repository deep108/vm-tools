# Deploy-project template

Templates for setting up a new hosted-app project that follows the architecture in [`docs/deploy-architecture.md`](../../docs/deploy-architecture.md): single-VM deploy from the dev VM, signed git tags, age-encrypted secrets, per-project kamal user on Hetzner.

## What's in here

| Path | Purpose |
|------|---------|
| `bin/bootstrap-server` | One-time-per-server setup: creates kamal-`<project>` user on Hetzner, removes admin from docker group, runs `kamal setup` |
| `bin/deploy` | Daily-driver deploy: decrypt secrets via age, run `kamal deploy` against a signed tag |
| `config/deploy.yml` | Kamal config skeleton with placeholders |
| `.kamal/secrets.example` | Documents which env vars the app needs at runtime |
| `.gitignore.append` | Lines to add to your project's `.gitignore` |

What this template does NOT include:

- `Dockerfile` — language-specific, the project provides its own
- `app/` — the actual application code
- `pyproject.toml` / `package.json` / `go.mod` — language-specific build config

## Instantiate for a new project

Run on the dev VM where the project repo lives. Replace `<project>` with your project name (lowercase, hyphenated — used in script paths, kamal user names, container names).

```bash
PROJECT="<project>"
HETZNER_HOST="<ip-of-target-server>"      # e.g. 5.78.183.19
DOMAIN="${PROJECT}.deepdevelopment.com"   # whatever hostname you'll point at this app
ADMIN_USER="$USER"                         # whoever provision-vm.sh created on Hetzner

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
```

After this, edit `config/deploy.yml`'s `env.secret` list to match the secrets your app actually needs, and create the encrypted secrets file:

```bash
cp .kamal/secrets.example /tmp/secrets-plain
$EDITOR /tmp/secrets-plain          # fill in real values
age -p < /tmp/secrets-plain > .kamal/secrets.age   # prompts for passphrase
shred -u /tmp/secrets-plain
```

## First deploy

Once your `Dockerfile` and `app/` exist:

```bash
bin/bootstrap-server      # one-time per (project, server)
```

This creates the kamal user, runs `kamal setup`, and ships the first deploy.

## Daily deploys

```bash
# After committing your changes:
git tag -s v0.1.x -m "..."
git push <remote> v0.1.x
git verify-tag v0.1.x && bin/deploy v0.1.x
```

The `verify-tag` step is typed explicitly rather than baked into `bin/deploy`, so a compromised script can't skip the check.
