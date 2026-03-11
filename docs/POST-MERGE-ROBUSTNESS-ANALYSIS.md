# Post-Merge Robustness Analysis

> Architectural analysis of all bugs found during the pre-merge testing rounds (2026-02-25 → 2026-03-05).
> Goal: Identify root-cause patterns and propose structural defenses so these bug classes can't recur.

**Author:** ClaudeBot, 2026-03-05
**Scope:** 28 bugs across 4 live droplet provisions + 3 retests
**Branch:** `feature/post-merge-cleanup`

---

## Bug Catalog (grouped by root cause)

### Pattern 1: Config Generation ↔ Consumption Mismatch

| Bug | Symptom | Root Cause |
|-----|---------|-----------|
| Account naming (`accounts.agent1` vs `accounts.default`) | `Telegram bot token missing for account "agent1"` | E2E script used agent ID, config had `default` |
| Doctor renames single-account | Config generated with `agent1`, Doctor migrated to `default` on startup | OpenClaw Doctor auto-migration not accounted for |
| Missing binding for first agent | Claude not responding on 2A | First agent relied on implicit fallback routing that doesn't work with agent ID account names |
| `dmPolicy` at wrong level | Doctor migration prompt hangs in non-interactive systemd | Top-level DM keys trigger Doctor's "merge old+new" migration |

**Common Root Cause:** Config is generated in one script and consumed by another (or by OpenClaw itself), with no validation that the consumer can use what was generated.

**Structural Defense:**
1. **Config smoke test function.** After `generate-config.sh` produces a config, run `openclaw doctor --dry-run` on it. If Doctor reports any changes, the config is wrong. Add this to `build-full-config.sh`.
2. **Binding completeness check.** After bindings are generated, verify every agent has a reachable routing path. For each agent, check that either a binding exists or the agent is the default fallback.
3. **E2E reply-account derivation.** Instead of the E2E script independently computing the account name, read it from the generated config: `jq '.channels.telegram.accounts | keys[0]' config.json`. Single source of truth.

### Pattern 2: Silent Failures

| Bug | Symptom | Root Cause |
|-----|---------|-----------|
| E2E intro "succeeded" but never delivered | `openclaw agent --deliver` exited 0, delivery failed in container logs | CLI exit code doesn't reflect delivery failure |
| `set -a` missing for child processes | Child scripts couldn't see env vars | `source file.sh` sets vars in current shell only |

**Common Root Cause:** Trusting exit codes or side effects without verifying the actual outcome.

**Structural Defense:**
1. **Verify delivery in E2E.** After `openclaw agent --deliver`, check container/service logs for `Delivery failed` within a short window. If found, mark the intro as failed. Better: use `--json` output and parse the delivery status.
2. **Env propagation test.** Add a test to `generate_group_env()` that spawns a child shell, sources the env file, and verifies a sentinel var is visible. Catches `set -a` omissions.

### Pattern 3: Systemd Footguns

| Bug | Symptom | Root Cause |
|-----|---------|-----------|
| `StartLimitBurst` in `[Service]` | Infinite restart loops that look capped | systemd silently ignores `[Service]` placement |
| `Restart=always` | Service never stops, even on crash loop | `always` includes clean exit 0, no burst limit respected |
| `.path` unit re-triggers | Notification spam loop | `PathExists` re-fires after oneshot exits if file still exists |
| `local` keyword in main body | Fatal error in ExecStartPost → service killed | `local` is only valid inside functions |

**Common Root Cause:** systemd has subtle semantics that aren't caught by `bash -n` or `systemctl daemon-reload`.

**Structural Defense:**
1. **Systemd unit linter.** Add a test that parses generated `.service` files and checks:
   - `StartLimitBurst` and `StartLimitIntervalSec` are in `[Unit]`, not `[Service]`
   - `Restart=` is `on-failure`, never `always`
   - `ExecStartPost` scripts don't use `local` outside functions
   - `Environment=CI=true` is present (prevents `@clack/prompts` stdin block)
2. **Oneshot cleanup contract.** Any `.path`-triggered oneshot MUST remove the watched file in both success AND failure paths. Add a grep-based test: for each `.path` unit, find the watched file and verify the triggered service removes it.

### Pattern 4: Race Conditions & Timing

| Bug | Symptom | Root Cause |
|-----|---------|-----------|
| Intro marker checked before E2E finished | Verify script saw no marker | E2E service still running when verify checked |
| Runcmd vs shutdown race | Provisioning steps lost on reboot | `reboot` in runcmd races with remaining entries |
| Container "starting" during verify | Health check not yet passed | Docker health check interval vs verify timing |

**Common Root Cause:** Checking state before the state-producing process has completed.

**Structural Defense:**
1. **Wait-for-completion in verify scripts.** Already fixed (wait loop for E2E service). Generalize: any verify check that depends on an async process should poll for completion with a timeout.
2. **cloud-init power_state.** Already fixed — reboot is deferred to after all runcmd entries complete. No further action needed.
3. **Health check grace period.** Container health checks have a start period. Verify scripts should wait for `healthy` status, not just `running`.

### Pattern 5: State Cleanup on Failure Paths

| Bug | Symptom | Root Cause |
|-----|---------|-----------|
| Safe-mode bot message flood | Bot responds to every message indefinitely | Terminal failure path didn't stop the safe-mode bot service |
| Notification spam from `.path` re-trigger | Repeated critical failure messages | Unhealthy marker not cleaned up after handler ran |
| Gateway config clobber on restart | Recovery config overwritten by old in-memory config | Gateway persists config on SIGTERM; restart = stop(clobber) + start |

**Common Root Cause:** Error/failure paths don't clean up all state, and each leaked state artifact triggers another round of actions.

**Structural Defense:**
1. **EXIT trap audit.** Every long-running handler (`safe-mode-handler.sh`, `try-full-config.sh`) must have a trap that cleans up marker files on ANY exit (0, 1, signal). Add a test: grep for `trap` in each handler, verify it covers cleanup.
2. **Stop-modify-start as primitive.** Already implemented (`hc_stop_modify_start`). Enforce: no script modifies config files while the service is running. Add a grep-based lint: no `cp.*openclaw.json` or `generate-config` call without a preceding `hc_stop_service` or `systemctl stop`.

### Pattern 6: Env Var / Config Propagation Gaps

| Bug | Symptom | Root Cause |
|-----|---------|-----------|
| `group.env` missing owner IDs | E2E couldn't find owner to notify | Hand-curated allowlist in `generate_group_env()` |
| `platform=both` not handled | `get_owner_id_for_platform()` returned empty | Case statement didn't have a `both` branch |
| `GEMINI_API_KEY` vs `GOOGLE_API_KEY` | Google provider not loading | OpenClaw reads one, we set the other |
| `NODE_OPTIONS=--experimental-sqlite` | Crash loop on Node v22 | Env var from older OpenClaw version left in unit file |

**Common Root Cause:** Env vars are hand-managed across multiple files with no automated validation that producers and consumers agree.

**Structural Defense:**
This is the core problem addressed by `ENV-REFACTOR-PLAN.md` Phase 1. The key structural fix is:
1. **Include-all instead of allowlist.** `group.env` starts from `habitat-parsed.env` contents and adds overrides. New vars propagate automatically.
2. **Env contract test.** A test that lists all env vars consumed by runtime scripts (`grep -roh '\$[A-Z_]*' scripts/`) and verifies each one is present in a sample `group.env`. Catches propagation gaps before provisioning.

---

## Proposed Additions to Refactor Plan

### New: Config Validation Gate (add to ENV-REFACTOR-PLAN Phase 1)

After `build-full-config.sh` generates all configs:

```bash
validate_generated_configs() {
  local manifest="/etc/openclaw-groups.json"
  
  for group in $(jq -r '.groups | keys[]' "$manifest"); do
    local config_path
    config_path=$(jq -r ".groups[\"$group\"].configPath" "$manifest")
    
    # 1. Doctor dry-run — config should produce zero changes
    if ! openclaw doctor --config "$config_path" --dry-run --non-interactive 2>&1 | grep -q "No changes"; then
      log "ERROR: Doctor would modify config for $group — config is invalid"
      return 1
    fi
    
    # 2. Binding completeness — every agent has a routing path
    local agent_count binding_count default_agent
    agent_count=$(jq '.agents.list | length' "$config_path")
    binding_count=$(jq '.bindings | length' "$config_path")
    default_agent=$(jq -r '.agents.list[] | select(.default == true) | .id' "$config_path")
    
    if [ "$agent_count" -gt 1 ] && [ "$binding_count" -lt "$agent_count" ]; then
      log "ERROR: $group has $agent_count agents but only $binding_count bindings"
      return 1
    fi
    
    # 3. Account existence — every binding references a real account
    for acct in $(jq -r '.bindings[].match.accountId' "$config_path" 2>/dev/null); do
      for channel in telegram discord; do
        if jq -e ".channels.$channel.accounts[\"$acct\"]" "$config_path" &>/dev/null; then
          continue 2
        fi
      done
      log "ERROR: binding references account '$acct' but no channel has it"
      return 1
    done
  done
  
  log "All generated configs validated"
}
```

### New: Systemd Unit Linter (add as Phase 4 or standalone)

```python
# tests/test_systemd_units.py
def test_start_limit_in_unit_section():
    """StartLimitBurst must be in [Unit], not [Service]."""
    for unit_file in find_generated_units():
        content = parse_ini(unit_file)
        assert "StartLimitBurst" not in content.get("Service", {}), \
            f"{unit_file}: StartLimitBurst in [Service] (must be [Unit])"

def test_restart_policy():
    """Restart must be on-failure, never always."""
    for unit_file in find_generated_units():
        content = parse_ini(unit_file)
        restart = content.get("Service", {}).get("Restart", "")
        assert restart != "always", f"{unit_file}: Restart=always is forbidden"

def test_ci_env_set():
    """CI=true prevents @clack/prompts stdin block."""
    for unit_file in find_generated_units():
        content = read_file(unit_file)
        assert "CI=true" in content, f"{unit_file}: missing Environment=CI=true"
```

### New: Delivery Verification in E2E (add to ENV-REFACTOR-PLAN Phase 2)

After `openclaw agent --deliver` returns, check for delivery failure:

```bash
# In gateway-e2e-check.sh, after the intro command
local output
output=$(timeout 90 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
  --agent "$agent_id" --message "$intro_prompt" --deliver \
  --reply-channel "$intro_plat" --reply-account "$reply_acct" \
  --reply-to "$plat_owner" --timeout 60 --json 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
  log "  ✗ $agent_name intro command failed (exit $rc)"
elif echo "$output" | grep -qi "delivery failed\|token missing"; then
  log "  ✗ $agent_name intro delivery failed: $(echo "$output" | grep -i 'delivery failed')"
else
  log "  ✓ $agent_name intro sent via $intro_plat"
  intro_ok=true
fi
```

### New: Env Contract Test (add to ENV-REFACTOR-PLAN Phase 1)

```python
# tests/test_env_contract.py
def test_all_consumed_vars_in_group_env():
    """Every env var consumed by runtime scripts must be in group.env."""
    consumed = set()
    for script in RUNTIME_SCRIPTS:
        consumed |= extract_env_vars(script)  # grep for ${VAR} and $VAR
    
    sample_env = generate_sample_group_env()
    provided = set(sample_env.keys())
    
    # Some vars are set by systemd itself or computed at runtime
    RUNTIME_ONLY = {"HOME", "USER", "PATH", "PWD", "TERM", ...}
    
    missing = consumed - provided - RUNTIME_ONLY
    assert not missing, f"Vars consumed but not in group.env: {missing}"
```

---

## Priority Order

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 1 | Config validation gate (Doctor dry-run + binding check) | Small | Prevents Pattern 1 entirely |
| 2 | Systemd unit linter | Small | Prevents Pattern 3 entirely |
| 3 | Delivery verification in E2E | Small | Catches Pattern 2 silent failures |
| 4 | ENV-REFACTOR Phase 1 (group.env SSOT) | Medium | Prevents Pattern 6 entirely |
| 5 | ENV-REFACTOR Phase 2 (unified notification) | Medium | Simplifies Pattern 5 cleanup |
| 6 | ENV-REFACTOR Phase 3 (eliminate tri-state) | Small | Cleanup, no new defenses |
| 7 | Env contract test | Small | Regression guard for Pattern 6 |

Items 1-3 can be done immediately on `feature/post-merge-cleanup`. Items 4-7 are the ENV-REFACTOR phases.

---

## Summary

The 28 bugs found during testing fall into 6 structural patterns. The most impactful defenses are:

1. **Validate configs against OpenClaw Doctor** before deploying them (prevents the entire "Doctor renames my config" class)
2. **Lint systemd units** for known footguns (prevents infinite restart loops, silent misconfig)
3. **Verify delivery outcomes** instead of trusting exit codes (prevents silent notification failures)
4. **Include-all env generation** instead of hand-curated allowlists (prevents env propagation gaps)

These four changes would have prevented 22 of the 28 bugs found during testing.
