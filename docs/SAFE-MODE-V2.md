# Safe Mode & Health Check Architecture (v2)

> Supersedes [SAFE-MODE.md](SAFE-MODE.md). Covers the refactored architecture where the health check monolith has been split into focused, single-responsibility scripts with proper systemd integration.

## Overview

When an OpenClaw gateway fails to start or its agents can't communicate (bad API key, expired OAuth, invalid bot token), the system automatically detects the problem, attempts recovery with backup credentials, and brings a diagnostic SafeModeBot online to help the user troubleshoot.

The health check system works identically across all three isolation modes — **single** (`none`), **session**, and **container** — using a universal per-group pattern.

---

## Table of Contents

1. [Design Principles](#design-principles)
2. [Boot Sequence](#boot-sequence)
3. [Architecture Overview](#architecture-overview)
4. [Script Responsibilities](#script-responsibilities)
5. [Systemd Unit Structure](#systemd-unit-structure)
6. [Health Check Flow](#health-check-flow)
7. [Recovery Flow](#recovery-flow)
8. [Notification Flow](#notification-flow)
9. [Isolation Modes](#isolation-modes)
10. [State Files & Paths](#state-files--paths)
11. [Exit Codes](#exit-codes)
12. [Permissions](#permissions)
13. [Known Issues & Gotchas](#known-issues--gotchas)
14. [Debugging](#debugging)
15. [Test Habitats](#test-habitats)

---

## Design Principles

### 1. No Services Before Reboot

**OpenClaw services MUST NOT start until after the post-install reboot.**

During initial boot (phase1 + phase2):
- Services are **enabled** (`systemctl enable`) but **never started**
- `generate-session-services.sh` checks for `boot-complete` marker — if missing, it only enables
- Config files, workspaces, and state directories are written and prepared
- After phase2 completes, the system reboots

**Why the reboot is required:**
- Packages installed in parallel may need kernel modules loaded
- systemd unit files written during cloud-init need `daemon-reload` (reboot is the cleanest reset)
- Avoids weird state from halfway-installed packages (Chrome, xrdp, etc.)
- Services should only start in a known-clean environment

After reboot:
- Services auto-start via systemd (`WantedBy=multi-user.target`)
- Health check runs exactly **once** per service (one per isolation group)
- E2E tests verify all agents can respond

### 2. Account Name = Agent ID

Bot tokens are stored under accounts named after the agent ID — **never** `default`:

| Agent ID | Account Name | Config Path |
|----------|-------------|-------------|
| `agent1` | `agent1` | `channels.telegram.accounts.agent1.botToken` |
| `agent2` | `agent2` | `channels.telegram.accounts.agent2.botToken` |
| `safe-mode` | `safe-mode` | `channels.telegram.accounts.safe-mode.botToken` |

Using `default` causes two problems:
- `--reply-account agent1` can't find a token named `default`
- Duplicating tokens under both `default` and `agent1` creates **two polling instances** on the same token → Telegram 409 conflicts

### 3. Gateway Must Bind to Loopback

Health check and safe mode recovery use `openclaw agent --deliver` via the CLI. The gateway **must** bind to `loopback` (not `lan`). With `bind: "lan"`, the CLI gets "pairing required" errors because it connects via 127.0.0.1 which doesn't match the LAN binding.

### 4. Permissions Set During Creation

All directories and files are created with correct ownership from the start using `lib-permissions.sh`. No deferred `chown -R` calls. See [Permissions](#permissions).

### 5. Build Failures Must Be Fatal

If `build-full-config.sh` fails during phase2, a `build-failed` marker is written and `phase2-complete` is **never** touched. This prevents the system from rebooting into a broken state.

### 6. Env-Var-Only Timeouts

All health check timeouts are configurable via environment variables with production defaults. Nothing is hardcoded for testing — tests pass env vars, nothing to revert.

---

## Boot Sequence

```
┌──────────────────────────────────────────────────────────────────┐
│                       PHASE 1 (cloud-init)                       │
│                                                                  │
│  cloud-init runcmd → bootstrap.sh → phase1-critical.sh           │
│                                                                  │
│  • Install Node.js, OpenClaw                                     │
│  • Create bot user                                               │
│  • Write emergency config (openclaw.emergency.json)              │
│  • Write minimal config (openclaw.json)                          │
│  • Create bootstrap openclaw.service (NO health check)           │
│  • systemctl ENABLE openclaw (NOT start!)                        │
│  • Fix permissions (lib-permissions.sh)                          │
│  • Launch phase2-background.sh (nohup)                           │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                     PHASE 2 (background)                         │
│                                                                  │
│  phase2-background.sh                                            │
│                                                                  │
│  • Install packages (Chrome, ffmpeg, rclone, etc.)               │
│  • build-full-config.sh (branches by isolation mode):            │
│                                                                  │
│    ┌─ none (single) ─────────────────────────────────────────┐   │
│    │ Rebuild openclaw.service WITH ExecStartPost             │   │
│    │ Generate openclaw-safeguard.path + .service             │   │
│    │ Generate openclaw-e2e.service                           │   │
│    │ systemctl enable all                                    │   │
│    └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│    ┌─ session ───────────────────────────────────────────────┐   │
│    │ generate-session-services.sh:                           │   │
│    │   For each group: openclaw-{group}.service              │   │
│    │                   openclaw-safeguard-{group}.path + svc │   │
│    │                   openclaw-e2e-{group}.service           │   │
│    │   Disable bootstrap openclaw.service                    │   │
│    │   systemctl enable all per-group units                  │   │
│    └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│    ┌─ container ─────────────────────────────────────────────┐   │
│    │ generate-docker-compose.sh:                             │   │
│    │   Per-group Docker containers (health checks TBD)       │   │
│    └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  • Fix all permissions (lib-permissions.sh)                      │
│  • Touch phase2-complete marker                                  │
│  • REBOOT                                                        │
│                                                                  │
│  ⚠️  If build-full-config.sh fails:                              │
│      → Write build-failed marker                                 │
│      → Do NOT touch phase2-complete                              │
│      → Reboot still happens, but no services will start          │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼ REBOOT
                               │
┌──────────────────────────────────────────────────────────────────┐
│                        POST-REBOOT                               │
│                                                                  │
│  systemd starts all enabled services automatically               │
│                                                                  │
│  Per isolation mode:                                             │
│    none:      openclaw.service (rebuilt with health check)        │
│    session:   openclaw-{group}.service per group                 │
│    container: docker compose up                                  │
│                                                                  │
│  Each service's lifecycle (see Architecture Overview below):     │
│    1. Gateway starts (ExecStart)                                 │
│    2. HTTP health check (ExecStartPost) — lightweight            │
│    3. E2E check (separate service) — thorough                    │
│    4. If unhealthy → safeguard handler (triggered by .path)      │
└──────────────────────────────────────────────────────────────────┘
```

### Why Two Phases?

Phase1 runs in cloud-init's `runcmd` context. It installs the minimum needed (Node.js, OpenClaw, jq) and kicks off phase2 as a background process (`nohup`). Phase2 handles everything else — the heavy package installs, config generation, service creation — then triggers the reboot.

The background fork exists because cloud-init has a timeout on `runcmd`. Some package installations (Chrome, LibreOffice, etc.) take long enough to risk hitting that limit.

**Known tradeoff:** The nohup fork creates a race condition — phase2 runs concurrently with the rest of cloud-init's runcmd. This is mitigated by the `phase2-complete` marker file and the reboot gate.

> **Future consideration:** A single-phase `provision.sh` could eliminate the background fork, the dual markers, and the duplicate `apt-get update`, but the **reboot is still required** for the reasons listed in [Design Principles](#design-principles).

---

## Architecture Overview

The health check system uses three separate systemd units per isolation group:

```
openclaw-{group}.service                    ← Main gateway process
  │
  └─ ExecStartPost: gateway-health-check.sh ← HTTP-only, ~100 lines
       │
       ├─ HTTP responds? → exit 0 → service becomes "active"
       │                              │
       │                              ▼
       │                    openclaw-e2e-{group}.service
       │                    (BindsTo main, starts when active)
       │                      │
       │                      ├─ Channel tokens OK?
       │                      ├─ All agents respond to prompts?
       │                      │
       │                      ├─ YES → ✅ Healthy, agents introduce themselves
       │                      │
       │                      └─ NO → writes /var/lib/init-status/unhealthy-{group}
       │                                │
       │                                ▼
       │                      openclaw-safeguard-{group}.path  (watches marker)
       │                        │
       │                        └─ openclaw-safeguard-{group}.service
       │                             │
       │                             └─ safe-mode-handler.sh
       │                                  ├─ Smart recovery (find working creds)
       │                                  ├─ Notify user
       │                                  ├─ Restart service with safe config
       │                                  └─ SafeModeBot introduces itself
       │
       └─ HTTP not responding? → writes unhealthy marker → exit 1
            │                      (also triggers safeguard)
            │
            └─ systemd Restart=on-failure → retries gateway start
```

### Why Three Separate Units?

**Before (monolith):** A single 1500-line `gateway-health-check.sh` ran as `ExecStartPost`. It did HTTP polling, E2E testing, recovery, notifications, config swapping, and service restarts — all in one script. Problems:
- Service stayed in "activating" state for minutes while E2E ran
- Self-referential restarts (`systemctl restart` from inside ExecStartPost) caused SIGTERM races
- No separation between "is the process alive?" and "can agents talk?"
- Difficult to test individual components

**After (three units):**

| Unit | Responsibility | Lines | Runs as |
|------|---------------|-------|---------|
| `gateway-health-check.sh` | HTTP endpoint responding? | ~100 | ExecStartPost (blocking) |
| `gateway-e2e-check.sh` | Agents can actually communicate? | ~350 | Separate oneshot service |
| `safe-mode-handler.sh` | Recovery + notification | ~300 | Triggered by .path watcher |

Benefits:
- Service reaches "active" state quickly (just HTTP check)
- E2E runs asynchronously, doesn't block service status
- Recovery is reactive (triggered by marker file), not inline
- Each component can be tested independently
- No self-referential `systemctl restart` from ExecStartPost

---

## Script Responsibilities

### `gateway-health-check.sh` (~100 lines)

**Purpose:** Verify the gateway HTTP endpoint is alive. Nothing else.

**Called by:** `ExecStartPost` in the main service unit.

**Flow:**
1. Wait `HEALTH_CHECK_SETTLE_SECS` (default: 45s) for gateway to initialize
2. Poll `http://127.0.0.1:${PORT}/` every 5 seconds
3. While polling, check if the gateway process is still alive (`pgrep -f "openclaw.gateway"`)
4. At `HEALTH_CHECK_WARN_SECS` (default: 120s), send a "still waiting" notification
5. At `HEALTH_CHECK_HARD_MAX_SECS` (default: 300s), give up

**Exit codes:**
- `0` — HTTP responding, service becomes "active"
- `1` — Failed, writes unhealthy marker, systemd restarts (`Restart=on-failure`)

**Process-alive detection:** The script tracks whether the gateway process has been seen. If the process was running and then vanishes (crash), it fails immediately. If the process never appears within 60 seconds, it also fails. This prevents waiting 5 minutes for a process that crashed on startup.

### `gateway-e2e-check.sh` (~350 lines)

**Purpose:** Verify agents can actually respond to messages. Runs after the gateway HTTP endpoint is confirmed alive.

**Called by:** `openclaw-e2e-{group}.service` (separate systemd unit, `BindsTo` main service).

**Normal mode flow:**
1. `check_channel_connectivity()` — validate every agent's bot token via API
2. `check_agents_e2e()` — prompt each agent and verify it responds + delivers
3. All pass → mark healthy, agents introduce themselves to the user
4. Any fail → write unhealthy marker (triggers safeguard .path unit)

**Safe mode flow (Run 2):**
1. `check_safe_mode_e2e()` — verify safe-mode agent can respond
2. Pass → mark safe mode stable, SafeModeBot introduces itself
3. Fail → write unhealthy marker again (safeguard will try another recovery attempt)

**Always exits 0** — recovery is handled by the safeguard unit, not this script. It only writes the unhealthy marker file to signal the problem.

### `safe-mode-handler.sh` (~300 lines)

**Purpose:** Handle safe mode entry, credential recovery, and user notification. Completely separated from health checking.

**Triggered by:** `openclaw-safeguard-{group}.path` watching `/var/lib/init-status/unhealthy-{group}`.

**Flow:**
1. Check recovery attempt count (max 2)
2. Source `safe-mode-recovery.sh` (smart credential discovery)
3. Run recovery — find working chat tokens + API keys
4. If recovery fails, fall back to `openclaw.emergency.json`
5. Mark safe mode state
6. Notify user (via raw API — instant, no LLM needed)
7. Generate `BOOT_REPORT.md` for SafeModeBot
8. Restart the gateway service with the safe config
9. SafeModeBot introduces itself with AI-powered diagnostics

**Exit codes:**
- `0` — Recovery succeeded, service restarted
- `1` — Recovery attempted, needs restart (systemd handles)
- `2` — Critical failure after max attempts, gave up

### `lib-health-check.sh` (~150 lines)

**Purpose:** Shared utilities sourced by all health check scripts.

**Provides:**
- `hc_init_logging(group)` — set up log file and run ID
- `hc_load_environment()` — source env files, set up common variables
- `get_owner_id_for_platform(platform)` — resolve owner/user ID
- `hc_is_in_safe_mode()` — check safe mode marker
- `hc_get_recovery_attempts()` — read recovery counter
- All shared variables: `CONFIG_PATH`, `SAFE_MODE_FILE`, `HC_SERVICE_NAME`, etc.

### `lib-notify.sh` (~210 lines)

**Purpose:** Notification library for Telegram and Discord.

**Provides:**
- `validate_telegram_token_direct(token)` — call `getMe`, check response
- `validate_discord_token_direct(token)` — call `/users/@me`, check response
- `notify_find_token()` — search for any working notification token (sets `NOTIFY_PLATFORM`, `NOTIFY_TOKEN`, `NOTIFY_OWNER`)
- `notify_send_message(text)` — send via discovered token (HTML supported for Telegram, auto-converted for Discord)

**Token discovery order:**
1. Safe mode config tokens (if in safe mode)
2. Habitat agent tokens (preferred platform first)
3. Cross-platform fallback (e.g., Telegram failed → try Discord)

### `safe-mode-recovery.sh`

**Purpose:** Smart credential discovery. Finds working chat tokens and API keys from all available sources.

**Token discovery:**
1. Try user's configured platform first (telegram/discord)
2. Try ALL agent tokens on that platform (filtered by GROUP in session isolation)
3. If none work, try fallback platform
4. Record which agent/token works

**API provider discovery:**
1. Try user's configured provider
2. Fallback order: anthropic → openai → google
3. Check OAuth profiles first, then API keys
4. Trust Anthropic OAuth tokens (`sk-ant-oat*`) without API validation

### Deployment Paths

| Script | Installed to |
|--------|-------------|
| `lib-health-check.sh` | `/usr/local/sbin/` |
| `lib-notify.sh` | `/usr/local/sbin/` |
| `lib-permissions.sh` | `/usr/local/sbin/` |
| `gateway-health-check.sh` | `/usr/local/bin/` |
| `gateway-e2e-check.sh` | `/usr/local/bin/` |
| `safe-mode-handler.sh` | `/usr/local/bin/` |
| `safe-mode-recovery.sh` | `/usr/local/bin/` |

---

## Systemd Unit Structure

### Single Mode (`isolation: none`)

```
openclaw.service
  └─ ExecStartPost: gateway-health-check.sh

openclaw-e2e.service
  └─ BindsTo: openclaw.service
  └─ ExecStart: gateway-e2e-check.sh

openclaw-safeguard.path
  └─ PathExists: /var/lib/init-status/unhealthy
  └─ Activates: openclaw-safeguard.service

openclaw-safeguard.service
  └─ ExecStart: safe-mode-handler.sh
```

### Session Mode (`isolation: session`)

Per group (e.g., `browser`, `documents`):

```
openclaw-browser.service
  └─ ExecStartPost: gateway-health-check.sh
  └─ Environment: GROUP=browser, GROUP_PORT=18790

openclaw-e2e-browser.service
  └─ BindsTo: openclaw-browser.service
  └─ ExecStart: gateway-e2e-check.sh
  └─ Environment: GROUP=browser, GROUP_PORT=18790

openclaw-safeguard-browser.path
  └─ PathExists: /var/lib/init-status/unhealthy-browser

openclaw-safeguard-browser.service
  └─ ExecStart: safe-mode-handler.sh
  └─ Environment: GROUP=browser, GROUP_PORT=18790, RUN_MODE=path-triggered
```

### Container Mode (`isolation: container`)

Each Docker container runs its own gateway + health check:

```yaml
services:
  browser:
    container_name: openclaw-browser
    environment:
      - GROUP=browser
      - GROUP_PORT=18789
      - ISOLATION=container
    volumes:
      - /usr/local/bin/gateway-health-check.sh:/usr/local/bin/gateway-health-check.sh:ro
      - /etc/droplet.env:/etc/droplet.env:ro
      - /var/lib/init-status:/var/lib/init-status
```

Recovery uses `docker restart` instead of `systemctl restart`.

> **Note:** Container health checks are not yet fully implemented. The per-group pattern exists but the Docker entrypoint integration is TBD.

### Key Systemd Settings

| Setting | Value | Why |
|---------|-------|-----|
| `Restart` | `on-failure` | Restart on crash, not on clean exit |
| `RestartPreventExitStatus` | `2` | Exit 2 = critical, don't retry |
| `RestartSec` | `10` | Wait 10s between restart attempts |
| `TimeoutStartSec` | `420` | 45s settle + 300s hard max + buffer |
| `TimeoutStartSec` (E2E) | `600` | Agent intros can be slow |
| `BindsTo` (E2E) | main service | E2E dies when main service stops |
| `Requisite` (E2E) | main service | Don't start E2E unless main is active |

**On `Restart=on-failure`:** This means the service **will** restart after crashes, health check failures (exit 1), and unexpected shutdowns. It will **not** restart after:
- Clean `systemctl stop` (exit 0)
- Critical failure with exit code 2
- Config changes applied via `openclaw config.apply` (which does a clean restart internally)

This is safe because OpenClaw's internal config reload (`/config/apply` API) does its own clean restart cycle — it doesn't depend on systemd's restart mechanism.

---

## Health Check Flow

### Stage 1: HTTP Check (ExecStartPost)

The lightest possible check — is the process alive and accepting HTTP?

```
gateway-health-check.sh
│
├─ Skip if recently recovered (within 120s)
│
├─ Wait SETTLE seconds (45s default)
│
├─ Poll http://127.0.0.1:PORT/ every 5s
│   ├─ Track process with pgrep "openclaw.gateway"
│   ├─ Process seen then vanished? → FAIL immediately (crash)
│   ├─ Process never appeared after 60s? → FAIL
│   ├─ At WARN_AT seconds (120s) → send "still waiting" notification
│   └─ At HARD_MAX seconds (300s) → FAIL (timeout)
│
├─ HTTP 200? → exit 0 (service becomes "active")
│
└─ Failed? → write unhealthy marker → exit 1
              (systemd restarts via on-failure)
```

### Stage 2: E2E Agent Check (Separate Service)

Runs only after Stage 1 passes (service is "active").

```
gateway-e2e-check.sh
│
├─ Is this safe mode (Run 2)?
│   └─ YES → check_safe_mode_e2e()
│            │ Prompt safe-mode agent: "Reply HEALTH_CHECK_OK"
│            ├─ Pass → mark stable, SafeModeBot intro → exit 0
│            └─ Fail → write unhealthy marker → exit 0
│
└─ Normal mode:
    │
    ├─ check_channel_connectivity()
    │   │ For each agent in this group:
    │   │   Telegram: curl .../bot{token}/getMe
    │   │   Discord:  curl .../users/@me with Bot token
    │   │   Must have at least one valid token per platform config
    │   │
    │   ├─ All tokens valid → continue to E2E
    │   └─ Any token invalid → write unhealthy marker → exit 0
    │
    └─ check_agents_e2e()
        │ For each agent in this group:
        │   openclaw agent --agent {id} --message "introduce yourself"
        │     --deliver --reply-channel {platform}
        │     --reply-account {id} --reply-to {owner}
        │
        ├─ All respond → ✅ healthy, intros delivered → exit 0
        └─ Any fail → write unhealthy marker → exit 0
```

**Why channel check before E2E?** OpenClaw has a delivery-recovery feature that silently falls back to other accounts when a token fails. Without the explicit token validation, a broken Telegram token is invisible — the agent responds fine (LLM works), and delivery succeeds through another agent's token. The channel check catches broken tokens that OpenClaw's recovery would otherwise mask.

### Stage 3: Safe Mode Recovery (Triggered by .path)

Only runs when an unhealthy marker appears.

```
safe-mode-handler.sh
│
├─ Already exhausted max recovery attempts (2)?
│   └─ YES → 🔴 CRITICAL: notify user, exit 2 (stop permanently)
│
├─ Source safe-mode-recovery.sh
│
├─ Run smart recovery
│   ├─ Find working chat token (by group, preferred platform first)
│   ├─ Find working API key (anthropic → openai → google)
│   ├─ Generate safe mode config
│   │
│   ├─ SUCCESS → apply recovered config
│   └─ FAILED → copy openclaw.emergency.json as fallback
│
├─ Mark safe mode state
├─ Increment recovery counter
│
├─ Send notification (raw API, instant)
│   "⚠️ [Habitat] Entering Safe Mode — SafeModeBot will follow up"
│
├─ Generate BOOT_REPORT.md (diagnostics for SafeModeBot)
│
├─ Restart gateway service with safe config
│   (This triggers ExecStartPost → HTTP check → E2E check (Run 2))
│
├─ Service up? → SafeModeBot intro via openclaw agent --deliver
│   (AI-generated diagnostics: what failed, what's working)
│
└─ Service won't start? → exit 2 (critical)
```

---

## Recovery Flow

### Two Recovery Mechanisms

#### 1. Smart Recovery (Runtime)

Dynamic credential discovery when the health check fails.

**Token search order:**
1. User's configured platform first (telegram/discord)
2. All agent tokens on that platform (filtered by GROUP)
3. Cross-platform fallback

**API key search order:**
1. User's configured provider for agent1
2. Anthropic → OpenAI → Google
3. OAuth profiles checked first, then API keys
4. Anthropic OAuth tokens (`sk-ant-oat*`) trusted without API validation

#### 2. Emergency Config (Static Fallback)

Pre-built config created at boot time by `phase1-critical.sh`. Used when the smart recovery script itself fails (bug, syntax error, all credentials broken).

Uses agent1's **exact** settings:
- Model: `AGENT1_MODEL` (no fallback)
- API key: based on model provider
- Bot token: `AGENT1_BOT_TOKEN` (no searching)

Intentionally simple — no fallback logic means no fallback bugs.

### Recovery Attempt Limits

| Attempt | What Happens |
|---------|-------------|
| 1st | Smart recovery → find working creds → restart |
| 2nd | Smart recovery again → maybe different creds → restart |
| 3rd+ | 🔴 CRITICAL — notify user, stop permanently (exit 2) |

The counter is stored in `/var/lib/init-status/recovery-attempts{-GROUP}` and cleared on successful health check.

---

## Notification Flow

Notifications are sent **once per boot** (duplicate prevention via marker files).

### Scenarios

| Scenario | What User Receives |
|----------|-------------------|
| Healthy boot | Each agent introduces itself (via E2E check delivery) |
| Safe mode recovery works | ⚠️ Script notification (instant) + SafeModeBot intro (AI diagnostics) |
| Everything broken | 🔴 CRITICAL notification only (raw API) |

### Healthy Boot

No separate notification — the E2E check doubles as the intro. Each agent introduces itself through its own bot token during `check_agents_e2e()`:

```bash
openclaw agent --agent "$agent_id" \
  --message "introduce yourself" \
  --deliver --reply-channel "$platform" \
  --reply-account "$agent_id" \
  --reply-to "$owner_id"
```

### Safe Mode Boot (Two Messages)

1. **Script notification** (instant, raw API) — no LLM needed:
   > ⚠️ **[MyHabitat] Entering Safe Mode**
   > Health check failed. Recovering with backup configuration.
   > SafeModeBot will follow up shortly with diagnostics.

2. **SafeModeBot intro** (seconds later, via `openclaw agent --deliver`) — AI-generated:
   > Hi, I'm SafeModeBot running in emergency mode. Your agent1 Telegram token appears invalid (got 404 from getMe). I'm running on Anthropic Claude with a Google API key fallback. Want me to help you generate a new bot token?

Both are needed: the script notification is immediate and guaranteed, while the SafeModeBot intro provides intelligent diagnostics from reading `BOOT_REPORT.md`.

### Critical Failure

Raw API notification only — no bot is available:
> 🔴 **[MyHabitat] CRITICAL FAILURE**
> Gateway failed after 2 recovery attempts. Bot is OFFLINE.
> Check logs: `journalctl -u openclaw-browser -n 50`

### Notification Token Discovery

The notification system tries multiple sources to find a working token (it needs to send even when most credentials are broken):

1. Safe mode config tokens (if recovery already ran)
2. Habitat agent tokens (preferred platform first)
3. Cross-platform fallback (Telegram broken → try Discord)

---

## Isolation Modes

### Universal Pattern

The same scripts run identically in all modes. Every invocation handles **one group**. The only differences are env vars and restart mechanism:

| Mode | Service Name | GROUP | PORT | Restart Method |
|------|-------------|-------|------|---------------|
| `none` (single) | `openclaw` | _(empty)_ | 18789 | `systemctl restart openclaw` |
| `session` | `openclaw-{group}` | e.g., `browser` | 18790+ | `systemctl restart openclaw-browser` |
| `container` | (inside Docker) | e.g., `browser` | 18789 | `docker restart openclaw-browser` |

### Single Mode (`isolation: none`)

One gateway, one set of health check units. `build-full-config.sh` rebuilds the bootstrap service with an ExecStartPost and generates safeguard + E2E units.

### Session Mode (`isolation: session`)

Multiple gateways, one per isolation group. `generate-session-services.sh` creates per-group service units, each with its own:
- Config at `~/.openclaw/configs/{group}/openclaw.session.json`
- State dir at `~/.openclaw-sessions/{group}/`
- Health check, E2E, and safeguard units
- Port assignment (18790, 18791, ...)

**Token filtering:** In session mode, health checks only validate tokens for agents in the current group (via `AGENT{N}_ISOLATION_GROUP` env vars). This prevents false failures from checking tokens belonging to another group.

The bootstrap `openclaw.service` is **disabled** when session services are created — it's replaced by the per-group services.

### Container Mode (`isolation: container`)

Each container runs its own gateway. The health check scripts are mounted as read-only volumes. State directories (`/var/lib/init-status/`) are shared between containers and the host.

> Container health checks are not yet fully implemented. The per-group pattern and Docker compose generation exist, but the entrypoint integration is TBD.

---

## State Files & Paths

### Per-Group State Files

| File | Single Mode | Session Mode |
|------|------------|--------------|
| Safe mode flag | `/var/lib/init-status/safe-mode` | `/var/lib/init-status/safe-mode-{group}` |
| Unhealthy marker | `/var/lib/init-status/unhealthy` | `/var/lib/init-status/unhealthy-{group}` |
| Recovery counter | `/var/lib/init-status/recovery-attempts` | `/var/lib/init-status/recovery-attempts-{group}` |
| Recently recovered | `/var/lib/init-status/recently-recovered` | `/var/lib/init-status/recently-recovered-{group}` |
| Gateway failed | `/var/lib/init-status/gateway-failed` | `/var/lib/init-status/gateway-failed-{group}` |
| Notification marker | `/var/lib/init-status/notification-sent-*` | Same (includes status context) |

### Boot State Files

| File | Purpose |
|------|---------|
| `/var/lib/init-status/boot-complete` | Initial boot + reboot finished |
| `/var/lib/init-status/phase2-complete` | Phase 2 finished (reboot imminent) |
| `/var/lib/init-status/build-failed` | Build pipeline failed (blocks phase2-complete) |
| `/var/lib/init-status/stage` | Current provisioning stage number |
| `/var/lib/init-status/setup-complete` | All health checks passed |

### Config Files

| File | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Active config (single mode) |
| `~/.openclaw/openclaw.full.json` | Full config backup |
| `~/.openclaw/openclaw.emergency.json` | Static fallback (agent1's exact settings) |
| `~/.openclaw/configs/{group}/openclaw.session.json` | Per-group config (session mode) |

### Log Files

| File | Purpose |
|------|---------|
| `/var/log/gateway-health-check.log` | Single mode health check log |
| `/var/log/gateway-health-check-{group}.log` | Per-group health check log |
| `/var/log/safe-mode-diagnostics.txt` | Recovery diagnostics |
| `/var/log/init-stages.log` | Provisioning stage transitions |
| `/var/log/provision.log` | Phase 1+2 provisioning output |

---

## Exit Codes

### gateway-health-check.sh (ExecStartPost)

| Code | Meaning | Systemd Action |
|------|---------|----------------|
| 0 | HTTP responding | Service becomes "active" |
| 1 | HTTP failed | Write unhealthy marker, `Restart=on-failure` |

### gateway-e2e-check.sh (E2E service)

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Always | Writes unhealthy marker if E2E failed; safeguard handles recovery |

### safe-mode-handler.sh (Safeguard service)

| Code | Meaning | Action |
|------|---------|--------|
| 0 | Recovery succeeded, service restarted | Clean exit |
| 1 | Recovery attempted, needs retry | Systemd may restart |
| 2 | Critical failure, gave up | Stop permanently (`RestartPreventExitStatus=2`) |

---

## Permissions

All scripts use `lib-permissions.sh` for centralized, atomic permission management.

### Key Functions

| Function | Purpose |
|----------|---------|
| `ensure_bot_dir <path> [mode]` | Create directory with correct ownership |
| `ensure_bot_file <path> [mode]` | Fix file ownership and permissions |
| `fix_bot_permissions [home]` | Fix ALL standard directories |
| `fix_workspace_permissions [home]` | Fix `clawd/` tree |
| `fix_state_permissions [home]` | Fix `.openclaw*` tree |
| `fix_session_config_dir <dir>` | Fix systemd config directory |

### Permission Model

| Path | Mode | Reason |
|------|------|--------|
| `/home/bot` | 750 | Home dir, no world access |
| `~/.openclaw/` | 700 | Contains credentials |
| `~/.openclaw/*.json` | 600 | Config files with API keys |
| `~/.openclaw/agents/*/agent/auth-profiles.json` | 600 | OAuth tokens |
| `~/clawd/` | 755 | Workspace root |
| `~/clawd/agents/*/` | 755 | Agent workspaces |
| `~/.openclaw-sessions/` | 700 | Session isolation state |
| `/etc/systemd/system/{group}/openclaw.session.json` | 600 | Contains bot tokens |

### Why This Exists

Previously, permissions were set by scattered `chown -R` calls at the end of scripts. This caused a timing bug: services started before the `chown` ran, causing `EACCES: permission denied` errors and false safe mode triggers.

---

## Known Issues & Gotchas

### Anthropic OAuth Tokens
Anthropic OAuth tokens (`sk-ant-oat*`) cannot be validated via API (the `/v1/models` endpoint rejects them). The recovery script trusts them if present. They use `Authorization: Bearer` header, not `x-api-key`.

### OpenClaw Delivery Recovery Masks Broken Tokens
OpenClaw silently falls back to other bot accounts when delivery fails. A broken Telegram token is invisible to the E2E agent check because the agent responds fine (LLM works) and delivery succeeds through another account's token. This is why `check_channel_connectivity()` must run **before** `check_agents_e2e()`.

### iOS Shortcut Config Caching
iOS Shortcuts read files from Dropbox but may use a stale cache. You must open the Dropbox app and let it sync before running the Shortcut. The Shortcut shows a flat file list and cannot navigate subfolders.

### DDNS May Be Stale
Always check the DigitalOcean API for current droplet IPs. `dig +short` may return the old IP from a previous droplet.

### Google Auth in Session Isolation
OpenClaw has a bug where it can't find Google API keys from `auth-profiles.json` in session isolation. Workaround: use Anthropic for safe mode.

### Gateway Process Name
The OpenClaw binary spawns as `openclaw-gateway` (hyphenated). Use `openclaw.gateway` regex for `pgrep` to match both `openclaw-gateway` (binary name) and `openclaw gateway` (command args).

### Config Directory Ownership
Session config directories (`/etc/systemd/system/{group}/` or `~/.openclaw/configs/{group}/`) must be owned by the bot user. OpenClaw creates temporary files for atomic writes, and `EACCES` errors cause plugin auto-enable failures.

### Telegram Bot Rename Rate Limits
`rename-bots.sh` calls the Telegram `setMyName` API with aggressive rate limits (~18 hours between renames). Failures are non-fatal.

---

## Debugging

### Check Health Check Logs

```bash
# Single mode:
sudo cat /var/log/gateway-health-check.log

# Session isolation (per group):
sudo cat /var/log/gateway-health-check-browser.log
sudo cat /var/log/gateway-health-check-documents.log
```

### Check Recovery Diagnostics

```bash
sudo cat /var/log/safe-mode-diagnostics.txt
```

### Check Current State

```bash
# All state files:
ls -la /var/lib/init-status/

# Is safe mode active?
ls /var/lib/init-status/safe-mode*

# Recovery attempts:
cat /var/lib/init-status/recovery-attempts*
```

### Check Services

```bash
# Single mode:
systemctl status openclaw
systemctl status openclaw-e2e
systemctl status openclaw-safeguard.path

# Session mode:
systemctl status openclaw-browser
systemctl status openclaw-e2e-browser
systemctl status openclaw-safeguard-browser.path
```

### Check Config

```bash
# Active model:
jq '.agents.defaults.model' ~/.openclaw/openclaw.json

# Environment keys:
jq '.env | keys' ~/.openclaw/openclaw.json

# Account names:
jq '.channels.telegram.accounts | keys' ~/.openclaw/openclaw.json
```

### Check Permissions

```bash
ls -la ~/clawd/agents/
ls -la ~/.openclaw/
ls -la ~/.openclaw-sessions/        # session isolation only
ls -la ~/.openclaw/configs/          # session configs
```

### Via API (if gateway is running)

```bash
curl http://localhost:18789/status
```

### Collect Full Debug Bundle

```bash
sudo /usr/local/bin/collect-debug-logs.sh > /tmp/debug-bundle.txt
```

---

## Test Habitats

Test configs live in `Droplets/habitats/` on Dropbox:

| Habitat | Tests |
|---------|-------|
| `test-single-basic` | Single agent, all creds valid — should pass |
| `test-single-broken-chat` | Broken bot token — should trigger safe mode |
| `test-single-broken-llm` | Broken API key — should trigger safe mode |
| `test-session-basic` | Session isolation, all valid — should pass |
| `test-session-broken-group` | One group broken, one healthy |
| `test-container-basic` | Container isolation — should pass |
| `test-container-broken` | Container with broken creds |
| `test-multi-platform-fallback` | Telegram broken → Discord fallback |
| `SafeMode-BadToken` | Broken bot token → recovery |
| `SafeMode-DiscordFallback` | Broken Telegram → fallback to Discord |
| `SafeMode-E2E-Test` | E2E health check with safe mode |

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `lib-permissions.sh` | Centralized permission utilities |
| `lib-health-check.sh` | Shared health check utilities (logging, env, variables) |
| `lib-notify.sh` | Notification library (Telegram/Discord) |
| `phase1-critical.sh` | Creates initial configs, enables bootstrap service |
| `phase2-background.sh` | Installs packages, calls build-full-config, reboots |
| `build-full-config.sh` | Builds full config, branches by isolation mode |
| `generate-session-services.sh` | Creates per-group systemd units (session mode) |
| `generate-docker-compose.sh` | Creates per-group containers (container mode) |
| `gateway-health-check.sh` | HTTP-only health check (ExecStartPost) |
| `gateway-e2e-check.sh` | E2E agent verification (separate service) |
| `safe-mode-handler.sh` | Recovery, notification, restart (triggered by .path) |
| `safe-mode-recovery.sh` | Smart credential discovery |
| `generate-boot-report.sh` | Creates diagnostic report for SafeModeBot |
| `setup-safe-mode-workspace.sh` | Creates SafeModeBot workspace and identity |
| `collect-debug-logs.sh` | Collects full debug bundle |
| `rename-bots.sh` | Renames bot usernames on Telegram |
