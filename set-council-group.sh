#!/bin/bash
# =============================================================================
# set-council-group.sh - Configure council group/channel for Telegram or Discord
# =============================================================================
# Purpose: Sets the council communication channel in clawdbot configuration.
#          Supports both Telegram (groups) and Discord (guilds/channels).
#
# Usage:
#   set-council-group.sh <id> [--platform telegram|discord]
#   set-council-group.sh <guild_id> <channel_id> --platform discord
#
# Arguments:
#   <id>          - For Telegram: group_id. For Discord: guild_id (requires channel_id)
#   <channel_id>  - Discord only: the channel ID within the guild
#
# Options:
#   --platform    - Platform to configure: telegram or discord
#                   Can also be set via PLATFORM environment variable
#                   CLI flag takes priority over env var
#
# Environment:
#   PLATFORM      - Default platform if --platform not specified
#
# Examples:
#   # Telegram (default if PLATFORM not set)
#   set-council-group.sh -1001234567890
#
#   # Discord via flag
#   set-council-group.sh 123456789012345678 987654321098765432 --platform discord
#
#   # Discord via env
#   PLATFORM=discord set-council-group.sh 123456789012345678 987654321098765432
# =============================================================================

set -euo pipefail

# Parse arguments
PLATFORM_FLAG=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --platform)
      PLATFORM_FLAG="$2"
      shift 2
      ;;
    --platform=*)
      PLATFORM_FLAG="${1#*=}"
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Restore positional args
set -- "${POSITIONAL_ARGS[@]:-}"

# Determine platform: CLI flag takes priority over env var
if [[ -n "$PLATFORM_FLAG" ]]; then
  PLATFORM="$PLATFORM_FLAG"
elif [[ -n "${PLATFORM:-}" ]]; then
  PLATFORM="${PLATFORM}"
else
  PLATFORM="telegram"  # Default to telegram for backward compatibility
fi

# Normalize platform to lowercase
PLATFORM=$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')

# Load environment
set -a
source /etc/droplet.env
set +a
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

H="/home/$USERNAME"
CFG="$H/.clawdbot/clawdbot.json"

# Validate config exists
[ ! -f "$CFG" ] && { echo "Config not found: $CFG" >&2; exit 1; }

# Platform-specific logic
case "$PLATFORM" in
  telegram)
    # Telegram: requires 1 arg (group_id)
    [[ ${#POSITIONAL_ARGS[@]} -lt 1 ]] && { 
      echo "Usage: set-council-group.sh <group_id> [--platform telegram]" >&2
      exit 1
    }
    GID="${POSITIONAL_ARGS[0]}"
    
    # Backup config
    cp "$CFG" "$CFG.bak"
    
    # Update Telegram groups config
    if grep -q '"groups":{' "$CFG"; then
      sed -i "s|\"groups\":{[^}]*}|\"groups\":{\"${GID}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}|" "$CFG"
    else
      sed -i "s|\"telegram\":{\"enabled\":true|\"telegram\":{\"enabled\":true,\"groups\":{\"${GID}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}|" "$CFG"
    fi
    
    # Write state files
    echo "$GID" > "$H/clawd/.council-group-id"
    echo "true" > "$H/clawd/.council-enabled"
    echo "telegram" > "$H/clawd/.council-platform"
    chown "$USERNAME:$USERNAME" "$H/clawd/.council-group-id" "$H/clawd/.council-enabled" "$H/clawd/.council-platform"
    
    MSG="Council group set to Telegram group $GID"
    ;;
    
  discord)
    # Discord: requires 2 args (guild_id, channel_id)
    [[ ${#POSITIONAL_ARGS[@]} -lt 2 ]] && {
      echo "Usage: set-council-group.sh <guild_id> <channel_id> --platform discord" >&2
      exit 1
    }
    GUILD_ID="${POSITIONAL_ARGS[0]}"
    CHANNEL_ID="${POSITIONAL_ARGS[1]}"
    
    # Backup config
    cp "$CFG" "$CFG.bak"
    
    # Update Discord guilds/channels config
    # Format: channels.discord.guilds.<guild_id>.channels.<channel_id>
    if grep -q '"guilds":{' "$CFG"; then
      # Guilds already exist - add/update this guild
      sed -i "s|\"guilds\":{[^}]*}|\"guilds\":{\"${GUILD_ID}\":{\"channels\":{\"${CHANNEL_ID}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}}}|" "$CFG"
    else
      # No guilds section - add it under discord
      sed -i "s|\"discord\":{\"enabled\":true|\"discord\":{\"enabled\":true,\"guilds\":{\"${GUILD_ID}\":{\"channels\":{\"${CHANNEL_ID}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}}}|" "$CFG"
    fi
    
    # Write state files
    echo "${GUILD_ID}:${CHANNEL_ID}" > "$H/clawd/.council-group-id"
    echo "true" > "$H/clawd/.council-enabled"
    echo "discord" > "$H/clawd/.council-platform"
    chown "$USERNAME:$USERNAME" "$H/clawd/.council-group-id" "$H/clawd/.council-enabled" "$H/clawd/.council-platform"
    
    MSG="Council channel set to Discord guild $GUILD_ID channel $CHANNEL_ID"
    ;;
    
  *)
    # Unknown platform - log warning to stderr and exit 0 (don't crash boot)
    echo "Warning: Unknown platform '$PLATFORM'. Supported: telegram, discord. Skipping council setup." >&2
    exit 0
    ;;
esac

# Restart clawdbot service
systemctl restart clawdbot
sleep 3

# Verify service started successfully
if systemctl is-active --quiet clawdbot; then
  echo "$MSG. Clawdbot restarted."
else
  echo "Restart failed, restoring backup" >&2
  cp "$CFG.bak" "$CFG"
  systemctl restart clawdbot
  exit 1
fi
