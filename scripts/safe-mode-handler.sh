#!/bin/bash
# =============================================================================
# safe-mode-handler.sh — Handles safe mode entry, recovery, and notification
# =============================================================================
# Triggered by systemd .path unit when an unhealthy marker appears.
# Separate from health checking — this script only handles recovery.
#
# Inputs:
#   GROUP       — isolation group name (optional, for session isolation)
#   GROUP_PORT  — gateway port for this group (optional)
#   RUN_MODE    — "standalone" (default) or "path-triggered"
#
# Exit codes:
#   0 = recovery succeeded, service restarted
#   1 = recovery attempted, needs restart (systemd handles)
#   2 = critical failure, gave up
# =============================================================================

set -o pipefail

# Source shared libraries
for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-health-check.sh" ] && { source "$lib_path/lib-health-check.sh"; break; }
done
type hc_init_logging &>/dev/null || { echo "FATAL: lib-health-check.sh not found" >&2; exit 1; }

for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$lib_path/lib-notify.sh" ] && { source "$lib_path/lib-notify.sh"; break; }
done
type notify_send_message &>/dev/null || { echo "FATAL: lib-notify.sh not found" >&2; exit 1; }

[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh

# Initialize
hc_init_logging "${GROUP:-}"
hc_load_environment

RUN_MODE="${RUN_MODE:-standalone}"
MAX_RECOVERY_ATTEMPTS=2

log "============================================================"
log "========== SAFE MODE HANDLER STARTING =========="
log "============================================================"
log "RUN_ID=$HC_RUN_ID | MODE=$RUN_MODE | GROUP=${GROUP:-none}"

# --- Recovery attempt tracking ---

RECOVERY_ATTEMPTS=$(hc_get_recovery_attempts)
ALREADY_IN_SAFE_MODE=false
hc_is_in_safe_mode && ALREADY_IN_SAFE_MODE=true

log "ALREADY_IN_SAFE_MODE=$ALREADY_IN_SAFE_MODE, RECOVERY_ATTEMPTS=$RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS"

if [ "$ALREADY_IN_SAFE_MODE" = "true" ] && [ "$RECOVERY_ATTEMPTS" -ge "$MAX_RECOVERY_ATTEMPTS" ]; then
  log "CRITICAL: Already exhausted $MAX_RECOVERY_ATTEMPTS recovery attempts"
  touch /var/lib/init-status/gateway-failed${GROUP:+-$GROUP}
  set_stage 13

  # Try to notify even in critical state
  notify_find_token && notify_send_message "🔴 <b>[${HC_HABITAT_NAME}] CRITICAL FAILURE</b>

Gateway failed after $MAX_RECOVERY_ATTEMPTS recovery attempts.
Bot is OFFLINE.

Check logs: <code>journalctl -u $HC_SERVICE_NAME -n 50</code>"

  exit 2
fi

# --- Source recovery functions ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/safe-mode-recovery.sh" ] && source "$SCRIPT_DIR/safe-mode-recovery.sh"
[ -f "/usr/local/bin/safe-mode-recovery.sh" ] && source "/usr/local/bin/safe-mode-recovery.sh"

# --- Run recovery ---

log "Entering SAFE MODE with smart recovery"
SMART_RECOVERY_SUCCESS=false

# Run recovery in a function to allow proper local variable scoping
run_recovery_attempt() {
  export HOME_DIR="$H" USERNAME="$HC_USERNAME" RECOVERY_LOG="$HC_LOG"

  if type run_full_recovery_escalation &>/dev/null; then
    log "Attempting full recovery escalation..."
    local output exit_code
    output=$(run_full_recovery_escalation 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
      log "Recovery succeeded"
      log "Recovery output: $output"
      return 0
    else
      log "Recovery FAILED (exit $exit_code)"
      log "Recovery output: $output"
    fi
  fi

  if type run_smart_recovery &>/dev/null; then
    log "Attempting smart recovery..."
    local output exit_code
    output=$(run_smart_recovery 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
      log "Recovery succeeded"
      return 0
    else
      log "Recovery FAILED (exit $exit_code): $output"
    fi
  fi

  return 1
}

if run_recovery_attempt; then
  SMART_RECOVERY_SUCCESS=true
else
  log "!!! SMART RECOVERY FAILED — no fallback available !!!"
  log "Manual intervention required. Check /var/log/gateway-health-check.log"
fi

# Mark safe mode
touch "$SAFE_MODE_FILE"

# Write SAFE_MODE.md for agents
recovery_status="FAILED — manual intervention needed"
[ "$SMART_RECOVERY_SUCCESS" = "true" ] && recovery_status="smart recovery"

for si in $(seq 1 "$AC"); do
  cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Config failed health checks

Recovery: **${recovery_status}**

Check logs: cat /var/log/gateway-health-check${GROUP:+-$GROUP}.log
SAFEMD
  if type ensure_bot_file &>/dev/null; then
    ensure_bot_file "$H/clawd/agents/agent${si}/SAFE_MODE.md" 644
  else
    chown "$HC_USERNAME:$HC_USERNAME" "$H/clawd/agents/agent${si}/SAFE_MODE.md"
  fi
done

# Update stages
set_stage 12

# Increment recovery counter
echo "$((RECOVERY_ATTEMPTS + 1))" > "$HC_RECOVERY_COUNTER"

# --- Send notification ---

if [ "$ALREADY_IN_SAFE_MODE" != "true" ]; then
  log "========== SENDING SAFE MODE WARNING =========="
  notify_find_token && notify_send_message "⚠️ <b>[${HC_HABITAT_NAME}] Entering Safe Mode</b>

Health check failed. Recovering with backup configuration.

SafeModeBot will follow up shortly with diagnostics."
  log "========== SAFE MODE WARNING SENT =========="
fi

# --- Generate boot report ---

generate_boot_report() {
  local report_path="$H/clawd/agents/safe-mode/BOOT_REPORT.md"
  mkdir -p "$(dirname "$report_path")"

  # Capture the actual errors from OpenClaw service logs (journalctl)
  local service_name="openclaw${GROUP:+-$GROUP}"
  local service_errors
  service_errors=$(journalctl -u "$service_name" --no-pager -n 100 --since "5 min ago" 2>/dev/null \
    | grep -iE "401|403|error|failed|authentication|unauthorized|invalid.*key|No API key" \
    | grep -v "rename-bots" \
    | head -15 || echo "Could not read service logs")

  # Capture errors from OpenClaw log file (JSON format)
  local openclaw_log_errors=""
  local log_file
  log_file=$(ls -t /tmp/openclaw/openclaw-*.log 2>/dev/null | head -1)
  if [ -n "$log_file" ]; then
    openclaw_log_errors=$(grep -o '"0":"[^"]*401[^"]*\|"0":"[^"]*error[^"]*\|"0":"[^"]*authentication[^"]*' "$log_file" 2>/dev/null \
      | sed 's/"0":"//; s/"$//' \
      | head -10 || true)
  fi

  cat > "$report_path" <<REPORT
# Boot Report - Safe Mode Active

## What Happened
Safe mode was triggered because the health check detected the primary bot could not respond.
This usually means an API credential (Anthropic, OpenAI, or Google) is invalid or expired.

## Errors Detected
\`\`\`
${service_errors:-No service errors captured}
\`\`\`

## Recovery Actions
$(grep -E "Recovery|recovery|SAFE MODE|token|API|provider|model" "$HC_LOG" 2>/dev/null | tail -20)

## Diagnostics
$(cat /var/log/safe-mode-diagnostics.txt 2>/dev/null || echo "No diagnostics available")

## Next Steps
1. Check the "Errors Detected" section above for the root cause (usually a 401/invalid API key)
2. Fix the broken credential in your habitat config or iOS Shortcut
3. Upload new config via API or recreate the droplet
REPORT

  if type ensure_bot_file &>/dev/null; then
    ensure_bot_file "$report_path" 644
  else
    chown "$HC_USERNAME:$HC_USERNAME" "$report_path" 2>/dev/null
  fi
  log "Generated BOOT_REPORT.md"
}

generate_boot_report

# --- Restart service ---

restart_and_verify() {
  local target_service="$HC_SERVICE_NAME"

  log "Restarting $target_service with safe mode config..."

  if [ -n "${GROUP:-}" ] && [ "$ISOLATION" = "container" ]; then
    docker restart "openclaw-${GROUP}" 2>/dev/null || true
  else
    systemctl restart "${target_service}.service" 2>/dev/null || systemctl restart "$target_service" 2>/dev/null || true
  fi
  sleep 5

  for attempt in 1 2 3; do
    local is_active=false

    if [ -n "${GROUP:-}" ] && [ "$ISOLATION" = "container" ]; then
      docker inspect --format='{{.State.Running}}' "openclaw-${GROUP}" 2>/dev/null | grep -q 'true' && is_active=true
    else
      systemctl is-active --quiet "${target_service}.service" 2>/dev/null && is_active=true
      systemctl is-active --quiet "$target_service" 2>/dev/null && is_active=true
    fi

    if [ "$is_active" = "true" ]; then
      log "$target_service started (attempt $attempt)"
      /usr/local/bin/rename-bots.sh >> "$HC_LOG" 2>&1 || true
      return 0
    fi

    log "$target_service not active, retry $attempt/3..."
    systemctl restart "${target_service}.service" 2>/dev/null || systemctl restart "$target_service" 2>/dev/null || true
    sleep 5
  done

  log "CRITICAL: $target_service failed to start"
  touch "/var/lib/init-status/gateway-failed${GROUP:+-$GROUP}"
  set_stage 13
  return 1
}

# Mark recovery time (prevents cascade)
date +%s > /var/lib/init-status/recently-recovered${GROUP:+-$GROUP}

if restart_and_verify; then
  # Trigger SafeModeBot intro (shared implementation in lib-notify.sh)
  notify_send_safe_mode_intro

  # Mark boot as complete (safe mode IS a completed boot, just degraded)
  touch /var/lib/init-status/setup-complete
  rm -f /var/lib/init-status/needs-post-boot-check

  log "========== SAFE MODE HANDLER COMPLETE =========="
  # Clean up the unhealthy marker since we've handled it
  rm -f "$HC_UNHEALTHY_MARKER"
  exit 0
else
  log "========== SAFE MODE HANDLER FAILED — SERVICE WON'T START =========="
  exit 2
fi
