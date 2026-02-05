#!/bin/bash
# =============================================================================
# rename-bots.sh — Rename Telegram bots via API
# =============================================================================
# Purpose:  Platform-aware bot renaming. Renames Telegram bots to include
#           the habitat name (e.g., "ClaudeBot (MyHabitat)").
#           Discord bot names are set in the Developer Portal, not via API.
#
# Inputs:   /etc/droplet.env — secrets and config
#           /etc/habitat-parsed.env — AGENT_COUNT, AGENT*_NAME, AGENT*_BOT_TOKEN,
#                                      HABITAT_NAME, PLATFORM
#
# Outputs:  Telegram bot display names updated via setMyName API
#
# Dependencies: curl, parse-habitat.py
#
# Original: /usr/local/bin/rename-bots.sh (in hatch.yaml write_files)
# =============================================================================
# Platform-aware bot renaming script.
# Renames Telegram bots via API when platform includes telegram.
# Discord bot names are set in the Developer Portal (not via API).
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ ! -f /etc/habitat-parsed.env ] && python3 /usr/local/bin/parse-habitat.py 2>/dev/null
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
PLATFORM="${PLATFORM:-$(d "$PLATFORM_B64")}"; PLATFORM="${PLATFORM:-telegram}"
AC=${AGENT_COUNT:-1}
HN="${HABITAT_NAME:-}"
rename_telegram() {
  for i in $(seq 1 $AC); do
    NV="AGENT${i}_NAME"; NAME="${!NV}"
    TV="AGENT${i}_BOT_TOKEN"; TOK="${!TV}"
    DN="${NAME}Bot"; [ -n "$HN" ] && DN="${NAME}Bot (${HN})"
    if [ -n "$TOK" ]; then
      curl -s "https://api.telegram.org/bot${TOK}/setMyName" -d "name=${DN}" > /dev/null
      echo "[rename-bots] Telegram: renamed agent${i} to '${DN}'"
    else
      echo "[rename-bots] Telegram: skipping agent${i} (no bot token)"
    fi
  done
}
log_discord_skip() {
  echo "[rename-bots] Discord: bot display names are configured in the Discord Developer Portal, not via API. Skipping."
}
case "$PLATFORM" in
  telegram)
    rename_telegram
    ;;
  discord)
    log_discord_skip
    ;;
  both)
    rename_telegram
    log_discord_skip
    ;;
  *)
    echo "[rename-bots] Unknown platform '${PLATFORM}', defaulting to telegram"
    rename_telegram
    ;;
esac
exit 0
