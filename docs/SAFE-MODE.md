# Smart Safe Mode

When OpenClaw fails to start (bad API key, expired OAuth, invalid bot token), the system automatically recovers by finding working credentials and bringing a diagnostic bot online.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         BOOT SEQUENCE                           │
├─────────────────────────────────────────────────────────────────┤
│  cloud-init → bootstrap.sh → phase1-critical.sh → REBOOT       │
│                                    │                            │
│                         Creates 3 configs:                      │
│                         • openclaw.json (full config)           │
│                         • openclaw.full.json (backup)           │
│                         • openclaw.emergency.json (fallback)    │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AFTER REBOOT                               │
├─────────────────────────────────────────────────────────────────┤
│  systemd starts clawdbot.service                                │
│       │                                                         │
│       ├── ExecStart: openclaw (gateway starts)                  │
│       │                                                         │
│       └── ExecStartPost: gateway-health-check.sh                │
│                │                                                │
│                ▼                                                │
│       ┌─────────────┐                                           │
│       │ Health OK?  │                                           │
│       └──────┬──────┘                                           │
│              │                                                  │
│       ┌──────┴──────┐                                           │
│       │             │                                           │
│      YES           NO                                           │
│       │             │                                           │
│       ▼             ▼                                           │
│   ✅ Ready!    Enter Safe Mode                                  │
│                     │                                           │
│                     ▼                                           │
│              ┌─────────────┐                                    │
│              │Smart Recovery│                                   │
│              └──────┬──────┘                                    │
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
│         (stable)       (give up)                                │
└─────────────────────────────────────────────────────────────────┘
```

## Health Check Validation

The health check validates three things:

1. **HTTP Responsiveness** - Gateway responds on port 18789
2. **Channel Connectivity** - Bot token works (Telegram `getMe` / Discord gateway)
3. **API Key Validity** - Can make actual API call to provider

All three must pass for the config to be considered healthy.

## Two Recovery Mechanisms

### 1. Smart Recovery (Runtime)

**When:** Health check fails at runtime  
**What:** Dynamically finds working credentials  
**Logic:**

```
Token Discovery:
1. Try user's platform first (telegram/discord)
2. Try ALL agent tokens on that platform
3. If none work, try fallback platform
4. Record which agent/token works

API Provider Discovery:
1. Try user's configured provider for agent1
2. Fallback order: anthropic → openai → google
3. Check OAuth profiles first, then API keys
4. Use first provider that responds successfully
```

### 2. Emergency Config (Static Fallback)

**When:** Smart recovery script itself fails (bug, syntax error)  
**What:** Pre-built config created at boot time  
**Logic:**

```
Uses agent1's EXACT settings:
- Model: AGENT1_MODEL (no fallback)
- API Key: Based on model provider (anthropic/openai/google)
- Bot Token: AGENT1_BOT_TOKEN (no searching)
```

The emergency config has **no fallback logic** - it's intentionally simple to minimize potential bugs. If agent1's credentials are broken, the emergency config won't help, but at least it won't make things worse with buggy fallback code.

## Notification Flow

Only **one notification** is sent per boot, reflecting the **final state**:

| Scenario | Run 1 | Run 2 | Notification |
|----------|-------|-------|--------------|
| Full config healthy | ✓ pass | — | ✅ **Ready!** |
| Safe mode recovery works | ✗ fail | ✓ pass | ⚠️ **SAFE MODE** |
| Everything broken | ✗ fail | ✗ fail | 🔴 **CRITICAL** |

**No intermediate notifications** - user isn't confused by "entering safe mode" followed by "ready" messages.

## Exit Codes

| Code | Meaning | Systemd Action |
|------|---------|----------------|
| 0 | Healthy (or safe mode stable) | Service running |
| 1 | Entered safe mode, needs restart | Restart service |
| 2 | Critical failure | Stop (RestartPreventExitStatus=2) |

## Key Files

| File | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Active config (what gateway loads) |
| `~/.openclaw/openclaw.full.json` | Full config backup |
| `~/.openclaw/openclaw.emergency.json` | Static fallback (agent1's exact settings) |
| `/var/lib/init-status/safe-mode` | Flag: currently in safe mode |
| `/var/lib/init-status/recovery-attempts` | Counter: prevents infinite loops |
| `/var/lib/init-status/notification-sent-*` | Prevents duplicate notifications |
| `~/clawd/agents/safe-mode/BOOT_REPORT.md` | Diagnostics for SafeModeBot |
| `/var/log/gateway-health-check.log` | Health check debug log |
| `/var/log/safe-mode-recovery.log` | Recovery debug log |

## SafeModeBot

When safe mode activates, a dedicated **SafeModeBot** comes online:

- **Identity:** Separate workspace at `~/clawd/agents/safe-mode/`
- **Purpose:** Diagnose issues, explain what failed, guide recovery
- **Reads:** `BOOT_REPORT.md` with diagnostic details
- **Model:** Whatever working provider was found (may differ from user's preference)

SafeModeBot knows it's in safe mode and can help the user fix their credentials.

## Scripts

| Script | Purpose |
|--------|---------|
| `phase1-critical.sh` | Creates initial configs including emergency fallback |
| `gateway-health-check.sh` | Validates health, triggers recovery, sends notifications |
| `safe-mode-recovery.sh` | Smart credential discovery and config generation |
| `generate-boot-report.sh` | Creates diagnostic report for SafeModeBot |
| `setup-safe-mode-workspace.sh` | Creates SafeModeBot workspace and identity |

## Debugging

**Check health check log:**
```bash
cat /var/log/gateway-health-check.log
```

**Check recovery log:**
```bash
cat /var/log/safe-mode-recovery.log
```

**Check current state:**
```bash
ls -la /var/lib/init-status/
cat /var/lib/init-status/safe-mode  # empty if in safe mode
```

**Check active config:**
```bash
jq '.agents.defaults.model' ~/.openclaw/openclaw.json
jq '.env | keys' ~/.openclaw/openclaw.json
```

**Via API (if running):**
```bash
curl http://localhost:5111/status
curl http://localhost:5111/log/gateway-health-check
```
