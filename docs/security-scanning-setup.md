# Security Scanning Setup — Solo Dev

A practical setup for vulnerability scanning across the Hetzner production box (running multiple Kamal-deployed apps as containers), the Debian dev VM (intermittent, project-scoped), and the macOS host. Designed for a solo developer: minimal moving parts, low alert volume, push-by-email so issues land somewhere persistent.

The goal: **the boring stuff patches itself, the interesting stuff emails me, and I never have to log in just to check.**

The structure follows the deploy architecture in `deploy-architecture.md`: apps ship as containers built via Kamal `builder.remote`, pushed to GAR, pulled back to Hetzner. So the highest-value scanning target on Hetzner is the **container images** that are actually running — not the host filesystem (mostly Debian + Docker, already covered by `debsecan`) and not language deps in `/opt` (there are none; deps live inside containers).

---

## Target Setup

| Surface | What runs | Cadence |
|---|---|---|
| Hetzner host packages (Debian) | `unattended-upgrades` (auto-reboot on) + `debsecan` with history | Continuous / daily |
| Hetzner container images | `trivy image` per deployed tag, registry-side, diff-and-email | Weekly |
| Deploy-time | `trivy image` in `bin/deploy` against just-built tag | Per-deploy |
| Dev VM packages | `unattended-upgrades` (auto-reboot off) | Continuous (fires on boot via `Persistent=true`) |
| Dev VM infection check | `rkhunter` + `debsums -c` via systemd timer | Weekly (`Persistent=true`) |
| Dev VM supply chain | `ignore-scripts` for npm/pnpm via chezmoi | Permanent config |
| macOS host | Apple Software Update + `brew upgrade` + on-demand `osv-scanner` per project | Manual |

---

## Hetzner box

### Host packages — already configured

`unattended-upgrades` (with auto-reboot at 10:00 UTC) and `debsecan` are already installed and documented in `hetzner-server-config.md`. The auto-reboot decision and rationale (Kamal containers restart automatically via `--restart unless-stopped`) are recorded there. Append future host-config changes to that file rather than this one.

The only addition over the existing setup is enabling **debsecan history** so it only mails on *new* findings rather than the full inventory daily. In `/etc/default/debsecan`:

```
REPORT=true
MAILTO=you+sec@example.com
SUITE=trixie
SUBJECT="debsecan: $(hostname)"
```

Verify the daily cron at `/etc/cron.d/debsecan` uses `--update-history`. If not, replace with:

```
30 6 * * * root test -x /usr/bin/debsecan && /usr/bin/debsecan --suite trixie --format report --update-history --only-fixed | mail -E -s "debsecan: $(hostname)" you+sec@example.com
```

`-E` makes `mail` skip empty bodies, so quiet days stay quiet.

### Container images — the main scanning target

Apps run as containers; that's where the actionable CVE surface lives. The scan runs on Hetzner (the only always-on machine) but as a non-privileged user with no docker access — purely registry-side via `trivy image --image-src remote`. This pattern is rootless-portable: if Kamal ever moves to rootless docker (deferred in `deploy-architecture.md`), the scanner is unaffected.

**Why not GAR's built-in scanning**: considered and declined. GAR scanning costs ~$0.26/push and stops re-evaluating images that haven't been pulled in 30 days. Trivy is free, has no stale-image cliff, and self-hosts cleanly. The notification path is the same shape either way (cron → diff → email), so GAR's continuous-rescan advantage doesn't survive contact with the polling cadence we'd run anyway.

**Setup**.

Create the scanner user (no docker group, no sudo, no SSH from outside):

```bash
sudo useradd -r -m -d /var/lib/secscan -s /bin/bash secscan
sudo install -d -o secscan -g secscan /var/lib/secscan/tags
```

Install trivy via the upstream apt repo:

```bash
sudo apt install wget gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt update && sudo apt install trivy
```

Create one GAR-reader service account, project-level `roles/artifactregistry.reader` binding (covers all current and future repos in the GCP project — readers can't push, so blast radius is acceptable). Stash its JSON key at `/var/lib/secscan/gar-reader.json`, mode 0400, owned by `secscan`.

`bin/deploy` writes the just-deployed tag to a known path on Hetzner so the scanner knows what to scan. One file per app at `/var/lib/secscan/tags/<app>.tag` containing the full GAR tag.

Wrapper script `/usr/local/sbin/secscan-images`:

```bash
#!/bin/bash
set -euo pipefail

STATE=/var/lib/secscan
TAGS_DIR="$STATE/tags"
LAST_CVES="$STATE/last.cves"
TODAY_CVES="$STATE/today.cves"
NEW_CVES="$STATE/new.cves"
MAILTO="you+sec@example.com"

export GOOGLE_APPLICATION_CREDENTIALS="$STATE/gar-reader.json"
export TRIVY_CACHE_DIR="$STATE/.cache"

: > "$TODAY_CVES"

for tag_file in "$TAGS_DIR"/*.tag; do
  [ -e "$tag_file" ] || continue
  app=$(basename "$tag_file" .tag)
  tag=$(cat "$tag_file")
  trivy image \
    --image-src remote \
    --scanners vuln \
    --ignore-unfixed \
    --severity HIGH,CRITICAL \
    --format json \
    --quiet \
    "$tag" \
  | jq -r --arg app "$app" \
      '.Results[]?.Vulnerabilities[]? | "\($app)\t\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion)\t\(.Severity)"' \
  >> "$TODAY_CVES"
done

sort -u -o "$TODAY_CVES" "$TODAY_CVES"
touch "$LAST_CVES"
comm -23 "$TODAY_CVES" "$LAST_CVES" > "$NEW_CVES"

if [ -s "$NEW_CVES" ]; then
  {
    echo "New HIGH/CRITICAL fixed vulnerabilities in deployed images on $(hostname):"
    echo
    column -t -s $'\t' "$NEW_CVES"
  } | mail -s "trivy: new image vulns on $(hostname)" "$MAILTO"
fi

mv "$TODAY_CVES" "$LAST_CVES"
```

Schedule weekly:

```bash
sudo install -m 755 -o root -g root secscan-images /usr/local/sbin/
echo "15 7 * * 1 secscan /usr/local/sbin/secscan-images" | sudo tee /etc/cron.d/secscan-images
```

Cron runs as `secscan`. The user has read/write only to its own home and the GAR reader key — no docker, no sudo.

**Trivy cache** lives under `/var/lib/secscan/.cache`. Trivy reuses unchanged image layers across runs, so weekly scans of unchanged images are nearly free in bandwidth (only the manifest is fetched to check for changes).

**No stale-image cliff**: trivy's CVE DB updates on each invocation, so a CVE disclosed Wednesday gets flagged at Sunday's scan. Images you haven't redeployed in months are still scanned every week.

### Mail delivery

Pick one. Both work; transactional API is less fiddly today.

**Option A: msmtp through an existing mailbox** (Gmail/Fastmail/etc.)

```bash
sudo apt install msmtp msmtp-mta mailutils
```

`/etc/msmtprc` (chmod 600, owned by root):

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           smtp.fastmail.com
port           465
tls_starttls   off
from           server-alerts@yourdomain.com
user           you@yourdomain.com
password       <app-specific-password>
```

Test: `echo "test" | mail -s "hello" you+sec@example.com`

Hetzner blocks outbound port 25 by default; submission auth on 465/587 sidesteps this without an unblock request.

**Option B: Postmark / Mailgun / SES via curl**

Replace `mail -s` calls with `curl` POSTs to the API. No MTA at all. Better deliverability. Free tiers cover this volume easily.

### Inbox hygiene

Filter `you+sec@example.com` (or whatever alias) into a folder you actually open. The diff-and-only-mail-on-change pattern means mail in this folder always represents new findings. If you start ignoring it, lower the volume — don't widen the filter.

---

## Deploy-time scan in `bin/deploy`

The weekly cron catches "image was clean when shipped, CVE disclosed since." The deploy-time scan catches "the image you just built is already vulnerable" within seconds.

In `templates/deploy-project/bin/deploy`, after `kamal deploy` returns successfully:

```bash
trivy image \
  --image-src remote \
  --scanners vuln \
  --ignore-unfixed \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  --quiet \
  "$IMAGE_TAG" \
  || echo "WARNING: HIGH/CRITICAL vulns in $IMAGE_TAG — see above" >&2

ssh "secscan@$HETZNER_HOST" "cat > /var/lib/secscan/tags/$APP_NAME.tag" <<<"$IMAGE_TAG"
```

Choice: warn-only vs. fail-the-deploy. Warn-only above; flip to `set -e` semantics on the trivy call if you'd rather block. For solo dev, warn is more honest — you might still want to ship a base-image patch even with one open CVE flagged.

The second line writes the tag to Hetzner so the weekly cron picks it up. Requires the deploying user (`kamal-<project>`) to have SSH access to the `secscan` user with a tightly-scoped authorized_keys entry (`command="tee /var/lib/secscan/tags/<app>.tag"`).

This SSH wiring isn't yet automated — tracked in `automation-roadmap.md` Tier 2.3 (covers the per-Hetzner-box `secscan` setup, the per-project authorized_keys grant, and the `bin/deploy` write).

---

## Dev VM (Debian)

The dev VM is intermittent — running only when actively working on a project. That rules out time-of-day cron and shifts everything to "fires on boot if it missed its window."

### Background hygiene — `unattended-upgrades`

Install with auto-reboot **disabled** (don't want surprise reboots mid-work):

```bash
sudo apt install unattended-upgrades apt-listchanges
sudo dpkg-reconfigure -plow unattended-upgrades
```

Leave `Unattended-Upgrade::Automatic-Reboot "false";` (default). The standard `apt-daily.timer` and `apt-daily-upgrade.timer` have `Persistent=true`, so they fire on next boot if they missed a window — which is what you want for a VM that's stopped most of the time. Apt patching effectively becomes "happens shortly after VM start, in the background."

When `/var/run/reboot-required` shows up, run `reboot` next time you're stopping the VM.

This belongs in `host/provision-vm.sh`'s Linux branch so every freshly-provisioned dev VM gets it without a manual step.

### Periodic infection check — `rkhunter` + `debsums`

Cheap signals that something obviously bad happened on the box. Doesn't catch sophisticated attacks, but covers known rootkits and tampered system binaries.

```bash
sudo apt install rkhunter debsums
sudo rkhunter --propupd
```

Systemd timer at `/etc/systemd/system/secscan.timer`:

```
[Unit]
Description=Weekly local infection check

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

Service at `/etc/systemd/system/secscan.service`:

```
[Unit]
Description=Run rkhunter + debsums and mail on findings

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/secscan-local
```

`/usr/local/sbin/secscan-local`:

```bash
#!/bin/bash
set -euo pipefail
MAILTO="you+sec@example.com"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

rkhunter --check --skip-keypress --report-warnings-only >> "$OUT" 2>&1 || true
echo "--- debsums -c ---" >> "$OUT"
debsums -c >> "$OUT" 2>&1 || true

if grep -qE 'Warning|FAILED' "$OUT"; then
  mail -s "secscan: $(hostname) findings" "$MAILTO" < "$OUT"
fi
```

Enable: `sudo systemctl enable --now secscan.timer`. The first `rkhunter --propupd` baselines against current state; re-run after major package upgrades to tame false positives.

### Supply chain at install time

The single biggest practical defense against a compromised npm/pnpm package is disabling lifecycle scripts globally. In the chezmoi-managed `.npmrc`:

```
ignore-scripts=true
```

Costs you a manual `npm rebuild` on the rare package that legitimately needs a postinstall (`sharp`, `node-sass`, native modules). Buys immunity to the most common drive-by attack vector.

Equivalents to consider: `pnpm config set side-effects-cache false`, `bun install --no-postinstall`. Prefer `uv` over `pip` where you can — `uv` is more conservative about executing arbitrary build code at install.

### Recovery posture

The dev VM's compromise-recovery story is **rebuild from clean**, not detect-and-clean. `provision-vm.sh` rebuilds in ~30 minutes; chezmoi reinstates dotfiles + tools automatically. This is a first-class option, not a last resort.

When something feels off — unexpected CPU at idle, unfamiliar processes, weird outbound network, paranoia after running sketchy code — rebuild the VM. Faster than forensic diagnosis, more reliable than any scanner.

The architecture in `deploy-architecture.md` is explicitly designed around this: secrets are age-encrypted in-repo, signing keys require a passphrase per use, no GitHub credentials live on the VM. A compromised dev VM can read but can't ship code without the developer's passphrase. Rebuilding and re-cloning is then the cheapest restore path.

### On-demand scanning

For auditing a project repo (yours or someone else's, before contributing):

```bash
trivy fs ~/code/some-project
osv-scanner --recursive ~/code/some-project
```

These are CVE-only — they catch *published* vulnerabilities in declared dependencies, not malicious code in a fresh package version. For that, the only realistic answer is sandboxing untrusted execution (Claude Code's `--sandbox`, the dev VM itself as a sandbox boundary against the host).

---

## macOS host

**No scheduled scanning.** The tools don't cover the actually-risky part of macOS (the OS itself — Apple ships fixes via Software Update, not as CVE-tracked packages). They'd partially cover Homebrew, which already nags about updates.

**Do**:
- Keep Software Update on automatic.
- `brew update && brew upgrade` regularly (`check-dev-tool-updates` in this repo wraps it).
- Run `osv-scanner` or `trivy fs` on a project directory when auditing a codebase.

**Reconsider** if you start running long-lived services on the Mac — but really, move that to the Linux box instead.

---

## Things considered and declined

| Declined | Why now | When to revisit |
|---|---|---|
| GAR's built-in vulnerability scanning | Trivy is free, has no 30-day stale-image cliff, and the notification plumbing is the same shape (cron + diff + email). | If you adopt Binary Authorization to gate deploys, or need third-party-attested findings for compliance. |
| Pub/Sub → Cloud Function notification path | Real-time alerting is overkill for CVE disclosures (daily/weekly cadence is correct at this scale). Adds two GCP services to maintain. | Sub-minute alerting becomes load-bearing (high-traffic public service, regulated workload). |
| Security Command Center Premium/Enterprise | Per-asset pricing aimed at enterprise SOCs. Standard tier is free and worth enabling for the UI; nothing more is justified. | Compliance context (SOC2, etc.) or a fleet large enough that a UI matters. |
| `trivy fs /` on Hetzner host | Apps don't store anything outside containers; debsecan covers Debian system packages; `/var/lib/docker` produces noise. | Never expected to. |
| Vulnerability dashboard (DefectDojo, Dependency-Track) | Solo dev won't log in. Email is push; dashboards are pull. SCC Standard gives a free UI as a side effect if you want one. | ≥2 people triaging, or compliance audit trail. |
| Real-time / push alerts (PagerDuty, ntfy) | CVE disclosures aren't a real-time problem at this scale. | Services where exploitation is plausible within hours of disclosure. |
| Scheduled scanning on dev VM beyond what's listed | The unattended-upgrades + rkhunter + debsums combo covers the realistic threats. More tooling generates noise that trains you to ignore alerts. | If the dev VM ever holds production-like data or stops being rebuildable on demand. |
| Scheduled scanning on macOS host | Tools miss the real macOS attack surface; Homebrew nags itself. | Probably never. |
| Grype + Syft SBOM pipeline | Trivy covers the same ground in one binary. SBOM-on-file matters when you need point-in-time records to re-scan against new CVEs. | Compliance / supply-chain attestation, scanning offline artifacts. |
| Centralized log aggregation (SIEM) | Vast overkill for one Hetzner box and one dev VM. | Multi-host fleet, compliance. |
| Behavioral install-time scanners (Socket.dev, Snyk, Phylum) | `ignore-scripts` covers the largest single attack vector for free. Commercial tools add account/CLI overhead disproportionate to solo-dev value. | Onboarding many new dependencies you don't trust, or working in a high-risk ecosystem. |
| AIDE / Tripwire on dev VM | Brutal noise on a dev machine where files change constantly. `debsums -c` covers most of the useful ground for free. | Single-purpose VM that doesn't change much. |
| Rootful → rootless docker migration on Hetzner | Off the well-trodden Kamal path, port-binding workarounds, debugging investment. Triggers in `deploy-architecture.md` not yet firing. | Per the deferred-decisions section in `deploy-architecture.md`. The scanning design above is rootless-portable already, so migrating won't break it. |

---

## Quick verification after setup

```bash
# Mail works (run on Hetzner and dev VM separately)
echo "delivery test" | mail -s "secscan setup test" you+sec@example.com

# debsecan dry run on Hetzner
sudo debsecan --suite trixie --format detail --only-fixed | head -20

# Trivy image scan against current deployed tags
sudo -u secscan /usr/local/sbin/secscan-images && head /var/lib/secscan/last.cves

# unattended-upgrades dry run (Hetzner OR dev VM)
sudo unattended-upgrades --dry-run --debug 2>&1 | tail -20

# Dev VM rkhunter + debsums dry run
sudo /usr/local/sbin/secscan-local

# Cron / timers installed
ls /etc/cron.d/ | grep -E 'debsecan|secscan'        # Hetzner
systemctl list-timers | grep -E 'apt-daily|secscan' # both
```

---

## Maintenance

- Roughly once a quarter, send the test-mail command above and confirm `last.cves` files on Hetzner are still updating week-over-week.
- On Debian point releases, bump `SUITE=` in `/etc/default/debsecan` manually — it doesn't auto-update.
- After major package upgrades on the dev VM, re-baseline rkhunter: `sudo rkhunter --propupd`.
- If the weekly image-scan mail starts being dozens of CVEs, tighten the filter (raise severity floor) rather than widening the inbox filter.
- When onboarding a new app, the deploy template's `bin/deploy` writes its tag file automatically — no per-app changes here. When retiring an app, delete its `/var/lib/secscan/tags/<app>.tag` on Hetzner.
- Append host-config changes to `hetzner-server-config.md` (running log), not to this doc.
