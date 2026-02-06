#!/bin/bash
# =============================================================================
# tg-notify.sh -- Send notifications via Telegram and/or Discord
# =============================================================================
# Purpose:  Platform-aware notification sender. Sends a message to the bot
#           owner via Telegram API and/or Discord DM based on PLATFORM config.
#
# Usage:    tg-notify.sh "Your message here"
#
# Inputs:   /etc/droplet.env -- PLATFORM_B64, TELEGRAM_USER_ID_B64
#           /etc/habitat-parsed.env -- AGENT1_BOT_TOKEN, AGENT1_DISCORD_BOT_TOKEN,
#                                      DISCORD_OWNER_ID, PLATFORM
#
# Dependencies: curl, python3, parse-habitat.py
#
# Original: /usr/local/bin/tg-notify.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ ! -f /etc/habitat-parsed.env ] && python3 /usr/local/bin/parse-habitat.py 2>/dev/null
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
# PLATFORM must be explicitly set - no silent defaults
PLATFORM="${PLATFORM:-$(d "$PLATFORM_B64")}"
MSG="$1"
[ -z "$MSG" ] && exit 1
TG_OK=0; DC_OK=0
# --- Telegram notification ---
send_telegram() {
  local TBT="${AGENT1_BOT_TOKEN}"
  local TUI=$(d "$TELEGRAM_USER_ID_B64")
  [ -z "$TBT" ] || [ -z "$TUI" ] && return 1
  curl -sf --max-time 10 "https://api.telegram.org/bot${TBT}/sendMessage" \
    -d "chat_id=${TUI}" \
    -d "text=${MSG}" > /dev/null 2>&1
}
# --- Discord notification ---
send_discord() {
  local DBT="${AGENT1_DISCORD_BOT_TOKEN}"
  local DOI="${DISCORD_OWNER_ID:-$(d "$DISCORD_OWNER_ID_B64")}"
  [ -z "$DBT" ] || [ -z "$DOI" ] && return 1

  local CHANNEL_ID=""
  local CACHE_FILE="/tmp/discord-dm-cache-${DOI}"
  local CACHE_MAX_AGE=86400  # 24 hours in seconds

  # Check cache first
  if [ -f "$CACHE_FILE" ]; then
    local CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$CACHE_AGE" -lt "$CACHE_MAX_AGE" ]; then
      CHANNEL_ID=$(cat "$CACHE_FILE" 2>/dev/null)
    fi
  fi

  # If no cached channel ID, fetch from API
  if [ -z "$CHANNEL_ID" ]; then
    local DM_RESP
    DM_RESP=$(curl -sf --max-time 10 \
      -X POST "https://discord.com/api/v10/users/@me/channels" \
      -H "Authorization: Bot ${DBT}" \
      -H "Content-Type: application/json" \
      -d "{\"recipient_id\":\"${DOI}\"}" 2>/dev/null)
    [ -z "$DM_RESP" ] && return 1

    CHANNEL_ID=$(echo "$DM_RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    [ -z "$CHANNEL_ID" ] && return 1

    # Cache the channel ID for future use
    echo "$CHANNEL_ID" > "$CACHE_FILE" 2>/dev/null
  fi

  # Send message to DM channel
  curl -sf --max-time 10 \
    -X POST "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages" \
    -H "Authorization: Bot ${DBT}" \
    -H "Content-Type: application/json" \
    -d "{\"content\":$(echo "$MSG" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().strip()))')}" > /dev/null 2>&1
}
case "$PLATFORM" in
  telegram)
    send_telegram; TG_OK=$?
    [ $TG_OK -ne 0 ] && exit 1
    ;;
  discord)
    send_discord; DC_OK=$?
    [ $DC_OK -ne 0 ] && exit 1
    ;;
  both)
    send_telegram; TG_OK=$?
    send_discord; DC_OK=$?
    # Succeed if at least one platform worked
    [ $TG_OK -ne 0 ] && [ $DC_OK -ne 0 ] && exit 1
    ;;
  *)
    echo "[tg-notify] ERROR: Invalid PLATFORM='${PLATFORM}'" >&2
    echo "  Valid options: telegram, discord, both" >&2
    echo "  Fix: Set PLATFORM in habitat config or /etc/droplet.env" >&2
    exit 1
    ;;
esac
exit 0
