#!/bin/bash
# shellcheck disable=SC2155  # Declare and assign separately - acceptable here as we don't check return values
# =============================================================================
# generate-boot-report.sh -- Boot Report & Coordinator System
# =============================================================================
# Purpose:  Generate comprehensive boot report showing intended vs actual
#           configuration, designate a coordinator bot, and notify user.
#
# Features:
#   - Token discovery: Find first working bot token
#   - Coordinator designation: First working agent handles repairs
#   - Component status: Detect failures and successes from logs
#   - Boot report: Full context for any bot to understand and fix issues
#   - Distribution: Copy report to all agent workspaces
#   - Notification: Send status via first working token
#
# Usage:    source generate-boot-report.sh
#           run_boot_report_flow
# =============================================================================

# Allow mock functions for testing
VALIDATE_TELEGRAM_TOKEN_FN="${VALIDATE_TELEGRAM_TOKEN_FN:-validate_telegram_token_real}"
VALIDATE_DISCORD_TOKEN_FN="${VALIDATE_DISCORD_TOKEN_FN:-validate_discord_token_real}"
SEND_TELEGRAM_FN="${SEND_TELEGRAM_FN:-send_telegram_real}"

# Paths (can be overridden for testing)
HABITAT_JSON_PATH="${HABITAT_JSON_PATH:-/etc/habitat.json}"
HABITAT_ENV_PATH="${HABITAT_ENV_PATH:-/etc/habitat-parsed.env}"
CLAWDBOT_LOG="${CLAWDBOT_LOG:-/var/log/clawdbot.log}"
HOME_DIR="${HOME_DIR:-/home/${USERNAME:-bot}}"

# =============================================================================
# Token Validation Functions
# =============================================================================

validate_telegram_token_real() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 1
  fi
  
  curl -sf --max-time 5 "https://api.telegram.org/bot${token}/getMe" >/dev/null 2>&1
}

validate_discord_token_real() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 1
  fi
  
  curl -sf --max-time 5 -H "Authorization: Bot ${token}" \
    "https://discord.com/api/v10/users/@me" >/dev/null 2>&1
}

send_telegram_real() {
  local token="$1"
  local chat_id="$2"
  local message="$3"
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    echo "TEST: Would send to $chat_id via token ${token:0:10}..."
    return 1
  fi
  
  curl -sf --max-time 10 \
    "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" >/dev/null 2>&1
}

# =============================================================================
# Token Discovery
# =============================================================================

# Find first working token for a platform
# Returns: "agent_number:token" or empty string
find_first_working_token() {
  local platform="${1:-telegram}"
  local count="${AGENT_COUNT:-0}"
  
  for i in $(seq 1 "$count"); do
    local token=""
    
    if [ "$platform" = "telegram" ]; then
      local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      token="${!token_var:-}"
      [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
      
      if [ -n "$token" ] && $VALIDATE_TELEGRAM_TOKEN_FN "$token"; then
        echo "${i}:${token}"
        return 0
      fi
    elif [ "$platform" = "discord" ]; then
      local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      token="${!token_var:-}"
      
      if [ -n "$token" ] && $VALIDATE_DISCORD_TOKEN_FN "$token"; then
        echo "${i}:${token}"
        return 0
      fi
    fi
  done
  
  echo ""
  return 1
}

# =============================================================================
# Coordinator Designation
# =============================================================================

# Designate the coordinator (first working agent)
# Returns: "agent_number:agent_name"
designate_coordinator() {
  local platform="${PLATFORM:-telegram}"
  
  # Find first working token
  local result=$(find_first_working_token "$platform")
  
  if [ -n "$result" ]; then
    local agent_num="${result%%:*}"
    local name_var="AGENT${agent_num}_NAME"
    local agent_name="${!name_var:-agent${agent_num}}"
    echo "${agent_num}:${agent_name}"
    return 0
  fi
  
  # Fallback to Agent1 if no validation possible
  echo "1:${AGENT1_NAME:-agent1}"
  return 1
}

# =============================================================================
# Component Status Detection
# =============================================================================

# Detect component failures from logs
detect_component_failures() {
  local log_file="${CLAWDBOT_LOG:-/var/log/clawdbot.log}"
  local failures=""
  
  if [ -f "$log_file" ]; then
    # Telegram failures
    while IFS= read -r line; do
      if [[ "$line" == *"channel exited"* ]] || [[ "$line" == *"failed"* ]]; then
        failures="${failures}${line}\n"
      fi
    done < <(grep -i "telegram.*\(exited\|failed\|error\)" "$log_file" 2>/dev/null || true)
    
    # Discord failures
    while IFS= read -r line; do
      failures="${failures}${line}\n"
    done < <(grep -i "discord.*\(exited\|failed\|error\)" "$log_file" 2>/dev/null || true)
    
    # API failures
    while IFS= read -r line; do
      failures="${failures}${line}\n"
    done < <(grep -i "\(anthropic\|openai\|google\).*\(401\|403\|error\)" "$log_file" 2>/dev/null || true)
  fi
  
  echo -e "$failures"
}

# Detect successful components from logs
detect_successful_components() {
  local log_file="${CLAWDBOT_LOG:-/var/log/clawdbot.log}"
  local successes=""
  
  if [ -f "$log_file" ]; then
    # Telegram successes (starting provider with bot name)
    while IFS= read -r line; do
      successes="${successes}${line}\n"
    done < <(grep -i "telegram.*starting provider.*@" "$log_file" 2>/dev/null || true)
    
    # Gateway listening
    while IFS= read -r line; do
      successes="${successes}${line}\n"
    done < <(grep -i "gateway.*listening\|listening on port" "$log_file" 2>/dev/null || true)
  fi
  
  echo -e "$successes"
}

# Get agent status summary
get_agent_statuses() {
  local count="${AGENT_COUNT:-0}"
  local statuses=""
  
  for i in $(seq 1 "$count"); do
    local name_var="AGENT${i}_NAME"
    local name="${!name_var:-agent${i}}"
    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    local token="${!token_var:-}"
    [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
    
    local status="❓ Unknown"
    if [ -n "$token" ]; then
      if $VALIDATE_TELEGRAM_TOKEN_FN "$token" 2>/dev/null; then
        status="✅ OK"
      else
        status="❌ FAILED"
      fi
    else
      status="⚠️ No token"
    fi
    
    statuses="${statuses}| Agent${i} | ${name} | Telegram | ${status} |\n"
  done
  
  echo -e "$statuses"
}

# =============================================================================
# Boot Report Generation
# =============================================================================

generate_boot_report() {
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local habitat_name="${HABITAT_NAME:-Unknown}"
  
  # Check if we're in safe mode
  local is_safe_mode="false"
  [ -f "/var/lib/init-status/safe-mode" ] && is_safe_mode="true"
  
  # Get coordinator (for multi-agent mode)
  local coordinator_result=$(designate_coordinator)
  local coordinator_num="${coordinator_result%%:*}"
  local coordinator_name="${coordinator_result#*:}"
  
  # Get habitat JSON
  local habitat_json=""
  if [ -f "$HABITAT_JSON_PATH" ]; then
    habitat_json=$(cat "$HABITAT_JSON_PATH" 2>/dev/null | head -50)
  else
    habitat_json='{"error": "habitat.json not found"}'
  fi
  
  # Get failures and successes
  local failures=$(detect_component_failures)
  local successes=$(detect_successful_components)
  local agent_statuses=$(get_agent_statuses)
  
  # Determine if there are errors
  local has_errors="false"
  [ -n "$failures" ] && has_errors="true"
  
  # Generate report header based on mode
  if [ "$is_safe_mode" = "true" ]; then
    # Load diagnostics if available
    local diagnostics=""
    if [ -f "/var/log/safe-mode-diagnostics.txt" ]; then
      diagnostics=$(cat /var/log/safe-mode-diagnostics.txt)
    fi
    
    cat <<EOF
# Boot Report — SAFE MODE ACTIVE
Generated: ${timestamp}
Habitat: ${habitat_name}

## ⚠️ Safe Mode
**You are the SafeModeBot** — the emergency recovery agent.

The normal bot(s) failed to start. You're running on borrowed credentials to help diagnose and fix the issue.

**Your job:** Diagnose the problem, attempt repair if possible, or escalate to the user.

### Recovery Diagnostics
\`\`\`
${diagnostics:-No diagnostics available}
\`\`\`
EOF
  else
    cat <<EOF
# Boot Report
Generated: ${timestamp}
Habitat: ${habitat_name}

## Coordinator
**Designated Fixer:** Agent${coordinator_num} (${coordinator_name})

If you are the coordinator, investigate any errors below.
If you are NOT the coordinator, acknowledge this report but take no action.
EOF
  fi

  cat <<EOF

## Intended Configuration
Source: ${HABITAT_JSON_PATH}
\`\`\`json
${habitat_json}
\`\`\`

## Actual Results

| Agent | Name | Platform | Status |
|-------|------|----------|--------|
${agent_statuses}

### Successful Components
\`\`\`
${successes:-No successes logged yet}
\`\`\`

EOF

  if [ "$has_errors" = "true" ]; then
    cat <<EOF
## ⚠️ Errors Requiring Attention
\`\`\`
${failures}
\`\`\`

EOF
  else
    cat <<EOF
## ✅ No Errors Detected
All components started successfully.

EOF
  fi

  cat <<EOF
## Reference
- Habitat schema: https://github.com/dfrysinger/hatchery/blob/main/docs/HABITAT.md
- Troubleshooting: https://github.com/dfrysinger/hatchery/blob/main/docs/TROUBLESHOOTING.md
- Full habitat file: ${HABITAT_JSON_PATH}
- Parsed environment: ${HABITAT_ENV_PATH}
- Boot logs: /var/log/post-boot-check.log
- Service logs: journalctl -u clawdbot -n 100

EOF

  # Different instructions for safe mode vs normal multi-agent mode
  if [ "$is_safe_mode" = "true" ]; then
    cat <<EOF
## What To Do (Safe Mode)

You are the only bot running. The normal agent(s) failed to start.

### Step 1: Diagnose
Review the errors above. Use these commands to investigate:

\`\`\`bash
# Check what went wrong
journalctl -u clawdbot --since "10 minutes ago" | grep -iE "error|failed|401|403|404"

# Check the recovery log
cat /var/log/post-boot-check.log | tail -50

# Validate tokens:
# Telegram: curl -s "https://api.telegram.org/bot<TOKEN>/getMe" | jq .ok
# Discord:  curl -s -H "Authorization: Bot <TOKEN>" "https://discord.com/api/v10/users/@me" | jq .id
\`\`\`

### Step 2: Common Fixes

| Error | Meaning | What You Can Do |
|-------|---------|-----------------|
| getMe failed / 404 | Invalid Telegram token | Token needs regeneration — escalate to user |
| Unauthorized / 401 | Bad Discord token | Token needs regeneration — escalate to user |
| disallowed intents | Discord missing permissions | User must enable Message Content Intent |
| API key invalid | Anthropic/OpenAI/etc failed | Key expired or revoked — escalate to user |

### Step 3: Escalate if Needed

If the problem requires new credentials (tokens, API keys), tell the user clearly:
- What credential is broken
- Where to get a new one (BotFather for Telegram, Discord Dev Portal, etc.)
- What to update in their habitat config

**Remember:** You're here to help diagnose and explain, not to access external systems the user controls.
EOF
  else
    cat <<EOF
## What To Do

### If you are the Coordinator (Agent${coordinator_num}):
1. Review the errors above carefully
2. Compare "Intended Configuration" with "Actual Results"
3. Fix any discrepancies (bad tokens, missing configs, etc.)
4. Verify fixes by checking service status

**Diagnostic Commands:**
\`\`\`bash
# Check service status
systemctl is-active clawdbot openclaw-browser openclaw-documents 2>/dev/null

# Check recent errors (look for patterns matching errors above)
journalctl -u clawdbot --since "5 minutes ago" | grep -iE "error|failed|unauthorized"

# Validate tokens (platform-specific):
# Telegram: curl -s "https://api.telegram.org/bot<TOKEN>/getMe" | jq .ok
# Discord:  curl -s -H "Authorization: Bot <TOKEN>" "https://discord.com/api/v10/users/@me" | jq .id
\`\`\`

**Common Error Patterns:**
| Error | Platform | Meaning | Fix |
|-------|----------|---------|-----|
| getMe failed / 404 | Telegram | Invalid or revoked token | Alert user - needs new token |
| disallowed intents | Discord | Missing intents in Dev Portal | User must enable Message Content Intent |
| Unauthorized / 401 | Both | Bad token | Alert user - needs new token |
| connection refused | Both | Network or service down | Check firewall, restart service |

**After Fixing:** \`sudo systemctl restart clawdbot\` then verify with \`systemctl is-active clawdbot\`

**Escalate to User if:** Token/key needs regeneration, or problem persists after 2 fix attempts.

### If you are NOT the Coordinator:
- Agent${coordinator_num} (${coordinator_name}) is handling this
- Take no repair action unless coordinator is offline
- Continue normal operation if your systems are working
- If coordinator appears stuck (>5 min no progress), you may take over
EOF
  fi
}

# =============================================================================
# Report Distribution
# =============================================================================

distribute_boot_report() {
  local report="$1"
  local count="${AGENT_COUNT:-1}"
  local home="${HOME_DIR:-/home/bot}"
  
  # Distribute to each agent workspace
  for i in $(seq 1 "$count"); do
    local workspace="$home/clawd/agents/agent${i}"
    if [ -d "$workspace" ] || [ "${TEST_MODE:-}" = "1" ]; then
      mkdir -p "$workspace" 2>/dev/null || true
      echo "$report" > "$workspace/BOOT_REPORT.md"
      [ -n "${USERNAME:-}" ] && chown "${USERNAME}:${USERNAME}" "$workspace/BOOT_REPORT.md" 2>/dev/null || true
    fi
  done
  
  # Also distribute to safe-mode workspace (for when recovery kicks in)
  local safe_mode_workspace="$home/clawd/agents/safe-mode"
  if [ -d "$safe_mode_workspace" ] || [ "${TEST_MODE:-}" = "1" ]; then
    mkdir -p "$safe_mode_workspace" 2>/dev/null || true
    echo "$report" > "$safe_mode_workspace/BOOT_REPORT.md"
    [ -n "${USERNAME:-}" ] && chown "${USERNAME}:${USERNAME}" "$safe_mode_workspace/BOOT_REPORT.md" 2>/dev/null || true
  fi
  
  # Also copy to shared folder
  local shared="$home/clawd/shared"
  mkdir -p "$shared" 2>/dev/null || true
  echo "$report" > "$shared/BOOT_REPORT.md"
  [ -n "${USERNAME:-}" ] && chown "${USERNAME}:${USERNAME}" "$shared/BOOT_REPORT.md" 2>/dev/null || true
}

# =============================================================================
# Notification
# =============================================================================

# Send boot notification via first working token
send_boot_notification() {
  local message="$1"
  local count="${AGENT_COUNT:-0}"
  local owner_id="${TELEGRAM_OWNER_ID:-}"
  
  [ -z "$owner_id" ] && return 1
  
  # Try each token until one works
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    local token="${!token_var:-}"
    [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
    
    if [ -n "$token" ]; then
      if $SEND_TELEGRAM_FN "$token" "$owner_id" "$message"; then
        return 0
      fi
    fi
  done
  
  return 1
}

# Generate notification message
generate_notification_message() {
  local habitat_name="${HABITAT_NAME:-Unknown}"
  local failures=$(detect_component_failures)
  local is_safe_mode="false"
  local is_gateway_failed="false"
  [ -f "/var/lib/init-status/safe-mode" ] && is_safe_mode="true"
  [ -f "/var/lib/init-status/gateway-failed" ] && is_gateway_failed="true"
  
  # CRITICAL: Gateway failed to start at all
  if [ "$is_gateway_failed" = "true" ]; then
    cat <<EOF
🔴 <b>[${habitat_name}] CRITICAL FAILURE</b>

Gateway failed to start after multiple attempts.
Bot is OFFLINE - no connectivity available.

Check logs: <code>journalctl -u clawdbot -n 50</code>
See CRITICAL_FAILURE.md for recovery steps.
EOF
    return
  fi
  
  # SAFE MODE notification - completely different message
  if [ "$is_safe_mode" = "true" ]; then
    cat <<EOF
⚠️ <b>[${habitat_name}] SAFE MODE</b>

Health check failed. SafeModeBot is online to diagnose.
EOF
    
    # Add diagnostics summary if available
    if [ -f "/var/log/safe-mode-diagnostics.txt" ]; then
      echo ""
      echo "<code>"
      # Skip the first line (header) since we're in a code block already
      tail -n +2 /var/log/safe-mode-diagnostics.txt
      echo "</code>"
    elif [ -n "$failures" ]; then
      # Fallback to failure summary if no diagnostics
      echo ""
      echo "<b>What went wrong:</b>"
      echo "$failures" | head -2 | sed 's/^/• /'
    fi
    
    echo ""
    echo "See BOOT_REPORT.md for details."
    return
  fi
  
  # NORMAL MODE notification
  local coordinator_result=$(designate_coordinator)
  local coordinator_num="${coordinator_result%%:*}"
  local coordinator_name="${coordinator_result#*:}"
  local count="${AGENT_COUNT:-1}"
  
  if [ -n "$failures" ]; then
    # Normal mode WITH errors
    cat <<EOF
⚠️ <b>[${habitat_name}]</b> Online with errors

<b>Coordinator:</b> Agent${coordinator_num} (${coordinator_name})

See BOOT_REPORT.md for details.
EOF
  else
    # Normal mode, all OK
    cat <<EOF
✅ <b>[${habitat_name}]</b> Ready!

EOF
    # List agents if more than one
    if [ "$count" -gt 1 ]; then
      echo "<b>All ${count} agents online:</b>"
      for i in $(seq 1 "$count"); do
        local name_var="AGENT${i}_NAME"
        local name="${!name_var:-Agent${i}}"
        echo "• ${name} ✓"
      done
    else
      local name_var="AGENT1_NAME"
      local name="${!name_var:-Agent1}"
      echo "${name} ready."
    fi
  fi
}

# =============================================================================
# Main Flow
# =============================================================================

run_boot_report_flow() {
  local log="${BOOT_REPORT_LOG:-/var/log/boot-report.log}"
  
  log_report() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$log"
  }
  
  log_report "Starting boot report generation..."
  
  # Source environment if not already loaded
  # shellcheck disable=SC1090  # Path is validated before sourcing
  [ -z "${AGENT_COUNT:-}" ] && [ -f "$HABITAT_ENV_PATH" ] && source "$HABITAT_ENV_PATH"
  
  # Generate report
  log_report "Generating boot report..."
  local report=$(generate_boot_report)
  
  # Distribute to all agents
  log_report "Distributing to agent workspaces..."
  distribute_boot_report "$report"
  
  # Send notification
  log_report "Sending notification..."
  local notification=$(generate_notification_message)
  if send_boot_notification "$notification"; then
    log_report "Notification sent successfully"
  else
    log_report "WARNING: Failed to send notification (no working tokens)"
  fi
  
  log_report "Boot report flow complete"
}

# =============================================================================
# Script Entry Point
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_boot_report_flow
fi
