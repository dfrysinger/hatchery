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

# Logging setup
# In session isolation mode (GROUP set), use group-specific log file
# This ensures we capture all health check runs for each group
RUN_MODE="${RUN_MODE:-standalone}"
RUN_ID="$$-$(date +%s)"  # Unique ID for this health check run

if [ -n "${GROUP:-}" ]; then
  LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check-${GROUP}.log}"
else
  LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check.log}"
fi

# Security: restrict log file permissions (diagnostic context, no secrets)
umask 077
touch "$LOG" && chmod 600 "$LOG" 2>/dev/null || true

log() {
  local msg="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$RUN_ID] $*"
  echo "$msg" >> "$LOG"
  # Also log to journald for persistence (won't be lost on reboot)
  logger -t "health-check${GROUP:+-$GROUP}" "$*" 2>/dev/null || true
}

log "============================================================"
log "========== GATEWAY HEALTH CHECK STARTING =========="
log "============================================================"
log "RUN_ID=$RUN_ID | MODE=$RUN_MODE | GROUP=${GROUP:-none} | PID=$$"

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

# Per-group health check mode (for session isolation)
# When GROUP is set, we only check agents in that group
# Agents are derived from AGENT{N}_ISOLATION_GROUP in habitat-parsed.env (single source of truth)
GROUP="${GROUP:-}"
GROUP_PORT="${GROUP_PORT:-18789}"

if [ -n "$GROUP" ]; then
  SERVICE_NAME="openclaw-${GROUP}"
  log "Config: GROUP MODE - group=$GROUP port=$GROUP_PORT service=$SERVICE_NAME"
else
  SERVICE_NAME="clawdbot"
  log "Config: isolation=$ISOLATION groups=$SESSION_GROUPS agents=$AC"
fi

# =============================================================================
# Recovery Attempt Tracking (prevents infinite loops)
# =============================================================================
# Allow up to 2 recovery attempts. This handles:
# - SafeModeBot modifying config and breaking it (attempt 2 fixes)
# - User breaking the emergency config (attempt 2 fixes)
# - True critical failure (give up after 2 attempts)

MAX_RECOVERY_ATTEMPTS=2

# Per-group state files when GROUP is set (session isolation)
# This prevents different groups from interfering with each other's recovery state
if [ -n "$GROUP" ]; then
  RECOVERY_COUNTER_FILE="/var/lib/init-status/recovery-attempts-${GROUP}"
  SAFE_MODE_FILE="/var/lib/init-status/safe-mode-${GROUP}"
  CONFIG_PATH="$H/.openclaw-sessions/${GROUP}/openclaw.session.json"
else
  RECOVERY_COUNTER_FILE="/var/lib/init-status/recovery-attempts"
  SAFE_MODE_FILE="/var/lib/init-status/safe-mode"
  CONFIG_PATH="$H/.openclaw/openclaw.json"
fi

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
log "  CONFIG_PATH=$CONFIG_PATH"
[ -f "$CONFIG_PATH" ] && log "  config exists ($(wc -c < "$CONFIG_PATH") bytes)"
[ -f "$H/.openclaw/openclaw.emergency.json" ] && log "  openclaw.emergency.json exists ($(wc -c < "$H/.openclaw/openclaw.emergency.json") bytes)"
[ -f "$H/.openclaw/openclaw.full.json" ] && log "  openclaw.full.json exists ($(wc -c < "$H/.openclaw/openclaw.full.json") bytes)"

# Check current config model
if [ -f "$CONFIG_PATH" ]; then
  CURRENT_MODEL=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$CONFIG_PATH" 2>/dev/null)
  CURRENT_ENV_KEYS=$(jq -r '.env | keys | join(",")' "$CONFIG_PATH" 2>/dev/null)
  log "Current config: model=$CURRENT_MODEL, env_keys=$CURRENT_ENV_KEYS"
fi

if [ -f "$SAFE_MODE_FILE" ]; then
  ALREADY_IN_SAFE_MODE=true
  [ -f "$RECOVERY_COUNTER_FILE" ] && RECOVERY_ATTEMPTS=$(cat "$RECOVERY_COUNTER_FILE" 2>/dev/null || echo 0)
  log "NOTE: Already in safe mode (recovery attempts: $RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS)"
fi
log "ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS"

# =============================================================================
# Health Check Functions
# =============================================================================

# Get owner ID for a platform (single source of truth for owner ID logic)
# Usage: owner_id=$(get_owner_id_for_platform "telegram")
#        owner_id=$(get_owner_id_for_platform "discord" "with_prefix")
get_owner_id_for_platform() {
  local platform="$1"
  local with_prefix="${2:-}"  # Pass "with_prefix" to add "user:" for Discord
  
  case "$platform" in
    telegram)
      echo "${TELEGRAM_OWNER_ID:-${TELEGRAM_USER_ID:-}}"
      ;;
    discord)
      local raw_id="${DISCORD_OWNER_ID:-}"
      if [ "$with_prefix" = "with_prefix" ] && [ -n "$raw_id" ]; then
        echo "user:${raw_id}"
      else
        echo "$raw_id"
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

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
  
  local config_file="$CONFIG_PATH"
  
  # In safe mode, read API key from actual config (recovery may have changed provider)
  if [ -f "$SAFE_MODE_FILE" ] && [ -f "$config_file" ]; then
    log "  Safe mode active - checking API from config"
    
    # Try to get API key from config env section
    local cfg_anthropic cfg_google cfg_openai
    cfg_anthropic=$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$config_file" 2>/dev/null)
    cfg_google=$(jq -r '.env.GOOGLE_API_KEY // empty' "$config_file" 2>/dev/null)
    cfg_openai=$(jq -r '.env.OPENAI_API_KEY // empty' "$config_file" 2>/dev/null)
    
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
      local auth_header
      # Detect OAuth Access Token (sk-ant-oat*) vs API key (sk-ant-api*)
      if [[ "$cfg_anthropic" == sk-ant-oat* ]]; then
        auth_header="Authorization: Bearer ${cfg_anthropic}"
      else
        auth_header="x-api-key: ${cfg_anthropic}"
      fi
      response=$(curl -sf --max-time 5 \
        -H "$auth_header" \
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
    local auth_header
    
    # Detect OAuth Access Token (sk-ant-oat*) vs API key (sk-ant-api*)
    # OAuth tokens use Authorization: Bearer, API keys use x-api-key
    if [[ "${ANTHROPIC_API_KEY}" == sk-ant-oat* ]]; then
      log "  Anthropic: detected OAuth token (oat), using Bearer auth"
      auth_header="Authorization: Bearer ${ANTHROPIC_API_KEY}"
    else
      auth_header="x-api-key: ${ANTHROPIC_API_KEY}"
    fi
    
    response=$(curl -sf --max-time 5 \
      -H "$auth_header" \
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
  
  local config_file="$CONFIG_PATH"
  
  # In safe mode, just verify the safe mode config has a working token
  # Safe mode recovery already found a working token, we just need to confirm it
  if [ -f "$SAFE_MODE_FILE" ] && [ -f "$config_file" ]; then
    log "  Safe mode active - validating safe mode config token"
    
    # Try Telegram token from config
    local tg_token
    tg_token=$(jq -r '.channels.telegram.botToken // empty' "$config_file" 2>/dev/null)
    if [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      log "  Safe mode Telegram token valid"
      log "  Channel connectivity verified (safe mode)"
      return 0
    fi
    
    # Try Discord token from config
    local dc_token
    dc_token=$(jq -r '.channels.discord.token // .channels.discord.accounts.default.token // empty' "$config_file" 2>/dev/null)
    if [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
      log "  Safe mode Discord token valid"
      log "  Channel connectivity verified (safe mode)"
      return 0
    fi
    
    log "  Safe mode config has no working chat tokens"
    return 1
  fi
  
  # Normal mode: validate ALL agents have working tokens for the specified platform(s)
  # No fallback - if user says "telegram", ALL agents must have valid Telegram tokens
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  
  local platform="${PLATFORM:-telegram}"
  local count="${AGENT_COUNT:-1}"
  local all_valid=true
  local failed_agents=""
  
  log "  Platform: $platform, Agent count: $count"
  
  for i in $(seq 1 "$count"); do
    local agent_valid=false
    
    # Check Telegram if platform is telegram or both
    if [ "$platform" = "telegram" ] || [ "$platform" = "both" ]; then
      local tg_token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local tg_token="${!tg_token_var:-}"
      if [ -z "$tg_token" ]; then
        tg_token_var="AGENT${i}_BOT_TOKEN"
        tg_token="${!tg_token_var:-}"
      fi
      
      if [ -n "$tg_token" ]; then
        if validate_telegram_token_direct "$tg_token"; then
          log "  Agent${i} Telegram token valid"
          agent_valid=true
        else
          log "  Agent${i} Telegram token INVALID"
        fi
      fi
    fi
    
    # Check Discord if platform is discord or both
    if [ "$platform" = "discord" ] || [ "$platform" = "both" ]; then
      local dc_token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local dc_token="${!dc_token_var:-}"
      
      if [ -n "$dc_token" ]; then
        if validate_discord_token_direct "$dc_token"; then
          log "  Agent${i} Discord token valid"
          agent_valid=true
        else
          log "  Agent${i} Discord token INVALID"
        fi
      fi
    fi
    
    # For "both" platform, agent needs at least one working token
    # For single platform, agent needs that specific platform's token to work
    if [ "$agent_valid" = "false" ]; then
      all_valid=false
      failed_agents="${failed_agents} agent${i}"
      log "  Agent${i} has NO working tokens for platform '$platform'"
    fi
  done
  
  if [ "$all_valid" = "false" ]; then
    log "  Channel check FAILED - broken agents:${failed_agents}"
    return 1
  fi
  
  log "  Channel connectivity verified (all $count agents valid)"
  return 0
}

# =============================================================================
# End-to-End Agent Health Check (NEW)
# =============================================================================
# Instead of checking tokens and API keys separately, ask each agent to respond.
# This tests EVERYTHING: chat token, API credentials, model validity, OAuth.
# The agent sends an introduction message to the chat channel.

check_agents_e2e() {
  log "========== E2E AGENT HEALTH CHECK =========="
  log "  This test asks each agent to introduce itself via chat"
  log "  Success = agent responds AND message delivered to owner"
  
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  
  local platform="${PLATFORM:-telegram}"
  local all_healthy=true
  local failed_agents=""
  
  # Determine which agents to check
  # If GROUP is set (session isolation), derive agents from AGENT{N}_ISOLATION_GROUP
  # Otherwise, check all agents
  local agents_to_check=()
  local count="${AGENT_COUNT:-1}"
  
  if [ -n "$GROUP" ]; then
    # Derive agents for this group from habitat-parsed.env (single source of truth)
    for i in $(seq 1 "$count"); do
      local agent_group_var="AGENT${i}_ISOLATION_GROUP"
      local agent_group="${!agent_group_var:-}"
      if [ "$agent_group" = "$GROUP" ]; then
        agents_to_check+=("agent${i}")
      fi
    done
    log "  Config: GROUP MODE - group=$GROUP, checking agents: ${agents_to_check[*]}"
  else
    for i in $(seq 1 "$count"); do
      agents_to_check+=("agent${i}")
    done
    log "  Config: STANDARD MODE - checking ${#agents_to_check[@]} agents"
  fi
  
  log "  Platform: $platform"
  
  # Determine delivery channel and owner (Discord needs "user:" prefix for DMs)
  local channel="$platform"
  local owner_id
  owner_id=$(get_owner_id_for_platform "$platform" "with_prefix")
  
  log "  Delivery: channel=$channel, owner_id=$owner_id"
  
  if [ -z "$owner_id" ] || [ "$owner_id" = "user:" ]; then
    log "  ERROR: No owner ID for platform '$platform'"
    log "  Check habitat config: platforms.$platform.ownerId must be set"
    return 1
  fi
  
  # NOTE: The bot should REPLY directly - the --deliver flag handles sending.
  # Don't say "send a message" which could make the bot try to use the message tool.
  local intro_prompt="You just came online after a reboot. Reply with a brief introduction (2-3 sentences) - your name, model, and role. Be friendly but concise. Your reply will be automatically delivered."
  
  for agent_id in "${agents_to_check[@]}"; do
    # Extract agent number from ID (e.g., "agent3" -> "3")
    local agent_num="${agent_id#agent}"
    local name_var="AGENT${agent_num}_NAME"
    local model_var="AGENT${agent_num}_MODEL"
    local agent_name="${!name_var:-$agent_id}"
    local agent_model="${!model_var:-unknown}"
    
    log "  -------- Testing $agent_id --------"
    log "  Agent: $agent_name ($agent_id)"
    log "  Model: $agent_model"
    log "  Command: openclaw agent --agent $agent_id --deliver --reply-channel $channel --reply-to $owner_id"
    
    local start_time=$(date +%s)
    
    # Use openclaw agent with --deliver to send response to chat
    # IMPORTANT: Run as $USERNAME, not root. Health check runs as root (ExecStartPost +)
    # but openclaw must run as the bot user to create files with correct ownership.
    # In session isolation mode, point to the session-specific config (correct gateway port).
    local env_prefix=""
    [ -n "${GROUP:-}" ] && env_prefix="OPENCLAW_CONFIG_PATH=$CONFIG_PATH"
    
    local output
    output=$(timeout 90 sudo -u "$USERNAME" env $env_prefix openclaw agent \
      --agent "$agent_id" \
      --message "$intro_prompt" \
      --deliver \
      --reply-channel "$channel" \
      --reply-to "$owner_id" \
      --timeout 60 \
      --json 2>&1)
    local exit_code=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ]; then
      log "  ✓ SUCCESS: $agent_name responded in ${duration}s"
      log "  Output (first 500 chars): $(echo "$output" | head -c 500)"
    else
      log "  ✗ FAILED: $agent_name (exit=$exit_code, duration=${duration}s)"
      log "  Full output:"
      echo "$output" | while IFS= read -r line; do
        log "    | $line"
      done
      all_healthy=false
      failed_agents="${failed_agents} ${agent_name}"
    fi
  done
  
  log "  -------- E2E Summary --------"
  if [ "$all_healthy" = "false" ]; then
    log "  RESULT: FAILED"
    log "  Broken agents:${failed_agents}"
    log "  Will trigger SAFE MODE"
    return 1
  fi
  
  log "  RESULT: SUCCESS - All $count agents responded"
  log "========== E2E CHECK COMPLETE =========="
  return 0
}

check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-6}"
  
  log "Health check: $service on port $port"
  
  for i in $(seq 1 $max_attempts); do
    sleep 5
    
    # Skip is-active check in execstartpost mode - service is "activating" not "active"
    # while ExecStartPost is running, so this check would always fail
    if [ "$RUN_MODE" != "execstartpost" ]; then
      if ! systemctl is-active --quiet "$service"; then
        log "  attempt $i/$max_attempts: service not active"
        continue
      fi
    fi
    
    if curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      log "  HTTP gateway responding"
      sleep 3
      
      # In safe mode, use simple token/API validation (safe mode config is minimal)
      # In normal mode, use full end-to-end agent check
      if [ -f "$SAFE_MODE_FILE" ]; then
        log "  Safe mode: using simple validation"
        if check_channel_connectivity "$service" && check_api_key_validity "$service"; then
          log "  HEALTHY (safe mode)"
          return 0
        else
          log "  HTTP OK but channel/API check failed"
          return 1
        fi
      else
        log "  Normal mode: using end-to-end agent check"
        if check_agents_e2e; then
          log "  HEALTHY"
          return 0
        else
          log "  HTTP OK but agent e2e check failed"
          return 1
        fi
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
      
      # Send warning to user BEFORE restart (only on first entry, not retries)
      if [ "$ALREADY_IN_SAFE_MODE" != "true" ]; then
        send_entering_safe_mode_warning
      fi
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
      
      # Send warning to user BEFORE restart (only on first entry, not retries)
      if [ "$ALREADY_IN_SAFE_MODE" != "true" ]; then
        send_entering_safe_mode_warning
      fi
    else
      log "Recovery FAILED (exit $recovery_exit): $recovery_output"
    fi
  fi
  
  # Fall back to minimal config
  if [ "$SMART_RECOVERY_SUCCESS" = "false" ]; then
    log "!!! SMART RECOVERY FAILED - falling back to emergency.json !!!"
    log "Emergency config before copy:"
    if [ -f "$H/.openclaw/openclaw.emergency.json" ]; then
      local emerg_model emerg_keys
      emerg_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$H/.openclaw/openclaw.emergency.json" 2>/dev/null)
      emerg_keys=$(jq -r '.env | keys | join(",")' "$H/.openclaw/openclaw.emergency.json" 2>/dev/null)
      log "  emergency.json: model=$emerg_model, env_keys=$emerg_keys"
    else
      log "  ERROR: emergency.json does not exist!"
    fi
    cp "$H/.openclaw/openclaw.emergency.json" "$CONFIG_PATH"
    chown $USERNAME:$USERNAME "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    log "Config after fallback:"
    local new_model
    new_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$CONFIG_PATH" 2>/dev/null)
    log "  $CONFIG_PATH: model=$new_model"
  else
    log "Smart recovery succeeded - using recovery-generated config"
    log "Config after recovery:"
    local new_model new_keys
    new_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' "$CONFIG_PATH" 2>/dev/null)
    new_keys=$(jq -r '.env | keys | join(",")' "$CONFIG_PATH" 2>/dev/null)
    log "  $CONFIG_PATH: model=$new_model, env_keys=$new_keys"
  fi
  
  # Mark safe mode
  touch "$SAFE_MODE_FILE"
  
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
  # In per-group mode (GROUP set), only stop this group's service
  # In all-groups mode (GROUP not set), stop all services (legacy)
  if [ "$ISOLATION" = "session" ]; then
    if [ -n "${GROUP:-}" ]; then
      # Per-group mode: only stop this group's service
      log "Stopping session service for group: $GROUP"
      systemctl stop "openclaw-${GROUP}.service" 2>/dev/null || true
    elif [ -n "$SESSION_GROUPS" ]; then
      # Legacy all-groups mode: stop all services
      IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
      for group in "${GROUP_ARRAY[@]}"; do
        systemctl stop "openclaw-${group}.service" 2>/dev/null || true
      done
    fi
  elif [ "$ISOLATION" = "container" ]; then
    systemctl stop openclaw-containers.service 2>/dev/null || true
  fi
  
  # Update stages
  echo '12' > /var/lib/init-status/stage
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=12 DESC=safe-mode" >> /var/log/init-stages.log
  
  log "Safe mode config applied"
}

restart_gateway() {
  local target_service=""
  local service_description=""
  
  # Determine which service to restart based on isolation mode
  if [ "$ISOLATION" = "session" ]; then
    if [ -n "${GROUP:-}" ]; then
      # Per-group mode: restart only this group's service
      target_service="openclaw-${GROUP}.service"
      service_description="session service ($GROUP)"
    elif [ -n "$SESSION_GROUPS" ]; then
      # Legacy all-groups mode: restart all session services
      target_service="all-session-services"
      service_description="all session services"
    fi
  elif [ "$ISOLATION" = "container" ]; then
    target_service="openclaw-containers.service"
    service_description="container service"
  else
    target_service="clawdbot"
    service_description="clawdbot"
  fi
  
  log "Restarting $service_description with safe mode config..."
  
  # Restart the appropriate service(s)
  if [ "$target_service" = "all-session-services" ]; then
    IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
    for group in "${GROUP_ARRAY[@]}"; do
      systemctl restart "openclaw-${group}.service" 2>/dev/null || true
    done
    sleep 5
  else
    systemctl restart "$target_service"
    sleep 5
  fi
  
  # Verify service started
  for attempt in 1 2 3; do
    local is_active=false
    
    if [ "$target_service" = "all-session-services" ]; then
      # Check if any session service is active
      is_active=true
      IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
      for group in "${GROUP_ARRAY[@]}"; do
        if ! systemctl is-active --quiet "openclaw-${group}.service"; then
          is_active=false
          break
        fi
      done
    else
      systemctl is-active --quiet "$target_service" && is_active=true
    fi
    
    if [ "$is_active" = "true" ]; then
      log "$service_description started (attempt $attempt)"
      
      # Rename bots
      /usr/local/bin/rename-bots.sh >> "$LOG" 2>&1 || true
      
      # NOTE: SafeModeBot wake is handled by send_boot_notification in Run 2
      # after we verify the safe mode config is actually working.
      # Don't wake here - it would race with the proper notification flow.
      
      return 0
    fi
    
    log "$service_description not active, retry $attempt/3..."
    
    if [ "$target_service" = "all-session-services" ]; then
      IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
      for group in "${GROUP_ARRAY[@]}"; do
        systemctl restart "openclaw-${group}.service" 2>/dev/null || true
      done
    else
      systemctl restart "$target_service"
    fi
    sleep 5
  done
  
  log "CRITICAL: $service_description failed to start"
  
  # Mark failure with group suffix if in per-group mode
  if [ -n "${GROUP:-}" ]; then
    touch "/var/lib/init-status/gateway-failed-${GROUP}"
  else
    touch /var/lib/init-status/gateway-failed
  fi
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

# Determine which mode we're running in
if [ -n "$GROUP" ]; then
  # Per-group health check (session isolation - each group checks itself)
  log "Group mode: checking group '$GROUP' on port $GROUP_PORT"
  check_service_health "$SERVICE_NAME" "$GROUP_PORT" 6 && HEALTHY=true

elif [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  # Legacy: session isolation without per-group health check
  # This path is kept for backwards compatibility but shouldn't be hit
  # since each session service now runs its own health check
  log "Session isolation mode (legacy - should not reach here)"
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  BASE_PORT=18790
  idx=0
  ALL_HEALTHY=true
  for group in "${GROUP_ARRAY[@]}"; do
    if ! check_service_health "openclaw-${group}.service" $((BASE_PORT + idx)) 6; then
      log "  Session group '$group' FAILED"
      ALL_HEALTHY=false
    fi
    idx=$((idx + 1))
  done
  HEALTHY=$ALL_HEALTHY

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

if [ "$HEALTHY" = "true" ] && [ "$ALREADY_IN_SAFE_MODE" = "true" ]; then
  # Safe mode config is working - keep safe mode active, don't pretend everything is normal
  log "DECISION: SAFE MODE STABLE - recovery config working, keeping safe mode flag"
  rm -f "$RECOVERY_COUNTER_FILE"
  rm -f "$RECENTLY_RECOVERED_FILE"
  
  # Mark as ready (in safe mode)
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=11 DESC=ready-safe-mode" >> /var/log/init-stages.log
  log "Status: stage=11 (ready in safe mode), setup-complete created"
  
  EXIT_CODE=0  # Don't restart, safe mode is working

elif [ "$HEALTHY" = "true" ]; then
  # Full config is healthy (not in safe mode) - truly ready
  log "DECISION: SUCCESS - gateway healthy, clearing safe mode state"
  rm -f "$SAFE_MODE_FILE"
  rm -f "$RECOVERY_COUNTER_FILE"
  rm -f "$RECENTLY_RECOVERED_FILE"
  for si in $(seq 1 $AC); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  
  # Mark as ready
  echo '11' > /var/lib/init-status/stage
  touch /var/lib/init-status/setup-complete
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=11 DESC=ready" >> /var/log/init-stages.log
  log "Status: stage=11 (ready), setup-complete created"
  
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

# Send via Telegram
send_telegram_notification() {
  local token="$1"
  local chat_id="$2"
  local message="$3"
  
  curl -sf --max-time 10 \
    "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" >> "$LOG" 2>&1
}

# Send via Discord (DM to owner)
send_discord_notification() {
  local token="$1"
  local owner_id="$2"
  local message="$3"
  
  # Strip "user:" prefix if present (OpenClaw format vs raw Discord ID)
  owner_id="${owner_id#user:}"
  
  # Convert HTML to Discord markdown
  local discord_msg
  discord_msg=$(echo "$message" | sed -e 's/<b>/\*\*/g' -e 's/<\/b>/\*\*/g' -e 's/<code>/`/g' -e 's/<\/code>/`/g')
  
  # First, create a DM channel with the user
  local dm_channel
  dm_channel=$(curl -sf --max-time 10 \
    -H "Authorization: Bot ${token}" \
    -H "Content-Type: application/json" \
    -X POST "https://discord.com/api/v10/users/@me/channels" \
    -d "{\"recipient_id\": \"${owner_id}\"}" 2>/dev/null | jq -r '.id // empty')
  
  if [ -z "$dm_channel" ]; then
    log "  Failed to create Discord DM channel"
    return 1
  fi
  
  # Send message to DM channel
  curl -sf --max-time 10 \
    -H "Authorization: Bot ${token}" \
    -H "Content-Type: application/json" \
    -X POST "https://discord.com/api/v10/channels/${dm_channel}/messages" \
    -d "{\"content\": $(echo "$discord_msg" | jq -Rs .)}" >> "$LOG" 2>&1
}

# Send warning BEFORE entering safe mode (uses token from recovery config)
# This notifies user that something failed and we're switching to safe mode
send_entering_safe_mode_warning() {
  log "========== SENDING SAFE MODE WARNING =========="
  
  local config_file="$CONFIG_PATH"
  if [ ! -f "$config_file" ]; then
    log "  No config file found - cannot send warning"
    return 1
  fi
  
  # Extract token from the config that recovery just wrote
  local platform=""
  local token=""
  
  # Try Discord first
  token=$(jq -r '.channels.discord.accounts.default.token // .channels.discord.token // empty' "$config_file" 2>/dev/null)
  if [ -n "$token" ]; then
    platform="discord"
  else
    # Try Telegram
    token=$(jq -r '.channels.telegram.botToken // empty' "$config_file" 2>/dev/null)
    if [ -n "$token" ]; then
      platform="telegram"
    fi
  fi
  
  if [ -z "$token" ]; then
    log "  No working token found in config - cannot send warning"
    return 1
  fi
  
  log "  Using ${platform} token from recovery config"
  
  # Get owner ID for the platform
  local owner_id
  owner_id=$(get_owner_id_for_platform "$platform")
  
  if [ -z "$owner_id" ]; then
    log "  No owner ID for platform '$platform' - cannot send warning"
    return 1
  fi
  
  # Get habitat name
  local habitat_name="${HABITAT_NAME:-Droplet}"
  
  # Build warning message
  local message="⚠️ <b>[${habitat_name}] Entering Safe Mode</b>

Health check failed. Recovering with backup configuration.

SafeModeBot will follow up shortly with diagnostics."
  
  log "  Sending warning via $platform to $owner_id"
  
  if [ "$platform" = "telegram" ]; then
    send_telegram_notification "$token" "$owner_id" "$message"
  elif [ "$platform" = "discord" ]; then
    send_discord_notification "$token" "$owner_id" "$message"
  fi
  
  log "  Warning sent"
  log "========== SAFE MODE WARNING COMPLETE =========="
}

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
  
  # Determine which platform to use for notification
  # In safe mode, check which channel the recovery config is actually using
  local send_platform=""
  local send_token=""
  local owner_id=""
  
  if [ -f "$SAFE_MODE_FILE" ] && [ -f "$CONFIG_PATH" ]; then
    # Check which channels are configured in safe mode config
    local tg_token dc_token
    tg_token=$(jq -r '.channels.telegram.botToken // .channels.telegram.accounts.default.botToken // empty' "$CONFIG_PATH" 2>/dev/null)
    dc_token=$(jq -r '.channels.discord.token // .channels.discord.accounts.default.token // empty' "$CONFIG_PATH" 2>/dev/null)
    
    # Prefer platform matching PLATFORM env, fall back to whatever is configured
    local preferred="${PLATFORM:-telegram}"
    
    if [ "$preferred" = "telegram" ] && [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      send_platform="telegram"
      send_token="$tg_token"
      owner_id=$(get_owner_id_for_platform "telegram")
      log "  Using Telegram from safe mode config"
    elif [ "$preferred" = "discord" ] && [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
      send_platform="discord"
      send_token="$dc_token"
      owner_id=$(get_owner_id_for_platform "discord" "with_prefix")
      log "  Using Discord from safe mode config"
    elif [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      send_platform="telegram"
      send_token="$tg_token"
      owner_id=$(get_owner_id_for_platform "telegram")
      log "  Falling back to Telegram from safe mode config"
    elif [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
      send_platform="discord"
      send_token="$dc_token"
      owner_id=$(get_owner_id_for_platform "discord" "with_prefix")
      log "  Falling back to Discord from safe mode config"
    fi
  fi
  
  # Normal mode: fall back to habitat tokens
  if [ -z "$send_token" ]; then
    local platform="${PLATFORM:-telegram}"
    
    for i in $(seq 1 "${AGENT_COUNT:-1}"); do
      if [ "$platform" = "telegram" ]; then
        local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
        local token="${!token_var:-}"
        [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
        
        if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
          send_platform="telegram"
          send_token="$token"
          owner_id=$(get_owner_id_for_platform "telegram")
          break
        fi
      elif [ "$platform" = "discord" ]; then
        local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
        local token="${!token_var:-}"
        
        if [ -n "$token" ] && validate_discord_token_direct "$token"; then
          send_platform="discord"
          send_token="$token"
          owner_id=$(get_owner_id_for_platform "discord" "with_prefix")
          break
        fi
      fi
    done
    
    # Cross-platform fallback
    if [ -z "$send_token" ]; then
      local alt_platform
      [ "$platform" = "telegram" ] && alt_platform="discord" || alt_platform="telegram"
      
      for i in $(seq 1 "${AGENT_COUNT:-1}"); do
        if [ "$alt_platform" = "telegram" ]; then
          local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
          local token="${!token_var:-}"
          [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
          
          if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
            send_platform="telegram"
            send_token="$token"
            owner_id=$(get_owner_id_for_platform "telegram")
            log "  Cross-platform fallback to Telegram"
            break
          fi
        elif [ "$alt_platform" = "discord" ]; then
          local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
          local token="${!token_var:-}"
          
          if [ -n "$token" ] && validate_discord_token_direct "$token"; then
            send_platform="discord"
            send_token="$token"
            owner_id=$(get_owner_id_for_platform "discord" "with_prefix")
            log "  Cross-platform fallback to Discord"
            break
          fi
        fi
      done
    fi
  fi
  
  if [ -z "$send_token" ] || [ -z "$owner_id" ]; then
    log "Cannot send notification - no working token or owner ID"
    log "  send_platform=$send_platform send_token=${send_token:+[set]} owner_id=$owner_id"
    return 1
  fi
  
  # Build message based on status
  local message=""
  case "$status" in
    healthy)
      # In normal mode, agents already introduced themselves via check_agents_e2e
      # So we don't need to send a separate "Ready!" notification
      log "  Agents already introduced themselves - skipping separate Ready notification"
      touch "$notification_file"
      return 0
      ;;
      
    safe-mode)
      # Pre-restart warning already sent by send_entering_safe_mode_warning()
      # Now just trigger SafeModeBot intro for detailed diagnostics
      
      # Generate boot report for SafeModeBot to read
      log "  Generating BOOT_REPORT.md for SafeModeBot to read..."
      generate_boot_report_md
      log "  BOOT_REPORT.md created at $H/clawd/agents/safe-mode/BOOT_REPORT.md"
      
      # Trigger SafeModeBot intro via openclaw agent
      # NOTE: In session isolation mode, session configs don't have a safe-mode agent,
      # so we skip the LLM-powered intro and rely on the direct notification already sent.
      if [ "$ISOLATION" = "session" ]; then
        log "========== SAFE MODE BOT INTRO (SKIPPED) =========="
        log "  Session isolation mode: SafeModeBot intro not available"
        log "  (Session configs only contain group agents, no safe-mode agent)"
        log "  User has been notified via direct Telegram/Discord API"
        return 0
      fi
      
      log "========== SAFE MODE BOT INTRO =========="
      log "  SafeModeBot will introduce itself and provide diagnostics"
      log "  Delivery: channel=$send_platform, owner=$owner_id"
      
      # IMPORTANT: The prompt must be clear that the bot should REPLY directly,
      # not try to use the message tool. The --deliver flag handles delivery.
      local safemode_prompt="You just came online in SAFE MODE after a boot failure.

IMPORTANT: Just reply directly here - your response will be automatically delivered to the user. Do NOT use the message tool.

Read your BOOT_REPORT.md file and reply with:
1. Brief intro (you're SafeModeBot, running in emergency mode)
2. What went wrong (summarize from BOOT_REPORT.md)
3. Offer to help investigate

Keep it to 3-5 sentences. Be helpful, not verbose."
      
      # In session isolation mode, openclaw agent can't connect to clawdbot (port 18789)
      # because session services use different ports. Set gateway URL to the correct port.
      local gateway_url=""
      local config_path=""
      if [ "$ISOLATION" = "session" ] && [ -n "${GROUP:-}" ] && [ -n "${GROUP_PORT:-}" ]; then
        gateway_url="ws://127.0.0.1:${GROUP_PORT}"
        config_path="${H}/.openclaw-sessions/${GROUP}/openclaw.session.json"
        log "  Session isolation mode: using gateway at $gateway_url"
      fi
      
      log "  Command: sudo -u $USERNAME openclaw agent --agent safe-mode --deliver --reply-channel $send_platform --reply-to $owner_id"
      
      local start_time=$(date +%s)
      
      # IMPORTANT: Run as $USERNAME, not root. Health check runs as root (ExecStartPost +)
      # but openclaw must run as the bot user to create files with correct ownership.
      local output
      
      # Build environment variables for session isolation
      local env_prefix=""
      if [ -n "$gateway_url" ]; then
        env_prefix="OPENCLAW_GATEWAY_URL=$gateway_url OPENCLAW_CONFIG_PATH=$config_path"
      fi
      
      output=$(timeout 120 sudo -u "$USERNAME" env $env_prefix openclaw agent \
        --agent "safe-mode" \
        --message "$safemode_prompt" \
        --deliver \
        --reply-channel "$send_platform" \
        --reply-to "$owner_id" \
        --timeout 90 \
        --json 2>&1)
      local exit_code=$?
      
      local end_time=$(date +%s)
      local duration=$((end_time - start_time))
      
      if [ $exit_code -eq 0 ]; then
        touch "$notification_file"
        log "  ✓ SUCCESS: SafeModeBot intro sent in ${duration}s"
        log "  Output (first 500 chars): $(echo "$output" | head -c 500)"
        log "========== SAFE MODE INTRO COMPLETE =========="
      else
        log "  ✗ FAILED: SafeModeBot intro (exit=$exit_code, duration=${duration}s)"
        log "  Full output:"
        echo "$output" | while IFS= read -r line; do
          log "    | $line"
        done
        log "  Direct notification already sent - SafeModeBot intro failed but user was notified"
      fi
      
      # Already sent direct notification, so we're done regardless of bot intro result
      return 0
      ;;
      
    critical)
      message="🔴 <b>[${habitat_name}] CRITICAL FAILURE</b>

Gateway failed to start after multiple attempts.
Bot is OFFLINE - no connectivity available.

Check logs: <code>journalctl -u clawdbot -n 50</code>
See CRITICAL_FAILURE.md for recovery steps."
      ;;
  esac
  
  # Send via appropriate platform
  log "  Sending via $send_platform to owner $owner_id"
  
  if [ "$send_platform" = "telegram" ]; then
    if send_telegram_notification "$send_token" "$owner_id" "$message"; then
      touch "$notification_file"
      log "  Notification sent successfully"
    else
      log "  Telegram notification failed"
      return 1
    fi
  elif [ "$send_platform" = "discord" ]; then
    if send_discord_notification "$send_token" "$owner_id" "$message"; then
      touch "$notification_file"
      log "  Notification sent successfully"
    else
      log "  Discord notification failed"
      return 1
    fi
  else
    log "  Unknown platform: $send_platform"
    return 1
  fi
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

# Send notification based on FINAL outcome only
# - No notification when first entering safe mode (Run 1) - wait for Run 2
# - This ensures user gets ONE notification reflecting the final state
if [ "$HEALTHY" = "true" ] && [ "$ALREADY_IN_SAFE_MODE" = "true" ]; then
  # Safe mode config verified working (Run 2)
  generate_boot_report_md
  send_boot_notification "safe-mode"
elif [ "$HEALTHY" = "true" ]; then
  # Full config healthy - truly ready
  send_boot_notification "healthy"
elif [ "$EXIT_CODE" = "2" ]; then
  # Critical failure - everything broken
  send_boot_notification "critical"
else
  # Entering safe mode (Run 1) - no notification yet, wait for Run 2 to confirm
  log "Entering safe mode - notification deferred until recovery verified"
  generate_boot_report_md  # Still generate report for SafeModeBot to read
fi

log "============================================================"
log "========== GATEWAY HEALTH CHECK COMPLETE =========="
log "============================================================"
log "RUN_ID=$RUN_ID | EXIT=$EXIT_CODE | HEALTHY=$HEALTHY | SAFE_MODE=$ALREADY_IN_SAFE_MODE"
exit $EXIT_CODE
