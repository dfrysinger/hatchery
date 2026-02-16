#!/bin/bash
# =============================================================================
# gateway-health-check.sh -- Universal gateway health check and safe mode recovery
# =============================================================================
# Purpose:  Validates gateway health after any restart. If unhealthy, triggers
#           safe mode recovery. Called by:
#           - post-boot-check.sh (at system boot)
#           - apply-config.sh (after config changes)
#           - clawdbot.service ExecStartPost (on every restart)
#
# Modes:
#   RUN_MODE=standalone (default): restarts service directly after recovery
#   RUN_MODE=execstartpost: returns exit code, lets systemd handle restart
#
# Exit codes:
#   0 = healthy
#   1 = failed, entered safe mode (config replaced, needs restart)
#   2 = critical failure (emergency config also broken, don't restart)
# =============================================================================

LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check.log}"
RUN_MODE="${RUN_MODE:-standalone}"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"
}

log "========== GATEWAY HEALTH CHECK STARTING (mode=$RUN_MODE) =========="

# =============================================================================
# Skip if recently recovered (prevents cascade from standalone → ExecStartPost)
# =============================================================================
RECENTLY_RECOVERED_FILE="/var/lib/init-status/recently-recovered"
RECENTLY_RECOVERED_TTL=120  # seconds

if [ "$RUN_MODE" = "execstartpost" ] && [ -f "$RECENTLY_RECOVERED_FILE" ]; then
  recovered_at=$(cat "$RECENTLY_RECOVERED_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - recovered_at))
  
  if [ "$age" -lt "$RECENTLY_RECOVERED_TTL" ]; then
    log "Skipping ExecStartPost health check - recovered ${age}s ago (TTL=${RECENTLY_RECOVERED_TTL}s)"
    exit 0
  fi
fi

# Source environment
if [ -f /etc/droplet.env ]; then
  set -a; source /etc/droplet.env; set +a
else
  log "ERROR: /etc/droplet.env not found"
  exit 0  # Don't fail if env missing (might be non-hatchery system)
fi

d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

if [ -f /etc/habitat-parsed.env ]; then
  source /etc/habitat-parsed.env
else
  log "ERROR: /etc/habitat-parsed.env not found"
  exit 0
fi

# Decode API keys from base64
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(d "$ANTHROPIC_KEY_B64")}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-$(d "$OPENAI_KEY_B64")}"
export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$(d "$GOOGLE_API_KEY_B64")}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-$(d "$BRAVE_KEY_B64")}"

# Set working variables
AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
ISOLATION="${ISOLATION_DEFAULT:-none}"
SESSION_GROUPS="${ISOLATION_GROUPS:-}"

log "Config: isolation=$ISOLATION groups=$SESSION_GROUPS agents=$AC"

# =============================================================================
# Recovery Attempt Tracking (prevents infinite loops)
# =============================================================================
# Allow up to 2 recovery attempts. This handles:
# - SafeModeBot modifying config and breaking it (attempt 2 fixes)
# - User breaking the emergency config (attempt 2 fixes)
# - True critical failure (give up after 2 attempts)

MAX_RECOVERY_ATTEMPTS=2
RECOVERY_COUNTER_FILE="/var/lib/init-status/recovery-attempts"

ALREADY_IN_SAFE_MODE=false
RECOVERY_ATTEMPTS=0

# === INSTRUMENTATION: Entry state ===
log "========== HEALTH CHECK START =========="
log "RUN_MODE=$RUN_MODE"
log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "PID: $$"
log "Init status files:"
for f in /var/lib/init-status/*; do
  [ -f "$f" ] && log "  $f = $(cat "$f" 2>/dev/null || echo '(empty)')"
done
log "Config files:"
[ -f "$H/.openclaw/openclaw.json" ] && log "  openclaw.json exists ($(wc -c < "$H/.openclaw/openclaw.json") bytes)"
[ -f "$H/.openclaw/openclaw.emergency.json" ] && log "  openclaw.emergency.json exists ($(wc -c < "$H/.openclaw/openclaw.emergency.json") bytes)"
[ -f "$H/.openclaw/openclaw.full.json" ] && log "  openclaw.full.json exists ($(wc -c < "$H/.openclaw/openclaw.full.json") bytes)"

# Check current config model
if [ -f "$H/.openclaw/openclaw.json" ]; then
  CURRENT_MODEL=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$H/.openclaw/openclaw.json" 2>/dev/null)
  CURRENT_ENV_KEYS=$(jq -r '.env | keys | join(",")' "$H/.openclaw/openclaw.json" 2>/dev/null)
  log "Current config: model=$CURRENT_MODEL, env_keys=$CURRENT_ENV_KEYS"
fi

if [ -f /var/lib/init-status/safe-mode ]; then
  ALREADY_IN_SAFE_MODE=true
  [ -f "$RECOVERY_COUNTER_FILE" ] && RECOVERY_ATTEMPTS=$(cat "$RECOVERY_COUNTER_FILE" 2>/dev/null || echo 0)
  log "NOTE: Already in safe mode (recovery attempts: $RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS)"
fi
log "ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS"

# =============================================================================
# Health Check Functions
# =============================================================================

validate_telegram_token_direct() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  local response
  response=$(curl -sf --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>&1)
  
  if [ $? -eq 0 ] && echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    return 0
  fi
  
  log "  Telegram token validation failed: $response"
  return 1
}

validate_discord_token_direct() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  local response
  response=$(curl -sf --max-time 10 \
    -H "Authorization: Bot ${token}" \
    "https://discord.com/api/v10/users/@me" 2>&1)
  
  if [ $? -eq 0 ] && echo "$response" | jq -e '.id' >/dev/null 2>&1; then
    return 0
  fi
  
  log "  Discord token validation failed: $response"
  return 1
}

check_api_key_validity() {
  local service="$1"
  
  log "  Checking API key validity..."
  
  local config_file="$H/.openclaw/openclaw.json"
  
  # In safe mode, read API key from actual config (recovery may have changed provider)
  if [ -f /var/lib/init-status/safe-mode ] && [ -f "$config_file" ]; then
    log "  Safe mode active - checking API from config"
    
    # Try to get API key from config env section
    local cfg_anthropic=$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$config_file" 2>/dev/null)
    local cfg_google=$(jq -r '.env.GOOGLE_API_KEY // empty' "$config_file" 2>/dev/null)
    local cfg_openai=$(jq -r '.env.OPENAI_API_KEY // empty' "$config_file" 2>/dev/null)
    
    # Test whichever key is in the config
    if [ -n "$cfg_google" ]; then
      if curl -sf --max-time 5 \
        "https://generativelanguage.googleapis.com/v1/models?key=${cfg_google}" >/dev/null 2>&1; then
        log "  Safe mode Google API key OK"
        return 0
      fi
    fi
    
    if [ -n "$cfg_anthropic" ]; then
      local response
      response=$(curl -sf --max-time 5 \
        -H "x-api-key: ${cfg_anthropic}" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" 2>&1)
      if [ $? -eq 0 ]; then
        log "  Safe mode Anthropic API key OK"
        return 0
      fi
    fi
    
    if [ -n "$cfg_openai" ]; then
      if curl -sf --max-time 5 \
        -H "Authorization: Bearer ${cfg_openai}" \
        "https://api.openai.com/v1/models" >/dev/null 2>&1; then
        log "  Safe mode OpenAI API key OK"
        return 0
      fi
    fi
    
    log "  Safe mode config has no working API key"
    return 1
  fi
  
  # Normal mode: Check journal for auth errors (only recent, after gateway started)
  local auth_errors
  auth_errors=$(journalctl -u "$service" --since "30 seconds ago" --no-pager 2>/dev/null | \
    grep -iE "(authentication_error|Invalid.*bearer.*token|invalid.*api.*key)" | head -3)
  
  if [ -n "$auth_errors" ]; then
    log "  Found API auth errors in journal"
    return 1
  fi
  
  # Direct API validation from env vars
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    local response
    response=$(curl -sf --max-time 5 \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      "https://api.anthropic.com/v1/messages" 2>&1)
    
    if ! echo "$response" | grep -qiE "(authentication_error|invalid.*key|401)"; then
      log "  Anthropic API key OK"
      return 0
    fi
  fi
  
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    if curl -sf --max-time 5 \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      "https://api.openai.com/v1/models" >/dev/null 2>&1; then
      log "  OpenAI API key OK"
      return 0
    fi
  fi
  
  if [ -n "${GOOGLE_API_KEY:-}" ]; then
    if curl -sf --max-time 5 \
      "https://generativelanguage.googleapis.com/v1/models?key=${GOOGLE_API_KEY}" >/dev/null 2>&1; then
      log "  Google API key OK"
      return 0
    fi
  fi
  
  log "  No working API keys found"
  return 1
}

check_channel_connectivity() {
  local service="$1"
  
  log "  Checking channel connectivity..."
  
  local token_valid=false
  local config_file="$H/.openclaw/openclaw.json"
  
  # In safe mode, read tokens from ACTUAL config (not habitat-parsed.env)
  # The safe mode config only contains the ONE working token
  if [ -f /var/lib/init-status/safe-mode ] && [ -f "$config_file" ]; then
    log "  Safe mode active - reading tokens from openclaw.json"
    
    # Try to extract Telegram token from config
    local tg_token=$(jq -r '.channels.telegram.botToken // empty' "$config_file" 2>/dev/null)
    if [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      log "  Safe mode Telegram token valid"
      token_valid=true
    fi
    
    # Try Discord if Telegram not configured or failed
    if [ "$token_valid" = "false" ]; then
      local dc_token=$(jq -r '.channels.discord.token // empty' "$config_file" 2>/dev/null)
      if [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
        log "  Safe mode Discord token valid"
        token_valid=true
      fi
    fi
    
    if [ "$token_valid" = "false" ]; then
      log "  Safe mode config has no working chat tokens"
    fi
  else
    # Normal mode: check all tokens from habitat-parsed.env
    [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
    
    local platform="${PLATFORM:-telegram}"
    local count="${AGENT_COUNT:-1}"
    
    for i in $(seq 1 "$count"); do
      if [ "$platform" = "telegram" ]; then
        local token="${!AGENT${i}_TELEGRAM_BOT_TOKEN:-}"
        [ -z "$token" ] && token="${!AGENT${i}_BOT_TOKEN:-}"
        
        if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
          log "  Agent${i} Telegram token valid"
          token_valid=true
          break
        fi
      elif [ "$platform" = "discord" ]; then
        local token="${!AGENT${i}_DISCORD_BOT_TOKEN:-}"
        
        if [ -n "$token" ] && validate_discord_token_direct "$token"; then
          log "  Agent${i} Discord token valid"
          token_valid=true
          break
        fi
      fi
    done
  fi
  
  # Try fallback platform (only in normal mode - safe mode already checked both)
  if [ "$token_valid" = "false" ] && [ ! -f /var/lib/init-status/safe-mode ]; then
    local fallback=""
    [ "$platform" = "telegram" ] && fallback="discord"
    [ "$platform" = "discord" ] && fallback="telegram"
    
    for i in $(seq 1 "$count"); do
      if [ "$fallback" = "telegram" ]; then
        local token="${!AGENT${i}_TELEGRAM_BOT_TOKEN:-}"
        [ -z "$token" ] && token="${!AGENT${i}_BOT_TOKEN:-}"
        
        if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
          log "  Agent${i} Telegram (fallback) token valid"
          token_valid=true
          break
        fi
      elif [ "$fallback" = "discord" ]; then
        local token="${!AGENT${i}_DISCORD_BOT_TOKEN:-}"
        
        if [ -n "$token" ] && validate_discord_token_direct "$token"; then
          log "  Agent${i} Discord (fallback) token valid"
          token_valid=true
          break
        fi
      fi
    done
  fi
  
  if [ "$token_valid" = "false" ]; then
    log "  All chat tokens are INVALID"
    return 1
  fi
  
  log "  Channel connectivity verified"
  return 0
}

check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-6}"
  
  log "Health check: $service on port $port"
  
  for i in $(seq 1 $max_attempts); do
    sleep 5
    
    if ! systemctl is-active --quiet "$service"; then
      log "  attempt $i/$max_attempts: service not active"
      continue
    fi
    
    if curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      log "  HTTP gateway responding"
      sleep 3
      
      if check_channel_connectivity "$service" && check_api_key_validity "$service"; then
        log "  HEALTHY"
        return 0
      else
        log "  HTTP OK but channel/API check failed"
        return 1
      fi
    fi
    log "  attempt $i/$max_attempts: HTTP not responding"
  done
  
  log "  FAILED after $max_attempts attempts"
  return 1
}

# =============================================================================
# Safe Mode Recovery
# =============================================================================

enter_safe_mode() {
  log "Entering SAFE MODE with smart recovery"
  
  # Source smart recovery functions
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$SCRIPT_DIR/safe-mode-recovery.sh" ] && source "$SCRIPT_DIR/safe-mode-recovery.sh"
  [ -f "/usr/local/bin/safe-mode-recovery.sh" ] && source "/usr/local/bin/safe-mode-recovery.sh"
  
  # Try recovery
  SMART_RECOVERY_SUCCESS=false
  if type run_full_recovery_escalation &>/dev/null; then
    log "Attempting full recovery escalation..."
    export HOME_DIR="$H" USERNAME="$USERNAME" RECOVERY_LOG="$LOG"
    
    local recovery_output
    recovery_output=$(run_full_recovery_escalation 2>&1)
    local recovery_exit=$?
    
    if [ $recovery_exit -eq 0 ]; then
      log "Recovery succeeded"
      log "Recovery output: $recovery_output"
      SMART_RECOVERY_SUCCESS=true
    else
      log "Recovery FAILED (exit $recovery_exit)"
      log "Recovery output: $recovery_output"
    fi
  elif type run_smart_recovery &>/dev/null; then
    log "Attempting smart recovery..."
    export HOME_DIR="$H" USERNAME="$USERNAME" RECOVERY_LOG="$LOG"
    
    local recovery_output
    recovery_output=$(run_smart_recovery 2>&1)
    local recovery_exit=$?
    
    if [ $recovery_exit -eq 0 ]; then
      log "Recovery succeeded"
      SMART_RECOVERY_SUCCESS=true
    else
      log "Recovery FAILED (exit $recovery_exit): $recovery_output"
    fi
  fi
  
  # Fall back to minimal config
  if [ "$SMART_RECOVERY_SUCCESS" = "false" ]; then
    log "!!! SMART RECOVERY FAILED - falling back to emergency.json !!!"
    log "Emergency config before copy:"
    if [ -f "$H/.openclaw/openclaw.emergency.json" ]; then
      local emerg_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$H/.openclaw/openclaw.emergency.json" 2>/dev/null)
      local emerg_keys=$(jq -r '.env | keys | join(",")' "$H/.openclaw/openclaw.emergency.json" 2>/dev/null)
      log "  emergency.json: model=$emerg_model, env_keys=$emerg_keys"
    else
      log "  ERROR: emergency.json does not exist!"
    fi
    cp "$H/.openclaw/openclaw.emergency.json" "$H/.openclaw/openclaw.json"
    chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
    chmod 600 "$H/.openclaw/openclaw.json"
    log "Config after fallback:"
    local new_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$H/.openclaw/openclaw.json" 2>/dev/null)
    log "  openclaw.json: model=$new_model"
  else
    log "Smart recovery succeeded - using recovery-generated config"
    log "Config after recovery:"
    local new_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$H/.openclaw/openclaw.json" 2>/dev/null)
    local new_keys=$(jq -r '.env | keys | join(",")' "$H/.openclaw/openclaw.json" 2>/dev/null)
    log "  openclaw.json: model=$new_model, env_keys=$new_keys"
  fi
  
  # Mark safe mode
  touch /var/lib/init-status/safe-mode
  
  # Create SAFE_MODE.md
  local status="minimal config"
  [ "$SMART_RECOVERY_SUCCESS" = "true" ] && status="smart recovery"
  
  for si in $(seq 1 $AC); do
    cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Config failed health checks

Recovery: **${status}**

Check logs: cat /var/log/gateway-health-check.log
SAFEMD
    chown $USERNAME:$USERNAME "$H/clawd/agents/agent${si}/SAFE_MODE.md"
  done
  
  # Stop isolation services if running
  if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
    IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
    for group in "${GROUP_ARRAY[@]}"; do
      systemctl stop "openclaw-${group}.service" 2>/dev/null || true
    done
  elif [ "$ISOLATION" = "container" ]; then
    systemctl stop openclaw-containers.service 2>/dev/null || true
  fi
  
  # Update stages
  echo '12' > /var/lib/init-status/stage
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=12 DESC=safe-mode" >> /var/log/init-stages.log
  
  log "Safe mode config applied"
}

restart_gateway() {
  log "Restarting clawdbot with safe mode config..."
  systemctl restart clawdbot
  sleep 5
  
  for attempt in 1 2 3; do
    if systemctl is-active --quiet clawdbot; then
      log "Clawdbot started (attempt $attempt)"
      
      # Rename bots
      /usr/local/bin/rename-bots.sh >> "$LOG" 2>&1 || true
      
      # Wake SafeModeBot in background
      (
        sleep 30
        GATEWAY_TOKEN=""
        [ -f "$H/.openclaw/gateway-token.txt" ] && GATEWAY_TOKEN=$(cat "$H/.openclaw/gateway-token.txt")
        if [ -n "$GATEWAY_TOKEN" ]; then
          sudo -u "$USERNAME" OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" openclaw system event \
            --text "Safe Mode active. Read BOOT_REPORT.md and diagnose what's broken." \
            --mode now >> "$LOG" 2>&1 || true
        fi
      ) &
      
      return 0
    fi
    log "Clawdbot not active, retry $attempt/3..."
    systemctl restart clawdbot
    sleep 5
  done
  
  log "CRITICAL: Clawdbot failed to start"
  touch /var/lib/init-status/gateway-failed
  echo '13' > /var/lib/init-status/stage
  return 1
}

# =============================================================================
# Main Health Check
# =============================================================================

# Wait for gateway to fully initialize
log "Waiting 30s for gateway to settle..."
sleep 30

HEALTHY=false

if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  log "Session isolation mode"
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  
  BASE_PORT=18790
  idx=0
  for group in "${GROUP_ARRAY[@]}"; do
    if check_service_health "openclaw-${group}.service" $((BASE_PORT + idx)) 6; then
      HEALTHY=true
      break
    fi
    idx=$((idx + 1))
  done

elif [ "$ISOLATION" = "container" ]; then
  log "Container isolation mode"
  check_service_health "openclaw-containers.service" 18790 6 && HEALTHY=true

else
  log "Standard mode"
  check_service_health "clawdbot" 18789 6 && HEALTHY=true
fi

# =============================================================================
# Handle Results
# =============================================================================

log "========== HEALTH CHECK DECISION =========="
log "HEALTHY=$HEALTHY, ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS"

if [ "$HEALTHY" = "true" ]; then
  log "DECISION: SUCCESS - gateway healthy, clearing safe mode state"
  rm -f /var/lib/init-status/safe-mode
  rm -f "$RECOVERY_COUNTER_FILE"
  rm -f "$RECENTLY_RECOVERED_FILE"
  for si in $(seq 1 $AC); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  EXIT_CODE=0

elif [ "$ALREADY_IN_SAFE_MODE" = "true" ] && [ "$RECOVERY_ATTEMPTS" -ge "$MAX_RECOVERY_ATTEMPTS" ]; then
  # Already tried recovery multiple times - give up
  log "CRITICAL: Still unhealthy after $RECOVERY_ATTEMPTS recovery attempts"
  log "Emergency config may be fundamentally broken or network issues"
  touch /var/lib/init-status/gateway-failed
  echo '13' > /var/lib/init-status/stage
  EXIT_CODE=2  # Don't trigger restart loop

else
  # Either first failure OR in safe mode but haven't exhausted retries
  # Re-run recovery (handles case where SafeModeBot broke the config)
  if [ "$ALREADY_IN_SAFE_MODE" = "true" ]; then
    log "Safe mode config unhealthy - re-running recovery (attempt $((RECOVERY_ATTEMPTS + 1))/$MAX_RECOVERY_ATTEMPTS)"
  fi
  
  enter_safe_mode
  
  # Increment recovery counter
  echo "$((RECOVERY_ATTEMPTS + 1))" > "$RECOVERY_COUNTER_FILE"
  
  if [ "$RUN_MODE" = "execstartpost" ]; then
    # Let systemd handle restart via exit code
    log "ExecStartPost mode: returning exit 1 for systemd restart"
    EXIT_CODE=1
  else
    # Standalone mode: restart directly and set marker to prevent cascade
    date +%s > "$RECENTLY_RECOVERED_FILE"
    if restart_gateway; then
      EXIT_CODE=1  # Recovered but was unhealthy
    else
      EXIT_CODE=2  # Critical failure
    fi
  fi
fi

# =============================================================================
# Send Notification
# =============================================================================

send_boot_notification() {
  local status="$1"  # healthy, safe-mode, critical
  
  # Prevent duplicate notifications
  local notification_file="/var/lib/init-status/notification-sent-${status}"
  if [ -f "$notification_file" ]; then
    log "Notification already sent for $status - skipping"
    return 0
  fi
  
  log "Sending notification: $status"
  
  # Get habitat name
  local habitat_name="${HABITAT_NAME:-Droplet}"
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  habitat_name="${HABITAT_NAME:-Droplet}"
  
  # Find a working token to send notification
  local platform="${PLATFORM:-telegram}"
  local send_token=""
  local owner_id=""
  
  # In safe mode, read token from emergency config
  if [ -f /var/lib/init-status/safe-mode ] && [ -f "$H/.openclaw/openclaw.json" ]; then
    send_token=$(jq -r '.channels.telegram.botToken // .channels.telegram.accounts.default.botToken // empty' "$H/.openclaw/openclaw.json" 2>/dev/null)
  fi
  
  # Fall back to habitat tokens
  if [ -z "$send_token" ]; then
    for i in $(seq 1 "${AGENT_COUNT:-1}"); do
      local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local token="${!token_var:-}"
      [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
      
      if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
        send_token="$token"
        break
      fi
    done
  fi
  
  owner_id="${TELEGRAM_OWNER_ID:-${TELEGRAM_USER_ID:-}}"
  
  if [ -z "$send_token" ] || [ -z "$owner_id" ]; then
    log "Cannot send notification - no working token or owner ID"
    return 1
  fi
  
  # Build message based on status
  local message=""
  case "$status" in
    healthy)
      local count="${AGENT_COUNT:-1}"
      if [ "$count" -gt 1 ]; then
        local agents_list=""
        for i in $(seq 1 "$count"); do
          local name_var="AGENT${i}_NAME"
          local name="${!name_var:-Agent${i}}"
          agents_list="${agents_list}• ${name} ✓
"
        done
        message="✅ <b>[${habitat_name}]</b> Ready!

<b>All ${count} agents online:</b>
${agents_list}"
      else
        local name="${AGENT1_NAME:-Agent1}"
        message="✅ <b>[${habitat_name}]</b> Ready!

${name} is online."
      fi
      ;;
      
    safe-mode)
      message="⚠️ <b>[${habitat_name}] SAFE MODE</b>

Health check failed. SafeModeBot is online to diagnose.

See BOOT_REPORT.md for details."
      ;;
      
    critical)
      message="🔴 <b>[${habitat_name}] CRITICAL FAILURE</b>

Gateway failed to start after multiple attempts.
Bot is OFFLINE - no connectivity available.

Check logs: <code>journalctl -u clawdbot -n 50</code>
See CRITICAL_FAILURE.md for recovery steps."
      ;;
  esac
  
  # Send via Telegram
  curl -sf --max-time 10 \
    "https://api.telegram.org/bot${send_token}/sendMessage" \
    -d "chat_id=${owner_id}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" >> "$LOG" 2>&1 && touch "$notification_file" || log "Notification send failed"
}

# Generate BOOT_REPORT.md for SafeModeBot
generate_boot_report_md() {
  local report_path="$H/clawd/agents/safe-mode/BOOT_REPORT.md"
  mkdir -p "$(dirname "$report_path")"
  
  cat > "$report_path" <<REPORT
# Boot Report - Safe Mode Active

## Status
Safe mode was triggered because the full config failed health checks.

## Recovery Actions Taken
$(cat /var/log/gateway-health-check.log 2>/dev/null | grep -E "Recovery|recovery|SAFE MODE|token|API" | tail -20)

## Diagnostics
$(cat /var/log/safe-mode-diagnostics.txt 2>/dev/null || echo "No diagnostics available")

## Next Steps
1. Check which credentials failed above
2. Review /var/log/gateway-health-check.log for details
3. Fix the broken credentials in habitat config
4. Upload new config via API or recreate droplet
REPORT
  
  chown $USERNAME:$USERNAME "$report_path" 2>/dev/null
  log "Generated BOOT_REPORT.md"
}

# Send notification based on outcome
if [ "$HEALTHY" = "true" ]; then
  send_boot_notification "healthy"
elif [ "$EXIT_CODE" = "2" ]; then
  send_boot_notification "critical"
else
  # Safe mode - generate report and notify
  generate_boot_report_md
  send_boot_notification "safe-mode"
fi

log "========== GATEWAY HEALTH CHECK COMPLETE (exit=$EXIT_CODE) =========="
exit $EXIT_CODE
