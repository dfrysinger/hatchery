# Hatchery Scripts

Standalone scripts extracted from `hatch.yaml` `write_files` entries.
These are the same scripts that cloud-init deploys to the droplet during provisioning.

> **Note:** `hatch.yaml` still contains the inline versions. Issue #19 will update
> `hatch.yaml` to reference these standalone files instead.

## Boot Flow

```
cloud-init
  └─ runcmd
       ├─ phase1-critical.sh     ← gets bot online (~60s)
       │    └─ phase2-background.sh  ← background desktop setup (~5min)
       │         └─ build-full-config.sh
       ├─ rename-bots.sh
       └─ (reboot)
            └─ post-boot-check.sh  ← applies full config or enters safe mode
```

## Scripts

### phase1-critical.sh
- **Purpose:** Critical early boot — installs Node.js, openclaw, creates user, generates minimal config, starts bot gateway
- **Original path:** `/usr/local/sbin/phase1-critical.sh`
- **Inputs:** `/etc/droplet.env` (all B64-encoded secrets)
- **Outputs:** `~/.openclaw/openclaw.json` (minimal), openclaw systemd service, `/var/lib/init-status/phase1-complete`
- **Dependencies:** `parse-habitat.py`, `tg-notify.sh`, `set-stage.sh`, npm, curl, openssl

### phase2-background.sh
- **Purpose:** Background setup — desktop (XFCE), dev tools, Chrome, VNC/XRDP, skills, email/calendar config
- **Original path:** `/usr/local/sbin/phase2-background.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env`
- **Outputs:** Desktop on `:10`, XRDP (port 3389), VNC (port 5900), skills installed, `/var/lib/init-status/phase2-complete`
- **Dependencies:** apt-get, npm (clawhub), `set-stage.sh`, `build-full-config.sh`, `restore-openclaw-state.sh`, `tg-notify.sh`

### build-full-config.sh
- **Purpose:** Generates the full `openclaw.json` with multi-agent support, browser, auth profiles, council, per-agent workspace files
- **Original path:** `/usr/local/sbin/build-full-config.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env`, `~/.openclaw/gateway-token.txt`
- **Outputs:** `~/.openclaw/openclaw.full.json`, per-agent `IDENTITY.md`/`SOUL.md`/`AGENTS.md`/`BOOT.md`/`BOOTSTRAP.md`/`USER.md`, `auth-profiles.json`, updated openclaw.service
- **Dependencies:** `/etc/droplet.env`, `/etc/habitat-parsed.env`, `bc` (for background color)

### post-boot-check.sh
- **Purpose:** Post-reboot health check — switches from minimal to full config, validates, enters safe mode on failure
- **Original path:** `/usr/local/bin/post-boot-check.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env`, `~/.openclaw/openclaw.full.json`, `/var/lib/init-status/needs-post-boot-check`
- **Outputs:** `/var/lib/init-status/setup-complete` (success) or `/var/lib/init-status/safe-mode` + `SAFE_MODE.md` (failure)
- **Dependencies:** `tg-notify.sh`, systemctl, curl

### try-full-config.sh
- **Purpose:** Manual tool to retry switching from safe-mode/minimal to full config
- **Original path:** `/usr/local/bin/try-full-config.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env`, `~/.openclaw/openclaw.full.json`
- **Outputs:** Removes `SAFE_MODE.md` and safe-mode marker on success; restores minimal config on failure
- **Dependencies:** systemctl, curl

### parse-habitat.py
- **Purpose:** Decodes `HABITAT_B64` JSON and writes `/etc/habitat-parsed.env` with all agent configs, platform settings, council config
- **Original path:** `/usr/local/bin/parse-habitat.py`
- **Inputs:** `HABITAT_B64` env var (required), `AGENT_LIB_B64` env var (optional)
- **Outputs:** `/etc/habitat.json`, `/etc/habitat-parsed.env`
- **Dependencies:** Python 3 (stdlib only: json, base64, os, sys)

### tg-notify.sh
- **Purpose:** Platform-aware notification sender — sends messages to owner via Telegram API and/or Discord DM
- **Original path:** `/usr/local/bin/tg-notify.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env`
- **Outputs:** Telegram/Discord messages to bot owner
- **Dependencies:** curl, python3, `parse-habitat.py`

### api-server.py
- **Purpose:** Lightweight HTTP status API on port 8080 — exposes provisioning status, health checks, sync/shutdown endpoints
- **Original path:** `/usr/local/bin/api-server.py`
- **Inputs:** `/var/lib/init-status/*` (stage/phase files), systemctl
- **Outputs:** HTTP endpoints: `GET /status`, `GET /health`, `GET /stages`, `POST /sync`, `POST /prepare-shutdown`
- **Dependencies:** Python 3 (stdlib: http.server, subprocess, json), `/usr/local/bin/sync-openclaw-state.sh`

### restore-openclaw-state.sh
- **Purpose:** Restores bot memory (MEMORY.md, USER.md), agent memory dirs, and session transcripts from Dropbox
- **Original path:** `/usr/local/bin/restore-openclaw-state.sh`
- **Inputs:** `/etc/droplet.env` (DROPBOX_TOKEN_B64), `/etc/habitat-parsed.env` (HABITAT_NAME, AGENT_COUNT)
- **Outputs:** Restored memory files and transcripts under `~/clawd/` and `~/.openclaw/`
- **Dependencies:** rclone, `tg-notify.sh`, `parse-habitat.py`

### rename-bots.sh
- **Purpose:** Renames Telegram bots to include habitat name (e.g., "ClaudeBot (MyHabitat)")
- **Original path:** `/usr/local/bin/rename-bots.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env` (AGENT*_NAME, AGENT*_BOT_TOKEN, HABITAT_NAME, PLATFORM)
- **Outputs:** Telegram bot display names updated via `setMyName` API
- **Dependencies:** curl, `parse-habitat.py`

## Utility Scripts

These are smaller helper scripts that require executable permissions but don't need full documentation headers (Issue #168).

### kill-droplet.sh
- **Purpose:** Destroys the DigitalOcean droplet via API (called by self-destruct timer)
- **Original path:** `/usr/local/bin/kill-droplet.sh`
- **Inputs:** `/etc/droplet.env` (DO_TOKEN_B64, HABITAT_NAME)
- **Outputs:** DELETE API call to DigitalOcean to destroy droplet by tag
- **Dependencies:** curl, `sync-openclaw-state.sh`

### mount-dropbox.sh
- **Purpose:** Mounts Dropbox folder in user's home directory using rclone FUSE
- **Inputs:** Requires `dropbox:` remote configured in rclone
- **Outputs:** `~/Dropbox` mounted, Thunar file manager opened
- **Dependencies:** rclone, fusermount, thunar

### schedule-destruct.sh
- **Purpose:** Schedules automatic droplet destruction after N minutes if DESTRUCT_MINS is set
- **Original path:** `/usr/local/bin/schedule-destruct.sh`
- **Inputs:** `/etc/droplet.env`, `/etc/habitat-parsed.env` (DESTRUCT_MINS)
- **Outputs:** systemd timer unit `self-destruct` that will call `kill-droplet.sh`
- **Dependencies:** systemd-run, `parse-habitat.py`, `kill-droplet.sh`

### verify-firewall.sh
- **Purpose:** Runtime check to ensure UFW rules match security policy (no forbidden ports exposed)
- **Original path:** `/usr/local/bin/verify-firewall.sh`
- **Inputs:** UFW status output
- **Outputs:** Exit code 0 (pass), 1 (forbidden port), or 2 (missing required port)
- **Dependencies:** ufw

## Environment Files

All scripts source one or both of these:

| File | Description |
|------|-------------|
| `/etc/droplet.env` | Raw B64-encoded secrets injected by cloud-init |
| `/etc/habitat-parsed.env` | Decoded/parsed habitat config (generated by `parse-habitat.py`) |

## Common Patterns

```bash
# Base64 decode helper (used in all bash scripts)
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

# Source env files
set -a; source /etc/droplet.env; set +a
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
```
