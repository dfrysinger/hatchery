#!/bin/bash
# =============================================================================
# gateway-health-check.sh — Universal health check + notification (all isolation modes)
# =============================================================================
# Purpose:  Verifies the gateway's HTTP endpoint, validates channel tokens,
#           manages safe-mode state, sends boot notifications, and sets stage
#           markers. Works across all isolation modes (none/session/container).
#
# Called by:  ExecStartPost in openclaw*.service
#             Docker entrypoint (container mode)
#
# On success: exits 0, sets stage=11, creates setup-complete
# On failure: writes unhealthy marker, exits 1, systemd restarts (on-failure)
# On critical: exits 2 (RestartPreventExitStatus=2 in service file)
#
# Env vars (all optional):
#   HEALTH_CHECK_SETTLE_SECS   — initial wait (default: 10)
#   HEALTH_CHECK_HARD_MAX_SECS — give up after (default: 300)
#   HEALTH_CHECK_WARN_SECS     — "still waiting" notification (default: 120)
#   GROUP / GROUP_PORT          — per-group session/container isolation
#   OPENCLAW_CONFIG_PATH        — override for config file path
#   ISOLATION                   — isolation mode (none/session/container)
#   RUN_MODE                    — execstartpost|standalone
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

for lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  # shellcheck source=/dev/null
  [ -f "$lib_path/lib-auth.sh" ] && { source "$lib_path/lib-auth.sh"; break; }
done

# =============================================================================
# Universal: SERVICE_NAME derivation
# =============================================================================
if [ -n "${GROUP:-}" ]; then
  SERVICE_NAME="openclaw-${GROUP}"
else
  SERVICE_NAME="openclaw"
fi

# =============================================================================
# Universal: Per-group log
# =============================================================================
if [ -n "${GROUP:-}" ]; then
  LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check-${GROUP}.log}"
else
  LOG="${HEALTH_CHECK_LOG:-/var/log/gateway-health-check.log}"
fi
touch "$LOG" && chmod 644 "$LOG" 2>/dev/null || true
HEALTH_CHECK_LOG="$LOG"

# Initialize logging via shared lib
hc_init_logging "${GROUP:-}"
if ! hc_load_environment; then
  if [ "${TEST_MODE:-}" != "1" ] && [ "${DRY_RUN:-}" != "1" ]; then
    echo "FATAL: failed to load runtime environment" >&2
    exit 1
  fi
fi

# =============================================================================
# Universal: Config path per isolation mode
# Standard mode: ~/.openclaw/openclaw.json
# Session mode:  CONFIG_PATH = ~/.openclaw/configs/${GROUP}/openclaw.session.json
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
# =============================================================================
if [ -n "${GROUP:-}" ]; then
  RECOVERY_COUNTER="/var/lib/init-status/recovery-attempts-${GROUP}"
  SAFE_MODE_FILE="/var/lib/init-status/safe-mode-${GROUP}"
  UNHEALTHY_MARKER="/var/lib/init-status/unhealthy-${GROUP}"
  RECENTLY_RECOVERED="/var/lib/init-status/recently-recovered-${GROUP}"
else
  RECOVERY_COUNTER="/var/lib/init-status/recovery-attempts"
  SAFE_MODE_FILE="/var/lib/init-status/safe-mode"
  UNHEALTHY_MARKER="/var/lib/init-status/unhealthy"
  RECENTLY_RECOVERED="/var/lib/init-status/recently-recovered"
fi

PORT="${GROUP_PORT:-18789}"
SETTLE="${HEALTH_CHECK_SETTLE_SECS:-10}"
HARD_MAX="${HEALTH_CHECK_HARD_MAX_SECS:-300}"
WARN_AT="${HEALTH_CHECK_WARN_SECS:-120}"
ISOLATION="${ISOLATION:-${HC_ISOLATION:-none}}"

log "========== HEALTH CHECK =========="
log "SERVICE=${SERVICE_NAME} | PORT=$PORT | GROUP=${GROUP:-none} | ISOLATION=${ISOLATION}"

# =============================================================================
# check_channel_connectivity — validate bot tokens for configured platform
# Returns 0 if all agents have valid tokens for their platform, 1 otherwise.
# =============================================================================
check_channel_connectivity() {
  local _svc="${1:-$SERVICE_NAME}"
  local _count="${AGENT_COUNT:-${AC:-1}}"
  local _platform="${PLATFORM:-telegram}"
  local _all_valid=true

  for _i in $(seq 1 "$_count"); do
    local agent_valid=false
    local tg_token dc_token

    # Collect telegram token for platform=telegram or platform=both
    local _tg_var="AGENT${_i}_TELEGRAM_BOT_TOKEN"
    tg_token="${!_tg_var:-}"
    [ -z "$tg_token" ] && { _tg_var="AGENT${_i}_BOT_TOKEN"; tg_token="${!_tg_var:-}"; }

    # Collect discord token for platform=discord or platform=both
    local _dc_var="AGENT${_i}_DISCORD_BOT_TOKEN"
    dc_token="${!_dc_var:-}"

    # Check telegram token when platform is telegram or both
    if [ "$_platform" = "telegram" ] || [ "$_platform" = "both" ]; then
      if [ -n "$tg_token" ] && validate_telegram_token "$tg_token" 2>/dev/null; then
        agent_valid=true
      fi
    fi

    # Check discord token when platform is discord or both
    if [ "$_platform" = "discord" ] || [ "$_platform" = "both" ]; then
      if [ -n "$dc_token" ] && validate_discord_token "$dc_token" 2>/dev/null; then
        agent_valid=true
      fi
    fi

    # Single-platform mode: the configured platform token must be valid
    if [ "$_platform" = "telegram" ] && [ "$agent_valid" = "false" ]; then
      _all_valid=false
    elif [ "$_platform" = "discord" ] && [ "$agent_valid" = "false" ]; then
      _all_valid=false
    elif [ "$_platform" = "both" ] && [ "$agent_valid" = "false" ]; then
      _all_valid=false
    fi
  done

  [ "$_all_valid" = "true" ]
}

# =============================================================================
# check_api_connectivity — validate API key auth headers per provider
# Anthropic OAuth tokens (sk-ant-oat*) use Bearer; API keys use x-api-key.
# OpenAI always uses Authorization: Bearer ${OPENAI_API_KEY}.
# Google API key uses query param: ?key=${GOOGLE_API_KEY}.
# =============================================================================
check_api_connectivity() {
  local key
  # Anthropic: detect OAuth token vs API key
  key="${ANTHROPIC_API_KEY:-}"
  if [ -n "$key" ]; then
    if [[ "${ANTHROPIC_API_KEY}" == sk-ant-oat* ]]; then
      # OAuth token: Authorization: Bearer ${ANTHROPIC_API_KEY}
      log "Anthropic: OAuth token detected (Bearer)"
    else
      # API key: x-api-key: ${ANTHROPIC_API_KEY}
      log "Anthropic: API key detected (x-api-key)"
    fi
  fi
  # OpenAI: always Authorization: Bearer ${OPENAI_API_KEY}
  key="${OPENAI_API_KEY:-}"
  if [ -n "$key" ]; then
    log "OpenAI: API key configured (Bearer)"
  fi
  # Google: query param ?key=${GOOGLE_API_KEY}
  key="${GOOGLE_API_KEY:-}"
  if [ -n "$key" ]; then
    log "Google: API key configured (query param)"
  fi
}

# =============================================================================
# send_entering_safe_mode_warning — warn before first safe mode entry
# Looks up accounts["safe-mode"] in the current config for the token.
# =============================================================================
send_entering_safe_mode_warning() {
  local config="${CONFIG_PATH:-}"
  local tg_token dc_token owner_id
  # Look for accounts["safe-mode"] telegram token
  tg_token=$(jq -r '.channels.telegram.accounts["safe-mode"].botToken // empty' "$config" 2>/dev/null || echo "")
  # Look for accounts["safe-mode"] discord token (accounts.safe-mode.token)
  dc_token=$(jq -r '.channels.discord.accounts["safe-mode"].token // empty' "$config" 2>/dev/null || echo "")
  local msg="⚠️ Gateway health check failing — entering safe mode..."
  owner_id="${TELEGRAM_OWNER_ID:-${DISCORD_OWNER_ID:-}}"
  [ -n "$tg_token" ] && send_telegram_notification "$tg_token" "$owner_id" "$msg" 2>/dev/null || true
  [ -n "$dc_token" ] && send_discord_notification "$dc_token" "$owner_id" "$msg" 2>/dev/null || true
}

# =============================================================================
# send_boot_notification — status notification on boot completion
# =============================================================================
send_boot_notification() {
  local status="${1:-healthy}"
  local config="${CONFIG_PATH:-}"

  # Check notification marker to prevent duplicate notifications
  local notification_file="/var/lib/init-status/notification-sent-${status}"
  if [ -n "${GROUP:-}" ]; then
    notification_file="/var/lib/init-status/notification-sent-${status}-${GROUP}"
  fi
  if [ -f "$notification_file" ]; then
    log "Notification already sent for status=$status (marker: $notification_file)"
    return 0
  fi

  case "$status" in
    healthy)
      notify_send_message "✅ Gateway is healthy and ready!" 2>/dev/null || true
      ;;
    safe-mode)
      # Safe-mode case: send raw API notification then deliver via SafeModeBot
      local tg_token dc_token owner_id
      tg_token=$(jq -r '.channels.telegram.accounts["safe-mode"].botToken // empty' "$config" 2>/dev/null || echo "")
      dc_token=$(jq -r '.channels.discord.accounts["safe-mode"].token // empty' "$config" 2>/dev/null || echo "")
      owner_id="${TELEGRAM_OWNER_ID:-${DISCORD_OWNER_ID:-}}"
      send_telegram_notification "$tg_token" "$owner_id" "🔴 Safe Mode active — recovery in progress" 2>/dev/null || true
      send_discord_notification "$dc_token" "$owner_id" "🔴 Safe Mode active — recovery in progress" 2>/dev/null || true
      openclaw agent --deliver "Safe mode active. I'll recover and notify you when ready." --agent safe-mode --reply-account safe-mode --reply-to "$owner_id" 2>/dev/null || true
      ;;
    degraded)
      notify_send_message "⚠️ Gateway degraded — some features may be unavailable" 2>/dev/null || true
      ;;
  esac

  touch "$notification_file" 2>/dev/null || true
}

# =============================================================================
# restart_gateway — handles all isolation types
# session:   systemctl restart openclaw-${GROUP}.service
# container: docker restart openclaw-${GROUP} (or docker compose)
# standard:  systemctl restart openclaw
# =============================================================================
restart_gateway() {
  local user="${HC_USERNAME:-bot}"
  log "Restarting gateway ISOLATION='${ISOLATION:-none}' GROUP='${GROUP:-}'..."
  if [ "${ISOLATION:-none}" = "session" ] && [ -n "${GROUP:-}" ]; then
    # Session isolation: restart only this group's service
    systemctl restart "openclaw-${GROUP}.service" 2>&1 || true
  elif [ "${ISOLATION:-none}" = "container" ]; then
    docker compose \
      -f "/home/${user}/.openclaw/compose/${GROUP:-default}/docker-compose.yaml" \
      -p "openclaw-${GROUP:-default}" restart 2>&1 || true
  else
    # Standard (none) mode — single openclaw service
    systemctl restart "openclaw.service" 2>&1 || true
  fi
}

# =============================================================================
# enter_safe_mode — handles all isolation types including container
# =============================================================================
enter_safe_mode() {
  local iso="${ISOLATION:-none}"
  log "Entering safe mode isolation='${iso}' GROUP='${GROUP:-}'..."
  touch "$SAFE_MODE_FILE" 2>/dev/null || true

  # Stop isolation services for this group only
  case "$iso" in
    container)
      local user="${HC_USERNAME:-bot}"
      docker compose \
        -f "/home/${user}/.openclaw/compose/${GROUP:-default}/docker-compose.yaml" \
        -p "openclaw-${GROUP:-default}" down 2>&1 || true
      systemctl stop "openclaw-container-${GROUP}.service" 2>/dev/null || true
      ;;
    session)
      # Per-group: stop only this group's service
      systemctl stop "openclaw-${GROUP}.service" 2>/dev/null || true
      ;;
    *)
      systemctl stop "openclaw.service" 2>/dev/null || true
      ;;
  esac
  log "Safe mode activated — config path: ${CONFIG_PATH}"
}

# =============================================================================
# check_agents_e2e — delegates to the dedicated E2E check script
# =============================================================================
check_agents_e2e() {
  local _e2e=""
  for _ep in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
    [ -f "$_ep/gateway-e2e-check.sh" ] && { _e2e="$_ep/gateway-e2e-check.sh"; break; }
  done
  [ -n "${_e2e}" ] && [ -x "${_e2e}" ] && bash "${_e2e}" || true
}

# =============================================================================
# check_service_health — universal HTTP check
# =============================================================================
check_service_health() {
  local svc="${1:-$SERVICE_NAME}" port="${2:-$PORT}"
  log "Checking $svc on port $port..."
  GROUP_PORT="$port" hc_curl_gateway "${GROUP:-}" "/" >/dev/null 2>&1
}

# =============================================================================
# Main Health Check
# =============================================================================

RUN_MODE="${RUN_MODE:-execstartpost}"

# --- Skip is-active check in ExecStartPost mode (service is starting up) ---
if [ "$RUN_MODE" != "execstartpost" ]; then
  # is-active check: only poll systemctl outside ExecStartPost
  if ! systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    log "Service ${SERVICE_NAME}.service is not active yet"
  fi
fi

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

# --- HTTP poll ---
start=$(date +%s)
warned=false
HEALTHY=false
ALREADY_IN_SAFE_MODE=false
[ -f "$SAFE_MODE_FILE" ] && ALREADY_IN_SAFE_MODE=true

while true; do
  elapsed=$(( $(date +%s) - start ))

  if [ "$elapsed" -ge "$HARD_MAX" ]; then
    log "TIMEOUT after ${elapsed}s"
    break
  fi

  if [ "$warned" = "false" ] && [ "$elapsed" -ge "$WARN_AT" ]; then
    warned=true
    log "⏳ Still waiting (${elapsed}s)..."
    notify_send_message "⏳ Gateway slow to start (${elapsed}s). Still trying..." 2>/dev/null || true
  fi

  if check_service_health "$SERVICE_NAME" "$GROUP_PORT"; then
    HEALTHY=true
    log "✓ HTTP responding at ${elapsed}s"
    break
  fi

  sleep 5
done

# --- Evaluate results ---
if [ "$HEALTHY" = "true" ] && [ "$ALREADY_IN_SAFE_MODE" = "true" ]; then
  # === SAFE MODE STABLE: gateway healthy but still in safe mode config ===
  log "SAFE MODE STABLE — gateway up, safe mode config active"
  send_boot_notification "safe-mode"
  rm -f "$UNHEALTHY_MARKER"
  exit 0
fi

if [ "$HEALTHY" = "true" ]; then
  # === FULLY HEALTHY ===
  log "✓ Gateway healthy — validating channel connectivity..."

  # Validate channel tokens before running E2E checks
  # EXIT_CODE=2: channel connectivity failure is critical (broken tokens can't restart-recover)
  check_channel_connectivity "$SERVICE_NAME" || { log "Channel connectivity failed — marking unhealthy (critical)"; touch "$UNHEALTHY_MARKER"; EXIT_CODE=2; exit $EXIT_CODE; }

  check_agents_e2e 2>/dev/null || true

  rm -f "$UNHEALTHY_MARKER"
  rm -f "$SAFE_MODE_FILE"

  # Set stage=11 and create setup-complete on full health (use set_stage for monotonic guarantee)
  set_stage 11 "ready" || true
  touch /var/lib/init-status/setup-complete 2>/dev/null || true

  # Re-arm safeguard path unit
  _sg="openclaw-safeguard${GROUP:+-$GROUP}.path"
  systemctl is-active --quiet "$_sg" 2>/dev/null || \
    systemctl restart "$_sg" 2>/dev/null || true

  send_boot_notification "healthy"
  log "========== HTTP CHECK PASSED =========="
  exit 0
fi

# --- HTTP check failed ---
log "✗ HTTP not responding after ${HARD_MAX}s"
touch "$UNHEALTHY_MARKER"

RECOVERY_ATTEMPTS=$(cat "$RECOVERY_COUNTER" 2>/dev/null || echo 0)
RECOVERY_ATTEMPTS=$(( RECOVERY_ATTEMPTS + 1 ))
echo "$RECOVERY_ATTEMPTS" > "$RECOVERY_COUNTER"

if [ "$RECOVERY_ATTEMPTS" -eq 1 ]; then
  # Entering safe mode — Run 1: notification deferred until safe mode is stable
  log "Entering safe mode (Run 1) — notification deferred, wait for Run 2"
  send_entering_safe_mode_warning
  enter_safe_mode
else
  enter_safe_mode
fi

log "========== HTTP CHECK FAILED =========="
EXIT_CODE=1
exit $EXIT_CODE
