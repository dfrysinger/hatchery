#!/bin/bash
# =============================================================================
# lib-notify.sh — Notification utilities for health check and safe mode
# =============================================================================
# Source this file for Telegram/Discord notification capabilities.
# Requires: lib-health-check.sh sourced first (for log(), get_owner_id_for_platform)
#
# Usage:
#   source /usr/local/sbin/lib-notify.sh
#   notify_send "telegram" "$token" "$chat_id" "Hello"
#   notify_find_token "telegram"   # sets NOTIFY_PLATFORM, NOTIFY_TOKEN, NOTIFY_OWNER
# =============================================================================

# --- Auth library (token validation delegated to lib-auth.sh) ---

for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-auth.sh" ] && { source "$_lib_path/lib-auth.sh"; break; }
done
# validate_telegram_token() and validate_discord_token() now come from lib-auth.sh

# --- Low-level Send ---

send_telegram_notification() {
  local token="$1"
  local chat_id="$2"
  local message="$3"

  curl -sf --max-time 10 \
    "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" >> "$HC_LOG" 2>&1
}

send_discord_notification() {
  local token="$1"
  local owner_id="$2"
  local message="$3"

  # Strip "user:" prefix if present
  owner_id="${owner_id#user:}"

  # Convert HTML to Discord markdown
  local discord_msg
  discord_msg=$(echo "$message" | sed -e 's/<b>/\*\*/g' -e 's/<\/b>/\*\*/g' -e 's/<code>/`/g' -e 's/<\/code>/`/g')

  # Create DM channel
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

  curl -sf --max-time 10 \
    -H "Authorization: Bot ${token}" \
    -H "Content-Type: application/json" \
    -X POST "https://discord.com/api/v10/channels/${dm_channel}/messages" \
    -d "{\"content\": $(echo "$discord_msg" | jq -Rs .)}" >> "$HC_LOG" 2>&1
}

# --- Token Discovery ---
# Finds a working notification token. Sets global vars:
#   NOTIFY_PLATFORM, NOTIFY_TOKEN, NOTIFY_OWNER

notify_find_token() {
  NOTIFY_PLATFORM=""
  NOTIFY_TOKEN=""
  NOTIFY_OWNER=""

  local config_file="${HC_CONFIG_PATH:-}"

  # First: try tokens from safe mode config
  if [ -f "${HC_SAFE_MODE_FILE:-}" ] && [ -f "$config_file" ]; then
    local tg_token dc_token
    tg_token=$(jq -r '.channels.telegram.botToken // .channels.telegram.accounts["safe-mode"].botToken // .channels.telegram.accounts.default.botToken // empty' "$config_file" 2>/dev/null)
    dc_token=$(jq -r '.channels.discord.token // .channels.discord.accounts["safe-mode"].token // .channels.discord.accounts.default.token // empty' "$config_file" 2>/dev/null)

    local preferred="${HC_PLATFORM:-telegram}"

    if [ "$preferred" = "telegram" ] && [ -n "$tg_token" ] && validate_telegram_token "$tg_token"; then
      NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$tg_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "telegram"); return 0
    elif [ "$preferred" = "discord" ] && [ -n "$dc_token" ] && validate_discord_token "$dc_token"; then
      NOTIFY_PLATFORM="discord"; NOTIFY_TOKEN="$dc_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "discord" "with_prefix"); return 0
    elif [ -n "$tg_token" ] && validate_telegram_token "$tg_token"; then
      NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$tg_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "telegram"); return 0
    elif [ -n "$dc_token" ] && validate_discord_token "$dc_token"; then
      NOTIFY_PLATFORM="discord"; NOTIFY_TOKEN="$dc_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "discord" "with_prefix"); return 0
    fi
  fi

  # Second: try habitat agent tokens
  local platform="${HC_PLATFORM:-telegram}"
  local count="${HC_AGENT_COUNT:-1}"

  # Re-source to get AGENT{N} vars
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

  for i in $(seq 1 "$count"); do
    if [ "$platform" = "telegram" ] || [ "$platform" = "both" ]; then
      local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local token="${!token_var:-}"
      [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
      if [ -n "$token" ] && validate_telegram_token "$token"; then
        NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$token"
        NOTIFY_OWNER=$(get_owner_id_for_platform "telegram"); return 0
      fi
    fi
    if [ "$platform" = "discord" ] || [ "$platform" = "both" ]; then
      local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local token="${!token_var:-}"
      if [ -n "$token" ] && validate_discord_token "$token"; then
        NOTIFY_PLATFORM="discord"; NOTIFY_TOKEN="$token"
        NOTIFY_OWNER=$(get_owner_id_for_platform "discord" "with_prefix"); return 0
      fi
    fi
  done

  # Third: cross-platform fallback
  local alt_platform
  [ "$platform" = "telegram" ] && alt_platform="discord" || alt_platform="telegram"

  for i in $(seq 1 "$count"); do
    if [ "$alt_platform" = "telegram" ]; then
      local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local token="${!token_var:-}"
      [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
      if [ -n "$token" ] && validate_telegram_token "$token"; then
        NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$token"
        NOTIFY_OWNER=$(get_owner_id_for_platform "telegram")
        log "  Cross-platform fallback to Telegram"; return 0
      fi
    elif [ "$alt_platform" = "discord" ]; then
      local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local token="${!token_var:-}"
      if [ -n "$token" ] && validate_discord_token "$token"; then
        NOTIFY_PLATFORM="discord"; NOTIFY_TOKEN="$token"
        NOTIFY_OWNER=$(get_owner_id_for_platform "discord" "with_prefix")
        log "  Cross-platform fallback to Discord"; return 0
      fi
    fi
  done

  log "  No working notification token found"
  return 1
}

# --- High-level send ---

# Send a notification message, auto-discovering token if needed.
# Usage: notify_send_message "⚠️ Something happened"
notify_send_message() {
  local message="$1"

  if [ -z "${NOTIFY_TOKEN:-}" ]; then
    notify_find_token || { log "Cannot send notification - no working token"; return 1; }
  fi

  if [ -z "${NOTIFY_OWNER:-}" ]; then
    log "Cannot send notification - no owner ID"
    return 1
  fi

  log "  Sending via $NOTIFY_PLATFORM to $NOTIFY_OWNER"

  if [ "$NOTIFY_PLATFORM" = "telegram" ]; then
    send_telegram_notification "$NOTIFY_TOKEN" "$NOTIFY_OWNER" "$message"
  elif [ "$NOTIFY_PLATFORM" = "discord" ]; then
    send_discord_notification "$NOTIFY_TOKEN" "$NOTIFY_OWNER" "$message"
  else
    log "  Unknown platform: $NOTIFY_PLATFORM"
    return 1
  fi
}

# --- SafeModeBot Intro ---

# Send SafeModeBot intro with diagnostics via --deliver.
# Shared by gateway-e2e-check.sh and safe-mode-handler.sh.
# Requires: HC_PLATFORM, CONFIG_PATH, H, HC_USERNAME, HC_LOG, GROUP (optional), GROUP_PORT (optional)
notify_send_safe_mode_intro() {
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
  chown "${HC_USERNAME:-bot}:${HC_USERNAME:-bot}" "$report" 2>/dev/null

  local owner_id
  owner_id=$(get_owner_id_for_platform "${HC_PLATFORM:-telegram}" "with_prefix")
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

  local channel="${NOTIFY_PLATFORM:-${HC_PLATFORM:-telegram}}"

  log "  Command: openclaw agent --agent safe-mode --deliver --reply-channel $channel --reply-to $owner_id"

  local output exit_code
  output=$(timeout 120 sudo -u "${HC_USERNAME:-bot}" env $env_prefix openclaw agent \
    --agent "safe-mode" --message "$prompt" --deliver \
    --reply-channel "$channel" --reply-account "safe-mode" --reply-to "$owner_id" \
    --timeout 90 --json 2>&1)
  exit_code=$?

  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qE "No API key found|Embedded agent failed|FailoverError"; then
    log "  ✓ SafeModeBot intro sent"
  else
    log "  ✗ SafeModeBot intro failed (exit=$exit_code)"
    log "  User was already notified via direct API"
  fi
  log "========== SAFE MODE INTRO COMPLETE =========="
}
