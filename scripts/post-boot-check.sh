#!/bin/bash
# =============================================================================
# post-boot-check.sh -- Post-reboot health check and config upgrade
# =============================================================================
# Purpose:  Runs after reboot (via systemd oneshot). Upgrades from minimal
#           config to full config, validates health, and enters safe mode
#           if full config fails health checks.
#
# Inputs:   /etc/droplet.env, /etc/habitat-parsed.env
# Outputs:  /var/lib/init-status/setup-complete or safe-mode markers
# =============================================================================

LOG="/var/log/post-boot-check.log"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"
}

log "========== POST-BOOT-CHECK STARTING =========="

# Source environment
if [ -f /etc/droplet.env ]; then
  set -a; source /etc/droplet.env; set +a
else
  log "ERROR: /etc/droplet.env not found"
  exit 1
fi

d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

if [ -f /etc/habitat-parsed.env ]; then
  source /etc/habitat-parsed.env
else
  log "ERROR: /etc/habitat-parsed.env not found"
  exit 1
fi

# Decode API keys from base64 (droplet.env stores them encoded)
# Export them so safe-mode-recovery.sh can use them
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(d "$ANTHROPIC_KEY_B64")}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-$(d "$OPENAI_KEY_B64")}"
export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$(d "$GOOGLE_API_KEY_B64")}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-$(d "$BRAVE_KEY_B64")}"

# Set working variables
AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
TG="/usr/local/bin/tg-notify.sh"
ISOLATION="${ISOLATION_DEFAULT:-none}"
# NOTE: Do NOT use "GROUPS" - it's a bash built-in array variable that causes conflicts
SESSION_GROUPS="${ISOLATION_GROUPS:-}"

log "Config: isolation=$ISOLATION groups=$SESSION_GROUPS agents=$AC"

# Check for trigger file
if [ ! -f /var/lib/init-status/needs-post-boot-check ]; then
  log "No trigger file - exiting"
  exit 0
fi

log "Trigger file found, waiting 15s for services to settle..."
sleep 15

# Check for full config
if [ ! -f "$H/.openclaw/openclaw.full.json" ]; then
  log "No full config found - exiting"
  rm -f /var/lib/init-status/needs-post-boot-check
  exit 0
fi

# Apply full config
log "Applying full config..."
cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
chmod 600 "$H/.openclaw/openclaw.json"

# Health check function for a single service/port
# Now includes Telegram connectivity verification (not just HTTP gateway)
check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-12}"
  
  log "Health check: $service on port $port"
  
  for i in $(seq 1 $max_attempts); do
    sleep 5
    
    # Check systemd status
    local active
    active=$(systemctl is-active "$service" 2>&1)
    if [ "$active" != "active" ]; then
      log "  attempt $i/$max_attempts: not active ($active)"
      continue
    fi
    
    # Try curl (HTTP gateway up)
    if curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      log "  HTTP gateway responding after $i attempts"
      
      # Now verify Telegram connectivity by checking logs for errors
      # Wait a moment for Telegram connection attempts to complete
      sleep 3
      
      if check_channel_connectivity "$service"; then
        # Also verify API key validity
        if check_api_key_validity "$service"; then
          log "  HEALTHY (HTTP + channel + API key verified)"
          return 0
        else
          log "  HTTP + channel OK but API key validation failed"
          return 1
        fi
      else
        log "  HTTP OK but channel connectivity failed"
        return 1
      fi
    fi
    log "  attempt $i/$max_attempts: curl failed"
  done
  
  log "  FAILED after $max_attempts attempts"
  return 1
}

# Check API key validity by making a minimal API call
# Returns 0 if at least one provider works, 1 if all fail
check_api_key_validity() {
  local service="$1"
  local today=$(date +%Y-%m-%d)
  local openclaw_log="/tmp/openclaw/openclaw-${today}.log"
  
  log "  Checking API key validity for $service..."
  
  # Check for authentication errors in journal (last 60 seconds)
  local auth_errors
  auth_errors=$(journalctl -u "$service" --since "1 minute ago" --no-pager 2>/dev/null | \
    grep -iE "(authentication_error|Invalid.*bearer.*token|401|invalid.*api.*key|api.*key.*invalid)" | head -5)
  
  if [ -n "$auth_errors" ]; then
    log "  Found API authentication errors in journal:"
    echo "$auth_errors" | while read line; do log "    $line"; done
    return 1
  fi
  
  # Also check OpenClaw log file
  if [ -f "$openclaw_log" ]; then
    local log_auth_errors
    log_auth_errors=$(tail -100 "$openclaw_log" 2>/dev/null | \
      grep -iE "(authentication_error|Invalid.*bearer.*token|401|invalid.*api.*key|api.*key.*invalid)" | head -5)
    
    if [ -n "$log_auth_errors" ]; then
      log "  Found API authentication errors in OpenClaw log:"
      echo "$log_auth_errors" | while read line; do log "    $line"; done
      return 1
    fi
  fi
  
  # Alternative: Make a direct API call to validate
  # This is more reliable than log parsing but adds latency
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    local response
    response=$(curl -sf --max-time 5 \
      -H "x-api-key: ${ANTHROPIC_API_KEY}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      "https://api.anthropic.com/v1/messages" 2>&1)
    
    # Check for auth errors (401, invalid key)
    if echo "$response" | grep -qiE "(authentication_error|invalid.*key|401)"; then
      log "  Anthropic API key validation failed"
      # Don't return yet - check other providers
    else
      log "  Anthropic API key validated OK"
      return 0
    fi
  fi
  
  # Try OpenAI if Anthropic failed or not configured
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    local openai_response
    openai_response=$(curl -sf --max-time 5 \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      "https://api.openai.com/v1/models" 2>&1)
    
    if [ $? -eq 0 ] && ! echo "$openai_response" | grep -qiE "(invalid|401|unauthorized)"; then
      log "  OpenAI API key validated OK"
      return 0
    fi
  fi
  
  # Try Google/Gemini if others failed
  if [ -n "${GOOGLE_API_KEY:-}" ]; then
    local google_response
    google_response=$(curl -sf --max-time 5 \
      "https://generativelanguage.googleapis.com/v1/models?key=${GOOGLE_API_KEY}" 2>&1)
    
    if [ $? -eq 0 ] && ! echo "$google_response" | grep -qiE "(invalid|401|unauthorized)"; then
      log "  Google API key validated OK"
      return 0
    fi
  fi
  
  # All providers failed or no keys configured
  log "  WARNING: No working API keys found"
  return 1
}

# Directly validate a Telegram token via getMe API call
validate_telegram_token_direct() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  local response
  response=$(curl -sf --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>&1)
  local exit_code=$?
  
  if [ $exit_code -eq 0 ] && echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    return 0
  fi
  
  log "  Telegram token validation failed: $response"
  return 1
}

# Directly validate a Discord token via /users/@me API call
validate_discord_token_direct() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  local response
  response=$(curl -sf --max-time 10 \
    -H "Authorization: Bot ${token}" \
    "https://discord.com/api/v10/users/@me" 2>&1)
  local exit_code=$?
  
  if [ $exit_code -eq 0 ] && echo "$response" | jq -e '.id' >/dev/null 2>&1; then
    return 0
  fi
  
  log "  Discord token validation failed: $response"
  return 1
}

# Check channel connectivity by:
# 1. Making direct API calls to validate tokens (primary - most reliable)
# 2. Checking service logs for connection errors (fallback/additional info)
check_channel_connectivity() {
  local service="$1"
  local today=$(date +%Y-%m-%d)
  local openclaw_log="/tmp/openclaw/openclaw-${today}.log"
  
  log "  Checking channel connectivity for $service..."
  
  # Source environment to get token values
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  
  local platform="${PLATFORM:-telegram}"
  local token_found=false
  local token_valid=false
  
  # Try to validate at least one token directly
  local count="${AGENT_COUNT:-1}"
  for i in $(seq 1 "$count"); do
    if [ "$platform" = "telegram" ]; then
      local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local token="${!token_var:-}"
      [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
      
      if [ -n "$token" ]; then
        token_found=true
        if validate_telegram_token_direct "$token"; then
          log "  Agent${i} Telegram token valid"
          token_valid=true
          break
        else
          log "  Agent${i} Telegram token INVALID"
        fi
      fi
    elif [ "$platform" = "discord" ]; then
      local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local token="${!token_var:-}"
      
      if [ -n "$token" ]; then
        token_found=true
        if validate_discord_token_direct "$token"; then
          log "  Agent${i} Discord token valid"
          token_valid=true
          break
        else
          log "  Agent${i} Discord token INVALID"
        fi
      fi
    fi
  done
  
  # If no tokens found, check other platform as fallback
  if [ "$token_found" = "false" ] || [ "$token_valid" = "false" ]; then
    local fallback_platform=""
    [ "$platform" = "telegram" ] && fallback_platform="discord"
    [ "$platform" = "discord" ] && fallback_platform="telegram"
    
    for i in $(seq 1 "$count"); do
      if [ "$fallback_platform" = "telegram" ]; then
        local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
        local token="${!token_var:-}"
        [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
        
        if [ -n "$token" ]; then
          token_found=true
          if validate_telegram_token_direct "$token"; then
            log "  Agent${i} Telegram (fallback) token valid"
            token_valid=true
            break
          fi
        fi
      elif [ "$fallback_platform" = "discord" ]; then
        local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
        local token="${!token_var:-}"
        
        if [ -n "$token" ]; then
          token_found=true
          if validate_discord_token_direct "$token"; then
            log "  Agent${i} Discord (fallback) token valid"
            token_valid=true
            break
          fi
        fi
      fi
    done
  fi
  
  if [ "$token_found" = "false" ]; then
    log "  WARNING: No chat tokens found in habitat config"
    return 1
  fi
  
  if [ "$token_valid" = "false" ]; then
    log "  ERROR: All chat tokens are INVALID"
    return 1
  fi
  
  # Also check logs for additional error patterns (belt and suspenders)
  local ERROR_PATTERNS="(getMe.*failed|telegram.*error|telegram.*failed|404.*Not Found|disallowed intents|Invalid.*token|discord.*error|discord.*failed|Unauthorized|channel.*failed|connection.*refused)"
  
  # Check journalctl for recent channel errors (last 60 seconds)
  local journal_errors
  journal_errors=$(journalctl -u "$service" --since "1 minute ago" --no-pager 2>/dev/null | \
    grep -iE "$ERROR_PATTERNS" | head -5)
  
  if [ -n "$journal_errors" ]; then
    log "  Found channel errors in journal (token was valid but connection failed):"
    echo "$journal_errors" | while read line; do log "    $line"; done
    return 1
  fi
  
  # Also check OpenClaw log file if it exists
  if [ -f "$openclaw_log" ]; then
    local log_errors
    log_errors=$(tail -100 "$openclaw_log" 2>/dev/null | \
      grep -iE "$ERROR_PATTERNS" | head -5)
    
    if [ -n "$log_errors" ]; then
      log "  Found channel errors in OpenClaw log:"
      echo "$log_errors" | while read line; do log "    $line"; done
      return 1
    fi
  fi
  
  log "  Channel connectivity verified (direct token validation + no log errors)"
  return 0
}

HEALTHY=false

if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  log "Session isolation mode"
  
  # Ensure state directories have correct permissions
  STATE_BASE="$H/.openclaw-sessions"
  if [ -d "$STATE_BASE" ]; then
    chown -R $USERNAME:$USERNAME "$STATE_BASE" 2>/dev/null || true
    chmod -R u+rwX "$STATE_BASE" 2>/dev/null || true
  fi
  
  # Parse groups and restart services
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  log "Processing ${#GROUP_ARRAY[@]} group(s): ${GROUP_ARRAY[*]}"
  
  for group in "${GROUP_ARRAY[@]}"; do
    log "Restarting openclaw-${group}.service"
    systemctl restart "openclaw-${group}.service" 2>&1 || true
  done
  
  # Check if at least one session service is healthy
  BASE_PORT=18790
  group_index=0
  for group in "${GROUP_ARRAY[@]}"; do
    port=$((BASE_PORT + group_index))
    if check_service_health "openclaw-${group}.service" "$port" 12; then
      HEALTHY=true
      log "Session service healthy: $group"
      break
    fi
    group_index=$((group_index + 1))
  done

elif [ "$ISOLATION" = "container" ]; then
  log "Container isolation mode"
  systemctl restart openclaw-containers.service 2>/dev/null || true
  sleep 10
  if check_service_health "openclaw-containers.service" 18790 12; then
    HEALTHY=true
  fi

else
  log "Standard mode (no isolation)"
  systemctl restart clawdbot 2>&1 || true
  if check_service_health "clawdbot" 18789 12; then
    HEALTHY=true
  fi
fi

if [ "$HEALTHY" = "true" ]; then
  log "SUCCESS - marking setup complete"
  rm -f /var/lib/init-status/needs-post-boot-check
  rm -f /var/lib/init-status/safe-mode
  for si in $(seq 1 $AC); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  touch /var/lib/init-status/setup-complete
  echo '11' > /var/lib/init-status/stage
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=11 DESC=ready" >> /var/log/init-stages.log
  touch /var/lib/init-status/boot-complete
  
  # Update bot display names with habitat name (may have been missed during initial boot)
  log "Updating bot display names..."
  /usr/local/bin/rename-bots.sh >> "$LOG" 2>&1 || log "Warning: rename-bots.sh failed (non-fatal)"
  
  # Note: Boot report flow will send the final notification with agent details
  rm -f /var/lib/init-status/safe-mode  # Clear any stale safe-mode marker
else
  log "FAILURE - entering SAFE MODE with smart recovery"
  touch /var/lib/init-status/safe-mode
  
  # Source smart recovery functions
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$SCRIPT_DIR/safe-mode-recovery.sh" ]; then
    source "$SCRIPT_DIR/safe-mode-recovery.sh"
  elif [ -f "/usr/local/bin/safe-mode-recovery.sh" ]; then
    source "/usr/local/bin/safe-mode-recovery.sh"
  fi
  
  # Try full recovery escalation (token hunting + API fallback + doctor + state cleanup)
  SMART_RECOVERY_SUCCESS=false
  if type run_full_recovery_escalation &>/dev/null; then
    log "Attempting full recovery escalation..."
    export HOME_DIR="$H"
    export USERNAME="$USERNAME"
    export RECOVERY_LOG="$LOG"
    
    if recovery_result=$(run_full_recovery_escalation 2>&1); then
      log "Full recovery escalation succeeded: $recovery_result"
      SMART_RECOVERY_SUCCESS=true
    else
      log "Full recovery escalation failed, falling back to minimal config"
    fi
  elif type run_smart_recovery &>/dev/null; then
    log "Attempting smart recovery (token hunting + API fallback)..."
    export HOME_DIR="$H"
    export USERNAME="$USERNAME"
    export RECOVERY_LOG="$LOG"
    
    if recovery_result=$(run_smart_recovery 2>&1); then
      log "Smart recovery succeeded: $recovery_result"
      SMART_RECOVERY_SUCCESS=true
    else
      log "Smart recovery failed, falling back to minimal config"
    fi
  else
    log "Smart recovery not available, using minimal config"
  fi
  
  # If all recovery failed, fall back to minimal config
  if [ "$SMART_RECOVERY_SUCCESS" = "false" ]; then
    log "All recovery attempts failed, restoring minimal config..."
    cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
    chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
    chmod 600 "$H/.openclaw/openclaw.json"
  fi
  
  # Create SAFE_MODE.md for each agent
  RECOVERY_STATUS="minimal config"
  [ "$SMART_RECOVERY_SUCCESS" = "true" ] && RECOVERY_STATUS="smart recovery (found working credentials)"
  
  for si in $(seq 1 $AC); do
    cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Full config failed health checks

The full openclaw config failed to start. Recovery method: **${RECOVERY_STATUS}**

**Isolation mode:** $ISOLATION
**Session groups:** $SESSION_GROUPS
**Smart recovery:** $SMART_RECOVERY_SUCCESS

## What Happened

1. Full config was applied after reboot
2. Health checks failed (services didn't respond)
3. Safe mode activated with ${RECOVERY_STATUS}
4. You're now running on port 18789

## Troubleshooting

Check logs:
\`\`\`bash
cat /var/log/post-boot-check.log
cat /var/log/safe-mode-recovery.log
journalctl -u clawdbot -n 100
$([ "$ISOLATION" = "session" ] && echo "systemctl status openclaw-browser openclaw-documents")
\`\`\`

Try full config again:
\`\`\`bash
sudo /usr/local/bin/try-full-config.sh
\`\`\`

## Smart Recovery Details

Safe mode now automatically:
- Tries all bot tokens until one works
- Falls back through API providers (Anthropic → OpenAI → Gemini)
- Generates emergency config with working credentials
SAFEMD
    chown $USERNAME:$USERNAME "$H/clawd/agents/agent${si}/SAFE_MODE.md"
  done
  
  # Stop any session/container services and start clawdbot as fallback
  if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
    log "Stopping session services for safe mode fallback"
    IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
    for group in "${GROUP_ARRAY[@]}"; do
      systemctl stop "openclaw-${group}.service" 2>/dev/null || true
    done
  elif [ "$ISOLATION" = "container" ]; then
    log "Stopping container service for safe mode fallback"
    systemctl stop openclaw-containers.service 2>/dev/null || true
  fi
  
  log "Starting clawdbot as safe mode fallback"
  systemctl restart clawdbot
  sleep 5
  
  # Verify clawdbot actually started - prevent restart loops
  CLAWDBOT_STARTED=false
  for attempt in 1 2 3; do
    if systemctl is-active --quiet clawdbot; then
      CLAWDBOT_STARTED=true
      log "Clawdbot started successfully (attempt $attempt)"
      break
    fi
    log "Clawdbot not active, retry $attempt/3..."
    systemctl restart clawdbot
    sleep 5
  done
  
  if [ "$CLAWDBOT_STARTED" = "false" ]; then
    log "CRITICAL: Clawdbot failed to start after 3 attempts"
    log "Gateway failure detected - safe mode bot unavailable"
    touch /var/lib/init-status/gateway-failed
    
    # Create critical failure marker
    for si in $(seq 1 $AC); do
      cat > "$H/clawd/agents/agent${si}/CRITICAL_FAILURE.md" <<CRITMD
# CRITICAL FAILURE - Gateway Won't Start

The OpenClaw gateway (clawdbot) failed to start after multiple attempts.

**Status:** Bot is OFFLINE - no Telegram/Discord connectivity

## What to Check

1. **Service status:**
   \`\`\`bash
   systemctl status clawdbot
   journalctl -u clawdbot -n 50
   \`\`\`

2. **Config syntax:**
   \`\`\`bash
   cat ~/.openclaw/openclaw.json | jq .
   \`\`\`

3. **Port conflicts:**
   \`\`\`bash
   ss -tlnp | grep 18789
   \`\`\`

## Recovery

Try manual restart:
\`\`\`bash
sudo systemctl restart clawdbot
journalctl -u clawdbot -f
\`\`\`

Or restore minimal config:
\`\`\`bash
cp ~/.openclaw/openclaw.minimal.json ~/.openclaw/openclaw.json
sudo systemctl restart clawdbot
\`\`\`
CRITMD
      chown $USERNAME:$USERNAME "$H/clawd/agents/agent${si}/CRITICAL_FAILURE.md"
    done
  fi
  
  # Update bot display names with habitat name (important after recovery)
  log "Updating bot display names after recovery..."
  /usr/local/bin/rename-bots.sh >> "$LOG" 2>&1 || log "Warning: rename-bots.sh failed (non-fatal)"
  
  # Set stage to 11 (ready) even in safe mode - bot is online, just in recovery mode
  # Use different DESC to distinguish from normal ready
  if [ "$CLAWDBOT_STARTED" = "true" ]; then
    echo '11' > /var/lib/init-status/stage
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=11 DESC=safe-mode-ready" >> /var/log/init-stages.log
  else
    echo '12' > /var/lib/init-status/stage
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=12 DESC=critical-failure" >> /var/log/init-stages.log
  fi
  
  rm -f /var/lib/init-status/needs-post-boot-check
  # Note: Don't send notification here - boot report flow will send 
  # a proper safe mode notification with failure details
fi

# Generate boot report for all agents
log "Generating boot report..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/generate-boot-report.sh" ]; then
  source "$SCRIPT_DIR/generate-boot-report.sh"
  export HOME_DIR="$H"
  export HABITAT_JSON_PATH="/etc/habitat.json"
  export HABITAT_ENV_PATH="/etc/habitat-parsed.env"
  export CLAWDBOT_LOG="/var/log/clawdbot.log"
  export BOOT_REPORT_LOG="$LOG"
  run_boot_report_flow
  log "Boot report generated and distributed"
elif [ -f "/usr/local/bin/generate-boot-report.sh" ]; then
  source "/usr/local/bin/generate-boot-report.sh"
  export HOME_DIR="$H"
  export HABITAT_JSON_PATH="/etc/habitat.json"
  export HABITAT_ENV_PATH="/etc/habitat-parsed.env"
  export CLAWDBOT_LOG="/var/log/clawdbot.log"
  export BOOT_REPORT_LOG="$LOG"
  run_boot_report_flow
  log "Boot report generated and distributed"
else
  log "WARNING: generate-boot-report.sh not found, skipping boot report"
fi

log "========== POST-BOOT-CHECK COMPLETE =========="
