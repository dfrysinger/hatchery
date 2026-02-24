#!/bin/bash
# =============================================================================
# try-full-config.sh -- Attempt switch from safe-mode to full config
# =============================================================================
# Purpose:  Switch from minimal/safe-mode config to full config.
#           Validates health and rolls back on failure.
#           Handles both single-service and session-isolation modes.
#
# Usage:    sudo try-full-config.sh [--group <group>]
#           Without --group: restarts all services (single mode or all groups)
#           With --group: restarts only the specified isolation group
#
# Dependencies: systemctl, curl, openclaw-state.sh (optional)
# =============================================================================
set -euo pipefail

set -a; source /etc/droplet.env; set +a
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

AC="${AGENT_COUNT:-1}"
H="/home/${USERNAME:-bot}"
ISOLATION="${ISOLATION_DEFAULT:-none}"
STATE_CMD="/usr/local/bin/openclaw-state.sh"
MANIFEST="${MANIFEST:-/etc/openclaw-groups.json}"

# Source lib-isolation if available (for hc_* functions)
for _lp in /usr/local/sbin /usr/local/bin; do
  [ -f "$_lp/lib-health-check.sh" ] && source "$_lp/lib-health-check.sh" && break
done

# Parse args
TARGET_GROUP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) TARGET_GROUP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# --- State machine: lock and transition ---
if [ -x "$STATE_CMD" ]; then
  if [ -n "$TARGET_GROUP" ]; then
    GROUP="$TARGET_GROUP" "$STATE_CMD" lock --holder "try-full-config" --ttl 300 2>/dev/null || true
    GROUP="$TARGET_GROUP" "$STATE_CMD" transition --to TRANSITIONING --reason "try-full-config" --by "operator" 2>/dev/null || true
  else
    "$STATE_CMD" lock --holder "try-full-config" --ttl 300 2>/dev/null || true
    "$STATE_CMD" transition --to TRANSITIONING --reason "try-full-config" --by "operator" 2>/dev/null || true
  fi
fi

# --- Determine which services to restart ---
restart_services() {
  if [ "$ISOLATION" = "session" ] || [ "$ISOLATION" = "container" ]; then
    if [ -n "$TARGET_GROUP" ]; then
      log "Restarting group ${TARGET_GROUP} (${ISOLATION})"
      if type hc_restart_service &>/dev/null; then
        ISOLATION="$ISOLATION" hc_restart_service "$TARGET_GROUP"
      else
        # Fallback: use manifest serviceName
        local svc_name
        svc_name=$(jq -r --arg g "$TARGET_GROUP" '.groups[$g].serviceName // empty' "$MANIFEST" 2>/dev/null)
        [ -n "$svc_name" ] && systemctl restart "${svc_name}.service"
      fi
    else
      # Restart all isolation groups
      local groups="${ISOLATION_GROUPS:-}"
      IFS=',' read -ra _groups <<< "$groups"
      for grp in "${_groups[@]}"; do
        log "Restarting group ${grp}"
        if type hc_restart_service &>/dev/null; then
          local grp_iso
          grp_iso=$(jq -r --arg g "$grp" '.groups[$g].isolation // "session"' "$MANIFEST" 2>/dev/null)
          ISOLATION="$grp_iso" hc_restart_service "$grp"
        else
          local svc_name
          svc_name=$(jq -r --arg g "$grp" '.groups[$g].serviceName // empty' "$MANIFEST" 2>/dev/null)
          [ -n "$svc_name" ] && systemctl restart "${svc_name}.service"
        fi
      done
    fi
  else
    log "Restarting openclaw.service"
    systemctl restart openclaw.service
  fi
}

# --- Read port from manifest (SSOT) ---
get_port() {
  local grp="$1"
  if [ -f "$MANIFEST" ]; then
    jq -r --arg g "$grp" '.groups[$g].port // empty' "$MANIFEST" 2>/dev/null
  fi
}

# --- Determine health check port(s) ---
check_health() {
  if [ "$ISOLATION" = "session" ] || [ "$ISOLATION" = "container" ]; then
    if [ -n "$TARGET_GROUP" ]; then
      local port
      port=$(get_port "$TARGET_GROUP")
      port="${port:-18789}"
      if type hc_curl_gateway &>/dev/null; then
        local grp_iso
        grp_iso=$(jq -r --arg g "$TARGET_GROUP" '.groups[$g].isolation // "session"' "$MANIFEST" 2>/dev/null)
        local grp_net
        grp_net=$(jq -r --arg g "$TARGET_GROUP" '.groups[$g].network // "host"' "$MANIFEST" 2>/dev/null)
        ISOLATION="$grp_iso" NETWORK_MODE="$grp_net" GROUP_PORT="$port" \
          hc_curl_gateway "$TARGET_GROUP" "/" >/dev/null 2>&1
      else
        curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1
      fi
    else
      local groups="${ISOLATION_GROUPS:-}"
      IFS=',' read -ra _groups <<< "$groups"
      for grp in "${_groups[@]}"; do
        local port
        port=$(get_port "$grp")
        port="${port:-18789}"
        if ! curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
          return 1
        fi
      done
    fi
  else
    curl -sf "http://127.0.0.1:18789/" >/dev/null 2>&1
  fi
}

# --- Apply full config ---
log "Attempting full config switch (isolation=$ISOLATION, group=${TARGET_GROUP:-all})"

if [ "$ISOLATION" = "session" ] && [ -n "$TARGET_GROUP" ]; then
  # Per-group: restore the group's session config from the full template
  # The session config is regenerated by generate-session-services.sh
  log "Regenerating session config for group $TARGET_GROUP"
  bash /usr/local/sbin/generate-session-services.sh 2>/dev/null || true
else
  # Single mode or all groups: restore the main config
  cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
  chown "${USERNAME}:${USERNAME}" "$H/.openclaw/openclaw.json"
  chmod 600 "$H/.openclaw/openclaw.json"
  # Also regenerate isolation configs if in isolation mode
  [ "$ISOLATION" = "session" ] && bash /usr/local/sbin/generate-session-services.sh 2>/dev/null || true
  [ "$ISOLATION" = "container" ] && bash /usr/local/sbin/generate-docker-compose.sh 2>/dev/null || true
fi

restart_services

# --- Wait for health ---
HEALTHY=false
for _ in $(seq 1 12); do
  sleep 5
  if check_health; then
    HEALTHY=true
    break
  fi
  log "Waiting for health..."
done

# --- Handle result ---
if [ "$HEALTHY" = "true" ]; then
  log "SUCCESS: Full config is healthy"

  # Clean up safe mode markers
  if [ -n "$TARGET_GROUP" ]; then
    rm -f "/var/lib/init-status/safe-mode-${TARGET_GROUP}"
    rm -f "/var/lib/init-status/recovery-attempts-${TARGET_GROUP}"
    rm -f "/var/lib/init-status/recently-recovered-${TARGET_GROUP}"
  else
    rm -f /var/lib/init-status/safe-mode /var/lib/init-status/safe-mode-*
    rm -f /var/lib/init-status/recovery-attempts /var/lib/init-status/recovery-attempts-*
    for si in $(seq 1 "$AC"); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  fi

  # Update state machine
  if [ -x "$STATE_CMD" ]; then
    if [ -n "$TARGET_GROUP" ]; then
      GROUP="$TARGET_GROUP" "$STATE_CMD" transition --to HEALTHY --reason "full-config-restored" --by "try-full-config" 2>/dev/null || true
      GROUP="$TARGET_GROUP" "$STATE_CMD" unlock 2>/dev/null || true
    else
      "$STATE_CMD" transition --to HEALTHY --reason "full-config-restored" --by "try-full-config" 2>/dev/null || true
      "$STATE_CMD" unlock 2>/dev/null || true
    fi
  fi

  exit 0
else
  log "FAILED: Rolling back to safe-mode config"

  # Rollback
  if [ -f "$H/.openclaw/openclaw.minimal.json" ]; then
    cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
    chown "${USERNAME}:${USERNAME}" "$H/.openclaw/openclaw.json"
    chmod 600 "$H/.openclaw/openclaw.json"
  fi
  restart_services

  # Update state machine
  if [ -x "$STATE_CMD" ]; then
    if [ -n "$TARGET_GROUP" ]; then
      GROUP="$TARGET_GROUP" "$STATE_CMD" transition --to SAFE_MODE --reason "full-config-failed" --by "try-full-config" 2>/dev/null || true
      GROUP="$TARGET_GROUP" "$STATE_CMD" unlock 2>/dev/null || true
    else
      "$STATE_CMD" transition --to SAFE_MODE --reason "full-config-failed" --by "try-full-config" 2>/dev/null || true
      "$STATE_CMD" unlock 2>/dev/null || true
    fi
  fi

  log "Check logs: journalctl -u openclaw-${TARGET_GROUP:-openclaw} --since '5 min ago'"
  exit 1
fi
