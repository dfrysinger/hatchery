#!/bin/bash
# =============================================================================
# gateway-health-check.sh — Lightweight HTTP health check
# =============================================================================
# Purpose:  Verifies the gateway's HTTP endpoint is responding after startup.
#           This is the ONLY thing it does. No E2E testing, no recovery,
#           no notifications, no config swapping.
#
# Called by:  ExecStartPost in openclaw*.service
#
# On success: exits 0, service becomes "active", E2E service runs next
# On failure: writes unhealthy marker, exits 1, systemd restarts (on-failure)
#
# Env vars (all optional, for testing):
#   HEALTH_CHECK_SETTLE_SECS  — initial wait (default: 10)
#   HEALTH_CHECK_HARD_MAX_SECS — give up after (default: 300)
#   HEALTH_CHECK_WARN_SECS    — "still waiting" notification (default: 120)
#   GROUP / GROUP_PORT         — per-group session isolation
# =============================================================================

# Source shared libraries
for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
type hc_init_logging &>/dev/null || { echo "FATAL: lib-health-check.sh not found" >&2; exit 1; }

for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-notify.sh" ] && { source "$lib_path/lib-notify.sh"; break; }
done
type notify_send_message &>/dev/null || { echo "FATAL: lib-notify.sh not found" >&2; exit 1; }

hc_init_logging "${GROUP:-}"
hc_load_environment || exit 0

PORT="${GROUP_PORT:-18789}"
SETTLE="${HEALTH_CHECK_SETTLE_SECS:-10}"
HARD_MAX="${HEALTH_CHECK_HARD_MAX_SECS:-300}"
WARN_AT="${HEALTH_CHECK_WARN_SECS:-120}"

log "========== HTTP HEALTH CHECK =========="
log "PORT=$PORT | SETTLE=${SETTLE}s | HARD_MAX=${HARD_MAX}s | GROUP=${GROUP:-none}"

# --- Skip if recently recovered ---
RECENTLY_RECOVERED="/var/lib/init-status/recently-recovered${GROUP:+-$GROUP}"
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

# --- HTTP poll with process-alive detection ---
start=$(date +%s)
warned=false
process_seen=false

while true; do
  elapsed=$(( $(date +%s) - start ))

  # Hard max
  if [ "$elapsed" -ge "$HARD_MAX" ]; then
    log "TIMEOUT after ${elapsed}s"
    break
  fi

  # Process alive?
  if pgrep -f "openclaw.gateway" >/dev/null 2>&1; then
    process_seen=true
  elif [ "$process_seen" = "true" ]; then
    log "Gateway process DIED"; break
  elif [ "$elapsed" -ge 60 ]; then
    log "Gateway process never appeared after ${elapsed}s"; break
  fi

  # "Still waiting" notification
  if [ "$warned" = "false" ] && [ "$elapsed" -ge "$WARN_AT" ]; then
    warned=true
    log "⏳ Still waiting (${elapsed}s)..."
    notify_find_token 2>/dev/null && \
      notify_send_message "⏳ <b>[${HC_HABITAT_NAME}]</b> Gateway slow to start (${elapsed}s). Still trying..." 2>/dev/null || true
  fi

  # HTTP check
  if curl -sf "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    log "✓ HTTP responding at ${elapsed}s"
    rm -f "$HC_UNHEALTHY_MARKER"
    log "========== HTTP CHECK PASSED =========="
    exit 0
  fi

  sleep 5
done

# --- Failed ---
log "✗ HTTP not responding — writing unhealthy marker"
touch "$HC_UNHEALTHY_MARKER"
log "========== HTTP CHECK FAILED =========="
exit 1
