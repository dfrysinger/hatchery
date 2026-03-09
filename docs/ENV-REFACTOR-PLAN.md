# Environment & Notification Refactoring Plan

> Eliminate redundant env loading, hand-curated allowlists, and parallel notification paths.

**Status:** In progress
**Branch:** `feature/post-merge-cleanup` (off main v5.0.0)
**Author:** ClaudeBot + Daniel, 2026-03-04
**Updated:** 2026-03-05 — added Phase 0 (robustness quick wins) from post-merge analysis

---

## Problem Statement

Environment variables flow from habitat JSON to runtime scripts through 3 overlapping mechanisms. Owner notification has 2 parallel implementations. The `platform=both` tri-state leaks into every consumer. Scripts re-source env files they don't trust. New variables silently fail to propagate because `group.env` is a hand-curated allowlist.

### Evidence

| Symptom | Root Cause |
|---------|-----------|
| Intros never worked with `platform=both` | `get_owner_id_for_platform()` case statement didn't handle `both` |
| `group.env` missing owner IDs | Hand-curated allowlist in `generate_group_env()` |
| Session service never generated in mixed-mode | `generate-session-services.sh` gated on `ISOLATION_DEFAULT` instead of trusting caller's pre-filtered groups |
| Container OOM on reprovision didn't pick up Dropbox fix | Compose file is a static artifact baked at provision time — no runtime re-read |
| `gateway-e2e-check.sh` sources `habitat-parsed.env` 4 times | Scripts don't trust the env they were given |
| `notify_find_token()` has its own owner-resolution logic | Parallel implementation of "find the owner" |
| Every new env var requires touching `lib-isolation.sh` | Allowlist pattern guarantees future regressions |

---

## Goals

1. **Single env file per group.** `group.env` is the ONLY file any runtime script loads. No script ever sources `habitat-parsed.env` or `droplet.env` directly.

2. **Generated, not hand-curated.** `group.env` is produced by filtering/merging `habitat-parsed.env` with group-specific overrides. Adding a new var to `parse-habitat.py` automatically makes it available to all groups.

3. **One notification function.** `notify_owner "message"` is the only way to send a message to the habitat owner. No caller touches `TELEGRAM_OWNER_ID`, `DISCORD_OWNER_ID`, or platform-specific logic.

4. **No tri-state platform leaking.** `platform=both` is resolved once at env generation time into a notification preference order. Consumers never see it.

5. **Testable.** Every function has a unit test. The test suite catches missing vars before a droplet provision does.

**Named SSOTs** (per ChatGPT review):
- **Topology SSOT:** `/etc/openclaw-groups.json` — group names, ports, isolation mode, service names
- **Runtime env SSOT:** `group.env` — all env vars a runtime script needs, per group

---

## Current Architecture (Before)

### Env Loading (3 overlapping paths)

```
                        ┌─────────────────────────┐
                        │     habitat.json         │
                        │  (iOS Shortcut input)    │
                        └────────┬────────────────┘
                                 │
                        ┌────────▼────────────────┐
                        │   parse-habitat.py       │
                        │                          │
                        ├──► /etc/habitat-parsed.env  (ALL vars, chmod 600)
                        ├──► /etc/habitat.json        (raw JSON copy)
                        └──────────────────────────┘

    ┌──────────────────────────────────────────────────────────┐
    │  build-full-config.sh                                    │
    │    sources: droplet.env + habitat-parsed.env             │
    │    calls: generate_group_env() in lib-isolation.sh       │
    │      → writes group.env with HAND-PICKED subset          │
    │        (GROUP, PORT, API keys... but NOT owner IDs,      │
    │         PLATFORM, AGENT_COUNT, HABITAT_NAME, etc.)       │
    └──────────────────────────────────────────────────────────┘

Runtime:
    systemd EnvironmentFile= → group.env (partial)
    gateway-health-check.sh  → hc_load_environment()
                               → env_load()
                                 → source /etc/droplet.env
                                 → source /etc/habitat-parsed.env
    gateway-e2e-check.sh     → hc_load_environment() (same as above)
                             → source /etc/habitat-parsed.env (3 MORE times)
    safe-mode-handler.sh     → hc_load_environment()
                             → source safe-mode-recovery.sh
```

**Problem:** group.env is supposed to be the runtime env, but scripts bypass it and source the global files directly because group.env is incomplete.

### Owner Notification (2 parallel paths)

```
Path 1: Raw API (lib-notify.sh)
    notify_find_token()
      → tries telegram tokens, discord tokens, in priority order
      → sets NOTIFY_PLATFORM, NOTIFY_TOKEN, NOTIFY_OWNER (globals)
    notify_send_message(message)
      → calls notify_find_token() if not already set
      → get_owner_id_for_platform(NOTIFY_PLATFORM)
      → send_telegram_notification() or send_discord_notification()
    Used by: safe-mode warnings, critical failure alerts

Path 2: OpenClaw CLI (gateway-e2e-check.sh)
    send_agent_intros()
      → source /etc/habitat-parsed.env
      → get_owner_id_for_platform(HC_PLATFORM, "with_prefix")
      → openclaw agent --deliver --reply-to $owner_id
    Used by: agent intros after boot

Shared: get_owner_id_for_platform() in lib-health-check.sh
    → case telegram|discord|both|*
    → reads TELEGRAM_OWNER_ID, DISCORD_OWNER_ID from env
```

**Problem:** Two callers, two notification mechanisms, shared function that doesn't handle all cases. Adding a new platform (e.g., Signal) requires changes in 3+ files.

### `platform=both` Tri-State Leak

Every consumer must handle three values: `telegram`, `discord`, `both`.

| Consumer | Handles `both`? | Consequence |
|----------|----------------|-------------|
| `get_owner_id_for_platform()` | Now yes (bd39b4d) | Was silently returning empty |
| `notify_find_token()` | Sort of (tries all) | Has its own priority logic |
| E2E channel connectivity check | Yes (dedicated branch) | 30+ lines of duplication |
| `generate-config.sh` channel config | Yes (builds both sections) | Separate if/elif branches |

---

## Target Architecture (After)

### Env Loading (single path)

```
                        ┌─────────────────────────┐
                        │     habitat.json         │
                        └────────┬────────────────┘
                                 │
                        ┌────────▼────────────────┐
                        │   parse-habitat.py       │
                        ├──► /etc/habitat-parsed.env  (global SSOT, unchanged)
                        ├──► /etc/habitat.json
                        └──────────────────────────┘

    ┌──────────────────────────────────────────────────────────┐
    │  generate_group_env() in lib-isolation.sh                │
    │                                                          │
    │  1. Start with ALL of habitat-parsed.env                 │
    │  2. Remove vars that must NOT leak (agent tokens from    │
    │     other groups, if multi-tenant — currently N/A)       │
    │  3. Add group-specific overrides:                        │
    │     GROUP, GROUP_PORT, ISOLATION, NETWORK_MODE,          │
    │     OPENCLAW_CONFIG_PATH, OPENCLAW_STATE_DIR             │
    │  4. Add decoded secrets from droplet.env:                │
    │     ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.              │
    │  5. Write result to group.env                            │
    └──────────────────────────────────────────────────────────┘

Runtime:
    systemd EnvironmentFile= → group.env (COMPLETE)
    ALL scripts              → source group.env (via hc_load_environment)
    Nobody sources habitat-parsed.env or droplet.env at runtime.
```

**Key change:** `generate_group_env()` starts from `habitat-parsed.env` (include-all) instead of building from scratch (allowlist). Group-specific overrides are appended. No hand-curation.

### Owner Notification (single path)

```
notify_owner(message)                    ← NEW: single entry point
  ├── resolves platform preference       (from NOTIFY_PLATFORMS env var)
  ├── for each platform:
  │     ├── finds working token          (_find_notify_token)
  │     ├── resolves owner ID            (_get_owner_id → per-platform ID)
  │     └── sends via raw API            (send_telegram/discord_notification)
  └── returns 0 on first success, 1 if all exhausted

TELEGRAM_OWNER_ID=5874850284             ← Per-platform (different namespaces)
DISCORD_OWNER_ID=795380005466800159      ← Per-platform
NOTIFY_PLATFORMS=telegram,discord        ← Ordered preference list
NOTIFY_TELEGRAM_TOKEN=...               ← Token for notifications (may differ from agent tokens)
NOTIFY_DISCORD_TOKEN=...
```

**Key changes:**
- `platform=both` is resolved at parse time into `NOTIFY_PLATFORMS=telegram,discord`
- Per-platform owner IDs preserved: `TELEGRAM_OWNER_ID`, `DISCORD_OWNER_ID` (different namespaces — cannot collapse to single `OWNER_ID`)
- `notify_owner()` tries platforms in preference order, resolves owner ID per platform attempt
- No mutable global state — token/owner resolution is internal to `notify_owner()`
- Agent intros still use `openclaw agent --deliver` (different mechanism, correct — it needs the LLM) but use the same `_get_owner_id()` helper

### Platform Handling

```
parse-habitat.py resolves at parse time:

  platform: "both" + platforms.telegram.ownerId + platforms.discord.ownerId
    → NOTIFY_PLATFORMS="telegram,discord"
    → TELEGRAM_OWNER_ID="5874850284"
    → DISCORD_OWNER_ID="795380005466800159"

  platform: "telegram" + platforms.telegram.ownerId
    → NOTIFY_PLATFORMS="telegram"
    → TELEGRAM_OWNER_ID="5874850284"

Runtime consumers never see "both" — they see an ordered list.
```

---

## Implementation Plan

### Phase 1: group.env as SSOT (env loading)

**Goal:** `group.env` contains everything. No script sources `habitat-parsed.env` at runtime.

1. **Rewrite `generate_group_env()`** to start from `habitat-parsed.env` contents:
   ```bash
   generate_group_env() {
     local group="$1"
     local env_file="${CONFIG_BASE}/${group}/group.env"

     # Start with global vars from habitat-parsed.env
     grep -v '^#\|^$' /etc/habitat-parsed.env > "$env_file"

     # Append group-specific overrides (these win over globals)
     cat >> "$env_file" <<EOF
   GROUP=${group}
   GROUP_PORT=$(get_group_port "$group")
   ISOLATION=$(get_group_isolation "$group")
   NETWORK_MODE=$(get_group_network "$group" 2>/dev/null)
   OPENCLAW_CONFIG_PATH=${CONFIG_BASE}/${group}/openclaw.session.json
   OPENCLAW_STATE_DIR=${STATE_BASE}/${group}
   EOF

     # Append decoded secrets
     append_decoded_secrets "$env_file"

     chmod 600 "$env_file"
     chown "${LIB_SVC_USER}:${LIB_SVC_USER}" "$env_file"
   }
   ```

   **Implementation constraints** (per ChatGPT review):
   - Write `GROUP_ENV_VERSION=1` as the first line. Future migrations can check/bump this.
   - **Escaping:** All values are single-line `KEY=VALUE`. Values with spaces are double-quoted (`KEY="value with spaces"`). No newlines, no `#` in values. `parse-habitat.py` is responsible for sanitizing at generation time. Habitat JSON values that contain `"`, `$`, or backticks are rejected at parse time.
   - **Non-isolated mode:** Also gets a generated `group.env` (at the default config path). `hc_load_environment()` has ONE code path: source `group.env`. No fallback to `env_load()`.

2. **Simplify `hc_load_environment()`** — source group.env only:
   ```bash
   hc_load_environment() {
     local group="${GROUP:-}"
     local env_file

     if [ -n "$group" ]; then
       env_file="${HC_HOME:=/home/bot}/.openclaw/configs/${group}/group.env"
     else
       # Non-isolated mode: group.env is at the default config path
       env_file="${HC_HOME:=/home/bot}/.openclaw/configs/default/group.env"
     fi

     if [ -f "$env_file" ]; then
       set -a; source "$env_file"; set +a
     else
       log "ERROR: group.env not found at $env_file"
       return 1
     fi
     # ... set HC_* vars from env (unchanged)
   }
   ```

3. **Remove all `source /etc/habitat-parsed.env`** from runtime scripts:
   - `gateway-e2e-check.sh` lines 133, 169, 246
   - Any other script that sources it after `hc_load_environment()`

4. **Tests:**
   - Test that `generate_group_env()` output contains every var from `habitat-parsed.env`
   - Test that adding a new var to a mock `habitat-parsed.env` automatically appears in `group.env`
   - Test that group-specific overrides (GROUP, PORT) win over global values
   - Test that no runtime script contains `source.*habitat-parsed.env` (grep-based lint)

**Files changed:** `lib-isolation.sh`, `lib-health-check.sh`, `gateway-e2e-check.sh`, `gateway-health-check.sh`

### Phase 2: Unified notification (owner resolution)

**Goal:** One function to notify the owner. No caller touches platform-specific owner IDs.

1. **Add `NOTIFY_PLATFORMS` to `parse-habitat.py`:**
   ```python
   # Resolve platform preference order
   platform = hab.get("platform", "telegram")
   if platform == "both":
       notify_platforms = []
       if telegram_owner_id:
           notify_platforms.append("telegram")
       if discord_owner_id:
           notify_platforms.append("discord")
       f.write('NOTIFY_PLATFORMS="{}"\n'.format(",".join(notify_platforms or ["telegram"])))
   else:
       f.write('NOTIFY_PLATFORMS="{}"\n'.format(platform))
   ```

   **Owner ID design** (per ChatGPT review): Keep per-platform owner IDs as first-class outputs (`TELEGRAM_OWNER_ID`, `DISCORD_OWNER_ID`). `NOTIFY_PLATFORMS` selects routing order; owner ID is resolved per platform inside `notify_owner()`. No single collapsed `OWNER_ID` — Telegram and Discord IDs are different namespaces.

2. **Rewrite `notify_owner()` in `lib-notify.sh`:**
   ```bash
   # notify_owner "message"
   # Tries platforms in NOTIFY_PLATFORMS order. First working token wins.
   # Returns: 0 on success, 1 on failure.
   # Reason codes logged: no_token, no_owner, send_failed.
   # No mutable global state — all resolution is local.
   notify_owner() {
     local message="$1"
     local platforms="${NOTIFY_PLATFORMS:-telegram}"

     IFS=',' read -ra platform_list <<< "$platforms"
     for platform in "${platform_list[@]}"; do
       local token owner_id
       token=$(_find_notify_token "$platform")
       if [ -z "$token" ]; then
         log "  $platform: no_token — skipping"
         continue
       fi
       owner_id=$(_get_owner_id "$platform")
       if [ -z "$owner_id" ]; then
         log "  $platform: no_owner — skipping"
         continue
       fi

       log "  Sending via $platform to $owner_id"
       case "$platform" in
         telegram)
           if timeout 10 send_telegram_notification "$token" "$owner_id" "$message"; then
             return 0
           else
             log "  $platform: send_failed (rc=$?)"
           fi
           ;;
         discord)
           if timeout 10 send_discord_notification "$token" "user:$owner_id" "$message"; then
             return 0
           else
             log "  $platform: send_failed (rc=$?)"
           fi
           ;;
       esac
     done

     log "Cannot send notification — all platforms exhausted"
     return 1
   }
   ```

   **Behavior contract** (per ChatGPT review):
   - **Timeout:** 10s per platform attempt (prevents hanging on network issues)
   - **Retry:** No retry within `notify_owner` — caller decides whether to retry. Keeps the function simple.
   - **Reason codes:** Logged per platform: `no_token`, `no_owner`, `send_failed`. Caller sees exit 0 (success) or 1 (all platforms exhausted).
   - **No mutable globals:** All `NOTIFY_*` globals are eliminated. Token/owner resolution is local to the function. No side effects.

3. **Replace all callers:**
   - `safe-mode-handler.sh`: `notify_send_message "$msg"` → `notify_owner "$msg"`
   - `gateway-e2e-check.sh` intro function: keep `openclaw agent --deliver` (needs LLM), but resolve `--reply-to` via same `_get_owner_id()` helper
   - `gateway-health-check.sh`: `notify_send_message` → `notify_owner`
   - `_notify_critical_failure()`: same

4. **Delete:**
   - `notify_find_token()` (replaced by internal `_find_notify_token`)
   - `get_owner_id_for_platform()` (replaced by internal `_get_owner_id`)
   - `NOTIFY_PLATFORM`, `NOTIFY_TOKEN`, `NOTIFY_OWNER` globals (no more mutable state)

5. **Tests:**
   - `notify_owner` with telegram-only, discord-only, both (ordered)
   - `notify_owner` with first platform failing, falls back to second
   - `notify_owner` with no working tokens returns 1
   - No script references `get_owner_id_for_platform` (grep-based lint)

**Files changed:** `lib-notify.sh`, `lib-health-check.sh`, `safe-mode-handler.sh`, `gateway-e2e-check.sh`, `gateway-health-check.sh`, `parse-habitat.py`

### Phase 3: Eliminate platform tri-state from consumers

**Goal:** No runtime script contains `if platform == "both"` logic.

1. **E2E channel connectivity** — currently has separate branches for telegram/discord/both. Refactor to iterate `NOTIFY_PLATFORMS`:
   ```bash
   IFS=',' read -ra platforms <<< "${NOTIFY_PLATFORMS:-telegram}"
   for platform in "${platforms[@]}"; do
     check_channel_connectivity "$platform"
   done
   ```

2. **Config generation** — `generate-config.sh` builds channel config based on platform. Refactor to iterate a list instead of if/elif/both.

3. **Tests:**
   - Grep-based lint: no runtime script contains `= "both"` or `== "both"` (only parse-habitat.py should)
   - E2E check works with single and multiple platforms

**Files changed:** `gateway-e2e-check.sh`, `generate-config.sh`

---

### Phase 0: Robustness Quick Wins (no env refactor needed)

> Added 2026-03-05 from post-merge robustness analysis (`docs/POST-MERGE-ROBUSTNESS-ANALYSIS.md`).
> These defend against the 6 bug patterns found across 28 bugs during pre-merge testing.
> Phase 0 items are independent of env refactor and can land immediately.

**Goal:** Structural defenses that prevent bug recurrence, without changing env loading.

#### 0a. Config Validation Gate

After `build-full-config.sh` generates all configs, validate them before services start.

```bash
validate_generated_configs() {
  local manifest="/etc/openclaw-groups.json"

  for group in $(jq -r '.groups | keys[]' "$manifest"); do
    local config_path
    config_path=$(jq -r ".groups[\"$group\"].configPath" "$manifest")

    # 1. Binding completeness — every agent has a routing path
    local agent_count binding_count
    agent_count=$(jq '.agents.list | length' "$config_path")
    binding_count=$(jq '.bindings | length' "$config_path")

    if [ "$agent_count" -gt 1 ] && [ "$binding_count" -lt "$agent_count" ]; then
      log "ERROR: $group has $agent_count agents but only $binding_count bindings"
      return 1
    fi

    # 2. Account existence — every binding references a real account
    for channel in telegram discord; do
      local channel_accounts
      channel_accounts=$(jq -r ".channels.$channel.accounts // {} | keys[]" "$config_path" 2>/dev/null)
      for acct in $(jq -r ".bindings[] | select(.match.channel == \"$channel\") | .match.accountId" "$config_path" 2>/dev/null); do
        if ! echo "$channel_accounts" | grep -qx "$acct"; then
          log "ERROR: binding references $channel account '$acct' but it doesn't exist in config"
          return 1
        fi
      done
    done

    # 3. Account naming — single-agent groups should use the real agent ID key.
    # "default" is accepted only for backward compatibility.
    if [ "$agent_count" -eq 1 ]; then
      local single_agent_id
      single_agent_id=$(jq -r '.agents.list[0].id // empty' "$config_path" 2>/dev/null)
      for channel in telegram discord; do
        local acct_keys
        acct_keys=$(jq -r ".channels.$channel.accounts // {} | keys[]" "$config_path" 2>/dev/null)
        if [ -n "$acct_keys" ] && [ "$acct_keys" != "$single_agent_id" ] && [ "$acct_keys" != "default" ]; then
          log "ERROR: single-agent $group should use account key '$single_agent_id' (or legacy 'default'), but found '$acct_keys'"
          return 1
        fi
      done
    fi
  done

  log "All generated configs validated"
}
```

**Bugs this prevents:** Account naming mismatch (4 bugs), missing bindings (1 bug), Doctor migration surprises (2 bugs).

**Files changed:** `build-full-config.sh`

**Tests:**
- Config with mismatched binding → validation fails
- Config with single-agent `agent1` account → validation fails
- Config with multi-agent missing binding → validation fails
- Valid config → validation passes

#### 0b. Systemd Unit Linter (DONE — `c9daaa5`)

Static analysis tests for generated systemd units. Already implemented in `tests/test_systemd_units.py` (12 tests).

Catches:
- `StartLimitBurst` in `[Service]` instead of `[Unit]`
- `Restart=always` instead of `on-failure`
- Missing `CI=true` environment
- Missing EXIT trap in safe-mode handler
- `local` keyword outside functions
- Docker compose missing `cap_drop: ALL`, `no-new-privileges`, retry cap

#### 0c. Delivery Verification in E2E

`openclaw agent --deliver` exits 0 even when delivery fails. The E2E script must parse output for failure indicators.

```bash
# In gateway-e2e-check.sh, replace the current intro send block:
local output
output=$(timeout 90 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
  --agent "$agent_id" --message "$intro_prompt" --deliver \
  --reply-channel "$intro_plat" --reply-account "$reply_acct" \
  --reply-to "$plat_owner" --timeout 60 --json 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
  log "  ✗ $agent_name intro command failed (exit $rc)"
elif echo "$output" | grep -qi "delivery failed\|token missing"; then
  log "  ✗ $agent_name intro delivery failed: $(echo "$output" | grep -i 'delivery\|token')"
else
  log "  ✓ $agent_name intro sent via $intro_plat"
  intro_ok=true
fi
```

**Bugs this prevents:** Silent delivery failure (the bug that cost us 3 droplet provisions to diagnose).

**Files changed:** `gateway-e2e-check.sh`

**Tests:**
- Mock `openclaw agent` that exits 0 but outputs "Delivery failed" → intro marked as failed
- Mock that exits 0 with clean output → intro marked as success
- Mock that exits non-zero → intro marked as failed

#### 0d. Env Contract Test

Verify that every env var consumed by runtime scripts is present in a generated `group.env`. Catches propagation gaps before a droplet provision does.

```python
# tests/test_env_contract.py
RUNTIME_SCRIPTS = [
    "gateway-e2e-check.sh",
    "gateway-health-check.sh",
    "safe-mode-handler.sh",
    "safe-mode-recovery.sh",
    "try-full-config.sh",
]

# Vars set by systemd, bash, or computed at runtime — not expected in group.env
RUNTIME_ONLY = {
    "HOME", "USER", "PATH", "PWD", "TERM", "SHELL", "LANG",
    "HOSTNAME", "SHLVL", "OLDPWD", "IFS", "OPTIND", "OPTARG",
    "BASH_SOURCE", "BASH_LINENO", "FUNCNAME", "LINENO",
    "PIPESTATUS", "RANDOM", "SECONDS", "BASHPID", "BASH_REMATCH",
    # Set by hc_load_environment / hc_init_logging
    "HC_HOME", "HC_USERNAME", "HC_LOG", "HC_SAFE_MODE_FILE",
    "HC_UNHEALTHY_MARKER", "HC_SETUP_COMPLETE", "HC_PLATFORM",
    # Set by systemd EnvironmentFile or ExecStart
    "GROUP", "GROUP_PORT", "CONFIG_PATH",
    "OPENCLAW_CONFIG_PATH", "OPENCLAW_STATE_DIR",
}

def extract_env_vars(script_path):
    """Extract env var names referenced as ${VAR} or $VAR in a script."""
    ...

def generate_sample_group_env():
    """Generate a sample group.env from test fixtures and return var names."""
    ...

def test_all_consumed_vars_available():
    """Every env var consumed by runtime scripts should be obtainable."""
    consumed = set()
    for script in RUNTIME_SCRIPTS:
        consumed |= extract_env_vars(script)
    # Vars that must come from group.env or habitat-parsed.env
    external = consumed - RUNTIME_ONLY
    # Verify each is produced by parse-habitat.py or generate_group_env
    ...
```

**Bugs this prevents:** `group.env` missing owner IDs, missing `HABITAT_NAME`, any future env var propagation gap.

**Files changed:** New test file `tests/test_env_contract.py`

---

## Migration Strategy

- **Phase 0 first** — quick wins, no architectural changes, can land immediately on `feature/post-merge-cleanup`.
- **Phase 1 next, alone.** Highest-value env change. Validated on a single test droplet.
- **Phase 2 after Phase 1 stabilizes.** Notification is sensitive — test with deliberate safe-mode triggers.
- **Phase 3 is cleanup.** No new behavior, just removing branching.
- Each phase is a separate PR. Each gets a test droplet provision before merge.

## Design Principles (learned from pre-merge testing)

### 0. Validate what you generate, verify what you deliver

28 bugs were found across 4 live droplet provisions during pre-merge testing. They fall into 6 structural patterns (full analysis in `docs/POST-MERGE-ROBUSTNESS-ANALYSIS.md`):

| Pattern | Count | Defense |
|---------|-------|---------|
| Config gen ↔ consumption mismatch | 4 | Validate configs against Doctor + check binding completeness (Phase 0a) |
| Silent failures | 2 | Parse delivery output, don't trust exit codes (Phase 0c) |
| Systemd footguns | 4 | Static analysis linter for generated units (Phase 0b, DONE) |
| Race conditions / timing | 3 | Wait-for-completion, health check grace periods |
| State cleanup on failure paths | 3 | EXIT traps, stop-modify-start primitive |
| Env propagation gaps | 4 | Include-all env generation (Phase 1), env contract test (Phase 0d) |

**Rule:** Every generated artifact (config, unit, compose file) must be validated before deployment. Every external tool invocation must have its outcome verified, not just its exit code.

### 1. No global defaults in per-group contexts

`ISOLATION_DEFAULT` leaked into `generate-session-services.sh` and `generate-docker-compose.sh` via a guard that checked the global default instead of trusting the caller's pre-filtered group list. This is the same class of bug as `platform=both` leaking into consumers.

**Rule:** Generators and runtime scripts receive explicit per-group values. They never read global defaults to decide whether to act. The orchestrator (`build-full-config.sh`) is the only place that reads global defaults and dispatches.

This applies to the refactoring too: `group.env` should contain resolved per-group values, not raw globals that downstream scripts must interpret.

### 2. Static artifacts are a separate staleness class

Compose files, systemd units, and config JSONs are baked at provision time. Updating `group.env` or Dropbox after provision doesn't fix them — you need to re-run the generator or reprovision.

**Rule:** Generators should be idempotent and cheap to re-run. A single `rebuild-group <group>` command should regenerate all artifacts for a group from `group.env` + manifest. Phase 1 should consider whether this is worth building or if "reprovision" is good enough for now.

## Risks

| Risk | Mitigation |
|------|-----------|
| `group.env` inherits vars that break group isolation | Currently all groups share the same owner/keys. If multi-tenant comes, add an exclude list (still safer than an allowlist) |
| Decoded secrets in `group.env` (currently they're in `habitat-parsed.env` as base64) | Secrets are already decoded in the current `group.env`. No change in exposure. `chmod 600` is the defense |
| `env_load()` has side effects beyond sourcing (e.g., `env_decode_keys`) | Phase 1 must ensure decoded keys end up in `group.env` so `env_decode_keys()` is not needed at runtime |
| Breaking safe-mode notification during Phase 2 | Test by deliberately breaking API keys on a test droplet and verifying DM arrives |
| Static artifacts (compose, units) drift from env after hot-fix | Document "reprovision vs rebuild" decision; consider `rebuild-group` command in Phase 1 |

## Success Criteria

### Phase 0
- [x] Systemd unit linter catches StartLimitBurst, Restart=always, missing CI=true (12 tests)
- [ ] Config validation gate rejects mismatched account names and missing bindings
- [ ] E2E intro detects and logs delivery failures (not just exit code)
- [ ] Env contract test catches missing vars before provisioning

### Phase 1–3
- [ ] No runtime script contains `source.*habitat-parsed.env`
- [ ] No runtime script contains `source.*droplet.env`
- [ ] `grep -r "get_owner_id_for_platform" scripts/` returns 0 results
- [ ] `grep -r '= "both"' scripts/` only matches `parse-habitat.py`
- [ ] `grep -r "\bOWNER_ID\b" scripts/` is either 0 results OR only in explicitly approved compatibility shim
- [ ] Adding a new var to `parse-habitat.py` requires ZERO changes to `lib-isolation.sh`
- [ ] Test droplet with `platform=both` sends intros on first try
- [ ] Test droplet with broken API keys sends critical notification on first try
- [ ] Full test suite passes
