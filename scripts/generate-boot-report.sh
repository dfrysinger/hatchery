#!/bin/bash
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
  
  # Get coordinator
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
  
  # Generate report
  cat <<EOF
# Boot Report
Generated: ${timestamp}
Habitat: ${habitat_name}

## Coordinator
**Designated Fixer:** Agent${coordinator_num} (${coordinator_name})

If you are the coordinator, investigate any errors below.
If you are NOT the coordinator, acknowledge this report but take no action.

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

## What To Do

### If you are the Coordinator (Agent${coordinator_num}):
1. Review errors above
2. Compare "Intended Configuration" with "Actual Results"
3. Fix any discrepancies (bad tokens, missing configs, etc.)
4. Verify fixes by checking service status

### If you are NOT the Coordinator:
- Agent${coordinator_num} (${coordinator_name}) is handling this
- Take no repair action
- Continue normal operation if your systems are working
EOF
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
  local coordinator_result=$(designate_coordinator)
  local coordinator_num="${coordinator_result%%:*}"
  local coordinator_name="${coordinator_result#*:}"
  
  local status_emoji="✅"
  local status_text="Boot complete, all systems OK"
  
  if [ -n "$failures" ]; then
    status_emoji="⚠️"
    status_text="Boot complete with errors"
  fi
  
  cat <<EOF
${status_emoji} <b>[${habitat_name}]</b> ${status_text}

<b>Coordinator:</b> Agent${coordinator_num} (${coordinator_name})
EOF

  if [ -n "$failures" ]; then
    echo ""
    echo "See BOOT_REPORT.md for details."
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
