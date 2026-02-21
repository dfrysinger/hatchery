#!/bin/bash
# =============================================================================
# gateway-e2e-check.sh — End-to-end agent health verification
# =============================================================================
# Purpose:  After the gateway HTTP endpoint is up, this verifies agents can
#           actually respond. Tests channel connectivity, API keys, and runs
#           each agent through a real prompt/response cycle.
#
# Runs as:  openclaw-e2e-{group}.service (separate from main gateway service)
#           Triggered after main service becomes "active" (HTTP check passed)
#
# On success: clears safe mode state, marks healthy
# On failure: writes unhealthy marker (triggers safeguard recovery via .path)
#
# Env vars:
#   GROUP / GROUP_PORT — per-group session isolation
# =============================================================================

set -o pipefail

# Source shared libraries
for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
type hc_init_logging &>/dev/null || { echo "FATAL: lib-health-check.sh not found" >&2; exit 1; }

for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-notify.sh" ] && { source "$lib_path/lib-notify.sh"; break; }
done
type notify_send_message &>/dev/null || { echo "FATAL: lib-notify.sh not found" >&2; exit 1; }

for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-auth.sh" ] && { source "$lib_path/lib-auth.sh"; break; }
done

[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh

hc_init_logging "${GROUP:-}"
hc_load_environment || exit 0

# --- Skip if recently recovered (safe mode handler will restart + re-test) ---
RECENTLY_RECOVERED="/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
if [ -f "$RECENTLY_RECOVERED" ]; then
  age=$(( $(date +%s) - $(cat "$RECENTLY_RECOVERED" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 120 ]; then
    log "Skipping E2E — recovered ${age}s ago (safe mode handler will verify)"
    exit 0
  fi
fi

# Signal health-check stage to API server (stage 10)
# (after skip check so we don't clobber stage 12 set by safe-mode-handler)
echo '10' > /var/lib/init-status/stage 2>/dev/null || true

log "============================================================"
log "========== E2E HEALTH CHECK STARTING =========="
log "============================================================"
log "GROUP=${GROUP:-none} | PORT=${GROUP_PORT:-18789}"

ALREADY_IN_SAFE_MODE=false
hc_is_in_safe_mode && ALREADY_IN_SAFE_MODE=true
RECOVERY_ATTEMPTS=$(hc_get_recovery_attempts)
log "ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS"

# =============================================================================
# E2E Check Functions
# =============================================================================

check_api_key_validity() {
  local service="$1"
  log "  Checking API key validity..."

  local config_file="$CONFIG_PATH"

  # In safe mode, validate from config
  if hc_is_in_safe_mode && [ -f "$config_file" ]; then
    log "  Safe mode — checking API from config"

    local cfg_anthropic cfg_google cfg_openai
    cfg_anthropic=$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$config_file" 2>/dev/null)
    cfg_google=$(jq -r '.env.GOOGLE_API_KEY // empty' "$config_file" 2>/dev/null)
    cfg_openai=$(jq -r '.env.OPENAI_API_KEY // empty' "$config_file" 2>/dev/null)

    if [ -n "$cfg_google" ] && curl -sf --max-time 5 \
      "https://generativelanguage.googleapis.com/v1/models?key=${cfg_google}" >/dev/null 2>&1; then
      log "  Google API key OK"; return 0
    fi

    if [ -n "$cfg_anthropic" ]; then
      local auth_header
      auth_header=$(get_auth_header "anthropic" "$cfg_anthropic")
      if curl -sf --max-time 5 -H "$auth_header" -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" >/dev/null 2>&1; then
        log "  Anthropic API key OK"; return 0
      fi
    fi

    if [ -n "$cfg_openai" ] && curl -sf --max-time 5 \
      -H "Authorization: Bearer ${cfg_openai}" "https://api.openai.com/v1/models" >/dev/null 2>&1; then
      log "  OpenAI API key OK"; return 0
    fi

    log "  No working API key in safe mode config"; return 1
  fi

  # Normal mode: check journal for auth errors
  local auth_errors
  auth_errors=$(journalctl -u "$service" --since "30 seconds ago" --no-pager 2>/dev/null | \
    grep -iE "(authentication_error|Invalid.*bearer.*token|invalid.*api.*key)" | head -3)
  [ -n "$auth_errors" ] && { log "  Found API auth errors"; return 1; }

  # Direct API validation
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    local auth_header
    auth_header=$(get_auth_header "anthropic" "${ANTHROPIC_API_KEY}")
    local response
    response=$(curl -sf --max-time 5 -H "$auth_header" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
      -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      "https://api.anthropic.com/v1/messages" 2>&1)
    if ! echo "$response" | grep -qiE "(authentication_error|invalid.*key|401)"; then
      log "  Anthropic API key OK"; return 0
    fi
  fi

  if [ -n "${OPENAI_API_KEY:-}" ] && curl -sf --max-time 5 \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" "https://api.openai.com/v1/models" >/dev/null 2>&1; then
    log "  OpenAI API key OK"; return 0
  fi

  if [ -n "${GOOGLE_API_KEY:-}" ] && curl -sf --max-time 5 \
    "https://generativelanguage.googleapis.com/v1/models?key=${GOOGLE_API_KEY}" >/dev/null 2>&1; then
    log "  Google API key OK"; return 0
  fi

  log "  No working API keys found"; return 1
}

check_channel_connectivity() {
  log "  Checking channel connectivity..."

  local config_file="$CONFIG_PATH"

  # Safe mode: validate token from config
  if hc_is_in_safe_mode && [ -f "$config_file" ]; then
    local tg_token
    tg_token=$(jq -r '.channels.telegram.accounts["safe-mode"].botToken // .channels.telegram.botToken // empty' "$config_file" 2>/dev/null)
    if [ -n "$tg_token" ] && validate_telegram_token "$tg_token"; then
      log "  Channel connectivity verified (safe mode)"; return 0
    fi

    local dc_token
    dc_token=$(jq -r '.channels.discord.accounts["safe-mode"].token // .channels.discord.accounts.default.token // .channels.discord.token // empty' "$config_file" 2>/dev/null)
    if [ -n "$dc_token" ] && validate_discord_token "$dc_token"; then
      log "  Channel connectivity verified (safe mode)"; return 0
    fi

    log "  No working chat tokens in safe mode config"; return 1
  fi

  # Normal mode: validate ALL agents
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local all_valid=true failed_agents=""
  log "  Platform: $HC_PLATFORM, Agent count: $AC"

  for i in $(seq 1 "$AC"); do
    local agent_valid=false

    if [ "$HC_PLATFORM" = "telegram" ] || [ "$HC_PLATFORM" = "both" ]; then
      local tg_token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local tg_token="${!tg_token_var:-}"
      [ -z "$tg_token" ] && tg_token_var="AGENT${i}_BOT_TOKEN" && tg_token="${!tg_token_var:-}"
      [ -n "$tg_token" ] && validate_telegram_token "$tg_token" && { log "  Agent${i} Telegram OK"; agent_valid=true; }
    fi

    if [ "$HC_PLATFORM" = "discord" ] || [ "$HC_PLATFORM" = "both" ]; then
      local dc_token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local dc_token="${!dc_token_var:-}"
      [ -n "$dc_token" ] && validate_discord_token "$dc_token" && { log "  Agent${i} Discord OK"; agent_valid=true; }
    fi

    if [ "$agent_valid" = "false" ]; then
      all_valid=false; failed_agents="${failed_agents} agent${i}"
    fi
  done

  [ "$all_valid" = "false" ] && { log "  Channel check FAILED:${failed_agents}"; return 1; }
  log "  All $AC agents have valid tokens"; return 0
}

# Unified E2E check — works for both normal agents and safe-mode agent.
# Args: agent IDs to check (optional; defaults to group agents or all agents)
# Uses deterministic test prompt, no --deliver (fast, re-runnable).
check_agents_e2e() {
  log "========== E2E AGENT CHECK =========="

  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local all_healthy=true failed_agents=""
  local agents_to_check=("$@")

  # If no args, auto-discover agents
  if [ ${#agents_to_check[@]} -eq 0 ]; then
    if [ -n "$GROUP" ]; then
      for i in $(seq 1 "$AC"); do
        local gvar="AGENT${i}_ISOLATION_GROUP"; [ "${!gvar:-}" = "$GROUP" ] && agents_to_check+=("agent${i}")
      done
      log "  GROUP=$GROUP agents: ${agents_to_check[*]}"
    else
      for i in $(seq 1 "$AC"); do agents_to_check+=("agent${i}"); done
      log "  STANDARD: ${#agents_to_check[@]} agents"
    fi
  else
    log "  EXPLICIT agents: ${agents_to_check[*]}"
  fi

  # Deterministic test prompt — fast, no delivery, verifiable
  local test_prompt="Reply with exactly: HEALTH_CHECK_OK"

  for agent_id in "${agents_to_check[@]}"; do
    log "  -------- $agent_id --------"

    local start_time; start_time=$(date +%s)
    local env_prefix=""
    [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"

    local output
    output=$(timeout 60 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
      --agent "$agent_id" --message "$test_prompt" --timeout 30 --json 2>&1)
    local rc=$?
    local dur=$(( $(date +%s) - start_time ))

    if [ $rc -eq 0 ] && echo "$output" | grep -q "HEALTH_CHECK_OK" && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
      log "  ✓ $agent_id responded in ${dur}s"
    else
      local reason="exit=$rc"
      [ $rc -eq 0 ] && ! echo "$output" | grep -q "HEALTH_CHECK_OK" && reason="missing HEALTH_CHECK_OK (LLM error?)"
      log "  ✗ $agent_id FAILED ($reason, ${dur}s)"
      echo "$output" | while IFS= read -r line; do log "    | $line"; done
      all_healthy=false; failed_agents="${failed_agents} ${agent_id}"
    fi
  done

  [ "$all_healthy" = "false" ] && { log "  RESULT: FAILED —${failed_agents}"; return 1; }
  log "  RESULT: All agents passed"
  log "========== E2E CHECK COMPLETE ==========="; return 0
}

# =============================================================================
# Agent Intros — separate from health check, only on fresh boot
# =============================================================================

INTRO_SENT_MARKER="/var/lib/init-status/intro-sent${GROUP:+-$GROUP}"

send_agent_intros() {
  log "========== SENDING AGENT INTROS =========="

  # Only send intros on fresh boot (not re-checks or restarts)
  if [ -f "$INTRO_SENT_MARKER" ]; then
    log "  Intros already sent (marker exists) — skipping"
    return 0
  fi

  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local owner_id
  owner_id=$(get_owner_id_for_platform "$HC_PLATFORM" "with_prefix")
  [ -z "$owner_id" ] || [ "$owner_id" = "user:" ] && { log "  No owner ID — skipping intros"; return 0; }

  local agents_to_intro=()

  if [ -n "$GROUP" ]; then
    for i in $(seq 1 "$AC"); do
      local gvar="AGENT${i}_ISOLATION_GROUP"; [ "${!gvar:-}" = "$GROUP" ] && agents_to_intro+=("agent${i}")
    done
  else
    for i in $(seq 1 "$AC"); do agents_to_intro+=("agent${i}"); done
  fi

  local intro_prompt="You just came online after a reboot. Reply with a brief introduction (2-3 sentences) - your name, model, and role. Be friendly but concise. Your reply will be automatically delivered."

  for agent_id in "${agents_to_intro[@]}"; do
    local num="${agent_id#agent}"
    local name_var="AGENT${num}_NAME"; local agent_name="${!name_var:-$agent_id}"
    log "  Sending intro for $agent_id ($agent_name)..."

    local env_prefix=""
    [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"

    timeout 90 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
      --agent "$agent_id" --message "$intro_prompt" --deliver \
      --reply-channel "$HC_PLATFORM" --reply-account "$agent_id" --reply-to "$owner_id" \
      --timeout 60 --json >> "$HC_LOG" 2>&1 && log "  ✓ $agent_name intro sent" || log "  ✗ $agent_name intro failed"
  done

  touch "$INTRO_SENT_MARKER"
  log "========== INTROS COMPLETE =========="
}

# send_safe_mode_intro() — now in lib-notify.sh as notify_send_safe_mode_intro()

# =============================================================================
# Main
# =============================================================================

HEALTHY=false

if hc_is_in_safe_mode; then
  # Safe mode: verify safe-mode agent works (unified path)
  log "Safe mode: testing safe-mode agent E2E"
  if check_agents_e2e "safe-mode"; then
    HEALTHY=true
  fi
else
  # Normal mode: validate channels, then run E2E (unified path)
  log "Normal mode: channel check + E2E"
  if check_channel_connectivity && check_agents_e2e; then
    HEALTHY=true
  fi
fi

# =============================================================================
# Handle Results
# =============================================================================

log "========== E2E DECISION =========="
log "HEALTHY=$HEALTHY, ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE"

if [ "$HEALTHY" = "true" ] && [ "$ALREADY_IN_SAFE_MODE" = "true" ]; then
  log "DECISION: SAFE MODE STABLE — recovery config working"
  rm -f "$HC_UNHEALTHY_MARKER" "$HC_RECOVERY_COUNTER" "/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}" /var/lib/init-status/needs-post-boot-check
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete
  notify_send_safe_mode_intro

elif [ "$HEALTHY" = "true" ]; then
  log "DECISION: SUCCESS — all agents healthy"
  rm -f "$SAFE_MODE_FILE" "$HC_UNHEALTHY_MARKER" "$HC_RECOVERY_COUNTER" "/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}" /var/lib/init-status/needs-post-boot-check
  for si in $(seq 1 "$AC"); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete

  # Send agent intros (only on fresh boot, skipped on re-checks)
  send_agent_intros

else
  log "DECISION: UNHEALTHY — writing marker"
  touch "$HC_UNHEALTHY_MARKER"
fi

log "============================================================"
log "========== E2E HEALTH CHECK COMPLETE =========="
log "============================================================"
# E2E service always exits 0 — recovery is handled by safeguard .path unit
exit 0
