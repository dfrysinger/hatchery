#!/bin/bash
# =============================================================================
# gateway-health-check.sh — Universal HTTP health check (all isolation modes)
# =============================================================================
# Purpose:  Verifies the gateway's HTTP endpoint is responding after startup.
#           Works identically across all isolation modes (none/session/container).
#           The only differences per mode: service name, port, and how to restart.
#
# Called by:  ExecStartPost in openclaw*.service (session/none mode)
#             Docker entrypoint (container mode)
#
# On success: exits 0, service becomes "active", E2E service runs next
# On failure: writes unhealthy marker, exits 1, systemd restarts (on-failure)
#
# Env vars (all optional, for testing):
#   HEALTH_CHECK_SETTLE_SECS   — initial wait (default: 10)
#   HEALTH_CHECK_HARD_MAX_SECS — give up after (default: 300)
#   HEALTH_CHECK_WARN_SECS     — "still waiting" notification (default: 120)
#   GROUP / GROUP_PORT          — per-group session/container isolation
#   OPENCLAW_CONFIG_PATH        — override for config file path
#   ISOLATION                   — isolation mode (none/session/container)
# =============================================================================

set -euo pipefail

# Source shared libraries
for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  # shellcheck source=/dev/null
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
type hc_init_logging &>/dev/null || { echo "FATAL: lib-health-check.sh not found" >&2; exit 1; }

for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  # shellcheck source=/dev/null
  [ -f "$lib_path/lib-notify.sh" ] && { source "$lib_path/lib-notify.sh"; break; }
done
type notify_send_message &>/dev/null || { echo "FATAL: lib-notify.sh not found" >&2; exit 1; }

# =============================================================================
# Universal: SERVICE_NAME derivation
# Every mode derives a single service name for the group being checked.
# =============================================================================
if [ -n "${GROUP:-}" ]; then
  SERVICE_NAME="openclaw-${GROUP}"
else
  SERVICE_NAME="openclaw"
fi

# =============================================================================
# Universal: Per-group log
# Each group writes to its own log file to avoid interference.
# =============================================================================
if [ -n "${GROUP:-}" ]; then
  HC_LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check-${GROUP}.log}"
else
  HC_LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check.log}"
fi
touch "$HC_LOG" && chmod 644 "$HC_LOG" 2>/dev/null || true

# Initialize logging via shared lib (may override HC_LOG if HEALTH_CHECK_LOG set)
hc_init_logging "${GROUP:-}"
hc_load_environment || exit 0

# =============================================================================
# Universal: Config path per isolation mode
# Standard mode: ~/.openclaw/openclaw.json
# Session mode:  respect OPENCLAW_CONFIG_PATH or per-group session config
# =============================================================================
HC_USERNAME="${USERNAME:-${HC_USERNAME:-bot}}"
HC_HOME="/home/$HC_USERNAME"
if [ -n "${GROUP:-}" ]; then
  CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HC_HOME/.openclaw/configs/${GROUP}/openclaw.session.json}"
else
  CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HC_HOME/.openclaw/openclaw.json}"
fi

# =============================================================================
# Universal: Per-group state files
# Safe mode and recovery state are per-group to avoid cross-group interference.
# =============================================================================
if [ -n "${GROUP:-}" ]; then
  RECOVERY_COUNTER="/var/lib/init-status/recovery-attempts-${GROUP}"
  SAFE_MODE_FILE="/var/lib/init-status/safe-mode-${GROUP}"
  UNHEALTHY_MARKER="/var/lib/init-status/unhealthy-${GROUP}"
  RECENTLY_RECOVERED="/var/lib/init-status/recently-recovered-${GROUP}"
  NOTIFICATION_SENT="/var/lib/init-status/notification-sent-${GROUP}"
else
  RECOVERY_COUNTER="/var/lib/init-status/recovery-attempts"
  SAFE_MODE_FILE="/var/lib/init-status/safe-mode"
  UNHEALTHY_MARKER="/var/lib/init-status/unhealthy"
  RECENTLY_RECOVERED="/var/lib/init-status/recently-recovered"
  NOTIFICATION_SENT="/var/lib/init-status/notification-sent"
fi

PORT="${GROUP_PORT:-18789}"
SETTLE="${HEALTH_CHECK_SETTLE_SECS:-10}"
HARD_MAX="${HEALTH_CHECK_HARD_MAX_SECS:-300}"
WARN_AT="${HEALTH_CHECK_WARN_SECS:-120}"
ISOLATION="${ISOLATION:-${HC_ISOLATION:-none}}"

log "========== HTTP HEALTH CHECK =========="
log "SERVICE=${SERVICE_NAME} | PORT=$PORT | SETTLE=${SETTLE}s | HARD_MAX=${HARD_MAX}s | GROUP=${GROUP:-none} | ISOLATION=${ISOLATION}"
log "STATE: recovery=${RECOVERY_COUNTER} | safemode=${SAFE_MODE_FILE}"

# =============================================================================
# check_service_health — universal health check function
# Accepts variable service name and port — no mode branching needed here.
# Actual HTTP check delegates to hc_curl_gateway for network isolation support.
# =============================================================================
check_service_health() {
  local svc="${1:-$SERVICE_NAME}" port="${2:-$PORT}"
  log "Checking $svc on port $port..."
  hc_curl_gateway "${GROUP:-}" "/" >/dev/null 2>&1
}

# =============================================================================
# restart_gateway — handles all isolation types
# session:   systemctl restart openclaw-${GROUP}
# container: docker restart openclaw-${GROUP}  (or docker compose)
# standard:  systemctl restart openclaw
# =============================================================================
restart_gateway() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  local user="${HC_USERNAME:-bot}"
  log "Restarting gateway for group='${group}' isolation='${iso}'..."
  case "$iso" in
    container)
      # container restart via docker compose
      docker compose \
        -f "/home/${user}/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" restart 2>&1 || true
      ;;
    session)
      systemctl restart "openclaw-${group}" 2>&1 || true
      ;;
    *)
      # standard (none) mode — single openclaw service
      systemctl restart openclaw 2>&1 || true
      ;;
  esac
}

# =============================================================================
# enter_safe_mode — handles all isolation types including container
# =============================================================================
enter_safe_mode() {
  local group="${1:-${GROUP:-}}"
  local iso="${ISOLATION:-none}"
  log "Entering safe mode for group='${group}' isolation='${iso}'..."
  touch "$SAFE_MODE_FILE" 2>/dev/null || true
  case "$iso" in
    container)
      # container mode: stop the docker container
      local user="${HC_USERNAME:-bot}"
      docker compose \
        -f "/home/${user}/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" down 2>&1 || true
      systemctl stop "openclaw-container-${group}" 2>/dev/null || true
      ;;
    session)
      systemctl stop "openclaw-${group}" 2>/dev/null || true
      ;;
    *)
      systemctl stop openclaw 2>/dev/null || true
      ;;
  esac
  log "Safe mode activated — config path: ${CONFIG_PATH}"
}

# =============================================================================
# Main Health Check
# =============================================================================

# --- Skip if recently recovered ---
if [ -f "$RECENTLY_RECOVERED" ]; then
  age=$(( $(date +%s) - $(cat "$RECENTLY_RECOVERED" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 120 ]; then
    log "Skipping — recovered ${age}s ago"
    exit 0
  fi
fi

# --- Settle ---
log "Waiting ${SETTLE}s for gateway to settle..."
sleep "$SETTLE"

# --- HTTP poll: check_service_health($SERVICE_NAME, $GROUP_PORT) ---
start=$(date +%s)
warned=false

while true; do
  elapsed=$(( $(date +%s) - start ))

  # Hard max — enter safe mode if too many failures
  if [ "$elapsed" -ge "$HARD_MAX" ]; then
    log "TIMEOUT after ${elapsed}s"
    break
  fi

  # "Still waiting" notification (per-group marker to avoid floods)
  if [ "$warned" = "false" ] && [ "$elapsed" -ge "$WARN_AT" ]; then
    warned=true
    log "⏳ Still waiting (${elapsed}s)..."
    if ! [ -f "$NOTIFICATION_SENT" ]; then
      touch "$NOTIFICATION_SENT" 2>/dev/null || true
      notify_find_token 2>/dev/null && \
        notify_send_message "⏳ <b>[${HC_HABITAT_NAME:-Droplet}]</b> Gateway slow to start (${elapsed}s). Still trying..." 2>/dev/null || true
    fi
  fi

  # Universal HTTP check — works for session/container/none modes
  if check_service_health "$SERVICE_NAME" "$GROUP_PORT"; then
    log "✓ HTTP responding at ${elapsed}s"
    rm -f "$UNHEALTHY_MARKER"
    # Re-arm the safeguard .path unit if it's dead (belt-and-suspenders).
    _sg="openclaw-safeguard${GROUP:+-$GROUP}.path"
    systemctl is-active --quiet "$_sg" 2>/dev/null || \
      systemctl restart "$_sg" 2>/dev/null || true
    log "========== HTTP CHECK PASSED =========="
    exit 0
  fi

  sleep 5
done

# --- Failed ---
log "✗ HTTP not responding — writing unhealthy marker"
touch "$UNHEALTHY_MARKER"
log "========== HTTP CHECK FAILED =========="
exit 1

