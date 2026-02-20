# Simplification Plan: Boot & Health Check Architecture

> Branch: `experiment/single-phase-boot`
> Status: Planning
> Author: Claude (architectural review, Feb 20 2026)
> Related: [SAFE-MODE-V2.md](SAFE-MODE-V2.md) (current architecture reference)

## Motivation

The current boot and health check pipeline spans **5,600 lines across 14 scripts**. A deep review found several areas where the architecture can be significantly simplified while keeping the same high-level goals:

1. **Bot comes online reliably** after droplet provisioning
2. **Broken credentials are detected** via E2E health checks
3. **Automatic recovery** finds working credentials and brings SafeModeBot online
4. **User is notified** of problems and can get AI-powered diagnostics

The iOS Shortcut already provides excellent progress notifications during provisioning (progress bar, per-stage updates), so the server-side UX focus should be on the **post-reboot** experience: fast startup, fast health checks, and clear safe mode messaging.

---

## Table of Contents

1. [Changes Overview](#changes-overview)
2. [Phase 1: Single-Phase Provisioning](#phase-1-single-phase-provisioning)
3. [Phase 2: Unified Config Generator](#phase-2-unified-config-generator)
4. [Phase 3: Slim Down Recovery](#phase-3-slim-down-recovery)
5. [Phase 4: Health Check Refinements](#phase-4-health-check-refinements)
6. [Phase 5: Shared Libraries](#phase-5-shared-libraries)
7. [Testing Plan](#testing-plan)
8. [Migration & Backwards Compatibility](#migration--backwards-compatibility)
9. [Estimated Impact](#estimated-impact)

---

## Changes Overview

| # | Change | Effort | Impact | Phase |
|---|--------|--------|--------|-------|
| 1 | Reduce health check settle time (45s → 10s) | Trivial | 🟢 Medium | — (ship now) |
| 2 | Create `lib-env.sh` (shared env loading) | Low | 🟢 Low | 5 |
| 3 | Unified config generator (`generate-config.sh`) | Medium | 🔴 High | 2 |
| 4 | Split `build-full-config.sh` responsibilities | Low-Med | 🟡 Medium | 2 |
| 5 | Extract shared auth to `lib-auth.sh` (incl. OAuth headers), slim recovery | Medium | 🟠 High | 3 |
| 6 | Single-phase provisioning (eliminate background fork) | Medium | 🔴 High | 1 |
| 7 | Separate E2E test prompt from agent intro | Low | 🟡 Medium | 4 |
| 8 | Unify E2E normal/safe-mode paths | Low | 🟡 Low | 4 |
| 9 | Reduce `TimeoutStartSec` (420s → 180s for HTTP check) | Trivial | 🟢 Low | — (ship with #1) |
| 10 | Add fatal guards for missing library sources | Low | 🟢 Medium | 5 |
| 11 | Fix `local_*` naming in `safe-mode-handler.sh` | Low | 🟢 Low | 3 |

**Priority order:** 1 → 2 → 3 → 5 → 6 → 7 (per ChatGPT review — config DRY problem causes real bugs *now*; provisioning fork is ugly but functional)

**Dropped:**
- Server-side progress notifications — iOS Shortcut already provides a full progress bar with per-stage updates
- Emergency config — **consider dropping after Phase 2** lands. Smart recovery already tries every credential. Emergency config only helps if the full config has *structural* corruption (bad JSON), but `generate-config.sh` with jq should make that impossible. Keep for now as a safety net, revisit later.

**Deferred:**
- `run-integration-tests.sh` — referenced as the E2E test runner but needs its own task/PR. Minimum viable: bash script that provisions a test droplet, runs health check scenarios, reports pass/fail.

---

## Phase 1: Single-Phase Provisioning

### Problem

The current boot flow uses a fragile two-phase pattern:

```
cloud-init runcmd
  └─ phase1-critical.sh
       ├─ Install Node, OpenClaw, create user
       ├─ Create bootstrap openclaw.service (never used — services don't start until reboot)
       ├─ nohup phase2-background.sh &    ← BACKGROUND FORK (race condition)
       └─ return to cloud-init
  
phase2-background.sh (running concurrently with cloud-init)
  ├─ killall apt   ← symptom of the race
  ├─ apt-get update (2nd time)
  ├─ Install desktop, tools, browser
  ├─ build-full-config.sh
  ├─ Touch phase2-complete
  └─ reboot
```

Problems:
- Background fork creates race conditions with cloud-init's own package management
- `killall apt` at the top of phase2 is a band-aid for the race
- Two `apt-get update` calls (one in phase1, one in phase2)
- Bootstrap `openclaw.service` is created but never started (services wait for reboot)
- Three marker files (`phase1-complete`, `phase2-complete`, `boot-complete`) gate different behaviors
- `generate-session-services.sh` checks `boot-complete` to decide enable-only vs start

### Solution

Replace `phase1-critical.sh` + `phase2-background.sh` with a single `provision.sh`:

```
cloud-init runcmd
  └─ bootstrap.sh → provision.sh (sequential, no fork)
       ├─ Stage 1: Parse config, install Node/jq
       ├─ Stage 2: Install OpenClaw, create user
       ├─ Stage 3: Install ALL packages (single apt-get)
       ├─ Stage 4: Configure desktop services
       ├─ Stage 5: Configure apps (skills, email, calendar)
       ├─ Stage 6: Build configs, generate services (enable only)
       ├─ Stage 7: Write emergency config, fix permissions
       └─ REBOOT

Post-reboot:
  systemd starts enabled services → health check → E2E → safeguard
```

### What Gets Eliminated

| Eliminated | Why It's Safe |
|-----------|--------------|
| `nohup` background fork | Sequential execution, no race |
| `killall apt` hack | No concurrent apt processes |
| 2nd `apt-get update` | Single combined package install |
| Bootstrap `openclaw.service` | Never started anyway; real services created in Stage 6 |
| `phase1-complete` marker | Not needed — provision.sh is atomic |
| `phase2-complete` marker | Replaced by `provision-complete` (or just reboot) |
| `boot-complete` gate in `generate-session-services.sh` | Services are always enable-only during provisioning; `START_SERVICES=true` env var for post-boot config updates |
| `set-phase.sh` calls | Stages reported via `set-stage.sh` (already used) |

### What Stays

| Kept | Why |
|------|-----|
| **Reboot** | Packages need kernel modules, systemd needs daemon-reload, clean state required |
| **`set-stage.sh`** | iOS Shortcut polls the stage API for progress bar |
| **`build-failed` marker** | If config generation fails, don't reboot into a broken state |
| **`bootstrap.sh`** | Entry point that fetches hatchery release, hands off to provision.sh |

### Implementation Steps

1. **Fix `provision.sh`** — the prototype (commit `2d549c6`) ends with `systemctl start` instead of `reboot`. **Must restore the reboot.** Remove `killall apt` — it's no longer needed since there's no concurrent apt (the `systemctl stop apt-daily.timer` before the install is sufficient).
2. **Update `bootstrap.sh`** — detect `provision.sh` and use it; fall back to legacy `phase1-critical.sh` for backwards compat
3. **Update `generate-session-services.sh`** — replace `boot-complete` check with `START_SERVICES` env var (already done in prototype)
4. **Keep legacy scripts** — `phase1-critical.sh` and `phase2-background.sh` remain for older hatchery versions; `bootstrap.sh` auto-detects
5. **Update `hatch.yaml`** — add `provision.sh` to the scripts fetched during cloud-init
6. **Update stage numbers** — align with new 10-stage plan, update Shortcut dictionary

### Stage Mapping (iOS Shortcut)

The iOS Shortcut polls the stage API and displays progress. The stage→label dictionary in the Shortcut is **easy to update**, so stage numbers and labels are NOT a hard contract. The only real constraint:

> **The user should see a progress update roughly every 60 seconds or less.**

With ~8-9 minutes of provisioning, that means ~8-10 stages minimum. Stages can be added, removed, renumbered, or relabeled freely — just update the Shortcut dictionary to match.

**`provision.sh` stages:**

| Stage | Description | Est. Duration |
|-------|-------------|---------------|
| 1 | Parsing config, installing Node | ~30s |
| 2 | Installing OpenClaw, creating user | ~45s |
| 3 | Installing packages (desktop + tools + browser) | ~3-4 min |
| 4 | Configuring desktop & remote access | ~30s |
| 5 | Installing skills & apps | ~60s |
| 6 | Building configs & generating services | ~15s |
| 7 | Fixing permissions, rebooting | ~30-60s |
| 8 | ✅ Health check passed / ⚠️ Safe mode / ❌ Critical | post-reboot |

**Problem:** Stage 3 (package install) takes 3-4 minutes — too long without updates. Split it:

| Stage | Description | Est. Duration |
|-------|-------------|---------------|
| 1 | Parsing config, installing Node | ~30s |
| 2 | Installing OpenClaw | ~45s |
| 3 | Installing desktop environment | ~60-90s |
| 4 | Installing developer tools | ~60s |
| 5 | Installing browser & pip packages | ~45s |
| 6 | Configuring desktop & remote access | ~30s |
| 7 | Installing skills & apps | ~60s |
| 8 | Building configs & generating services | ~15s |
| 9 | Rebooting... | ~30-60s |
| 10 | ✅ Complete / ⚠️ Safe mode / ❌ Critical | post-reboot |

That's 10 stages, each under 90s. The Shortcut just needs a matching dictionary with 10 entries + whatever post-reboot statuses are desired (safe mode, critical, testing RDP, testing DNS, etc.).

**Special post-reboot stages** (set by health check scripts, not provision.sh):

| Stage | Meaning |
|-------|---------|
| 10 | ✅ Health check passed, all agents online |
| 11 | ⚠️ Safe mode triggered |
| 12 | ❌ Critical failure, bot offline |

---

## Phase 2: Unified Config Generator

### Problem

OpenClaw JSON configs are generated in **5 separate places**, each hand-assembling JSON via bash string interpolation:

| Script | Config Type | Lines |
|--------|------------|-------|
| `phase1-critical.sh` | Bootstrap minimal | ~60 |
| `phase1-critical.sh` | Emergency fallback | ~40 |
| `build-full-config.sh` | Full production | ~90 |
| `generate-session-services.sh` | Per-group session | ~45 |
| `safe-mode-recovery.sh` `generate_emergency_config()` | Recovery emergency | ~120 |

When the config schema changes (new field, renamed key, new platform), you update 5 places. Each uses slightly different patterns for the same structures (`channels.telegram.accounts`, `agents.list`, `gateway` block).

### Solution

Single `generate-config.sh` script that uses `jq` to build configs:

```bash
generate-config.sh --mode full          # Full production config
generate-config.sh --mode minimal       # Bootstrap (phase1 equivalent)
generate-config.sh --mode emergency     # Static fallback
generate-config.sh --mode session --group browser --port 18790
generate-config.sh --mode safe-mode --token "..." --provider anthropic
```

### Design

```bash
#!/bin/bash
# generate-config.sh — Single source of truth for OpenClaw config generation

source /usr/local/sbin/lib-env.sh

MODE="${1:?Usage: generate-config.sh --mode <full|minimal|emergency|session|safe-mode>}"

# Base config (common to all modes)
base_config() {
  jq -n \
    --arg port "${PORT:-18789}" \
    --arg bind "loopback" \
    --arg token "$(cat ~/.openclaw/gateway-token.txt 2>/dev/null || openssl rand -hex 16)" \
    '{
      gateway: { mode: "local", port: ($port|tonumber), bind: $bind,
                 auth: { mode: "token", token: $token } }
    }'
}

# Add agents to config
add_agents() {
  local config="$1" mode="$2" group="${3:-}"
  # ... iterate AGENT{N}_* vars, filter by group if session mode
  # Build agents.list array via jq
}

# Add channels to config  
add_channels() {
  local config="$1" mode="$2" group="${3:-}"
  # ... build telegram/discord channel blocks via jq
  # One place for account naming (agent1, agent2, safe-mode)
}

# Mode-specific assembly
case "$MODE" in
  full)     base_config | add_agents - full | add_channels - full | add_env - full ;;
  minimal)  base_config | add_agents - minimal | add_channels - minimal ;;
  session)  base_config | add_agents - session "$GROUP" | add_channels - session "$GROUP" ;;
  # ...
esac
```

### What This Fixes

- **Single source of truth** for config schema — change once, all modes get the fix
- **No bash string interpolation for JSON** — `jq` handles quoting, escaping, validation
- **Config validation built in** — `jq` fails on bad JSON (no more "write corrupt config, debug later")
- **Testable in isolation** — can unit test each mode without running the full provisioning pipeline

### Implementation Steps

1. **Create `generate-config.sh`** with `jq`-based config assembly
2. **Create helper functions** for each config section (agents, channels, env, gateway, etc.)
3. **Replace heredocs in `phase1-critical.sh`** (or `provision.sh`) with calls to `generate-config.sh --mode minimal` and `--mode emergency`
4. **Replace heredoc in `build-full-config.sh`** with call to `generate-config.sh --mode full`
5. **Replace heredoc in `generate-session-services.sh`** with call to `generate-config.sh --mode session --group $group`
6. **Replace `generate_emergency_config()` in `safe-mode-recovery.sh`** with call to `generate-config.sh --mode safe-mode`
7. **Split `build-full-config.sh`** workspace generation into `setup-workspaces.sh`

### Split `build-full-config.sh`

Current `build-full-config.sh` (574 lines) does config generation AND workspace setup AND systemd unit generation. After extracting config generation to `generate-config.sh`:

| Script | Responsibility | Est. Lines |
|--------|---------------|------------|
| `generate-config.sh` | All JSON config generation | ~250 |
| `setup-workspaces.sh` | Agent dirs, IDENTITY.md, SOUL.md, AGENTS.md, BOOT.md, BOOTSTRAP.md, USER.md, auth-profiles, safe-mode workspace, council setup | ~250 |
| `build-full-config.sh` | Orchestrator: call generate-config, setup-workspaces, generate systemd units, fix permissions, call generate-session-services if needed | ~150 |

---

## Phase 3: Slim Down Recovery

### Problem

`safe-mode-recovery.sh` is **1,461 lines** with 28 functions. It reimplements token validation, API key checking, and notification that already exist in `lib-notify.sh` and `gateway-e2e-check.sh`. Much of the complexity is in `generate_emergency_config()` (122 lines) which will be replaced by `generate-config.sh`.

### Solution

1. **Create `lib-auth.sh`** — shared authentication/validation library
2. **Slim `safe-mode-recovery.sh`** to orchestration only (~400-500 lines)

### `lib-auth.sh` Contents

Extract from `safe-mode-recovery.sh` and `gateway-e2e-check.sh`:

```bash
# Token validation
validate_telegram_token()     # Merged from recovery + lib-notify versions
validate_discord_token()      # Merged from recovery + lib-notify versions
validate_api_key()            # Provider-aware validation (anthropic/openai/google)

# Auth header construction
get_auth_header()             # Returns correct header for provider+token
                              # sk-ant-oat* → "Authorization: Bearer $token"
                              # anthropic   → "x-api-key: $token"
                              # openai      → "Authorization: Bearer $token"
                              # google      → (query param, not header)
                              # Currently duplicated in 3+ places

# Token discovery
find_working_telegram_token() # Search all agents for working token (group-aware)
find_working_discord_token()  # Same for Discord
find_working_platform_token() # Try preferred platform, then fallback

# API provider discovery
find_working_api_provider()   # Try providers in fallback order
check_oauth_profile()         # Validate OAuth token
get_provider_from_model()     # "anthropic/claude-3" → "anthropic"
get_provider_order()          # User's preferred → anthropic → openai → google
```

### What Stays in `safe-mode-recovery.sh`

Just the recovery orchestration:
- `run_smart_recovery()` — the main recovery flow
- `run_full_recovery_escalation()` — escalation with doctor fix
- `setup_safe_mode_workspace()` — already being moved to separate script
- `write_diagnostics_summary()` — diagnostics output
- `check_network()` — connectivity check
- `clear_corrupted_state()` — state cleanup

Config generation moves to `generate-config.sh`. Validation moves to `lib-auth.sh`. Notification moves to `lib-notify.sh`.

### Code Quality: Fix `local_*` Naming in `safe-mode-handler.sh`

`safe-mode-handler.sh` uses variables named `local_output`, `local_exit`, `local_status`, `local_owner_id` at the **top-level script scope** — not inside functions. The `local` keyword only works inside bash functions, so these are actually globals with misleading names.

Fix: Either wrap the recovery/restart/intro logic in proper functions (preferred — improves testability) or rename to `handler_output`, `sm_exit`, etc. This should be done as part of the Phase 3 refactor since we're already touching this file.

### Estimated Reduction

| Component | Before | After |
|-----------|--------|-------|
| `safe-mode-recovery.sh` | 1,461 lines | ~400 lines |
| `lib-auth.sh` | (new) | ~300 lines |
| `gateway-e2e-check.sh` `check_api_key_validity()` | 68 lines | Calls `lib-auth.sh` (~10 lines) |
| `gateway-e2e-check.sh` `check_channel_connectivity()` | 52 lines | Calls `lib-auth.sh` (~15 lines) |
| `lib-notify.sh` token validation | 45 lines | Calls `lib-auth.sh` (wrappers) |

Net: ~1,600 lines → ~750 lines. More importantly, **one implementation of each validation function**.

---

## Phase 4: Health Check Refinements

### 4a: Reduce Settle Time (45s → 10s) + TimeoutStartSec (420s → 180s)

**Current:** `HEALTH_CHECK_SETTLE_SECS=45` — pure sleep before first HTTP probe.

**Why it was 45s:** One droplet needed 63s for gateway "Doctor changes" config migration. The settle time was set high to avoid false failures.

**Why 10s is safe:** The adaptive polling already handles this. After the settle period, the script polls every 5s and keeps going as long as the gateway process is alive (up to `HARD_MAX=300s`). A 10s settle + adaptive polling covers the same cases with 35s less latency on normal boots.

**Change:**
```bash
SETTLE="${HEALTH_CHECK_SETTLE_SECS:-10}"   # was 45
```

One line change. Saves 35 seconds on every clean boot.

Also reduce `TimeoutStartSec` from 420s to 180s. The 420s value was sized for the old monolith that did E2E+recovery inline in ExecStartPost. With the decomposed three-unit design, the HTTP-only ExecStartPost should complete in ~105s worst case (10s settle + 60s no-process timeout + buffer). The E2E service already has its own `TimeoutStartSec=600` which is correctly sized for agent intros.

```bash
TimeoutStartSec=180   # was 420, sized for old monolith
```

### 4b: Separate E2E Test from Agent Intro

> **Status:** Plan only — code not yet implemented. The `gateway-e2e-check.sh` on this branch still sends `"introduce yourself"` with `--deliver`. This will be implemented in PR 6.

**Current:** The E2E check sends `"introduce yourself"` as the test prompt with `--deliver`, so the health check IS the boot greeting. Problems:
- Re-running health checks (e.g., after config update) re-sends intros
- Can't change the test prompt without changing the greeting
- Notification markers try to prevent duplicates but are per-boot only

**Proposed flow:**

```
check_agents_e2e():
  For each agent:
    1. Test prompt: "Reply with exactly: HEALTH_CHECK_OK"
       --timeout 30 --json (no --deliver)
    2. Check response contains "HEALTH_CHECK_OK"
    3. If ALL pass → mark healthy

send_agent_intros():  (new, separate function)
  If this is a fresh boot (not re-check):
    For each agent:
      "introduce yourself" --deliver --reply-channel ...
```

Benefits:
- Health check is fast (~10s per agent vs ~30s with delivery)
- Intros only fire once on fresh boot
- Health checks can be re-run safely (e.g., after config updates via API)
- Test is deterministic ("HEALTH_CHECK_OK") vs hoping the intro doesn't contain error strings

### 4c: Unify Normal/Safe-Mode E2E Paths

**Current:** Two separate functions:
- `check_agents_e2e()` — iterates agents in group, full E2E
- `check_safe_mode_e2e()` — just tests `safe-mode` agent

**Proposed:** Single function that takes an agent list:
```bash
check_agents_e2e() {
  local agents=("$@")
  # If no args, auto-discover from group
  [ ${#agents[@]} -eq 0 ] && agents=($(get_agents_for_group))
  
  for agent_id in "${agents[@]}"; do
    # Same validation logic for all agents
  done
}

# In main:
if hc_is_in_safe_mode; then
  check_agents_e2e "safe-mode"
else
  check_channel_connectivity && check_agents_e2e
fi
```

Small change, eliminates a ~20-line function and the conceptual split.

---

## Phase 5: Shared Libraries

### Create `lib-env.sh`

10 scripts each define their own `d()` base64 decoder and `source /etc/droplet.env`. Extract to shared library:

```bash
#!/bin/bash
# lib-env.sh — Shared environment loading

# Base64 decode helper
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

# Load standard env files
env_load() {
  [ -f /etc/droplet.env ] && { set -a; source /etc/droplet.env; set +a; }
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
}

# Decode common API keys from base64
env_decode_keys() {
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(d "${ANTHROPIC_KEY_B64:-}")}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$(d "${OPENAI_KEY_B64:-}")}"
  export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$(d "${GOOGLE_API_KEY_B64:-}")}"
  export BRAVE_API_KEY="${BRAVE_API_KEY:-$(d "${BRAVE_KEY_B64:-}")}"
}
```

### Library Hierarchy

After all phases, the library structure would be:

```
/usr/local/sbin/
  lib-env.sh              — env loading, base64 decode
  lib-auth.sh             — token/API validation, provider discovery
  lib-notify.sh           — Telegram/Discord notification (uses lib-auth for validation)
  lib-health-check.sh     — health check utilities (uses lib-env)
  lib-permissions.sh      — file/dir ownership utilities
```

Each library sources its dependencies:
```
lib-notify.sh     → sources lib-auth.sh (for validate_*_token)
lib-auth.sh       → sources lib-env.sh (for d(), env_load)
lib-health-check  → sources lib-env.sh (for env loading)
```

### Library Sourcing: Fatal Guards

The current code uses a search loop to find libraries but continues silently if none is found, causing cryptic undefined function errors later. All library sourcing must have a fatal guard:

```bash
# Current (fragile):
for lib_path in /usr/local/sbin /usr/local/bin ...; do
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
# If none found, execution continues with undefined functions...

# Fixed:
for lib_path in /usr/local/sbin /usr/local/bin ...; do
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
type hc_init_logging &>/dev/null || { echo "FATAL: lib-health-check.sh not found" >&2; exit 1; }
```

Apply this pattern to all library sourcing in all scripts.

---

## Testing Plan

### Existing Test Coverage

Currently: **904 tests passing, 3 skipped** across the test suite. Tests cover:
- Config generation (JSON validity, field presence)
- Service file generation (systemd units)
- Health check scenarios (mocked)
- Session isolation (per-group)
- Boot markers and stage transitions
- ShellCheck compliance

### New Tests Required

#### Phase 1: Single-Phase Provisioning

| Test | What It Validates |
|------|------------------|
| `test_provision_stages` | All 7 stages execute in order |
| `test_provision_reboot_at_end` | Script ends with reboot (not mid-script) |
| `test_provision_build_failure_blocks_reboot` | `build-failed` marker prevents reboot |
| `test_provision_stage_api_compatibility` | Stage numbers match what iOS Shortcut expects |
| `test_provision_no_service_start` | No `systemctl start openclaw` during provisioning |
| `test_provision_services_enabled` | All services `systemctl enable`'d before reboot |
| `test_provision_single_apt_update` | Only one `apt-get update` call |
| `test_provision_no_background_fork` | No `nohup`, no `disown`, no `&` |
| `test_bootstrap_legacy_fallback` | `bootstrap.sh` falls back to `phase1-critical.sh` when `provision.sh` absent |
| `test_provision_replaces_phases` | When `provision.sh` exists, `phase1` + `phase2` are not called |

#### Phase 2: Unified Config Generator

| Test | What It Validates |
|------|------------------|
| `test_generate_config_minimal` | Minimal mode produces valid JSON with gateway + 1 agent |
| `test_generate_config_full` | Full mode includes all agents, channels, env, browser, skills |
| `test_generate_config_session` | Session mode filters agents by group, correct port |
| `test_generate_config_emergency` | Emergency mode uses agent1's exact settings |
| `test_generate_config_safe_mode` | Safe mode uses provided token + provider |
| `test_generate_config_account_names` | Account names match agent IDs (never "default") |
| `test_generate_config_loopback_bind` | All modes use `bind: "loopback"` |
| `test_generate_config_multi_agent` | 3-agent habitat produces correct accounts + bindings |
| `test_generate_config_platform_telegram` | Telegram-only: discord disabled |
| `test_generate_config_platform_discord` | Discord-only: telegram disabled |
| `test_generate_config_platform_both` | Both platforms enabled |
| `test_generate_config_json_escaping` | Special characters in names/tokens properly escaped |
| `test_generate_config_idempotent` | Running twice produces identical output |
| `test_old_heredocs_removed` | No more `cat > ... <<CFG` patterns in phase/build scripts |

#### Phase 3: Shared Auth Library

| Test | What It Validates |
|------|------------------|
| `test_lib_auth_validate_telegram` | Valid/invalid/empty tokens |
| `test_lib_auth_validate_discord` | Valid/invalid/empty tokens |
| `test_lib_auth_validate_api_key` | Each provider (anthropic, openai, google) |
| `test_lib_auth_oauth_trust` | `sk-ant-oat*` tokens trusted without API call |
| `test_lib_auth_find_working_token_group_filter` | Only returns tokens for agents in current GROUP |
| `test_lib_auth_provider_fallback_order` | Tries user's provider → anthropic → openai → google |
| `test_lib_auth_cross_platform_fallback` | Telegram broken → tries Discord |
| `test_recovery_uses_lib_auth` | `safe-mode-recovery.sh` sources `lib-auth.sh`, no local copies |
| `test_e2e_uses_lib_auth` | `gateway-e2e-check.sh` sources `lib-auth.sh` |
| `test_recovery_line_count` | `safe-mode-recovery.sh` < 600 lines (enforced ceiling) |

#### Phase 4: Health Check Refinements

| Test | What It Validates |
|------|------------------|
| `test_settle_time_default` | Default settle is 10s (not 45s) |
| `test_settle_time_env_override` | `HEALTH_CHECK_SETTLE_SECS=5` works |
| `test_e2e_test_prompt_no_deliver` | Test phase doesn't use `--deliver` |
| `test_e2e_intro_separate` | Intro only runs after test passes, only on fresh boot |
| `test_e2e_recheck_no_intro` | Re-running health check doesn't re-send intros |
| `test_e2e_unified_safe_mode` | Safe mode uses same `check_agents_e2e` with `safe-mode` arg |
| `test_health_check_ok_response` | Checks for "HEALTH_CHECK_OK" in response |

#### Phase 5: Shared Libraries

| Test | What It Validates |
|------|------------------|
| `test_lib_env_d_function` | Base64 decode works, empty input returns empty |
| `test_lib_env_load` | Sources both env files |
| `test_lib_env_decode_keys` | Decodes all API keys from B64 |
| `test_no_local_d_functions` | No scripts define their own `d()` (except lib-env.sh) |
| `test_library_hierarchy` | Each lib sources its dependencies |

#### Integration Tests (End-to-End)

| Test | What It Validates |
|------|------------------|
| `test_e2e_fresh_boot_single` | Full provision → reboot → health check → agent intro (single mode) |
| `test_e2e_fresh_boot_session` | Full provision → reboot → per-group health check (session mode) |
| `test_e2e_broken_token_safe_mode` | Broken token → safe mode recovery → SafeModeBot intro |
| `test_e2e_broken_api_key` | Broken API key → recovery finds alternative |
| `test_e2e_config_update_recheck` | Upload new config → health check reruns → no duplicate intros |
| `test_e2e_all_broken_critical` | All credentials broken → critical notification → service stops |

These integration tests require a live droplet. They should be runnable via:
```bash
# From iOS Shortcut or manual trigger:
ssh bot@<droplet> 'sudo /usr/local/bin/run-integration-tests.sh'
```

> **TODO:** `run-integration-tests.sh` does not exist yet. Needs its own task/PR. Minimum viable: a bash script that iterates the E2E test cases above, reports pass/fail per case, and outputs a summary. Could provision test droplets via the DO API using test habitat configs from `Droplets/habitats/`, or run against an already-provisioned droplet. Should be runnable both from CI and manually via SSH.

---

## Migration & Backwards Compatibility

### Bootstrap Auto-Detection

`bootstrap.sh` already has an auto-detection mechanism. Updated logic:

```bash
if [ -f "$INSTALL_DIR/scripts/provision.sh" ]; then
  log "Using single-phase provisioning"
  /usr/local/sbin/provision.sh
else
  log "Using legacy two-phase provisioning"
  /usr/local/sbin/phase1-critical.sh
fi
```

### Stage Number Compatibility

The iOS Shortcut parses stage numbers from the API. New stages must either:
1. **Map to existing numbers** (preferred for initial rollout), or
2. **Update the Shortcut** to handle new stage names

Proposed: Keep stages 1-10 mapped the same, compress the new single-phase stages to fit. The `set-stage.sh` descriptions are what the Shortcut displays, so those can change freely.

### Rollback Path

If `provision.sh` has issues:
1. Set `hatcheryVersion` to a tag before the merge
2. `bootstrap.sh` pulls old release → old scripts → `phase1-critical.sh` path
3. No code deletion needed — legacy scripts remain in the repo

### Feature Flag

For safe rollout, `provision.sh` can check an opt-in flag:

```bash
# In hatch.yaml or habitat config:
"provisioningMode": "single-phase"   # or "legacy" (default)
```

This lets us test single-phase on specific habitats before making it the default.

---

## Estimated Impact

### Line Count

| Component | Before | After | Change |
|-----------|--------|-------|--------|
| `phase1-critical.sh` | 343 | 343 (kept for legacy) | 0 |
| `phase2-background.sh` | 299 | 299 (kept for legacy) | 0 |
| `provision.sh` | 0 | ~450 | +450 |
| `build-full-config.sh` | 574 | ~150 (orchestrator) | -424 |
| `generate-config.sh` | 0 | ~250 | +250 |
| `setup-workspaces.sh` | 0 | ~250 | +250 |
| `generate-session-services.sh` | 416 | ~300 (no config heredoc) | -116 |
| `safe-mode-recovery.sh` | 1,461 | ~400 | -1,061 |
| `lib-auth.sh` | 0 | ~300 | +300 |
| `lib-env.sh` | 0 | ~40 | +40 |
| `gateway-e2e-check.sh` | 348 | ~280 | -68 |
| **Net new code** | | | **~-379** |
| **Unique logic** (excl. legacy) | ~5,600 | ~3,300 | **-2,300 (~41%)** |

### Boot Time

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Provisioning | ~10 min | ~9 min (one apt-get) | ~1 min |
| Health check settle | 45s | 10s | 35s |
| E2E check (no --deliver) | ~30s/agent | ~10s/agent | ~20s/agent |
| **Total time to first bot response** | ~12 min | ~10 min | **~2 min faster** |

### Robustness

| Metric | Before | After |
|--------|--------|-------|
| Config generation locations | 5 | 1 |
| Token validation implementations | 3 | 1 |
| Race conditions | 1 (background fork) | 0 |
| Marker files to coordinate | 3+ | 1 (build-failed only) |
| Scripts that hand-build JSON | 4 | 0 (all use jq) |

---

## Implementation Order

```
PR 1 ──→ PR 2 ──→ PR 3 ──────→ PR 4 ──────→ PR 5 ──→ PR 6
(settle)  (libs)   (config DRY)  (auth+slim)  (prov)   (e2e)
trivial   low      HIGHEST VALUE  high value   medium   nice-to-have
```

Each PR is independently mergeable. Ship PR 1 immediately — it's zero risk.

### PRs (priority order)

| PR | Phase | Description | Dependencies | Rationale |
|----|-------|-------------|-------------|-----------|
| 1 | 4a | Settle 45s→10s + TimeoutStartSec 420s→180s | None | Zero risk, 35s faster every boot |
| 2 | 5 | `lib-env.sh` + fatal library guards | None | Foundation for everything else |
| 3 | 2 | `generate-config.sh` + `setup-workspaces.sh` + slim `build-full-config.sh` | None | **Highest value** — kills the #1 bug source (5 config heredocs) |
| 4 | 3 | `lib-auth.sh` (incl. OAuth headers) + slim `safe-mode-recovery.sh` + fix `local_*` naming | PR 2, PR 3 | Second highest — 1,461→~400 lines |
| 5 | 1 | `provision.sh` with reboot + `bootstrap.sh` auto-detect | PR 3 | Lower urgency — current flow works, fork is ugly but functional |
| 6 | 4b,4c | Separate E2E test from intro, unify normal/safe-mode paths | PR 4 | Nice-to-have, not blocking |
