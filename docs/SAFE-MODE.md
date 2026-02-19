# Smart Safe Mode

When OpenClaw fails to start (bad API key, expired OAuth, invalid bot token), the system automatically recovers by finding working credentials and bringing a diagnostic bot online.

## Critical Design Principles

### 1. No Services Before Reboot

**OpenClaw services MUST NOT start until after the post-install reboot.**

During initial boot (phase1 + phase2):
- Services are **enabled** (`systemctl enable`) but **never started**
- `generate-session-services.sh` checks `/var/lib/init-status/boot-complete` — if missing, it only enables
- Config files, workspaces, and state directories are written and prepared
- After phase2 completes, the system reboots

After reboot:
- Services auto-start via systemd (`WantedBy=multi-user.target`)
- Health check runs exactly **once** per service (one per isolation group)
- E2E tests verify all agents can respond

This prevents:
- Race conditions between config generation and service startup
- Multiple health check runs causing duplicate intro messages
- Config overwrites mid-health-check

### 2. Permissions Are Set During Creation

All directories and files are created with correct ownership from the start using `lib-permissions.sh` (see [Permissions Helper](#permissions-helper-lib-permissionssh) below). This avoids the timing bug where services start before a deferred `chown -R` runs.

### 3. Account Name = Agent ID

Bot tokens are stored under accounts named after the agent ID — **never** `default`:

| Mode | Agent ID | Account Name | Config Path |
|------|----------|-------------|-------------|
| Normal | `agent1` | `agent1` | `channels.telegram.accounts.agent1.botToken` |
| Normal | `agent2` | `agent2` | `channels.telegram.accounts.agent2.botToken` |
| Safe mode | `safe-mode` | `safe-mode` | `channels.telegram.accounts.safe-mode.botToken` |

This ensures `--reply-account $agent_id` always finds the correct token. Using `default` causes two problems:
- `--reply-account agent1` can't find a token named `default`
- Duplicating tokens under both `default` and `agent1` creates **two polling instances** on the same token → Telegram 409 conflicts with itself

### 4. Gateway Must Bind to Loopback

Safe mode recovery and health check use `openclaw agent --deliver` via the CLI. The gateway **must** bind to `loopback` (not `lan`) for this to work. With `bind: "lan"`, the CLI gets "pairing required" errors because it connects via 127.0.0.1 which doesn't match the LAN address.

## Boot Sequence

```
┌─────────────────────────────────────────────────────────────────┐
│                    INITIAL BOOT (PHASE 1)                       │
├─────────────────────────────────────────────────────────────────┤
│  cloud-init → bootstrap.sh → phase1-critical.sh                │
│                                    │                            │
│                  • Install Node.js, OpenClaw                    │
│                  • Write emergency config (openclaw.emergency)  │
│                  • Write minimal config (openclaw.json)         │
│                  • Create clawdbot.service                      │
│                  • systemctl ENABLE clawdbot (NOT start!)       │
│                  • Fix permissions (lib-permissions.sh)         │
│                  • Launch phase2-background.sh                  │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    BACKGROUND SETUP (PHASE 2)                   │
├─────────────────────────────────────────────────────────────────┤
│  phase2-background.sh                                           │
│       │                                                         │
│       ├── Install tools (Chrome, ffmpeg, rclone, etc.)          │
│       ├── build-full-config.sh                                  │
│       │     ├── Write full config (openclaw.full.json)          │
│       │     ├── Create agent workspaces (clawd/agents/*)        │
│       │     ├── Create auth-profiles.json                       │
│       │     ├── fix_bot_permissions() ← BEFORE services         │
│       │     └── generate-session-services.sh (if isolation)     │
│       │           ├── Create per-group systemd units            │
│       │           ├── Create state dirs (.openclaw-sessions/)   │
│       │           ├── systemctl ENABLE (NOT start!)             │
│       │           └── Checks /var/lib/init-status/boot-complete │
│       ├── Touch phase2-complete                                 │
│       └── REBOOT                                                │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AFTER REBOOT                               │
├─────────────────────────────────────────────────────────────────┤
│  systemd starts openclaw-{group}.service (or clawdbot.service)  │
│       │                                                         │
│       ├── ExecStart: openclaw gateway --bind loopback           │
│       │                                                         │
│       └── ExecStartPost: gateway-health-check.sh                │
│                │                                                │
│                ▼                                                │
│       ┌────────────────────┐                                    │
│       │ E2E Health Check   │                                    │
│       │ (per isolation     │                                    │
│       │  group)            │                                    │
│       └────────┬───────────┘                                    │
│                │                                                │
│       ┌────────┴────────┐                                       │
│       │                 │                                       │
│      ALL OK         ANY FAILED                                  │
│       │                 │                                       │
│       ▼                 ▼                                       │
│   ✅ Ready!      Enter Safe Mode                                │
│   Agents intro       │                                          │
│   themselves         ▼                                          │
│              ┌──────────────┐                                   │
│              │Smart Recovery│                                   │
│              └──────┬───────┘                                   │
│                     │                                           │
│              ┌──────┴──────┐                                    │
│              │             │                                    │
│           SUCCESS       FAILED                                  │
│              │             │                                    │
│              ▼             ▼                                    │
│         Restart     Use Emergency                               │
│         Gateway     Config                                      │
│              │             │                                    │
│              └──────┬──────┘                                    │
│                     │                                           │
│                     ▼                                           │
│              ┌─────────────┐                                    │
│              │   Run 2     │                                    │
│              │Health Check │                                    │
│              └──────┬──────┘                                    │
│                     │                                           │
│              ┌──────┴──────┐                                    │
│              │             │                                    │
│             OK           FAIL                                   │
│              │             │                                    │
│              ▼             ▼                                    │
│      ⚠️ SAFE MODE    🔴 CRITICAL                                │
│      SafeModeBot      (give up)                                 │
│      introduces                                                 │
│      itself                                                     │
└─────────────────────────────────────────────────────────────────┘
```

## E2E Health Check

The health check is the core of safe mode. It runs two stages in normal mode:

### Stage 1: Chat Token Validation

`check_channel_connectivity()` validates every agent's bot token **before** the E2E check.

This is critical because OpenClaw's delivery-recovery system silently falls back to other accounts when a token fails. Without this step, a broken Telegram token would be invisible — the agent responds fine (LLM works), and delivery succeeds through another account's token.

**Platform selection rules:**
- Only validates tokens for the **configured platform** (`$PLATFORM` from habitat config)
- `platform=telegram` → only checks Telegram tokens
- `platform=discord` → only checks Discord tokens
- `platform=both` → agent needs **at least one** working token
- Tokens for unconfigured platforms are **not checked** (a broken Discord token won't trigger safe mode if platform is telegram-only)

**Per-agent validation:**
- Each agent's token is validated via API (`getMe` for Telegram, `/users/@me` for Discord)
- **Missing token** (empty) → agent fails (treated as broken)
- **Invalid token** (API returns error) → agent fails
- **Any single agent failure** → entire group enters safe mode

```bash
# Telegram: curl https://api.telegram.org/bot${token}/getMe
# Discord:  curl -H "Authorization: Bot ${token}" https://discord.com/api/v10/users/@me
```

### Stage 2: End-to-End Agent Check (Normal Mode)

`check_agents_e2e()` in `gateway-health-check.sh`:

1. For each agent in the current isolation group:
   ```bash
   openclaw agent \
     --agent "$agent_id" \
     --message "introduce yourself" \
     --deliver \
     --reply-channel "$channel" \
     --reply-account "$agent_id" \   # ← ensures correct bot token
     --reply-to "$owner_id" \
     --timeout 60 --json
   ```
2. If exit code is 0 and no error strings in output → agent is healthy
3. **All** agents must pass for the group to be healthy
4. If any agent fails → entire group enters safe mode

### Safe Mode (Recovery Config)

`check_safe_mode_e2e()` in `gateway-health-check.sh`:

1. Sends a simple prompt to the safe-mode agent:
   ```bash
   openclaw agent --agent safe-mode --message "Reply with exactly: HEALTH_CHECK_OK"
   ```
2. Checks that the agent responds (no `--deliver`, just validates it works)
3. If it passes → safe mode is stable, SafeModeBot introduces itself

### Session Isolation

In session isolation mode, each isolation group runs its own gateway on a unique port. The health check runs per-group:

- `GROUP=browser` → checks agents in the browser group (e.g., agent3, agent4)
- `GROUP=documents` → checks agents in the documents group (e.g., agent1, agent2)

Environment variables point to the correct config:
```bash
OPENCLAW_CONFIG_PATH=/etc/systemd/system/{group}/openclaw.session.json
OPENCLAW_STATE_DIR=/home/bot/.openclaw-sessions/{group}
```

### Token Filtering by Group

In session isolation, bot tokens are filtered by group to prevent 409 conflicts:
- `find_working_telegram_token()` only checks tokens from agents in the current `AGENT{N}_ISOLATION_GROUP`
- `find_working_discord_token()` same

## Two Recovery Mechanisms

### 1. Smart Recovery (Runtime)

**When:** Health check fails at runtime  
**What:** Dynamically finds working credentials  
**Script:** `safe-mode-recovery.sh`

```
Token Discovery:
1. Try user's platform first (telegram/discord)
2. Try ALL agent tokens on that platform (filtered by GROUP)
3. If none work, try fallback platform
4. Record which agent/token works

API Provider Discovery:
1. Try user's configured provider for agent1
2. Fallback order: anthropic → openai → google
3. Check OAuth profiles first, then API keys
4. Trust Anthropic OAuth tokens (sk-ant-oat*) without API validation
5. Use first provider that responds successfully

Config Generation:
1. Build emergency config with working token + provider
2. Use loopback bind (required for CLI delivery)
3. Write to CONFIG_PATH
4. Create auth-profiles.json for safe-mode agent
```

### 2. Emergency Config (Static Fallback)

**When:** Smart recovery script itself fails (bug, syntax error)  
**What:** Pre-built config created at boot time by `phase1-critical.sh`

```
Uses agent1's EXACT settings:
- Model: AGENT1_MODEL (no fallback)
- API Key: Based on model provider (anthropic/openai/google)
- Bot Token: AGENT1_BOT_TOKEN (no searching)
```

The emergency config has **no fallback logic** — it's intentionally simple to minimize potential bugs. If agent1's credentials are broken, the emergency config won't help, but at least it won't make things worse with buggy fallback code.

## Notification Flow

Notifications are sent **once per boot** (duplicate prevention via `/var/lib/init-status/notification-sent-*` marker files).

| Scenario | Run 1 | Run 2 | What User Receives |
|----------|-------|-------|-------------------|
| Full config healthy | ✓ pass | — | Each agent introduces itself via E2E check |
| Safe mode recovery works | ✗ fail | ✓ pass | ⚠️ Script notification + SafeModeBot intro |
| Everything broken | ✗ fail | ✗ fail | 🔴 CRITICAL (raw API notification only) |

### Healthy Boot
No separate notification needed — the E2E check doubles as the intro. Each agent introduces itself through its own bot token during `check_agents_e2e()`.

### Safe Mode Boot (two messages)
1. **Script notification** (instant) — sent via raw Telegram/Discord API by the health check script. Simple alert: "Health check failed. SafeModeBot is online to diagnose."
2. **SafeModeBot intro** (seconds later) — sent via `openclaw agent --deliver --reply-account safe-mode`. AI-generated diagnostics: what failed, what's working, offers to help.

Both are needed: the script notification is immediate and guaranteed (no LLM required), while the SafeModeBot intro provides intelligent diagnostics.

### Critical Failure
Raw API notification only — no bot is available to introduce itself.

## SafeModeBot

When safe mode activates, a dedicated **SafeModeBot** comes online:

- **Identity:** Separate workspace at `~/clawd/agents/safe-mode/`
- **Purpose:** Diagnose issues, explain what failed, guide recovery
- **Reads:** `BOOT_REPORT.md` with diagnostic details
- **Model:** Whatever working provider was found (may differ from user's preference)
- **Intro:** Delivered via `--deliver --reply-account safe-mode --reply-channel $platform`

SafeModeBot knows it's in safe mode and can help the user fix their credentials.

## Permissions Helper (lib-permissions.sh)

All scripts that create bot-owned directories or files use `lib-permissions.sh` — a centralized permission utility that ensures correct ownership from the moment of creation.

### Location

- Source: `scripts/lib-permissions.sh`
- Installed to: `/usr/local/sbin/lib-permissions.sh`
- Sourced by: `phase1-critical.sh`, `build-full-config.sh`, `generate-session-services.sh`, `gateway-health-check.sh`, `generate-boot-report.sh`, `safe-mode-recovery.sh`

### Functions

| Function | Purpose | Example |
|----------|---------|---------|
| `ensure_bot_dir <path> [mode]` | Create directory with atomic bot ownership | `ensure_bot_dir "$H/.openclaw" 700` |
| `ensure_bot_file <path> [mode]` | Fix file ownership and permissions | `ensure_bot_file "$config" 600` |
| `fix_bot_permissions [home]` | Fix ALL standard directories (call before services) | `fix_bot_permissions "$H"` |
| `fix_workspace_permissions [home]` | Fix `clawd/` tree (agents, shared, memory) | — |
| `fix_state_permissions [home]` | Fix `.openclaw*` tree (configs, auth, sessions) | — |
| `fix_agent_workspace <dir>` | Fix single agent workspace | `fix_agent_workspace "$H/clawd/agents/agent1"` |
| `fix_session_state <dir>` | Fix session isolation state directory | `fix_session_state "$HOME/.openclaw-sessions/docs"` |
| `fix_session_config_dir <dir>` | Fix systemd config directory | `fix_session_config_dir "/etc/systemd/system/docs"` |

### Design

- Uses `install -d -o bot -g bot -m MODE` for atomic directory creation (correct ownership from the start)
- Falls back to `mkdir + chown + chmod` if `install` fails
- All functions are `export -f`'d so they work in child scripts
- Every script includes a graceful fallback: `if type ensure_bot_dir &>/dev/null; then ... else ... fi`

### Why This Exists

Previously, permissions were set by scattered `chown -R` calls at the end of scripts. This caused a timing bug: `build-full-config.sh` called `generate-session-services.sh` which started services, but the `chown` hadn't run yet. Agents couldn't create `.openclaw` directories in their workspaces, causing `EACCES: permission denied` errors and false safe mode triggers.

The fix: set permissions **during creation** using the helper, and call `fix_bot_permissions()` as a belt-and-suspenders check **before** `generate-session-services.sh` runs.

### Permission Model

| Path | Mode | Reason |
|------|------|--------|
| `/home/bot` | 750 | Home dir, no world access |
| `~/.openclaw/` | 700 | State dir, contains credentials |
| `~/.openclaw/credentials/` | 700 | Credential store |
| `~/.openclaw/*.json` | 600 | Config files with API keys |
| `~/.openclaw/agents/*/agent/auth-profiles.json` | 600 | OAuth tokens, API keys |
| `~/clawd/` | 755 | Workspace root |
| `~/clawd/agents/*/` | 755 | Agent workspaces |
| `~/clawd/agents/*/.openclaw/` | 700 | Agent-local OpenClaw state |
| `~/.openclaw-sessions/` | 700 | Session isolation state |
| `/etc/systemd/system/{group}/` | 755 | Systemd reads these |
| `/etc/systemd/system/{group}/openclaw.session.json` | 600 | Contains bot tokens |

## Exit Codes

| Code | Meaning | Systemd Action |
|------|---------|----------------|
| 0 | Healthy (or safe mode stable) | Service running |
| 1 | Entered safe mode, needs restart | Restart service (`Restart=on-failure`) |
| 2 | Critical failure | Stop permanently (`RestartPreventExitStatus=2`) |

## Key Files

| File | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Active config (what gateway loads) |
| `~/.openclaw/openclaw.full.json` | Full config backup |
| `~/.openclaw/openclaw.emergency.json` | Static fallback (agent1's exact settings) |
| `/var/lib/init-status/boot-complete` | Flag: initial boot + reboot finished |
| `/var/lib/init-status/safe-mode-{group}` | Flag: group is in safe mode |
| `/var/lib/init-status/recovery-attempts` | Counter: prevents infinite loops |
| `/var/lib/init-status/notification-sent-*` | Prevents duplicate notifications |
| `/var/lib/init-status/phase2-complete` | Phase 2 finished (reboot imminent) |
| `~/clawd/agents/safe-mode/BOOT_REPORT.md` | Diagnostics for SafeModeBot |
| `/var/log/gateway-health-check-{group}.log` | Per-group health check log |
| `/var/log/safe-mode-diagnostics.txt` | Recovery diagnostics summary |

## Scripts

| Script | Purpose |
|--------|---------|
| `lib-permissions.sh` | Centralized permission utilities (sourced by all others) |
| `phase1-critical.sh` | Creates initial configs, enables service, launches phase2 |
| `build-full-config.sh` | Builds complete config, calls generate-session-services |
| `generate-session-services.sh` | Creates per-group systemd units, enables (not starts during boot) |
| `gateway-health-check.sh` | E2E validation, triggers recovery, sends notifications |
| `safe-mode-recovery.sh` | Smart credential discovery and config generation |
| `generate-boot-report.sh` | Creates diagnostic report for SafeModeBot |
| `setup-safe-mode-workspace.sh` | Creates SafeModeBot workspace and identity |

## Known Issues & Gotchas

### Anthropic OAuth Tokens
Anthropic OAuth tokens (`sk-ant-oat*`) cannot be validated via API (the `/v1/models` endpoint rejects them). The recovery script trusts them if present. They use `Authorization: Bearer` header, not `x-api-key`.

### Google Auth in Session Isolation
OpenClaw has a bug where it can't find Google API keys from `auth-profiles.json` when running in session isolation mode. Workaround: use Anthropic for safe mode instead of Google.

### iOS Shortcut Config Upload
The iOS Shortcut calls `/config/apply` during phase2. `apply-config.sh` checks for `phase2-complete` before restarting services to prevent premature starts. If phase2 isn't complete, it saves the config but skips the restart.

### Telegram Bot Rename Rate Limits
`rename-bots.sh` calls the Telegram `setMyName` API. This has aggressive rate limits (~18 hours between renames). Failures are non-fatal and logged.

## Debugging

**Check health check log:**
```bash
# Per-group logs (session isolation):
sudo cat /var/log/gateway-health-check-browser.log
sudo cat /var/log/gateway-health-check-documents.log

# Single-agent log:
sudo cat /var/log/gateway-health-check.log
```

**Check recovery log:**
```bash
sudo cat /var/log/safe-mode-diagnostics.txt
```

**Check current state:**
```bash
ls -la /var/lib/init-status/
```

**Check active config:**
```bash
jq '.agents.defaults.model' ~/.openclaw/openclaw.json
jq '.env | keys' ~/.openclaw/openclaw.json
```

**Check permissions:**
```bash
ls -la ~/clawd/agents/
ls -la ~/.openclaw/
ls -la ~/.openclaw-sessions/  # session isolation only
```

**Via API (if running):**
```bash
curl http://localhost:5111/status
curl http://localhost:5111/log/gateway-health-check
```

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
