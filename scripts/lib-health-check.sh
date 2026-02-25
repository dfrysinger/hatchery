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

# --- Isolation-aware service management ---
# All health check consumers use these functions — never direct systemctl/docker calls.
# Works for all 3 isolation modes: none, session, container.
#
# In "none" mode (no isolation), group is ignored and the single "openclaw" service is used.
# In "session" mode, each group has its own systemd service "openclaw-{group}".
# In "container" mode, each group runs via docker compose.
#
# Environment deps:
#   ISOLATION  — from group.env (EnvironmentFile=) or hc_load_environment()
#   GROUP      — group name (empty in none mode)
#   GROUP_PORT — gateway port (default 18789)

# Resolve service name from group + isolation mode
_hc_service_name() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  if [ "$iso" = "none" ] || [ -z "$group" ]; then
    echo "openclaw"
  else
    echo "openclaw-${group}"
  fi
}

hc_restart_service() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  local user="${HC_USERNAME:-${USERNAME:-bot}}"
  case "$iso" in
    container)
      docker compose \
        -f "/home/${user}/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" restart 2>&1 ;;
    none)
      systemctl restart openclaw 2>&1 ;;
    *)
      systemctl restart "openclaw-${group}" 2>&1 ;;
  esac
}

hc_is_service_active() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  case "$iso" in
    container)
      # Check if container process is running (not health status).
      # This is the equivalent of systemd is-active — "is the process alive?"
      # For actual gateway readiness, use hc_curl_gateway() or hc_restart_and_wait().
      local running
      running=$(docker inspect --format='{{.State.Running}}' "openclaw-${group}" 2>/dev/null)
      [ "$running" = "true" ] ;;
    none)
      systemctl is-active --quiet openclaw ;;
    *)
      systemctl is-active --quiet "openclaw-${group}" ;;
  esac
}

# Poll hc_curl_gateway() until the gateway responds or timeout.
# No restart — just waits. Use after hc_restart_service() or on its own.
#
# Args:
#   $1 — group name (optional, for isolation modes)
#   $2 — max wait in seconds (optional, default auto-scaled by isolation mode)
#
# Returns: 0 if gateway responds, 1 if timed out
hc_wait_for_http() {
  local group="${1:-${GROUP:-}}"
  local max_wait="${2:-}"
  local iso="${ISOLATION:-none}"

  # Auto-scale timeout if not provided:
  #   none/session: systemd → Node boot = fast (30s)
  #   container: Docker restart → container up → Node boot = slow (90s)
  if [ -z "$max_wait" ]; then
    case "$iso" in
      container) max_wait=90 ;;
      *)         max_wait=30 ;;
    esac
  fi

  local start elapsed
  start=$(date +%s)
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$max_wait" ]; then
      log "Timed out after ${elapsed}s waiting for HTTP"
      return 1
    fi

    if hc_curl_gateway "$group" "/" >/dev/null 2>&1; then
      log "HTTP responding after ${elapsed}s"
      return 0
    fi

    sleep 5
  done
}

# Restart service and wait for HTTP readiness.
# Single canonical implementation — use this instead of hand-rolled poll loops.
# Restarts ONCE, then polls via hc_wait_for_http().
# Does NOT re-restart on each poll failure (the old bug).
#
# Args:
#   $1 — group name (optional, for isolation modes)
#   $2 — max wait in seconds (optional, default auto-scaled by isolation mode)
#
# Returns: 0 if gateway responds, 1 if timed out
hc_restart_and_wait() {
  local group="${1:-${GROUP:-}}"
  local max_wait="${2:-}"

  log "Restarting $(_hc_service_name "$group")..."
  hc_restart_service "$group" || true

  hc_wait_for_http "$group" "$max_wait"
}

hc_service_logs() {
  local group="${1:-${GROUP:-}}"
  local lines="${2:-50}"
  local iso="${ISOLATION:-none}"
  local user="${HC_USERNAME:-${USERNAME:-bot}}"
  case "$iso" in
    container)
      docker compose \
        -f "/home/${user}/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" logs --tail="$lines" 2>/dev/null ;;
    none)
      journalctl -u openclaw --no-pager -n "$lines" 2>/dev/null ;;
    *)
      journalctl -u "openclaw-${group}" --no-pager -n "$lines" 2>/dev/null ;;
  esac
}

hc_stop_service() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  local user="${HC_USERNAME:-${USERNAME:-bot}}"
  case "$iso" in
    container)
      docker compose \
        -f "/home/${user}/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" down 2>&1 ;;
    none)
      systemctl stop openclaw 2>&1 ;;
    *)
      systemctl stop "openclaw-${group}" 2>&1 ;;
  esac
}

# Start a stopped service (counterpart to hc_stop_service).
# For containers: docker compose up -d; for systemd: systemctl start.
hc_start_service() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  local user="${HC_USERNAME:-${USERNAME:-bot}}"
  case "$iso" in
    container)
      docker compose \
        -f "/home/${user}/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" up -d 2>&1 ;;
    none)
      systemctl start openclaw 2>&1 ;;
    *)
      systemctl start "openclaw-${group}" 2>&1 ;;
  esac
}

# Reach the gateway — handles all isolation modes including isolated network containers
hc_curl_gateway() {
  local group="${1:-${GROUP:-}}"
  local path="${2:-/}"
  local port="${GROUP_PORT:-18789}"
  local iso="${ISOLATION:-none}"
  local net="${NETWORK_MODE:-host}"

  if [ "$iso" = "container" ] && [ "$net" != "host" ]; then
    # Isolated network: reach via docker exec
    docker exec "openclaw-${group}" \
      curl -sf "http://127.0.0.1:${port}${path}" 2>/dev/null
  else
    # Host network, session mode, or none mode: direct curl
    curl -sf "http://127.0.0.1:${port}${path}" 2>/dev/null
  fi
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
