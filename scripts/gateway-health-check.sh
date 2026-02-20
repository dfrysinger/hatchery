#!/bin/bash
# =============================================================================
# gateway-health-check.sh — Gateway health check (check only, no recovery)
# =============================================================================
# Purpose:  Validates gateway health after startup. If unhealthy, writes a
#           marker file and exits with code 1. Recovery is handled separately
#           by safe-mode-handler.sh (triggered via systemd .path unit).
#
# Called by:
#   - openclaw*.service ExecStartPost (on every restart)
#   - Can also run standalone for diagnostics
#
# Exit codes:
#   0 = healthy
#   1 = unhealthy (marker written, systemd will restart via Restart=on-failure)
# =============================================================================

# Source shared libraries
for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-notify.sh" ] && { source "$lib_path/lib-notify.sh"; break; }
done
[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh

# Initialize
RUN_MODE="${RUN_MODE:-standalone}"
hc_init_logging "${GROUP:-}"
hc_load_environment || exit 0  # Don't fail if env missing (non-hatchery system)

log "============================================================"
log "========== GATEWAY HEALTH CHECK STARTING =========="
log "============================================================"
log "RUN_ID=$HC_RUN_ID | MODE=$RUN_MODE | GROUP=${GROUP:-none} | PID=$$"

# --- Skip if recently recovered ---
RECENTLY_RECOVERED_FILE="/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
RECENTLY_RECOVERED_TTL=120

if [ "$RUN_MODE" = "execstartpost" ] && [ -f "$RECENTLY_RECOVERED_FILE" ]; then
  recovered_at=$(cat "$RECENTLY_RECOVERED_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - recovered_at))
  if [ "$age" -lt "$RECENTLY_RECOVERED_TTL" ]; then
    log "Skipping — recovered ${age}s ago (TTL=${RECENTLY_RECOVERED_TTL}s)"
    exit 0
  fi
fi

# --- Entry state instrumentation ---
log "Init status files:"
for f in /var/lib/init-status/*; do
  [ -f "$f" ] && log "  $f = $(cat "$f" 2>/dev/null || echo '(empty)')"
done
log "Config: CONFIG_PATH=$CONFIG_PATH"
[ -f "$CONFIG_PATH" ] && log "  config exists ($(wc -c < "$CONFIG_PATH") bytes)"
[ -f "$H/.openclaw/openclaw.emergency.json" ] && log "  openclaw.emergency.json exists ($(wc -c < "$H/.openclaw/openclaw.emergency.json") bytes)"
[ -f "$H/.openclaw/openclaw.full.json" ] && log "  openclaw.full.json exists ($(wc -c < "$H/.openclaw/openclaw.full.json") bytes)"

if [ -f "$CONFIG_PATH" ]; then
  CURRENT_MODEL=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$CONFIG_PATH" 2>/dev/null)
  CURRENT_ENV_KEYS=$(jq -r '.env | keys | join(",")' "$CONFIG_PATH" 2>/dev/null)
  log "Current config: model=$CURRENT_MODEL, env_keys=$CURRENT_ENV_KEYS"
fi

ALREADY_IN_SAFE_MODE=false
RECOVERY_ATTEMPTS=0
hc_is_in_safe_mode && ALREADY_IN_SAFE_MODE=true
RECOVERY_ATTEMPTS=$(hc_get_recovery_attempts)
log "ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS"

# =============================================================================
# Health Check Functions
# =============================================================================

check_api_key_validity() {
  local service="$1"

  log "  Checking API key validity..."

  local config_file="$CONFIG_PATH"

  # In safe mode, validate key from config directly
  if [ -f "$SAFE_MODE_FILE" ] && [ -f "$config_file" ]; then
    log "  Safe mode active — checking API from config"

    local cfg_anthropic cfg_google cfg_openai
    cfg_anthropic=$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$config_file" 2>/dev/null)
    cfg_google=$(jq -r '.env.GOOGLE_API_KEY // empty' "$config_file" 2>/dev/null)
    cfg_openai=$(jq -r '.env.OPENAI_API_KEY // empty' "$config_file" 2>/dev/null)

    if [ -n "$cfg_google" ]; then
      if curl -sf --max-time 5 \
        "https://generativelanguage.googleapis.com/v1/models?key=${cfg_google}" >/dev/null 2>&1; then
        log "  Safe mode Google API key OK"; return 0
      fi
    fi

    if [ -n "$cfg_anthropic" ]; then
      local auth_header
      if [[ "$cfg_anthropic" == sk-ant-oat* ]]; then
        auth_header="Authorization: Bearer ${cfg_anthropic}"
      else
        auth_header="x-api-key: ${cfg_anthropic}"
      fi
      if curl -sf --max-time 5 \
        -H "$auth_header" -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" >/dev/null 2>&1; then
        log "  Safe mode Anthropic API key OK"; return 0
      fi
    fi

    if [ -n "$cfg_openai" ]; then
      if curl -sf --max-time 5 \
        -H "Authorization: Bearer ${cfg_openai}" \
        "https://api.openai.com/v1/models" >/dev/null 2>&1; then
        log "  Safe mode OpenAI API key OK"; return 0
      fi
    fi

    log "  Safe mode config has no working API key"; return 1
  fi

  # Normal mode: check journal for auth errors
  local auth_errors
  auth_errors=$(journalctl -u "$service" --since "30 seconds ago" --no-pager 2>/dev/null | \
    grep -iE "(authentication_error|Invalid.*bearer.*token|invalid.*api.*key)" | head -3)

  if [ -n "$auth_errors" ]; then
    log "  Found API auth errors in journal"; return 1
  fi

  # Direct API validation from env vars
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    local auth_header
    if [[ "${ANTHROPIC_API_KEY}" == sk-ant-oat* ]]; then
      auth_header="Authorization: Bearer ${ANTHROPIC_API_KEY}"
    else
      auth_header="x-api-key: ${ANTHROPIC_API_KEY}"
    fi
    local response
    response=$(curl -sf --max-time 5 \
      -H "$auth_header" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
      -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      "https://api.anthropic.com/v1/messages" 2>&1)
    if ! echo "$response" | grep -qiE "(authentication_error|invalid.*key|401)"; then
      log "  Anthropic API key OK"; return 0
    fi
  fi

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    if curl -sf --max-time 5 -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      "https://api.openai.com/v1/models" >/dev/null 2>&1; then
      log "  OpenAI API key OK"; return 0
    fi
  fi

  if [ -n "${GOOGLE_API_KEY:-}" ]; then
    if curl -sf --max-time 5 \
      "https://generativelanguage.googleapis.com/v1/models?key=${GOOGLE_API_KEY}" >/dev/null 2>&1; then
      log "  Google API key OK"; return 0
    fi
  fi

  log "  No working API keys found"; return 1
}

check_channel_connectivity() {
  log "  Checking channel connectivity..."

  local config_file="$CONFIG_PATH"

  # Safe mode: validate token from config
  if [ -f "$SAFE_MODE_FILE" ] && [ -f "$config_file" ]; then
    log "  Safe mode active — validating safe mode config token"

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

    log "  Safe mode config has no working chat tokens"; return 1
  fi

  # Normal mode: validate ALL agents
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local platform="${HC_PLATFORM}"
  local count="$AC"
  local all_valid=true
  local failed_agents=""

  log "  Platform: $platform, Agent count: $count"

  for i in $(seq 1 "$count"); do
    local agent_valid=false

    if [ "$platform" = "telegram" ] || [ "$platform" = "both" ]; then
      local tg_token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local tg_token="${!tg_token_var:-}"
      [ -z "$tg_token" ] && tg_token_var="AGENT${i}_BOT_TOKEN" && tg_token="${!tg_token_var:-}"
      if [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
        log "  Agent${i} Telegram token valid"; agent_valid=true
      fi
    fi

    if [ "$platform" = "discord" ] || [ "$platform" = "both" ]; then
      local dc_token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local dc_token="${!dc_token_var:-}"
      if [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
        log "  Agent${i} Discord token valid"; agent_valid=true
      fi
    fi

    if [ "$agent_valid" = "false" ]; then
      all_valid=false
      failed_agents="${failed_agents} agent${i}"
      log "  Agent${i} has NO working tokens for platform '$platform'"
    fi
  done

  if [ "$all_valid" = "false" ]; then
    log "  Channel check FAILED — broken agents:${failed_agents}"; return 1
  fi

  log "  Channel connectivity verified (all $count agents valid)"; return 0
}

# E2E safe-mode agent check
check_safe_mode_e2e() {
  log "========== SAFE MODE E2E CHECK =========="

  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local owner_id
  owner_id=$(get_owner_id_for_platform "$HC_PLATFORM" "with_prefix")

  if [ -z "$owner_id" ] || [ "$owner_id" = "user:" ]; then
    log "  ERROR: No owner ID"; return 1
  fi

  local env_prefix=""
  [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"

  local output
  output=$(timeout 60 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
    --agent "safe-mode" \
    --message "Reply with exactly: HEALTH_CHECK_OK" \
    --timeout 30 \
    --json 2>&1)
  local exit_code=$?

  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
    log "  ✓ safe-mode agent responded"; log "========== SAFE MODE E2E PASSED =========="; return 0
  else
    log "  ✗ safe-mode agent FAILED (exit=$exit_code)"
    echo "$output" | while IFS= read -r line; do log "    | $line"; done
    log "========== SAFE MODE E2E FAILED =========="; return 1
  fi
}

# E2E check for all agents
check_agents_e2e() {
  log "========== E2E AGENT HEALTH CHECK =========="

  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  local all_healthy=true
  local failed_agents=""
  local agents_to_check=()
  local count="$AC"

  if [ -n "$GROUP" ]; then
    for i in $(seq 1 "$count"); do
      local agent_group_var="AGENT${i}_ISOLATION_GROUP"
      local agent_group="${!agent_group_var:-}"
      [ "$agent_group" = "$GROUP" ] && agents_to_check+=("agent${i}")
    done
    log "  GROUP MODE: group=$GROUP, agents: ${agents_to_check[*]}"
  else
    for i in $(seq 1 "$count"); do agents_to_check+=("agent${i}"); done
    log "  STANDARD MODE: ${#agents_to_check[@]} agents"
  fi

  local channel="$HC_PLATFORM"
  local owner_id
  owner_id=$(get_owner_id_for_platform "$HC_PLATFORM" "with_prefix")

  if [ -z "$owner_id" ] || [ "$owner_id" = "user:" ]; then
    log "  ERROR: No owner ID for platform '$HC_PLATFORM'"; return 1
  fi

  local intro_prompt="You just came online after a reboot. Reply with a brief introduction (2-3 sentences) - your name, model, and role. Be friendly but concise. Your reply will be automatically delivered."

  for agent_id in "${agents_to_check[@]}"; do
    local agent_num="${agent_id#agent}"
    local name_var="AGENT${agent_num}_NAME"
    local model_var="AGENT${agent_num}_MODEL"
    local agent_name="${!name_var:-$agent_id}"
    local agent_model="${!model_var:-unknown}"

    log "  -------- Testing $agent_id --------"
    log "  Agent: $agent_name, Model: $agent_model"

    local start_time; start_time=$(date +%s)

    local env_prefix=""
    [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"

    local output
    output=$(timeout 90 sudo -u "$HC_USERNAME" env $env_prefix openclaw agent \
      --agent "$agent_id" \
      --message "$intro_prompt" \
      --deliver \
      --reply-channel "$channel" \
      --reply-account "$agent_id" \
      --reply-to "$owner_id" \
      --timeout 60 \
      --json 2>&1)
    local exit_code=$?

    local duration=$(( $(date +%s) - start_time ))

    if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
      log "  ✓ SUCCESS: $agent_name in ${duration}s"
    else
      log "  ✗ FAILED: $agent_name (exit=$exit_code, ${duration}s)"
      echo "$output" | while IFS= read -r line; do log "    | $line"; done
      all_healthy=false
      failed_agents="${failed_agents} ${agent_name}"
    fi
  done

  log "  -------- E2E Summary --------"
  if [ "$all_healthy" = "false" ]; then
    log "  RESULT: FAILED — broken:${failed_agents}"; return 1
  fi
  log "  RESULT: SUCCESS — All agents responded"
  log "========== E2E CHECK COMPLETE ==========="; return 0
}

# HTTP + E2E health check with adaptive timeout
check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-12}"
  local hard_max_seconds="${HEALTH_CHECK_HARD_MAX_SECS:-300}"
  local warn_after_seconds="${HEALTH_CHECK_WARN_SECS:-120}"
  local start_time; start_time=$(date +%s)
  local warned=false
  local process_seen=false

  log "Health check: $service on port $port (max_attempts=$max_attempts, hard_max=${hard_max_seconds}s)"

  for i in $(seq 1 "$max_attempts"); do
    sleep 5

    local elapsed=$(( $(date +%s) - start_time ))

    # Hard max timeout
    if [ "$elapsed" -ge "$hard_max_seconds" ]; then
      log "  HARD MAX TIMEOUT (${elapsed}s >= ${hard_max_seconds}s)"; return 1
    fi

    # Process-alive check
    if pgrep -f "openclaw.gateway.*--port.*${port}" >/dev/null 2>&1 || \
       pgrep -f "openclaw-gateway" >/dev/null 2>&1; then
      process_seen=true
    elif [ "$process_seen" = "true" ]; then
      log "  Gateway process DIED (was alive, now gone)"; return 1
    elif [ "$elapsed" -ge 60 ]; then
      log "  Gateway process never appeared after ${elapsed}s"; return 1
    fi

    # "Still waiting" notification
    if [ "$warned" = "false" ] && [ "$elapsed" -ge "$warn_after_seconds" ]; then
      warned=true
      log "  ⏳ Still waiting (${elapsed}s)..."
      notify_find_token 2>/dev/null && \
        notify_send_message "⏳ <b>[${HC_HABITAT_NAME}]</b> Gateway slow to start (${elapsed}s). Still trying..." 2>/dev/null || true
    fi

    # HTTP check
    if curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      log "  HTTP responding at ${elapsed}s"
      sleep 3

      # Run E2E checks
      if [ -f "$SAFE_MODE_FILE" ]; then
        log "  Safe mode: E2E check on safe-mode agent"
        if check_safe_mode_e2e; then
          log "  HEALTHY (safe mode E2E passed)"; return 0
        else
          log "  HTTP OK but safe-mode E2E failed"; return 1
        fi
      else
        log "  Normal mode: validating chat tokens"
        if ! check_channel_connectivity; then
          log "  Chat token validation FAILED"; return 1
        fi
        log "  Chat tokens OK — running E2E"
        if check_agents_e2e; then
          log "  HEALTHY"; return 0
        else
          log "  HTTP OK but E2E failed"; return 1
        fi
      fi
    fi

    log "  attempt $i/$max_attempts: HTTP not responding (process ${process_seen:+alive}${process_seen:-unknown}, ${elapsed}s)"

    # Extend attempts if process is alive
    if [ "$process_seen" = "true" ] && [ "$i" -ge "$max_attempts" ] && [ "$elapsed" -lt "$hard_max_seconds" ]; then
      max_attempts=$((max_attempts + 1))
    fi
  done

  log "  FAILED after all attempts"; return 1
}

# =============================================================================
# Main Health Check
# =============================================================================

# Settle wait
SETTLE_SECS="${HEALTH_CHECK_SETTLE_SECS:-45}"
log "Waiting ${SETTLE_SECS}s for gateway to settle..."
sleep "$SETTLE_SECS"

HEALTHY=false

# Run the check based on mode
if [ -n "$GROUP" ]; then
  log "Group mode: checking group '$GROUP' on port $GROUP_PORT"
  check_service_health "$SERVICE_NAME" "$GROUP_PORT" 12 && HEALTHY=true
elif [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  log "Session isolation mode (legacy — should not reach here)"
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  BASE_PORT=18790; idx=0; ALL_HEALTHY=true
  for group in "${GROUP_ARRAY[@]}"; do
    check_service_health "openclaw-${group}.service" $((BASE_PORT + idx)) 12 || ALL_HEALTHY=false
    idx=$((idx + 1))
  done
  HEALTHY=$ALL_HEALTHY
elif [ "$ISOLATION" = "container" ]; then
  log "Container isolation mode (legacy fallback)"
  check_service_health "openclaw-containers.service" 18790 12 && HEALTHY=true
else
  log "Standard mode"
  check_service_health "openclaw" 18789 12 && HEALTHY=true
fi

# =============================================================================
# Handle Results
# =============================================================================

log "========== HEALTH CHECK DECISION =========="
log "HEALTHY=$HEALTHY, ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS"

if [ "$HEALTHY" = "true" ] && [ "$ALREADY_IN_SAFE_MODE" = "true" ]; then
  # Safe mode config working — keep safe mode flag, clear unhealthy marker
  log "DECISION: SAFE MODE STABLE"
  rm -f "$HC_UNHEALTHY_MARKER" "$HC_RECOVERY_COUNTER" "/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete
  EXIT_CODE=0

  # Send safe mode notification (SafeModeBot intro)
  log "Safe mode verified — triggering SafeModeBot intro"
  # Inline the boot notification for safe mode (boot report + SafeModeBot intro)
  generate_safe_mode_boot_report() {
    local report_path="$H/clawd/agents/safe-mode/BOOT_REPORT.md"
    mkdir -p "$(dirname "$report_path")"
    cat > "$report_path" <<REPORT
# Boot Report - Safe Mode Active
## Recovery Actions
$(grep -E "Recovery|recovery|SAFE MODE|token|API" "$HC_LOG" 2>/dev/null | tail -20)
## Next Steps
1. Check which credentials failed
2. Review $HC_LOG for details
3. Fix credentials in habitat config
REPORT
    chown "$HC_USERNAME:$HC_USERNAME" "$report_path" 2>/dev/null
  }
  generate_safe_mode_boot_report

  # Send SafeModeBot intro
  local_owner_id=$(get_owner_id_for_platform "$HC_PLATFORM" "with_prefix")
  local_has_sm=$(jq -r '.agents.list[]? | select(.id == "safe-mode") | .id' "$CONFIG_PATH" 2>/dev/null)

  if [ -n "$local_has_sm" ] && [ -n "$local_owner_id" ] && [ "$local_owner_id" != "user:" ]; then
    local_env_prefix=""
    [ -n "${GROUP:-}" ] && local_env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH OPENCLAW_STATE_DIR=$H/.openclaw-sessions/$GROUP"
    [ -n "${GROUP:-}" ] && [ -n "${GROUP_PORT:-}" ] && local_env_prefix="$local_env_prefix OPENCLAW_GATEWAY_URL=ws://127.0.0.1:${GROUP_PORT}"

    local_channel="${HC_PLATFORM}"
    log "  SafeModeBot intro: channel=$local_channel owner=$local_owner_id"

    local_output=$(timeout 120 sudo -u "$HC_USERNAME" env $local_env_prefix openclaw agent \
      --agent "safe-mode" \
      --message "You just came online in SAFE MODE after a boot failure. Read BOOT_REPORT.md and reply with: 1) Brief intro 2) What went wrong 3) Offer to help. Keep it to 3-5 sentences." \
      --deliver --reply-channel "$local_channel" --reply-account "safe-mode" --reply-to "$local_owner_id" \
      --timeout 90 --json 2>&1)

    if [ $? -eq 0 ] && ! echo "$local_output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
      log "  ✓ SafeModeBot intro sent"
    else
      log "  ✗ SafeModeBot intro failed"
    fi
  fi

elif [ "$HEALTHY" = "true" ]; then
  # Full config healthy
  log "DECISION: SUCCESS — gateway healthy"
  rm -f "$SAFE_MODE_FILE" "$HC_UNHEALTHY_MARKER" "$HC_RECOVERY_COUNTER" "/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
  for si in $(seq 1 "$AC"); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete
  EXIT_CODE=0

else
  # Unhealthy — write marker for safe-mode-handler.sh
  log "DECISION: UNHEALTHY — writing marker $HC_UNHEALTHY_MARKER"
  touch "$HC_UNHEALTHY_MARKER"

  if [ "$RUN_MODE" = "execstartpost" ]; then
    log "ExecStartPost mode: returning exit 1 for systemd restart"
    EXIT_CODE=1
  else
    # Standalone mode: invoke handler directly
    log "Standalone mode: invoking safe-mode-handler.sh"
    GROUP="${GROUP:-}" GROUP_PORT="${GROUP_PORT:-}" /usr/local/bin/safe-mode-handler.sh
    EXIT_CODE=$?
  fi
fi

log "============================================================"
log "========== GATEWAY HEALTH CHECK COMPLETE =========="
log "============================================================"
log "RUN_ID=$HC_RUN_ID | EXIT=$EXIT_CODE | HEALTHY=$HEALTHY | SAFE_MODE=$ALREADY_IN_SAFE_MODE"
exit "$EXIT_CODE"
