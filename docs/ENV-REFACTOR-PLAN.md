# Environment & Notification Refactoring Plan

> Eliminate redundant env loading, hand-curated allowlists, and parallel notification paths.

**Status:** Planned (post-merge)
**Branch:** TBD (off main, after docker-isolation merge)
**Author:** ClaudeBot + Daniel, 2026-03-04

---

## Problem Statement

Environment variables flow from habitat JSON to runtime scripts through 3 overlapping mechanisms. Owner notification has 2 parallel implementations. The `platform=both` tri-state leaks into every consumer. Scripts re-source env files they don't trust. New variables silently fail to propagate because `group.env` is a hand-curated allowlist.

### Evidence

| Symptom | Root Cause |
|---------|-----------|
| Intros never worked with `platform=both` | `get_owner_id_for_platform()` case statement didn't handle `both` |
| `group.env` missing owner IDs | Hand-curated allowlist in `generate_group_env()` |
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

> **[ChatGPT inline review]**
> Strong goal set. Recommend explicitly naming two SSOTs to avoid ambiguity later:
> - **Topology SSOT:** `/etc/openclaw-groups.json`
> - **Runtime env SSOT:** `group.env`
> This keeps "single source of truth" precise instead of overloaded.

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
  ├── finds working token                (existing logic from notify_find_token)
  ├── resolves owner ID                  (from OWNER_ID env var — pre-resolved)
  └── sends via raw API                  (existing send_telegram/discord_notification)

OWNER_ID=5874850284                      ← Pre-resolved by parse-habitat.py
NOTIFY_PLATFORMS=telegram,discord        ← Ordered preference list
NOTIFY_TELEGRAM_TOKEN=...               ← Token for notifications (may differ from agent tokens)
NOTIFY_DISCORD_TOKEN=...
```

> **[ChatGPT inline review — important]**
> I would **not** collapse to a single `OWNER_ID` for multi-platform fallback.
> Telegram and Discord IDs are different namespaces/formats; a single ID can point to the wrong destination when fallback occurs.
> Prefer:
> - `TELEGRAM_OWNER_ID`
> - `DISCORD_OWNER_ID`
> - `NOTIFY_PLATFORMS=telegram,discord` (ordered preference)
> Then resolve owner ID **per platform attempt** inside `notify_owner()`.

**Key changes:**
- `platform=both` is resolved at parse time into `NOTIFY_PLATFORMS=telegram,discord`
- `OWNER_ID` is a single var (not per-platform) — it's the Telegram chat ID or Discord user ID depending on the first available platform
- `notify_owner()` tries platforms in preference order, no case statements
- Agent intros still use `openclaw agent --deliver` (different mechanism, correct — it needs the LLM) but use the same owner resolution

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

> **[ChatGPT inline review]**
> Add implementation constraints here:
> 1) Write `GROUP_ENV_VERSION=1` into every generated file for future migrations.
> 2) Document escaping/serialization guarantees (values with spaces/newlines/`#` should round-trip safely).
> 3) Decide whether non-isolated mode also gets a generated `group.env` (preferred for consistency), or clearly document fallback behavior as an exception.

2. **Simplify `hc_load_environment()`** — source group.env only:
   ```bash
   hc_load_environment() {
     local group="${GROUP:-}"
     local env_file

     if [ -n "$group" ]; then
       env_file="${HC_HOME:=/home/bot}/.openclaw/configs/${group}/group.env"
     else
       # Non-isolated mode: fall back to global files
       env_load || return 1
       return 0
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

> **[ChatGPT inline review]**
> Keep per-platform owner IDs as first-class outputs from parse-habitat (`TELEGRAM_OWNER_ID`, `DISCORD_OWNER_ID`).
> `NOTIFY_PLATFORMS` should select routing order; owner ID should still be resolved by selected platform.

2. **Rewrite `notify_owner()` in `lib-notify.sh`:**
   ```bash
   # notify_owner "message"
   # Tries platforms in NOTIFY_PLATFORMS order. First working token wins.
   notify_owner() {
     local message="$1"
     local platforms="${NOTIFY_PLATFORMS:-telegram}"

     IFS=',' read -ra platform_list <<< "$platforms"
     for platform in "${platform_list[@]}"; do
       local token owner_id
       token=$(_find_notify_token "$platform") || continue
       owner_id=$(_get_owner_id "$platform") || continue
       [ -z "$owner_id" ] && continue

       log "  Sending via $platform to $owner_id"
       case "$platform" in
         telegram) send_telegram_notification "$token" "$owner_id" "$message"; return $? ;;
         discord)  send_discord_notification "$token" "user:$owner_id" "$message"; return $? ;;
       esac
     done

     log "Cannot send notification — no working platform"
     return 1
   }
   ```

> **[ChatGPT inline review]**
> Nice direction. Add explicit behavior contract:
> - timeout/retry/backoff per platform
> - return reason codes (`no_token`, `no_owner`, `send_failed`) for diagnostics
> - no mutable global notify state (`NOTIFY_*`) outside function scope

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

## Migration Strategy

- **Phase 1 first, alone.** It's the highest-value, lowest-risk change. Can be validated on a single test droplet.
- **Phase 2 after Phase 1 stabilizes.** Notification is sensitive — test with deliberate safe-mode triggers.
- **Phase 3 is cleanup.** No new behavior, just removing branching.
- Each phase is a separate PR. Each gets a test droplet provision before merge.

## Risks

| Risk | Mitigation |
|------|-----------|
| `group.env` inherits vars that break group isolation | Currently all groups share the same owner/keys. If multi-tenant comes, add an exclude list (still safer than an allowlist) |
| Decoded secrets in `group.env` (currently they're in `habitat-parsed.env` as base64) | Secrets are already decoded in the current `group.env`. No change in exposure. `chmod 600` is the defense |
| `env_load()` has side effects beyond sourcing (e.g., `env_decode_keys`) | Phase 1 must ensure decoded keys end up in `group.env` so `env_decode_keys()` is not needed at runtime |
| Breaking safe-mode notification during Phase 2 | Test by deliberately breaking API keys on a test droplet and verifying DM arrives |

## Success Criteria

- [ ] No runtime script contains `source.*habitat-parsed.env`
- [ ] No runtime script contains `source.*droplet.env`
- [ ] `grep -r "get_owner_id_for_platform" scripts/` returns 0 results
- [ ] `grep -r '= "both"' scripts/` only matches `parse-habitat.py`
- [ ] `grep -r "\bOWNER_ID\b" scripts/` is either 0 results OR only in explicitly approved compatibility shim
- [ ] Adding a new var to `parse-habitat.py` requires ZERO changes to `lib-isolation.sh`
- [ ] Test droplet with `platform=both` sends intros on first try
- [ ] Test droplet with broken API keys sends critical notification on first try
- [ ] Full test suite passes
