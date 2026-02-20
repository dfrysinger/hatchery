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
      [[ "$cfg_anthropic" == sk-ant-oat* ]] && auth_header="Authorization: Bearer ${cfg_anthropic}" || auth_header="x-api-key: ${cfg_anthropic}"
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
    [[ "${ANTHROPIC_API_KEY}" == sk-ant-oat* ]] && auth_header="Authorization: Bearer ${ANTHROPIC_API_KEY}" || auth_header="x-api-key: ${ANTHROPIC_API_KEY}"
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
    if [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      log "  Channel connectivity verified (safe mode)"; return 0
    fi

    local dc_token
    dc_token=$(jq -r '.channels.discord.accounts["safe-mode"].token // .channels.discord.accounts.default.token // .channels.discord.token // empty' "$config_file" 2>/dev/null)
    if [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
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
      [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token" && { log "  Agent${i} Telegram OK"; agent_valid=true; }
    fi

    if [ "$HC_PLATFORM" = "discord" ] || [ "$HC_PLATFORM" = "both" ]; then
      local dc_token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local dc_token="${!dc_token_var:-}"
      [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token" && { log "  Agent${i} Discord OK"; agent_valid=true; }
    fi

    if [ "$agent_valid" = "false" ]; then
      all_valid=false; failed_agents="${failed_agents} agent${i}"
    fi
  done

  [ "$all_valid" = "false" ] && { log "  Channel check FAILED:${failed_agents}"; return 1; }
  log "  All $AC agents have valid tokens"; return 0
}

check_safe_mode_e2e() {
  log "  Testing safe-mode agent E2E..."

  local env_prefix=""
  [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"

  local output
  output=$(timeout 60 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
    --agent "safe-mode" --message "Reply with exactly: HEALTH_CHECK_OK" --timeout 30 --json 2>&1)
  local rc=$?

  if [ $rc -eq 0 ] && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
    log "  ✓ safe-mode agent responded"; return 0
  fi
  log "  ✗ safe-mode agent FAILED (exit=$rc)"
  echo "$output" | while IFS= read -r line; do log "    | $line"; done
  return 1
}

check_agents_e2e() {
  log "========== E2E AGENT CHECK =========="

  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local all_healthy=true failed_agents=""
  local agents_to_check=()

  if [ -n "$GROUP" ]; then
    for i in $(seq 1 "$AC"); do
      local gvar="AGENT${i}_ISOLATION_GROUP"; [ "${!gvar:-}" = "$GROUP" ] && agents_to_check+=("agent${i}")
    done
    log "  GROUP=$GROUP agents: ${agents_to_check[*]}"
  else
    for i in $(seq 1 "$AC"); do agents_to_check+=("agent${i}"); done
    log "  STANDARD: ${#agents_to_check[@]} agents"
  fi

  local owner_id
  owner_id=$(get_owner_id_for_platform "$HC_PLATFORM" "with_prefix")
  [ -z "$owner_id" ] || [ "$owner_id" = "user:" ] && { log "  No owner ID"; return 1; }

  local intro_prompt="You just came online after a reboot. Reply with a brief introduction (2-3 sentences) - your name, model, and role. Be friendly but concise. Your reply will be automatically delivered."

  for agent_id in "${agents_to_check[@]}"; do
    local num="${agent_id#agent}"
    local name_var="AGENT${num}_NAME"; local agent_name="${!name_var:-$agent_id}"
    local model_var="AGENT${num}_MODEL"; local agent_model="${!model_var:-unknown}"
    log "  -------- $agent_id ($agent_name, $agent_model) --------"

    local start_time; start_time=$(date +%s)
    local env_prefix=""
    [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"

    local output
    output=$(timeout 90 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
      --agent "$agent_id" --message "$intro_prompt" --deliver \
      --reply-channel "$HC_PLATFORM" --reply-account "$agent_id" --reply-to "$owner_id" \
      --timeout 60 --json 2>&1)
    local rc=$?
    local dur=$(( $(date +%s) - start_time ))

    if [ $rc -eq 0 ] && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
      log "  ✓ $agent_name in ${dur}s"
    else
      log "  ✗ $agent_name FAILED (exit=$rc, ${dur}s)"
      echo "$output" | while IFS= read -r line; do log "    | $line"; done
      all_healthy=false; failed_agents="${failed_agents} ${agent_name}"
    fi
  done

  [ "$all_healthy" = "false" ] && { log "  RESULT: FAILED —${failed_agents}"; return 1; }
  log "  RESULT: All agents passed"
  log "========== E2E CHECK COMPLETE ==========="; return 0
}

# =============================================================================
# SafeModeBot intro (sends diagnostics to user)
# =============================================================================

send_safe_mode_intro() {
  log "========== SAFE MODE BOT INTRO =========="

  # Generate boot report
  local report="$H/clawd/agents/safe-mode/BOOT_REPORT.md"
  mkdir -p "$(dirname "$report")"
  cat > "$report" <<REPORT
# Boot Report - Safe Mode Active
## Recovery Actions
$(grep -E "Recovery|recovery|SAFE MODE|token|API" "$HC_LOG" 2>/dev/null | tail -20)
## Next Steps
1. Check which credentials failed
2. Review $HC_LOG for details
3. Fix credentials in habitat config
REPORT
  chown "$HC_USERNAME:$HC_USERNAME" "$report" 2>/dev/null

  local owner_id
  owner_id=$(get_owner_id_for_platform "$HC_PLATFORM" "with_prefix")
  local has_sm
  has_sm=$(jq -r '.agents.list[]? | select(.id == "safe-mode") | .id' "$CONFIG_PATH" 2>/dev/null)

  if [ -z "$has_sm" ] || [ -z "$owner_id" ] || [ "$owner_id" = "user:" ]; then
    log "  Skipping (no safe-mode agent or owner)"; return 0
  fi

  local env_prefix=""
  [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"
  [ -n "${GROUP:-}" ] && [ -n "${GROUP_PORT:-}" ] && env_prefix="$env_prefix OPENCLAW_GATEWAY_URL=ws://127.0.0.1:${GROUP_PORT}"

  local prompt="You just came online in SAFE MODE after a boot failure.

IMPORTANT: Just reply directly - your response will be automatically delivered. Do NOT use the message tool.

Read BOOT_REPORT.md and reply with: 1) Brief intro 2) What went wrong 3) Offer to help. Keep it to 3-5 sentences."

  local output
  output=$(timeout 120 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
    --agent "safe-mode" --message "$prompt" --deliver \
    --reply-channel "$HC_PLATFORM" --reply-account "safe-mode" --reply-to "$owner_id" \
    --timeout 90 --json 2>&1)

  if [ $? -eq 0 ] && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
    log "  ✓ SafeModeBot intro sent"
  else
    log "  ✗ SafeModeBot intro failed (user already notified via API)"
  fi
  log "========== SAFE MODE INTRO COMPLETE =========="
}

# =============================================================================
# Main
# =============================================================================

HEALTHY=false

if hc_is_in_safe_mode; then
  # Safe mode (Run 2): verify safe-mode agent works
  log "Safe mode: testing safe-mode agent E2E"
  if check_safe_mode_e2e; then
    HEALTHY=true
  fi
else
  # Normal mode: validate channels, then run full E2E
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
  rm -f "$HC_UNHEALTHY_MARKER" "$HC_RECOVERY_COUNTER" "/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete
  send_safe_mode_intro

elif [ "$HEALTHY" = "true" ]; then
  log "DECISION: SUCCESS — all agents healthy"
  rm -f "$SAFE_MODE_FILE" "$HC_UNHEALTHY_MARKER" "$HC_RECOVERY_COUNTER" "/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
  for si in $(seq 1 "$AC"); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete

else
  log "DECISION: UNHEALTHY — writing marker"
  touch "$HC_UNHEALTHY_MARKER"
fi

log "============================================================"
log "========== E2E HEALTH CHECK COMPLETE =========="
log "============================================================"
# E2E service always exits 0 — recovery is handled by safeguard .path unit
exit 0
