# Hatchery v5.0 — Product Requirements Document

**Version:** 1.2 (Final — Post-Panel Review)
**Date:** 2026-02-05
**Authors:** Council Review Panel (Claude, ChatGPT, Gemini) · Facilitated by Opus
**Status:** Final draft — Ready for implementation approval

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals & Non-Goals](#2-goals--non-goals)
3. [Architecture Evolution](#3-architecture-evolution)
4. [Reliability & Stability](#4-reliability--stability)
5. [Speed of Bring-up](#5-speed-of-bring-up)
6. [Context Restoration](#6-context-restoration)
7. [Security](#7-security)
8. [CI/CD & Testing](#8-cicd--testing)
9. [Accessibility](#9-accessibility)
10. [Council UX Improvements](#10-council-ux-improvements)
11. [Migration Path](#11-migration-path)
12. [Open Questions](#12-open-questions)
13. [Appendix: Round 1 Findings Traceability](#appendix-round-1-findings-traceability)

---

## 1. Executive Summary

Hatchery provisions ephemeral DigitalOcean droplets as AI-powered Cloud Browser workstations via iOS Shortcuts. The current v4.4 release works but carries significant technical debt: a 57KB monolithic YAML with inline bash/python scripts, fragile JSON generation via string concatenation, race conditions in downloads, unauthenticated services, and no automated testing.

v5.0 is a structural overhaul that addresses all 13 findings from the council code review while evolving the architecture toward a maintainable, testable, and accessible system. The YAML shrinks from 57KB to ~10-15KB. Scripts move to individually testable files in the repo. A CI/CD pipeline validates every change. The user experience remains unchanged — tap a Shortcut, get a droplet.

---

## 2. Goals & Non-Goals

### Goals

| # | Goal | Success Metric |
|---|------|---------------|
| G1 | Eliminate all 13 Round 1 reliability/security findings | Zero critical/high findings in post-implementation review |
| G2 | Reduce YAML to ≤15KB | Measured after externalization |
| G3 | Bot online in ≤2 minutes; context restored in ≤3 minutes when Dropbox reachable | Time-to-bot-online and time-to-context-restored measured separately |
| G4 | All scripts individually testable via CI | 100% of scripts have at least one test |
| G5 | Non-technical user can deploy via wizard Shortcut | No terminal commands required for standard deployment |
| G6 | Safe mode is bulletproof | Bot recoverable from any failure state without user SSH access |

### Non-Goals

- **Custom DO image (Packer)** — Deferred to v6.0. Worth pursuing but adds pipeline complexity.
- **Multi-droplet coordination** — Identified as a blind spot; deferred to future version.
- **Upstream clawdbot changes** — v5.0 must work with clawdbot as-is. No dependency on new upstream features.
- **Migration tooling for v4.4 → v5.0** — Users create fresh droplets; migration is not required.

### Model Fallbacks

Clawdbot natively supports model fallback chains via `agents.defaults.model.fallbacks` and per-agent `model: { primary, fallbacks }`. This is an existing feature, not a new requirement.

**Requirements:**
- R2.1: Habitat JSON SHOULD support an optional `modelFallbacks` array per agent (e.g., `["anthropic/claude-sonnet-4", "google/gemini-3-pro-preview"]`).
- R2.2: build-config.py MUST generate `model: { primary: "...", fallbacks: [...] }` in clawdbot.json when fallbacks are specified.
- R2.3: If no fallbacks are specified per-agent, the global `agents.defaults.model.fallbacks` from the habitat config applies.
- R2.4: This ensures that when a model hits rate limits, the agent automatically falls to the next model in the chain — maintaining availability for troubleshooting and conversation continuity.

### Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| GitHub unavailable during bootstrap | Droplet stuck — no scripts fetched | Emergency inline fallback in YAML (§10.2), retry with backoff |
| Telegram unavailable during setup | User has zero visibility | /status API always available; iOS Shortcut polls /status as backup |
| npm registry down | clawdbot can't install | Retry loop (R5.1.1); emergency mode installs from cached .tgz in release tarball |
| Dropbox token expired/invalid | No memory restore, sync fails silently | Explicit token validation in Phase 1; clear error to user (R9.2.1) |
| Phase 1 interrupted mid-run | Partial state, broken droplet | All scripts must be idempotent (new R4.7.1) |
| apt/dpkg lock contention | Phase 2 apt-get stalls or fails | Robust lock acquisition with timeout (new R4.7.2) |

---

## 3. Architecture Evolution

### 3.1 Current Architecture (v4.4)

```
┌─────────────────────────────────┐
│         hatch.yaml (57KB)       │
│  ┌───────────────────────────┐  │
│  │ /etc/droplet.env          │  │
│  │ parse-habitat.py          │  │
│  │ phase1-critical.sh        │  │
│  │ phase2-background.sh      │  │
│  │ build-full-config.sh      │  │
│  │ api-server.py             │  │
│  │ restore/sync scripts      │  │
│  │ post-boot-check.sh        │  │
│  │ helper scripts (8+)       │  │
│  │ template files (4+)       │  │
│  │ systemd units (6+)        │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

Everything inline. Untestable. One change requires editing a 57KB YAML.

### 3.2 Target Architecture (v5.0)

```
┌────────────────────┐     ┌──────────────────────────────┐
│  hatch.yaml (~12KB)│     │  GitHub Release (hatchery)    │
│  ┌──────────────┐  │     │  ┌──────────────────────┐    │
│  │ droplet.env  │  │ ──> │  │ scripts/             │    │
│  │ bootstrap.sh │  │     │  │   phase1.sh           │    │
│  │ parse-hab.py │  │     │  │   phase2.sh           │    │
│  │ set-stage.sh │  │     │  │   build-config.py     │    │
│  │ tg-notify.sh │  │     │  │   api-server.py       │    │
│  │ systemd units│  │     │  │   restore.sh / sync.sh│    │
│  └──────────────┘  │     │  │   post-boot-check.sh  │    │
└────────────────────┘     │  │   try-full-config.sh   │    │
                           │  │   kill-droplet.sh      │    │
┌────────────────────┐     │  │   rename-bots.sh       │    │
│ iOS Shortcut       │     │  │   vnc-setup.sh         │    │
│  HABITAT_B64       │     │  ├──────────────────────┐    │
│  AGENT_LIB_B64     │     │  │ templates/           │    │
└────────────────────┘     │  │   BOOT.md / TOOLS.md  │    │
                           │  │   HEARTBEAT.md         │    │
                           │  │   SAFE_MODE.md         │    │
                           │  ├──────────────────────┐    │
                           │  │ schemas/             │    │
                           │  │   habitat.schema.json │    │
                           │  │   agents.schema.json  │    │
                           │  ├──────────────────────┐    │
                           │  │ tests/               │    │
                           │  │   (unit + integration)│    │
                           │  └──────────────────────┘    │
                           └──────────────────────────────┘
```

### 3.3 What Stays in the YAML

The YAML retains only what **must** be inline for cloud-init to function before network-fetched scripts are available:

| File | Reason |
|------|--------|
| `/etc/droplet.env` | Credentials. Must exist before anything runs. |
| `parse-habitat.py` | Parses HABITAT_B64 → habitat.json + env file. Required by bootstrap. |
| `bootstrap.sh` | ~80 lines. Fetches release tarball from GitHub, verifies SHA256, extracts, runs phase1. |
| `set-stage.sh` / `set-phase.sh` | Tiny (5 lines each). Logging helpers used by bootstrap before scripts are fetched. |
| `tg-notify.sh` | ~20 lines. Sends Telegram alerts. Needed before bot is online. |
| Systemd unit files | `api-server.service`, `clawdbot.service` (minimal), `clawdbot-sync.timer` — declarative, small. |
| `api-server.py` | Status API. Needed before scripts are fetched to report bootstrap progress. |

**Estimated YAML size: 10-15KB** (down from 57KB).

### 3.4 Bootstrap Flow

```
cloud-init bootcmd
  ├─ Create /var/lib/init-status/
  ├─ Stop apt timers (prevent lock contention)
  └─ Mask xrdp (not used in v5.0)

cloud-init write_files
  └─ Write: droplet.env, parse-habitat.py, bootstrap.sh,
            set-stage.sh, tg-notify.sh, api-server.py, systemd units

cloud-init runcmd
  ├─ Enable api-server (status endpoint available immediately)
  ├─ Run parse-habitat.py → /etc/habitat.json + /etc/habitat-parsed.env
  └─ Run bootstrap.sh:
       ├─ Fetch hatchery release tarball from GitHub (pinned tag)
       ├─ Verify SHA256 checksum
       ├─ Extract to /opt/hatchery/
       └─ Exec /opt/hatchery/scripts/phase1.sh
            ├─ Install Node.js (from tarball, sequential, no race)
            ├─ Install clawdbot (pinned version, with retry)
            ├─ Create user, set up workspace
            ├─ Install rclone (static binary)
            ├─ Restore memory from Dropbox (MEMORY.md + latest transcripts)
            ├─ Generate minimal config (via build-config.py)
            ├─ Start clawdbot → BOT ONLINE WITH CONTEXT
            ├─ Schedule self-destruct (timer starts NOW, not at boot)
            └─ Launch phase2.sh in background
                 ├─ Desktop environment
                 ├─ Developer tools
                 ├─ Browser + Chrome setup
                 ├─ VNC with password + noVNC web interface
                 ├─ Skills installation
                 ├─ Credentials setup (himalaya, gh, khal, rclone)
                 ├─ Full config generation (via build-config.py)
                 ├─ Enable sync timer
                 └─ Reboot → post-boot-check upgrades to full config
```

### 3.5 File Organization in Repo

```
hatchery/
├── hatch.yaml                  # The cloud-init template (~12KB)
├── version.json                # Version metadata + dependency pins
├── docs/
│   └── PRD-v5.0.md            # This document
├── scripts/
│   ├── phase1.sh              # Critical path: Node → clawdbot → memory → bot online
│   ├── phase2.sh              # Background: desktop, tools, VNC, full config
│   ├── build-config.py        # Python config generator (replaces build-full-config.sh)
│   ├── api-server.py          # Status/health API
│   ├── restore-state.sh       # Restore memory + transcripts from Dropbox
│   ├── sync-state.sh          # Periodic sync to Dropbox
│   ├── post-boot-check.sh     # Config upgrade + health verification
│   ├── try-full-config.sh     # Manual safe-mode recovery
│   ├── kill-droplet.sh        # Self-destruct
│   ├── rename-bots.sh         # Telegram bot display names
│   ├── schedule-destruct.sh   # Timer setup
│   ├── mount-dropbox.sh       # Desktop shortcut helper
│   └── set-council-group.sh   # Council group config
├── templates/
│   ├── BOOT.md
│   ├── HEARTBEAT.md
│   ├── TOOLS.md
│   ├── SAFE_MODE.md
│   └── BOOTSTRAP.md
├── schemas/
│   ├── habitat.schema.json    # JSON Schema for habitat config
│   └── agents.schema.json     # JSON Schema for agent library
├── tests/
│   ├── unit/
│   │   ├── test_build_config.py    # pytest: JSON generation edge cases
│   │   ├── test_parse_habitat.py   # pytest: input validation
│   │   └── test_scripts.bats       # bats: shell script tests
│   ├── integration/
│   │   └── test_deploy.sh          # Spin up real droplet, validate
│   └── fixtures/
│       ├── habitat-valid.json
│       ├── habitat-unicode.json
│       ├── habitat-missing-fields.json
│       ├── agents-special-chars.json
│       └── agents-empty.json
└── .github/
    └── workflows/
        ├── pr-validate.yml         # Lint + unit tests on every PR
        ├── integration-test.yml    # Real droplet test on merge
        ├── dependency-update.yml   # Weekly version bump checks
        └── release.yml             # Build + publish release tarball
```

---

## 4. Reliability & Stability

### 4.1 Config Generation Rewrite (Finding #2)

**Problem:** `build-full-config.sh` constructs JSON via bash string concatenation. Special characters in agent names, identities, or soul text produce invalid JSON → safe mode.

**Solution:** Replace with `build-config.py`.

**Requirements:**
- R4.1.1: All JSON output MUST be generated via `json.dumps()` — no string concatenation.
- R4.1.2: All workspace files (IDENTITY.md, AGENTS.md, BOOT.md, BOOTSTRAP.md, USER.md, SOUL.md) MUST be generated via Python string formatting with proper escaping.
- R4.1.3: Input habitat JSON and agent library MUST be validated against JSON Schemas before processing.
- R4.1.4: On validation failure, generate a detailed error message listing every invalid field, and send via Telegram.
- R4.1.5: On validation failure, still generate a minimal working config for agent1 (graceful degradation).
- R4.1.6: Output configs MUST be validated (parse the generated JSON back) before writing to disk.
- R4.1.7: Script MUST be callable as: `build-config.py --habitat /etc/habitat.json --output-dir /home/bot --mode minimal|full`
- R4.1.8: Unit tests MUST cover: quotes in names, newlines in identity text, unicode agent names, empty agent library, missing optional fields, 1/3/10 agents, council present/absent.

### 4.2 Download Race Condition Fix (Finding #7)

**Problem:** Downloads backgrounded in bootcmd use cross-shell `wait` which silently fails. `tar` may operate on incomplete files.

**Solution:** Eliminate cross-shell downloads. Move Node.js download into phase1.sh (sequential). Chrome download stays in phase2.sh (not time-critical). Both use completion markers.

**Requirements:**
- R4.2.1: Node.js download MUST be sequential within phase1.sh. No cross-shell PID passing.
- R4.2.2: Chrome download in bootcmd MUST write a `.done` marker file on completion: `wget ... && touch /tmp/downloads/chrome.deb.done`
- R4.2.3: phase2.sh MUST poll for the `.done` marker with a timeout (max 120s), not use `wait`.
- R4.2.4: If download times out, phase2 MUST re-download directly with error logging.

### 4.3 Memory Sync Safety (Finding #8)

**Problem:** `rclone sync` is destructive — mirrors local to Dropbox, deleting remote files not present locally. If restore fails, first sync wipes Dropbox.

**Solution:** Replace `rclone sync` with `rclone copy` + restore guard file.

**Requirements:**
- R4.3.1: sync-state.sh MUST use `rclone copy` (never `rclone sync`) for all uploads.
- R4.3.2: A guard file `/var/lib/init-status/restore-ok` MUST be created only after successful memory restore.
- R4.3.3: sync-state.sh MUST refuse to upload memory if the restore-ok guard file does not exist.
- R4.3.4: sync-state.sh MUST check rclone exit code. After 3 consecutive failures, send Telegram notification.

### 4.4 Error Handling (Finding #13)

**Problem:** `set -e` in phase1-critical.sh causes silent aborts on any non-zero exit.

**Solution:** Replace with trap-based error handler.

**Requirements:**
- R4.4.1: No script SHALL use `set -e` without a corresponding ERR trap. `set -euo pipefail` combined with an ERR trap is acceptable and preferred over bare `set -e`.
- R4.4.2: All scripts MUST define a trap handler: `trap 'error_handler $LINENO "$BASH_COMMAND"' ERR`
- R4.4.3: The error handler MUST: log the failed command + line number, send Telegram notification, continue for non-critical failures, abort only for fatal failures (Node install, clawdbot install).
- R4.4.4: Each script MUST define which commands are fatal vs. non-fatal.
- R4.4.5: On fatal failure, the handler MUST write a diagnostic SAFE_MODE.md with the specific error before exiting.

### 4.5 Input Validation (Finding #11)

**Problem:** parse-habitat.py fallback on bad input leaves bot with incomplete config.

**Solution:** JSON Schema validation + graduated fallback.

**Requirements:**
- R4.5.1: parse-habitat.py MUST validate HABITAT_B64 using Python's standard `json` library only (no third-party dependencies like `jsonschema` — these are unavailable on fresh Ubuntu images during cloud-init). Validation checks: required keys exist (`name`, `agents`), `agents` is a non-empty list, each agent has `agent` and `botToken` strings. Full JSON Schema validation deferred to build-config.py in Phase 1 (post-pip-install).
- R4.5.2: build-config.py (Phase 1, post-install) MUST validate habitat and agent library against `schemas/habitat.schema.json` and `schemas/agents.schema.json` using the `jsonschema` Python library.
- R4.5.3: Validation errors MUST list every failing field with expected type/format.
- R4.5.4: On partial failure (some fields valid, some not): use valid fields, substitute safe defaults for invalid ones, log every substitution.
- R4.5.5: On complete failure (not valid base64, not valid JSON): extract bot token via regex as last resort, generate emergency config, send detailed Telegram error.

### 4.6 Safe Mode Improvements

**Requirements:**
- R4.6.1: Safe mode MUST result in a working bot that can respond to Telegram messages.
- R4.6.2: SAFE_MODE.md MUST contain the specific error that triggered safe mode, not generic instructions.
- R4.6.3: The bot in safe mode MUST be able to run `try-full-config.sh` when asked by the user via Telegram.
- R4.6.4: try-full-config.sh MUST send Telegram notifications for success/failure.
- R4.6.5: Safe mode MUST be recoverable without SSH access (Telegram-only recovery).
- R4.6.6: Safe mode MUST attempt multi-agent minimal config first (10s health check timeout). Fall back to single-agent (agent1) ONLY if multi-agent minimal fails health check. Full agent configs are preserved on disk so upgrade to full config can restore all agents. (Judge overrules ChatGPT + Gemini who prefer single-agent — multi-agent-first with fast fallback gets both reliability AND user intent.)
- R4.6.7: Post-boot-check MUST write a `/var/lib/init-status/config-upgraded` marker after successfully applying full config. On subsequent reboots, skip the upgrade attempt if marker exists and full config is already active.
- R4.6.8: **Telegram Token Fallback** — If the bot's assigned Telegram token fails to send (HTTP 401/403), safe mode MUST iterate through other agents' bot tokens from the habitat config and attempt to send using any working token. Once a working token is found, use it to notify the user of the issue.
- R4.6.9: **User Outreach Retry** — When safe mode needs user help to resolve an issue and the user hasn't responded, the bot MUST retry notification every 30 minutes for 3 attempts, then stop. This ensures the user didn't simply miss a notification without becoming spammy.

### 4.7 Script Robustness (Judge Addition)

**Requirements:**
- R4.7.1: All scripts MUST be idempotent. If phase1.sh or phase2.sh is interrupted and re-run, it MUST produce the same result without errors. Use guard files (e.g., `/var/lib/init-status/node-installed`) to skip completed steps.
- R4.7.2: Phase 2 MUST acquire dpkg/apt locks with a retry loop (max 120s, 5s interval) before running apt-get. Use `flock /var/lib/dpkg/lock-frontend` or poll for lock availability. Do NOT use `killall -9 apt` — this corrupts dpkg state.
- R4.7.3: All log files (`/var/log/phase1.log`, `phase2.log`, `init-stages.log`, `post-boot-check.log`) MUST have logrotate configs to prevent unbounded growth on long-running droplets.

---

## 5. Speed of Bring-up

### 5.1 Phase 1 Critical Path

**Target:** Bot online with memory context in ≤2 minutes from droplet creation.

**Critical path sequence:**
1. cloud-init writes files (~2s)
2. parse-habitat.py (~1s)
3. bootstrap.sh fetches + extracts release tarball (~5s)
4. Node.js download + extract (~15s)
5. `npm install -g clawdbot@<pinned>` with retry (~30s)
6. User creation + workspace setup (~2s)
7. rclone binary download (~5s)
8. Memory restore from Dropbox — MEMORY.md + 2 newest transcripts (~10s)
9. build-config.py minimal config (~1s)
10. Start clawdbot + verify health (~10s)

**Estimated total: ~80s**

**Requirements:**
- R5.1.1: npm install MUST retry up to 3 times with 5s backoff.
- R5.1.2: rclone MUST be installed as a static binary download (not via apt) to avoid package manager contention.
- R5.1.3: Memory restore in Phase 1 MUST be lightweight: only MEMORY.md, USER.md, and the 2 most recent transcript files per agent. Full transcript restore deferred to Phase 2.
- R5.1.4: If memory restore fails (Dropbox error, no token), Phase 1 MUST continue. Bot starts without context rather than blocking.
- R5.1.5: Self-destruct timer MUST be scheduled after Phase 1 completes (not at boot).

### 5.2 Phase 2 Background

**Requirements:**
- R5.2.1: Phase 2 MUST NOT block or interfere with the running bot.
- R5.2.2: Phase 2 MUST report progress via set-stage.sh (visible in /status API).
- R5.2.3: Full transcript restore MUST happen in Phase 2.
- R5.2.4: Phase 2 completion MUST trigger a clawdbot wake event to notify the bot.

---

## 6. Context Restoration

### 6.1 Phase 1 Memory Restore (Finding #9)

**Problem:** In v4.4, the bot starts in Phase 1 but memory isn't restored until Phase 2. The bot's first interactions lack any prior context.

**Solution:** Lightweight memory restore in Phase 1, before clawdbot starts.

**Requirements:**
- R6.1.1: Phase 1 MUST restore MEMORY.md and USER.md for all agents before starting clawdbot.
- R6.1.2: Phase 1 MUST restore the 2 most recent transcript files (.jsonl) per agent.
- R6.1.3: Remaining transcripts MUST be restored in Phase 2 (background).
- R6.1.4: BOOTSTRAP.md MUST be written before clawdbot starts, instructing the bot to read restored transcripts for context.
- R6.1.5: If Dropbox is unreachable, Phase 1 MUST continue without blocking. Log the failure and retry in Phase 2.

### 6.2 Sync Reliability

**Requirements:**
- R6.2.1: Periodic sync (every 2 min) MUST use `rclone copy` (additive, never deletes).
- R6.2.2: Sync MUST NOT run until restore-ok guard file exists.
- R6.2.3: Shutdown sync (ExecStop) MUST have a 30s timeout to prevent hung shutdowns.
- R6.2.4: Sync failures MUST be counted. After 3 consecutive failures, notify via Telegram.
- R6.2.5: Sync MUST include a generation counter to prevent older droplets from overwriting newer state. Implementation: Phase 1 writes a file `dropbox:clawdbot-memory/<habitat>/.generation` containing the droplet creation timestamp (from DO metadata API: `curl -s http://169.254.169.254/metadata/v1/created`). Before syncing, check remote `.generation` — only sync if local timestamp ≥ remote. The newest generation always wins.

---

## 7. Security

### 7.1 VNC Access (Finding #1)

**Problem:** x11vnc runs with no password and port 5900 is open to the internet.

**Solution:** Two access methods — native VNC with password + noVNC browser-based access.

**Requirements:**

**Native VNC (port 5900):**
- R7.1.1: x11vnc MUST require a password. A random 12-character password MUST be generated at setup and sent to the user via Telegram as a one-time notification. This is NOT derived from the droplet password (per ChatGPT: separate blast radius).
- R7.1.2: Password file MUST be stored at `/home/bot/.vnc/passwd` with 0600 permissions. Plaintext stored in `/home/bot/.vnc/password.txt` (0600) for bot-assisted recovery.
- R7.1.3: x11vnc MUST be started with `-rfbauth /home/bot/.vnc/passwd` (replacing `-nopw`).
- R7.1.4: Port 5900 open via ufw for direct VNC client access (Jump, Screens, etc.). **Note:** Classic VNC/RFB is unencrypted — password auth protects access but traffic is not confidential. For encrypted access, use noVNC over HTTPS (R7.1.9) or SSH tunnel. This trade-off is documented and acceptable for ephemeral droplets.

**noVNC Web Interface (port 6080):**
- R7.1.5: Install noVNC and websockify via apt (packages: `novnc` and `websockify`).
- R7.1.6: Run websockify on port 6080, proxying to localhost:5900. Managed via systemd unit `novnc.service`.
- R7.1.7: noVNC MUST use websockify's built-in `--web` flag with token-based auth. Password derived from PASSWORD_B64 (same as VNC). No nginx dependency required — keep the stack simple.
- R7.1.8: Port 6080 open via ufw. Users access via `http://<droplet-ip>:6080/vnc.html`.
- R7.1.9: If a domain is configured (HABITAT_DOMAIN), set up Let's Encrypt via certbot for HTTPS on port 6080. This is a v5.0 goal (Q1 resolved: YES, auto-HTTPS when domain is set).

### 7.2 API Server Auth (Finding #3)

**Requirements:**
- R7.2.1: GET endpoints (`/status`, `/health`, `/stages`) MUST remain public (no secrets exposed).
- R7.2.2: POST endpoints (`/sync`, `/prepare-shutdown`) MUST require `Authorization: Bearer <gateway-token>`.
- R7.2.3: Unauthorized POST requests MUST return 401 with no information leakage.
- R7.2.4: api-server.py MUST read the gateway token from `/home/bot/.clawdbot/gateway-token.txt` (same token used by clawdbot gateway control UI). Token file is 0600, owned by bot user.
- R7.2.5: GET `/status` MUST include: Hatchery version, Node version, clawdbot version, timestamps per stage, `last_error` field (last error message if any), and a human-readable `message` field.

### 7.3 Secrets Management (Finding #12)

**Problem:** API keys in systemd `Environment=` lines are readable by any local user.

**Requirements:**
- R7.3.1: All secrets MUST be stored in `/home/bot/.clawdbot/.env` (existing file, 0600).
- R7.3.2: Systemd service files MUST use `EnvironmentFile=/home/bot/.clawdbot/.env` instead of inline `Environment=` for secrets.
- R7.3.3: Non-secret environment variables (NODE_ENV, DISPLAY, PATH) MAY remain as inline `Environment=`.
- R7.3.4: No secret values SHALL appear in systemd unit files, clawdbot.json, or any file readable by other users.

### 7.4 Firewall Hardening

**Requirements:**
- R7.4.1: Phase 1 MUST run `ufw default deny incoming` and `ufw --force enable` before opening any ports.
- R7.4.2: Allowed ports: 22 (SSH), 80 (ACME challenges, only when HABITAT_DOMAIN set), 5900 (VNC), 6080 (noVNC), 8080 (status API). Port 18789 (clawdbot gateway) MUST bind to localhost by default; expose via ufw only if habitat config explicitly sets `exposeGateway: true`.
- R7.4.3: Port 3389 (RDP) is NOT opened by default. xrdp is retained in Phase 2 but port is only opened if habitat config sets `enableRDP: true`. VNC is the sole default remote access method.
- R7.4.4: Install fail2ban with default SSH jail + custom jail for VNC auth failures (5 attempts → 10 min ban).

### 7.5 Supply Chain (Findings #4, #5)

**Requirements:**
- R7.5.1: clawdbot version MUST be pinned in `version.json`. Full schema:
  ```json
  {
    "version": "5.0.0",
    "file": "hatch.yaml",
    "deps": {
      "clawdbot": {"version": "x.y.z"},
      "node": {"version": "22.12.0", "sha256": "..."},
      "himalaya": {"version": "x.y.z", "sha256": "..."},
      "rclone": {"version": "x.y.z", "sha256": "..."},
      "clawhub": {"version": "x.y.z"}
    },
    "minShortcutVersion": "2.0"
  }
  ```
- R7.5.2: himalaya MUST be installed from a pinned release URL with SHA256 verification. Hash stored in `version.json`.
- R7.5.3: Node.js version MUST be pinned in `version.json`. URL and SHA256 hash included.
- R7.5.4: No script SHALL use `curl | sh` or `wget | sh` patterns.
- R7.5.5: CI workflow MUST check for dependency updates weekly and open PRs with updated pins + hashes.

---

## 8. CI/CD & Testing

### 8.1 GitHub Actions Workflows

**Workflow 1: PR Validation** (`pr-validate.yml`) — Runs on every PR.

| Check | Tool | Target |
|-------|------|--------|
| Shell linting | ShellCheck | All `.sh` files |
| Python linting | ruff | All `.py` files |
| YAML linting | yamllint | `hatch.yaml` |
| JSON Schema validation | jsonschema (Python) | Test fixtures against schemas |
| Unit tests (Python) | pytest | `tests/unit/test_build_config.py`, `test_parse_habitat.py` |
| Unit tests (Shell) | bats | `tests/unit/test_scripts.bats` |
| Template rendering | pytest | Verify workspace files generate correctly |

**Workflow 2: Integration Test** (`integration-test.yml`) — Runs on **release candidates only** (tag push matching `v*-rc*`), NOT on every merge.

| Step | Action | Timeout |
|------|--------|---------|
| 1 | Create DO droplet (s-1vcpu-2gb) with test credentials | 60s |
| 2 | Poll `/status` endpoint until `phase1_complete` | 3min |
| 3 | Verify: clawdbot responds to API health check | 30s |
| 4 | Poll `/status` until `setup_complete` | 10min |
| 5 | Verify: VNC port responds (nmap check, not full auth test) | 30s |
| 6 | Verify: all expected systemd services active (SSH command) | 30s |
| 7 | Verify: memory files exist in expected locations | 10s |
| 8 | **Always** destroy droplet (in `finally` block — tagged `hatchery-ci-test` for cleanup sweeper) | 30s |

**Estimated cost:** ~$0.03 per run (s-1vcpu-2gb for ~15 min).

**Safeguards (per ChatGPT RISK-4):**
- Droplets tagged `hatchery-ci-test` with auto-destroy after 30 min (DO firewall tag)
- Weekly cleanup sweeper job destroys any `hatchery-ci-test` tagged droplets older than 1 hour
- Budget alert on DO at $5/month for CI usage

**PR validation (Workflow 1) uses Docker** for unit tests — no real droplets needed (per Gemini: Docker mock covers 95% of logic).

**Required GitHub Secrets for integration tests:**
- `DO_TOKEN` — DigitalOcean API token (test account)
- `TEST_BOT_TOKEN` — Telegram bot token for test agent
- `TEST_TELEGRAM_USER_ID` — Telegram user ID for test notifications
- `TEST_ANTHROPIC_KEY` — Anthropic API key (can be a low-tier key for health check only)
- `TEST_DROPBOX_TOKEN` — Dropbox token with a test memory folder

**Workflow 3: Dependency Updates** (`dependency-update.yml`) — Weekly cron.

- Check npm registry for new clawdbot version
- Check GitHub releases for new himalaya version
- Check Node.js release schedule for LTS updates
- Auto-create PR with updated `version.json` (new pins + SHA256 hashes)
- PR triggers Workflow 1 (lint + unit tests)
- If green, auto-triggers Workflow 2 (integration test)
- If green, auto-merge

**Workflow 4: Release** (`release.yml`) — Triggered on version tag push.

- Build release tarball from repo contents
- Compute SHA256 of tarball
- Create GitHub Release with tarball attached
- Update `version.json` on main with new release tag

### 8.2 Unit Test Coverage

**build-config.py tests** (highest priority):

```
test_agent_name_with_quotes        # O'Brien → valid JSON
test_agent_name_with_double_quotes # Agent "Test" → valid JSON
test_identity_with_newlines        # Multi-line identity text → correct .md file
test_unicode_agent_name            # Claude 🤖 → valid JSON
test_empty_agent_library           # No library → uses defaults
test_missing_optional_fields       # Minimal habitat → works
test_single_agent                  # 1 agent → correct config
test_three_agents                  # 3 agents → correct bindings
test_ten_agents                    # 10 agents → correct config
test_council_present               # Council config → judge/panelist protocols generated
test_council_absent                # No council → no council sections
test_minimal_mode                  # --mode minimal → minimal config output
test_full_mode                     # --mode full → full config with all sections
test_output_json_is_valid          # Every generated JSON file parses successfully
test_special_chars_in_soul         # Backticks, brackets, etc. in soul text
```

**parse-habitat.py tests:**

```
test_valid_input                   # Happy path
test_invalid_base64                # Garbage B64 → specific error message
test_invalid_json                  # Valid B64, invalid JSON → specific error
test_missing_required_fields       # No "name" → error with field name
test_missing_agents                # No agents array → error
test_empty_agent_library           # AGENT_LIB_B64 empty → warning, continue
test_partial_failure               # Some fields valid → use valid, default others
test_legacy_councilGroupId         # Old field name → still works
```

**Shell script tests (bats):**

```
test_set_stage_writes_file         # set-stage.sh writes to /var/lib/init-status/stage
test_tg_notify_handles_missing_env # tg-notify.sh exits cleanly without tokens
test_sync_refuses_without_guard    # sync-state.sh exits if restore-ok missing
test_sync_counts_failures          # sync-state.sh increments failure counter
```

---

## 9. Accessibility

### 9.1 Wizard Shortcut Experience

The iOS Shortcut remains the primary deployment interface. User experience:

1. Open Shortcut → Pick habitat (or create new)
2. Pick agents from library (or use defaults)
3. Tap "Launch" → Shortcut creates droplet via DO API
4. Receive Telegram message: "Droplet starting up..."
5. Receive Telegram message: "Bot online! Memory restored." (~2 min)
6. Receive Telegram message: "Desktop ready. VNC: <ip>:5900 / Web: <ip>:6080" (~8 min)

### 9.2 Error Communication

**Requirements:**
- R9.2.1: All user-facing error messages MUST be non-technical. Instead of "parse-habitat.py failed with KeyError: 'agents'", say: "Your habitat config is missing the agents list. Please check your Shortcut settings and try again."
- R9.2.2: Safe mode notification MUST include: what went wrong, what still works, and what to do next.
- R9.2.3: Phase 2 failures MUST be reported individually. "Desktop installed, but VNC setup failed. The bot is working. Attempting to fix VNC..."
- R9.2.4: The /status API MUST include a human-readable `message` field alongside the machine-readable status.

### 9.3 Input Validation at the Shortcut Level

**Requirements:**
- R9.3.1: JSON Schemas for habitat and agent configs MUST be published in the repo for the iOS Shortcut to validate against (where feasible).
- R9.3.2: Required fields MUST be clearly documented in schemas with descriptions.
- R9.3.3: version.json MUST include the minimum compatible Shortcut version to enable version-mismatch warnings.

---

## 10. Council UX Improvements

The multi-agent council deliberation protocol works well structurally but fights against Telegram's platform limitations. This section defines improvements based on a council self-review.

### 10.1 Report Delivery: Summary + File

**Problem:** Telegram's 4096 char limit splits reports into 3-7 messages, creating an unreadable wall of text.

**Requirements:**
- R10.1.1: Panelists MUST write full reports to `~/clawd/shared/reports/Round{N}_{AgentName}.md`.
- R10.1.2: Panelists MUST post a 3-5 bullet executive summary (≤1 message) to the group chat with a reference to the full report file.
- R10.1.3: The Judge MUST read panelist reports from the filesystem, not from chat messages.
- R10.1.4: The `reports/` directory is created automatically per-topic.

### 10.2 Coordination Protocol

**Problem:** Judge manually @mentions or sessions_sends each panelist, waits, checks, re-pings. Panelists silently drop messages.

**Requirements:**
- R10.2.1: The Judge MUST dispatch work to panelists via `sessions_send` with a structured message containing `COUNCIL:PROCEED` token, topic description, scope bounds, and round number.
- R10.2.2: Panelists MUST acknowledge within 60 seconds: "Received, working on report." If a panelist's AGENTS.md contains `COUNCIL:PROCEED`, it MUST NOT respond with NO_REPLY.
- R10.2.3: If no ACK after 60s, Judge re-pings once. If still no ACK after another 60s, proceed without that panelist and note their absence.
- R10.2.4: Reports have a 5-minute deadline from PROCEED signal. Judge sends a reminder at 4 minutes. At 5 minutes, Judge synthesizes with available reports.
- R10.2.5: All council messages in the group chat MUST include a header: `[topic:<slug> round:<n> role:<panelist|judge>]` for parseability.

### 10.3 Template Improvements (AGENTS.md)

**Requirements:**
- R10.3.1: Standardized report skeleton: Summary → Analysis (by priority) → Considerations → Open Questions.
- R10.3.2: Explicit trigger phrase: Panelists wait for "please proceed with your reports" (or `COUNCIL:PROCEED` via backchannel).
- R10.3.3: Disagreement handling: Panelists MUST flag contradictions with peers as `DISSENT: [position]` with evidence for both sides.
- R10.3.4: Inter-panelist questions: Allow `QUESTION for [Panelist]: [question]` — addressee responds in next round.
- R10.3.5: Scope bounds: Judge sets explicit scope in the dispatch message. Panelists must stay within bounds or flag scope expansion explicitly.

### 10.4 Automation (skill-council)

**Short-term (v4.5):** Shell scripts in the hatchery repo:
- `council-start.sh <topic>` — creates round folder, dispatches to panelists via sessions_send
- `council-status.sh` — checks which panelists have filed reports
- `council-archive.sh` — writes DECISIONS.md entry from synthesis

**Long-term (v5.0+):** ClawdHub skill `skill-council`:
- `council start <topic>` → creates folder, pings panelists, sets state to CLARIFYING
- `council proceed` → dispatches COUNCIL:PROCEED, sets state to REPORTING, starts timeout
- `council status` → shows who has reported, time remaining
- `council synthesize` → pre-loads all reports into Judge's context
- `council archive` → compiles DECISIONS.md + updates KNOWLEDGE.md
- State machine: CLARIFYING → REPORTING → SYNTHESIS → DECISION → ARCHIVED

### 10.5 Platform: Discord as Default

**Decision:** Discord is the default council platform. Telegram remains supported but is secondary.

**Discord advantages over Telegram for council:**
- **Forum channels** — each deliberation topic gets a thread, reports stay organized
- **File embeds** — full reports as .md file uploads, readable inline
- **Bot-to-bot** — bots see all messages in channels without @mention requirements
- **Reactions** — ⏳ "working", ✅ "done", 👀 "reviewing"
- **Pinned messages** — pin synthesis for easy reference
- **No message limit issues** — 2000 chars + file uploads for longer content

**Requirements:**
- R10.5.1: Clawdbot Discord channel MUST be configured as the default council platform for new habitats.
- R10.5.2: Each agent gets a Discord bot (same approach as Telegram — one bot token per agent).
- R10.5.3: Council group is a Discord server with a `#council` forum channel. Each topic becomes a forum post with threads for rounds.
- R10.5.4: Telegram remains available as an option (`council.platform: "telegram"`) for users who prefer it.
- R10.5.5: Agent DMs (1:1 with user) can be on either platform — user's choice.

**Habitat config:**
```json
{
  "council": {
    "groupId": "...",
    "groupName": "The Council",
    "judge": "Opus",
    "platform": "discord",
    "deliveryMode": "summary+file"
  }
}
```

**Action item:** Set up a Discord server for The Council and migrate ASAP. Telegram group stays active during transition.

---

## 11. Migration Path

### 10.1 Versioned Releases

v5.0 introduces proper versioning via GitHub Releases.

**Version strategy:**
- YAML embeds a `HATCHERY_VERSION` variable (e.g., "5.0.0")
- bootstrap.sh reads this version and fetches the matching GitHub Release tarball
- For development: `HATCHERY_VERSION=main` fetches from the main branch (unstable)

### 10.2 Rollback

If a release tarball fails to download:
1. bootstrap.sh retries 3 times with exponential backoff (5s, 15s, 30s)
2. On final failure: **fail fast**. Send Telegram notification: "Setup failed — could not fetch Hatchery scripts from GitHub. Please retry or check GitHub status." Do NOT maintain an inline emergency fallback (per Gemini + ChatGPT: maintaining two bootstrap paths is worse than failing cleanly; the iOS Shortcut can retry).
3. Set stage to "error" so /status API reports the failure clearly.

### 10.3 Phased Rollout

| Phase | Version | Changes |
|-------|---------|---------|
| 1 | v4.5 | Quick wins: rclone copy, destruct timer fix, EnvironmentFile, VNC password + fail2ban, API auth on POST, ufw hardening, error handling traps, gateway binds localhost |
| 2 | v5.0 | Full architecture: thin YAML, build-config.py, all scripts external via GitHub releases, CI/CD pipeline, input validation, noVNC, JSON Schema validation |

*v4.6 collapsed into v5.0 per Gemini's recommendation — the externalization IS the architecture change.*

---

## 11. Open Questions

| # | Question | Impact | Owner | Resolution |
|---|----------|--------|-------|------------|
| Q1 | Should we support HTTPS for noVNC automatically when HABITAT_DOMAIN is set? | Security, UX | Panel | **YES** — Auto-HTTPS via certbot when domain is configured (R7.1.9) |
| Q2 | What's the minimum viable set of Phase 2 packages? Can we trim the apt-get install lists? | Speed, size | Panel | **DEFER** — Audit during v4.6 implementation. Candidates for removal: vlc, thunderbird, libreoffice-writer |
| Q3 | Should the status API expose a cost estimate (uptime × droplet size hourly rate)? | UX | User | **OPEN** — Nice to have. Low priority. |
| Q4 | Do we need a mechanism for the iOS Shortcut to check for YAML updates? | Accessibility | User | **YES** — Shortcut checks `version.json` before creating droplet. If `minShortcutVersion` > current, prompt user to update Shortcut. |
| Q5 | Should safe mode support multi-agent configs, or always fall back to single-agent? | Reliability | Panel | **MULTI-AGENT FIRST** — Try multi-agent minimal, then single-agent as last resort (R4.6.6) |
| Q6 | Is RDP fully removed in v5.0, or kept as a fallback alongside VNC? | Architecture | User | **KEEP AS FALLBACK** — VNC primary, RDP retained for compatibility (R7.4.3) |

### New Open Questions (Judge Addition)

| # | Question | Impact | Owner |
|---|----------|--------|-------|
| Q7 | Should we bundle a clawdbot .tgz in the release tarball as npm-down fallback? | Reliability | Implementation |
| Q8 | How do we handle the YAML template itself being out of date? (User has old Shortcut with old YAML cached) | Accessibility | User |
| Q9 | Should Phase 2 reboot be eliminated? (Currently reboots to trigger post-boot-check; could use systemd instead) | Speed | Implementation |

---

## Appendix: Round 1 Findings Traceability

| # | Finding | Severity | v5.0 Section | Status |
|---|---------|----------|-------------|--------|
| F1 | VNC unauthenticated + internet-exposed | CRITICAL | §7.1 | Addressed |
| F2 | JSON generation via bash string concat | CRITICAL | §4.1 | Addressed |
| F3 | API server POST endpoints unauthenticated | CRITICAL | §7.2 | Addressed |
| F4 | npm install @latest unpinned | HIGH | §7.5 | Addressed |
| F5 | curl\|sh supply chain risk (himalaya) | HIGH | §7.5 | Addressed |
| F6 | Scripts should be externalized from YAML | HIGH | §3.2-3.5 | Addressed |
| F7 | Cross-shell wait race condition | HIGH | §4.2 | Addressed |
| F8 | rclone sync can delete memory data | HIGH | §4.3 | Addressed |
| F9 | Phase 1 Amnesia: bot before memory | HIGH | §6.1 | Addressed |
| F10 | Self-destruct timer from boot | MEDIUM | §5.1 (R5.1.5) | Addressed |
| F11 | parse-habitat.py fallback insufficient | MEDIUM | §4.5 | Addressed |
| F12 | API keys in systemd Environment= | CRITICAL | §7.3 | Addressed |
| F13 | set -e causes silent exits | HIGH | §4.4 | Addressed |

---

## Judge's Review Notes (v1.2 — Post-Panel Critique)

### What's Strong
- Architecture evolution (§3) is well-structured with a clear migration path
- Bootstrap flow diagram is excellent — clear critical path
- All 13 findings traced to specific requirements in the appendix
- Phased rollout (v4.5 → v4.6 → v5.0) is pragmatic — no big bang
- Test coverage plan is thorough, especially build-config.py edge cases

### What I Changed (v1.0 → v1.1)
1. **Added Risks & Mitigations table** (§2) — GitHub down, Telegram down, npm down, dpkg corruption
2. **Fixed R4.4.1** — `set -e` with ERR trap is fine; bare `set -e` without trap is the problem
3. **Added §4.7 Script Robustness** — idempotency (R4.7.1), proper dpkg lock handling instead of killall -9 (R4.7.2), log rotation (R4.7.3)
4. **Added R4.6.6** — Multi-agent safe mode before single-agent fallback
5. **Added R4.6.7** — Config-upgraded marker to prevent re-running post-boot-check
6. **Specified noVNC implementation** (R7.1.5-7) — websockify built-in, no nginx needed
7. **Resolved Q1** (YES auto-HTTPS), **Q4** (YES version check), **Q5** (multi-agent first), **Q6** (keep RDP as fallback)
8. **Defined version.json schema** (R7.5.1) — full dependency pinning structure
9. **Specified generation counter implementation** (R6.2.5) — DO metadata API
10. **Added integration test secrets** — what GitHub Secrets are needed
11. **Added Q7-Q9** — npm fallback, stale YAML, Phase 2 reboot elimination
12. **Kept RDP** as fallback (R7.4.3) — VNC primary, RDP for compatibility

### Panel Critique Synthesis (v1.1 → v1.2)

**Accepted from ChatGPT:**
- ✅ GAP-1: Threat model — added fail2ban (R7.4.4), gateway binds localhost by default (R7.4.2)
- ✅ GAP-2: VNC confidentiality — documented plaintext trade-off, noVNC/HTTPS is the encrypted path (R7.1.4)
- ✅ GAP-5: Observability — added version/error reporting to /status (R7.2.5)
- ✅ OE-2: Auto-merge disabled — dependency PRs require human approval
- ✅ RQ-1: Split G3 into time-to-bot-online and time-to-context-restored
- ✅ R7.1.1: Random per-service VNC password sent via Telegram (not derived from droplet password)
- ✅ RISK-1: Port 18789 binds localhost by default
- ✅ RISK-4: CI test cleanup guardrails (always-destroy, tagged, sweeper, budget cap)
- ❌ Q5 single-agent safe mode: Overruled — multi-agent-first with 10s timeout is fast enough
- ❌ Q6 remove RDP: Compromise — RDP not exposed by default, opt-in via habitat config

**Accepted from Gemini:**
- ✅ R4.5.1 CRITICAL FIX: jsonschema not available during cloud-init. Rewrote: stdlib-only validation in parse-habitat.py, full schema validation deferred to build-config.py post-install
- ✅ Emergency Mode removed: fail fast on GitHub unreachable
- ✅ Port 80 added for ACME challenges
- ✅ Phased rollout collapsed: v4.5 → v5.0 (skip v4.6)
- ✅ Integration tests on release candidates only, Docker for PR validation
- ❌ Q5 single-agent: Overruled (see above)
- ❌ Q6 remove RDP: Compromise (see above)

**New disagreements resolved:**
- ChatGPT wants IP allowlisting; deferred to Shortcut-level firewall management (existing "Repair Habitat Firewall" shortcut)
- Gemini wants Shortcut Interface Specification; added to "What's Still Missing" below

### Known Bug: VNC Root vs Bot Permissions

A root-vs-bot permissions issue was identified in v3.20 that blocks VNC from working in some configurations. The fix was attempted but the v3.20 YAML failed for unrelated reasons, so the fix never propagated to v4.0+.

**Root cause identified and fixed (2026-02-05):** `/run/user/<uid>` (XDG_RUNTIME_DIR) was never created for the `bot` user because systemd services don't trigger systemd-logind. Without it, D-Bus session bus fails → xfconfd can't connect → XFCE loads with "Unable to contact settings server" error.

**Two fixes required (both originally identified in v3.20 but lost when that YAML failed for unrelated reasons):**

**Fix 1 — Home directory ownership (phase1-critical.sh, after useradd):**
```bash
chown $USERNAME:$USERNAME $H
```
Without this, if cloud-init write_files creates files in `/home/bot` as root before `useradd -m` runs, the home dir stays `root:root` → XFCE can't create `.ICEauthority`, `.dbus`, `.cache`.

**Fix 2 — Desktop service (desktop.service):**
1. Add `Environment=XDG_RUNTIME_DIR=/run/user/<uid>`
2. Add `ExecStartPre=/bin/bash -c 'mkdir -p /run/user/<uid> && chown bot:bot /run/user/<uid> && chmod 700 /run/user/<uid>'`
3. Change ExecStart to `dbus-launch --exit-with-session xfce4-session` (replaces bare `xfce4-session` with `DBUS_SESSION_BUS_ADDRESS=autolaunch:` which silently fails)

**Action item:** Apply BOTH fixes in hatch.yaml immediately (v4.5 critical fix). Fix 2 verified working on Habitat-1. Fix 1 is a safety net for edge-case boot ordering.

### What's Still Missing (future PRD revisions)
- **iOS Shortcut PRD** — Map out and plan the Shortcut code side of the work. Significant refactoring needed. User will record new videos of Shortcuts for transcription → architectural diagram → PRD. Existing (slightly outdated) Shortcut code transcriptions in `Dropbox/Droplets/shortcuts/` with video recordings in `shortcuts/Videos/`. **This is a separate workstream and should be tracked as its own project.**
- iOS Shortcut Interface Specification (per Gemini: formal contract between Shortcut and YAML)
- Monitoring beyond Telegram (Uptime Robot, DO monitoring, etc.)
- Cost optimization analysis (which DO droplet size, when to downsize)
- Documentation for contributors (CONTRIBUTING.md)
- IP allowlisting at ufw level (currently handled by DO firewall via iOS Shortcut — strict rules, user IP only)

### Firewall Context

The iOS Shortcut creates a strict DO Cloud Firewall that only allows traffic from the user's current IP on specific ports. This significantly reduces the VNC/gateway exposure risk — the droplet is not truly "open to the internet" in practice. However, the YAML-level ufw hardening and fail2ban remain important as defense-in-depth (the DO firewall can be misconfigured or the user's IP can change).

---

*This PRD is a living document. Updates will be tracked via Git history in the hatchery repo.*
