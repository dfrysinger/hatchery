#!/bin/bash
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
  local CACHE_FILE="${DISCORD_DM_CACHE_FILE:-/tmp/discord-dm-cache-${DOI}}"
  local CACHE_MAX_AGE="${DISCORD_DM_CACHE_TTL:-86400}"  # default 24 hours

  # Check cache first
  if [ -f "$CACHE_FILE" ]; then
    local CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$CACHE_AGE" -lt "$CACHE_MAX_AGE" ]; then
      CHANNEL_ID=$(cat "$CACHE_FILE" 2>/dev/null)
    fi
  fi

  atomic_write_cache() {
    local path="$1"
    local value="$2"

    python3 - "$path" "$value" <<'PY'
import os, sys, tempfile
path = sys.argv[1]
value = sys.argv[2]
base_dir = os.path.dirname(os.path.abspath(path)) or "."
os.makedirs(base_dir, exist_ok=True)
fd, tmppath = tempfile.mkstemp(prefix=".tmp-", dir=base_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(value)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmppath, path)
except Exception:
    try:
        os.unlink(tmppath)
    except Exception:
        pass
    raise
PY
  }

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

    # Cache the channel ID for future use (atomic)
    atomic_write_cache "$CACHE_FILE" "$CHANNEL_ID" 2>/dev/null || true
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
