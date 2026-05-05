# Hetzner server config

Notes on manually-applied configuration on the Hetzner Cloud box(es) hosting deployed apps. This captures operational state that lives outside what the templated deploy scripts (`bin/bootstrap-server`, etc.) handle.

Append entries (with date) rather than replacing — this is a running log, not a recipe.

## Known Hetzner Cloud constraints

Persistent facts about Hetzner Cloud that affect anything we deploy or run on these boxes. Not date-stamped — these are platform-level, not change-log entries.

- **Outbound SMTP port 25 is blocked by default.** Hetzner Cloud blocks outbound :25 to fight botnet abuse; the unblock is gated on a support request. Use submission auth on **465 (TLS)** or **587 (STARTTLS)** instead — works without an unblock. Applies to anything sending mail from a Hetzner box: app transactional mail, alert pipes (`mail`, `msmtp`), monitoring notifications. Transactional APIs (Postmark, Mailgun, SES, SendGrid) sidestep this entirely since they're HTTPS, not SMTP.

## reader-buddy host (only Hetzner box currently)

### 2026-05-02 — `debsecan` installed

CLI tool that cross-references installed packages against the Debian Security Tracker. Useful for verifying a specific CVE patch has actually landed without manually looking up affected-versions in the tracker UI.

```bash
debsecan                              # full audit: every CVE with an installed vulnerable package
debsecan | grep -i CVE-2026-31431     # check a specific CVE (empty = patched or not in tracker)
```

### 2026-05-02 — `unattended-upgrades` auto-reboot enabled

Default behavior: security patches install automatically (via `apt-daily-upgrade.timer`) but reboot is left manual. Kernel CVE patches install but don't take effect until someone manually runs `reboot`, which means a kernel patch can sit installed-but-not-running indefinitely. Enabled auto-reboot so the patches actually run.

Edited `/etc/apt/apt.conf.d/50unattended-upgrades` — uncommented / set:

- `Unattended-Upgrade::Automatic-Reboot "true";`
- `Unattended-Upgrade::Automatic-Reboot-Time "10:00";` — UTC (the server's timezone). 10:00 UTC = 02:00 PST in winter / 03:00 PDT in summer, deep enough into the Seattle night that traffic is minimal year-round.
- `Unattended-Upgrade::Automatic-Reboot-WithUsers "true";`

Tradeoff accepted: ~20–30s unscheduled downtime when a kernel patch reboots, vs. patches sitting installed-but-inactive. App containers (`reader-buddy`, kamal-proxy) restart automatically since Kamal sets `--restart unless-stopped`.

Verify current settings:
```bash
grep -E "Automatic-Reboot" /etc/apt/apt.conf.d/50unattended-upgrades
```

To disable later: set `Automatic-Reboot "false";` (or comment the line).

## Notes for a second Hetzner box later

If/when you bring up another Hetzner host, the two changes above should be reapplied — they're not in the templated `bin/bootstrap-server`, since that's per-project setup not per-host hardening. Candidates for absorbing this into automation:

- `bridge-hetzner-server.sh` (Tier 2.2 of `automation-roadmap.md`) — could install debsecan + flip the reboot config in addition to its primary key-bridging job.
- `harden-hetzner.sh` (Tier 3) — would naturally own these along with NOPASSWD sudo, ufw rules, fail2ban, etc.
