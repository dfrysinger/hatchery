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

  # Remove unhealthy marker to break .path re-trigger loop
  # (gateway-failed marker records the terminal state)
  rm -f "$HC_UNHEALTHY_MARKER"

  # Only notify once — check for lockout marker
  local lockout_file="/var/lib/init-status/critical-notified${GROUP:+-$GROUP}"
  if [ ! -f "$lockout_file" ]; then
    notify_find_token && notify_send_message "🔴 <b>[${HC_HABITAT_NAME}] CRITICAL FAILURE</b>

Gateway failed after $MAX_RECOVERY_ATTEMPTS recovery attempts.
Bot is OFFLINE.

Check logs: <code>journalctl -u $HC_SERVICE_NAME -n 50</code>"
    touch "$lockout_file"
  else
    log "CRITICAL FAILURE notification already sent — suppressing duplicate"
  fi

  exit 2
fi

# --- Set up diagnostics log ---

export AUTH_DIAG_LOG="/var/log/auth-diagnostics${GROUP:+-$GROUP}.log"
: > "$AUTH_DIAG_LOG" 2>/dev/null || true
chmod 600 "$AUTH_DIAG_LOG" 2>/dev/null || true

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

# Write SAFE_MODE.md ONLY for agents in the affected group
# With session isolation, other groups should not be affected
recovery_status="FAILED — manual intervention needed"
[ "$SMART_RECOVERY_SUCCESS" = "true" ] && recovery_status="smart recovery"

for si in $(seq 1 "$AC"); do
  # If we're in session isolation and GROUP is set, only write to agents in THIS group
  if [ -n "${GROUP:-}" ] && [ -n "${ISOLATION_DEFAULT:-}" ] && [ "$ISOLATION_DEFAULT" != "none" ]; then
    agent_group_var="AGENT${si}_ISOLATION_GROUP"
    agent_group="${!agent_group_var:-}"
    if [ -n "$agent_group" ] && [ "$agent_group" != "$GROUP" ]; then
      continue  # Skip agents in other groups
    fi
  fi

  cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Config failed health checks

Recovery: **${recovery_status}**
Group: **${GROUP:-global}**

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

# Format diagnostics from AUTH_DIAG_LOG into human-readable sections
format_diagnostics() {
  local diag_file="${AUTH_DIAG_LOG:-/var/log/auth-diagnostics.log}"

  if [ ! -f "$diag_file" ] || [ ! -s "$diag_file" ]; then
    echo "No diagnostics available"
    return
  fi

  echo "🔍 Recovery diagnostics:"

  local category label
  for category in telegram discord api network doctor; do
    case "$category" in
      telegram) label="Telegram" ;;
      discord)  label="Discord" ;;
      api)      label="API Providers" ;;
      network)  label="Network" ;;
      doctor)   label="Doctor" ;;
    esac

    local entries
    entries=$(grep "^${category}:" "$diag_file" 2>/dev/null || true)

    if [ -n "$entries" ]; then
      echo "  ${label}:"
      while IFS=: read -r _cat name icon reason; do
        if [ -n "$reason" ] && [ "$reason" != "valid" ] && [ "$reason" != "ok" ]; then
          echo "    ${icon} ${name} (${reason})"
        else
          echo "    ${icon} ${name}"
        fi
      done <<< "$entries"
    fi
  done
}

generate_boot_report() {
  # Capture the actual errors from OpenClaw service logs via hc_service_logs
  local service_errors
  service_errors=$(hc_service_logs "${GROUP:-}" 100 2>/dev/null \
    | grep -iE "401|403|error|failed|authentication|unauthorized|invalid.*key|No API key" \
    | grep -v "rename-bots" \
    | head -15 || echo "Could not read service logs")

  local report
  report=$(cat <<REPORT
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
$(format_diagnostics)

## Next Steps
1. Check the "Errors Detected" section above for the root cause (usually a 401/invalid API key)
2. Fix the broken credential in your habitat config or iOS Shortcut
3. Upload new config via API or recreate the droplet
REPORT
)

  # Distribute to all agent workspaces + safe-mode + shared
  distribute_boot_report "$report"
  log "Generated and distributed BOOT_REPORT.md"
}

# Distribute boot report to all agent workspaces, safe-mode, and shared/
distribute_boot_report() {
  local report="$1"
  local count="${AC:-${AGENT_COUNT:-1}}"

  _write_report() {
    local path="$1"
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    echo "$report" > "$path"
    if type ensure_bot_file &>/dev/null; then
      ensure_bot_file "$path" 644
    else
      chown "$HC_USERNAME:$HC_USERNAME" "$path" 2>/dev/null || true
    fi
  }

  # Each agent workspace
  for i in $(seq 1 "$count"); do
    _write_report "$H/clawd/agents/agent${i}/BOOT_REPORT.md"
  done

  # Safe-mode workspace
  _write_report "$H/clawd/agents/safe-mode/BOOT_REPORT.md"

  # Shared folder
  _write_report "$H/clawd/shared/BOOT_REPORT.md"
}

generate_boot_report

# --- Restart service ---

restart_and_verify() {
  local svc_name
  svc_name=$(_hc_service_name "${GROUP:-}")

  log "Restarting $svc_name with safe mode config..."
  hc_restart_service "${GROUP:-}" || true
  sleep 5

  for attempt in 1 2 3; do
    if hc_is_service_active "${GROUP:-}"; then
      log "$svc_name started (attempt $attempt)"
      /usr/local/bin/rename-bots.sh >> "$HC_LOG" 2>&1 || true
      return 0
    fi

    log "$svc_name not active, retry $attempt/3..."
    hc_restart_service "${GROUP:-}" || true
    sleep 5
  done

  log "CRITICAL: $svc_name failed to start after 3 attempts"
  touch "/var/lib/init-status/gateway-failed${GROUP:+-$GROUP}"
  # Remove unhealthy marker to prevent .path unit re-trigger loop
  rm -f "$HC_UNHEALTHY_MARKER"
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
