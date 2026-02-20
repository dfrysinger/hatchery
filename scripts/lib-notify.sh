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

# --- Token Validation ---

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

    if [ "$preferred" = "telegram" ] && [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$tg_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "telegram"); return 0
    elif [ "$preferred" = "discord" ] && [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
      NOTIFY_PLATFORM="discord"; NOTIFY_TOKEN="$dc_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "discord" "with_prefix"); return 0
    elif [ -n "$tg_token" ] && validate_telegram_token_direct "$tg_token"; then
      NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$tg_token"
      NOTIFY_OWNER=$(get_owner_id_for_platform "telegram"); return 0
    elif [ -n "$dc_token" ] && validate_discord_token_direct "$dc_token"; then
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
      if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
        NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$token"
        NOTIFY_OWNER=$(get_owner_id_for_platform "telegram"); return 0
      fi
    fi
    if [ "$platform" = "discord" ] || [ "$platform" = "both" ]; then
      local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local token="${!token_var:-}"
      if [ -n "$token" ] && validate_discord_token_direct "$token"; then
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
      if [ -n "$token" ] && validate_telegram_token_direct "$token"; then
        NOTIFY_PLATFORM="telegram"; NOTIFY_TOKEN="$token"
        NOTIFY_OWNER=$(get_owner_id_for_platform "telegram")
        log "  Cross-platform fallback to Telegram"; return 0
      fi
    elif [ "$alt_platform" = "discord" ]; then
      local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
      local token="${!token_var:-}"
      if [ -n "$token" ] && validate_discord_token_direct "$token"; then
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
