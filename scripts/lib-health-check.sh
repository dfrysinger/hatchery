#!/bin/bash
# shellcheck disable=SC2034  # Variables used by sourcing scripts
# =============================================================================
# lib-health-check.sh — Shared utilities for health check and safe mode scripts
# =============================================================================
# Source this file from gateway-health-check.sh and safe-mode-handler.sh.
# Provides: logging, environment loading, common variable setup.
#
# Usage:
#   source /usr/local/sbin/lib-health-check.sh   (or /usr/local/bin/)
#   hc_init_logging "browser"    # Sets up LOG file and RUN_ID
#   hc_load_environment          # Sources env files, sets up variables
# =============================================================================

# --- Logging ---

# Global log variables (set by hc_init_logging)
HC_LOG=""
HC_RUN_ID=""

hc_init_logging() {
  local group="${1:-}"
  HC_RUN_ID="$$-$(date +%s)"

  if [ -n "$group" ]; then
    HC_LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check-${group}.log}"
  else
    HC_LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check.log}"
  fi

  touch "$HC_LOG" && chmod 644 "$HC_LOG" 2>/dev/null || true
}

log() {
  local msg
  msg="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$HC_RUN_ID] $*"
  echo "$msg" >> "$HC_LOG"
  logger -t "health-check${GROUP:+-$GROUP}" "$*" 2>/dev/null || true
}

# --- Environment Loading ---

# Source lib-env.sh for d() and env helpers
for _hc_lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_hc_lib_path/lib-env.sh" ] && { source "$_hc_lib_path/lib-env.sh"; break; }
done
type d &>/dev/null || { echo "FATAL: lib-env.sh not found (d() undefined)" >&2; exit 1; }

hc_load_environment() {
  # Load env files (droplet.env + habitat-parsed.env)
  if ! env_load; then
    log "ERROR: env_load failed (missing /etc/droplet.env?)"
    return 1
  fi

  if [ ! -f /etc/habitat-parsed.env ] && [ -z "${TEST_MODE:-}" ]; then
    log "ERROR: /etc/habitat-parsed.env not found"
    return 1
  fi

  # Decode API keys from base64
  env_decode_keys

  # Common variables
  HC_AGENT_COUNT="${AGENT_COUNT:-1}"
  HC_USERNAME="${USERNAME:-bot}"
  HC_HOME="/home/$HC_USERNAME"
  HC_ISOLATION="${ISOLATION_DEFAULT:-none}"
  HC_SESSION_GROUPS="${ISOLATION_GROUPS:-}"
  HC_PLATFORM="${PLATFORM:-telegram}"
  HC_HABITAT_NAME="${HABITAT_NAME:-Droplet}"

  # Per-group mode
  GROUP="${GROUP:-}"
  GROUP_PORT="${GROUP_PORT:-18789}"

  if [ -n "$GROUP" ]; then
    HC_SERVICE_NAME="openclaw-${GROUP}"
  else
    HC_SERVICE_NAME="openclaw"
  fi

  # Config and state paths
  if [ -n "$GROUP" ]; then
    HC_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HC_HOME/.openclaw/configs/${GROUP}/openclaw.session.json}"
    HC_RECOVERY_COUNTER="/var/lib/init-status/recovery-attempts-${GROUP}"
    HC_SAFE_MODE_FILE="/var/lib/init-status/safe-mode-${GROUP}"
    HC_UNHEALTHY_MARKER="/var/lib/init-status/unhealthy-${GROUP}"
  else
    HC_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HC_HOME/.openclaw/openclaw.json}"
    HC_RECOVERY_COUNTER="/var/lib/init-status/recovery-attempts"
    HC_SAFE_MODE_FILE="/var/lib/init-status/safe-mode"
    HC_UNHEALTHY_MARKER="/var/lib/init-status/unhealthy"
  fi

  # For backwards compat (many functions reference these directly)
  CONFIG_PATH="$HC_CONFIG_PATH"
  SAFE_MODE_FILE="$HC_SAFE_MODE_FILE"
  SERVICE_NAME="$HC_SERVICE_NAME"
  AC="$HC_AGENT_COUNT"
  H="$HC_HOME"
  ISOLATION="$HC_ISOLATION"
  SESSION_GROUPS="$HC_SESSION_GROUPS"
}

# --- Owner ID lookup ---

get_owner_id_for_platform() {
  local platform="$1"
  local with_prefix="${2:-}"

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

# --- State helpers ---

hc_is_in_safe_mode() {
  [ -f "$HC_SAFE_MODE_FILE" ]
}

hc_get_recovery_attempts() {
  if [ -f "$HC_RECOVERY_COUNTER" ]; then
    cat "$HC_RECOVERY_COUNTER" 2>/dev/null || echo 0
  else
    echo 0
  fi
}
