# Deploy Architecture for Hosted Apps

How dev-VM-resident projects (e.g. reader-buddy) deploy to Hetzner via Kamal, and what we've deliberately deferred.

This document captures the deploy architecture we've chosen and the architectural choices we've explicitly deferred, along with the conditions that would trigger revisiting them. The goal is that future-us doesn't have to re-derive the reasoning.

## Current architecture

Single-VM model: deploys originate on the dev VM, no separate deploy VM.

**Where things live**
- **Dev VM**: source code, signing key (passphrase-protected, no agent caching), age-encrypted secrets file, `bin/deploy` runs locally
- **Host (macOS)**: bare git repo per project; Tart VM lifecycle (unchanged)
- **Hetzner box**: Docker + Kamal proxy + app containers; one box hosts multiple apps, routed by hostname
- **No long-lived deploy VM**

**Deploy flow**
1. Develop on dev VM, push checkpoint commits to host bare repo as you work — none ship
2. When ready to release: review cumulative diff, then `git tag -s vX.Y.Z`
3. Push tag, then deploy with explicit verification (don't trust `bin/deploy` to verify itself):
   ```bash
   git verify-tag vX.Y.Z && bin/deploy vX.Y.Z
   ```
4. `bin/deploy` does `git checkout $TAG`, decrypts the secrets file with age, sources it, runs `kamal deploy`

**Security gates**
- Signed git tags are the only deployable artifact; verification is a typed step at the prompt
- Signing key passphrase entered per `git tag -s` (no agent caching)
- `allowed_signers` file lives at `~/.config/git/allowed_signers` on the dev VM, not in the repo
- Secrets stored in `~/.config/<project>/secrets.env.age`, decrypted per deploy with a deploy-specific passphrase
- No backup SSH key on Hetzner; cloud-console password reset is the break-glass

**Per-project Hetzner setup**
- Each project gets a dedicated `kamal-<project>` user on the Hetzner box (in docker group, no sudo, SSH-key-only)
- The interactive admin user (`daviddeepdev`) is removed from the docker group
- Kamal's `ssh.user` in `config/deploy.yml` is `kamal-<project>`
- `bin/bootstrap-server` creates the user idempotently on first run

**Multiple apps on one Hetzner box**
- Kamal's proxy handles per-hostname routing and per-app Let's Encrypt certs automatically
- Each app: own repo, own Kamal config, own kamal user, own age secrets file
- Container isolation between apps; shared kernel; shared docker daemon

## Base VM image additions

What gets baked into every guest VM at provisioning time vs. what's Linux-only because of platform constraints.

**Both platforms (macOS and Linux guests)**
- `git-delta` — pager replacement for syntax-highlighted diffs (configured via `run_onchange_before_06-configure-git-delta.sh.tmpl`, which sets `core.pager`, `interactive.diffFilter`, side-by-side, line-numbers, navigate, and zdiff3 conflict style — additive, doesn't clobber existing user gitconfig)
- `tig` — interactive commit/diff TUI for navigating release ranges
- `difftastic` — language-aware structural diffs for noisy changes
- `age` — file encryption for secrets at rest

These support the deploy review ceremony (signing tags requires reading diffs) and the secrets workflow (age-encrypted env files). All are useful enough as general dev tools that they belong in the base regardless of whether a given VM ever deploys.

**Linux guests only (Kamal toolchain)**
- Ruby via mise — precompiled binary install on ARM64 Linux, pinned to `3.4`. Added to the global mise config additively via `mise use -g ruby@3.4` in `run_onchange_before_05-install-kamal.sh.tmpl`, so it coexists with any other entries (e.g. Java for Android). `mise settings set ruby.compile false` opts into precompiled binaries explicitly so we don't depend on mise's default flipping at a future version (becomes default in mise 2026.8.0). The mise config file itself is NOT chezmoi-managed — chezmoi-managing it would clobber existing entries.
- `kamal` gem at pinned version (currently 2.11.0), installed via `gem install --user-install` in the same script. Bumping just means editing `KAMAL_VERSION` — `run_onchange_` re-triggers automatically.
- `docker` and `docker-buildx` via Linuxbrew (CLI only, no daemon; daemon work happens on the Hetzner box via `builder.remote`). Brew rather than Docker's apt repo because it keeps everything user-tooling-related on the same package manager — no apt repo setup, no GPG key fetching.
- `build-essential` — already installed by `bootstrap-linux.sh` before Homebrew, since linuxbrew itself requires a working compiler to bootstrap. Used for occasional native gem extensions.

**Why Linux-only for Kamal pieces**: Tart macOS guests can't run Docker (no nested virtualization for containers in the way Kamal expects), so deploys from macOS guests aren't possible in this architecture. macOS guests stay focused on iOS/native-Apple development; deploys happen from Linux guests. mise itself is installed on both platforms — only the global mise config that pre-installs Ruby is Linux-only (excluded on macOS guests via `.chezmoiignore`).

**Language runtime policy: mise everywhere, never brew**

Language runtimes (Ruby, Python, Node, Java, Go, etc.) are managed exclusively via mise. Brew is reserved for non-runtime tooling (`jq`, `tmux`, `neovim`, `starship`, `tig`, `git-delta`, `difftastic`, etc.). Reasons:
- Per-project version pinning via `.mise.toml` / `.tool-versions`
- Multiple versions side-by-side without PATH gymnastics
- Major/minor/patch precision and LTS aliases
- Brew's "one global runtime, upgraded out from under you" model conflicts with project-specific version requirements

Tools that ride on a runtime (gems, npm packages, pip packages) install via that runtime's package manager (`gem install --user-install`, `npm install -g`, etc.), not via brew.

## Threat model

What this architecture is designed to resist:
- **Drive-by malware** (npm postinstall, dependency-confusion attacks, untrusted Claude Code execution): can read files but can't sign tags or use the deploy passphrase non-interactively
- **Opportunistic attackers** with file access: encrypted secrets and passphrase-protected signing key are both useless without the passphrases
- **Supply-chain compromise via the bare repo**: signed-tag gate refuses to ship anything not cryptographically attested by the developer

What it does *not* fully resist:
- **Persistent keylogger-class attackers** on the dev VM: would eventually capture both the signing-key passphrase and the deploy passphrase. Mitigation would require hardware-token signing or a separate deploy VM (both deferred).
- **Host macOS compromise**: out of scope; affects everything Tart-related.

## Deferred decisions

Each entry: what we deferred, what it would buy us, and the trigger that should make us revisit.

### Separate deploy VM

**What it would enable (security)**
- Lower-attack-surface credential storage. The deploy VM never runs `npm install`, Claude Code on untrusted code, or web browsing.
- Verifier separation. The signed-tag verification (`git verify-tag`) runs on a different machine than dev-side compromise, so the verifier itself is more trustworthy.
- Stronger isolation against persistent attackers. Per-deploy passphrase on the dev VM is good against drive-by but degrades against keyloggers; a separate machine shifts the attacker's job.

**What it would enable (features)**
- Deploy from anywhere with SSH to the deploy VM (phone, second laptop)
- Deploys decoupled from dev VM lifecycle (deploy during dev VM rebuilds)
- Multi-project credential consolidation
- Multi-deployer scenarios (collaborator joins, gets SSH access rather than copies of secrets)

**Migration cost**
The original Phase B plan defined three scripts: `provision-vm.sh --deploy`, `register-deploy-vm.sh`, `onboard-deploy-target.sh`. None are written yet but the design is sound. Migration per project: move age-encrypted secrets to the deploy VM, update SSH alias, change deploy invocation location. Roughly half a day per project plus initial deploy-VM setup.

**Triggers that should make us revisit**
- Adding a project that handles other people's data (PII, payments, OAuth tokens for other people's services)
- Wanting genuine phone-based or away-from-dev-VM deploys
- Threat model concretely shifts (public profile, real adversaries)
- 3+ projects deploying to 2+ servers — consolidation argument starts winning

### Rootless docker on Hetzner

**What it would enable**
- Eliminates "docker group = effective root." A leaked deploy key gets the kamal user's namespace, not host root.
- Container escape vulnerabilities don't reach kernel-level privileges.
- Per-user docker daemons mean cross-app blast radius narrows to zero (different daemons, different namespaces).

**What it costs**
- Privileged-port binding for kamal-proxy (80/443) requires `sysctl net.ipv4.ip_unprivileged_port_start=80`, capability flags, or iptables redirects. Each is a "works until it doesn't" config that needs occasional revisiting.
- Off the well-trodden Kamal path. Kamal's docs and tested setups assume rootful docker. Image builds, volume mounts, log paths, cert renewal — likely all work, but not first-class supported.
- Modest debugging investment on first setup.

**Triggers**
- Adding the third app to a single Hetzner box (multi-tenancy isolation matters)
- First app handling other people's data (kernel-level isolation guarantee becomes valuable)
- Compliance contexts (PCI/HIPAA/etc.)

### 1Password integration for deploy secrets

**What it would enable**
- Web UI for editing/rotating secrets
- Audit log of secret reads (via service account)
- Centralized inventory of "where is each secret used"
- Vault sharing for collaborators

**What it costs**
- More moving parts (1P CLI + service account + age-wrapped token vs. plain age file)
- External dependency at deploy time (1P API must be reachable)
- Service account token rotation chore (max 1-year expiry)

**Current substitute**: plain `age`-encrypted env file per project at `~/.config/<project>/secrets.env.age`.

**Triggers**
- Multiple projects sharing the same secrets (e.g., the same Anthropic API key consumed by 3+ apps)
- Adding a collaborator who needs deploy capability
- Frequent rotation requirements (every few weeks rather than yearly/never)

### Hardware-token signing key

**What it would enable**
- Signing key material never leaves the YubiKey
- Even passphrase + key file exfiltration doesn't grant signing capability
- Strongest defense against persistent dev-VM compromise

**What it costs**
- YubiKey hardware
- USB forwarding into Tart Linux VMs is fiddly
- Per-sign hardware touch interaction

**Triggers**
- Threat model shifts to include patient/targeted attackers
- Project has external visibility / political profile

### `harden-hetzner.sh` automation

**What it would enable**
- One-command repeat of the Hetzner hardening (key-only SSH, ufw, fail2ban, unattended-upgrades, kamal user setup) on a new server

**Current state**: hardening was done manually for the first Hetzner box. Idempotent kamal-user creation will live in `bin/bootstrap-server` per project.

**Triggers**
- Provisioning a second Hetzner box (write the script the second time, per the original deferral)

### Hetzner provisioning via `hcloud` CLI

**What it would enable**
- VM creation, DNS records, firewall rules all scripted

**Current state**: web console for VM creation, manual A/AAAA records, ufw configured per-server.

**Triggers**
- Routinely managing 2+ servers (the manual cost starts mattering)
- Wanting reproducible environments for staging/testing

### Separate Hetzner box per app

**What it would enable**
- Hard kernel-level isolation between apps (different VMs)
- Independent SLAs (one app crashing/hanging doesn't affect others)
- Per-app resource scaling

**Cost**: ~$5-10/month per additional CPX11.

**Triggers**
- An app handling other people's data that shouldn't share a kernel with personal experiments
- Workload exhausting CPX11 (2 vCPU / 2 GB RAM)
- Differing uptime requirements between apps

### Lighter-runtime stack for new apps

**What it would enable**
- More apps per Hetzner box. Python (FastAPI + uvicorn) sits at ~150-300 MB resident per app; Go web servers typically run at 10-30 MB. A box that fits 4-5 Python apps could fit 20+ Go apps.
- Reduces pressure to scale to a bigger box or a second box.

**What it costs**
- Different language for new projects (less ecosystem overlap with reader-buddy)
- Go is weaker than Python for AI/ML work — for any app calling LLM APIs and doing data manipulation, Python's libraries (`anthropic`, `pydantic`, etc.) are genuinely more ergonomic. Go versions of these calls are doable but more verbose.

**Triggers**
- Building a new app that doesn't need Python's AI/ML ecosystem (URL shortener, RSS reader, expense tracker, simple dashboard, etc.) — a good default to consider Go
- Hitting memory pressure on the existing Hetzner box and not wanting to upgrade

**Note**: reader-buddy stays Python. This is a forward-looking consideration for *new* apps, not a migration plan for existing ones.

### Litestream backup encryption

**What it would enable**
- Encrypted SQLite backups in object storage

**Triggers**
- Something sensitive ends up in SQLite (user data, secrets-derived material)
- Currently deferred until reader-buddy's actual data shape is known

## Cross-cutting principles

- **Defer architecture until the trigger fires.** Each deferred item has a concrete reason to wait and a clear condition to revisit. We're not doing them now because the marginal benefit doesn't justify the complexity for current scope.
- **Migration paths are documented as part of deferral.** When a trigger fires, the work to migrate is bounded and known, not "we'll figure it out then."
- **Trust boundaries are minimized, not eliminated.** Every choice trades off complexity vs. resistance. We're choosing complexity proportional to threat model — drive-by + opportunistic resistance, not nation-state-grade.
