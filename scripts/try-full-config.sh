#!/bin/bash
# =============================================================================
# try-full-config.sh -- Attempt switch from safe-mode to full config
# =============================================================================
# Purpose:  Switch from minimal/safe-mode config to full config.
#           Validates health and rolls back on failure.
#           Handles all isolation modes: none, session, container.
#
# Usage:    sudo try-full-config.sh [--group <group>]
#           Without --group: restarts all services (single mode or all groups)
#           With --group: restarts only the specified isolation group
#
# Dependencies: lib-health-check.sh, lib-isolation.sh, openclaw-state.sh (optional)
#
# Env:
#   STATE_STRICT — if "true", state machine failures are fatal (for CI/testing)
# =============================================================================
set -euo pipefail

# Source shared libraries (hard requirements)
for _lp in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lp/lib-health-check.sh" ] && { source "$_lp/lib-health-check.sh"; break; }
done
type hc_init_logging &>/dev/null || { echo "FATAL: lib-health-check.sh not found" >&2; exit 1; }

for _lp in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lp/lib-isolation.sh" ] && { source "$_lp/lib-isolation.sh"; break; }
done
type generate_group_config &>/dev/null || { echo "FATAL: lib-isolation.sh not found" >&2; exit 1; }

[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh

hc_init_logging "${GROUP:-}"
hc_load_environment

AC="${AGENT_COUNT:-1}"
H="${HC_HOME:-/home/${USERNAME:-bot}}"
ISOLATION="${HC_ISOLATION:-none}"
STATE_CMD="/usr/local/bin/openclaw-state.sh"

# Parse args
TARGET_GROUP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) TARGET_GROUP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log "Attempting full config switch (isolation=$ISOLATION, group=${TARGET_GROUP:-all})"

# Guard: session/container modes require groups to be defined
if [ "$ISOLATION" = "session" ] || [ "$ISOLATION" = "container" ]; then
  if [ -z "$TARGET_GROUP" ] && [ -z "${ISOLATION_GROUPS:-${HC_SESSION_GROUPS:-}}" ]; then
    log "FATAL: isolation=$ISOLATION but no groups defined (ISOLATION_GROUPS empty)"
    exit 1
  fi
fi

# --- State machine helpers ---
# In strict mode (STATE_STRICT=true), state machine failures are fatal.
# Default: warn and continue (state machine is supplementary to marker files).
_state() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    return 0
  else
    log "WARNING: $desc failed"
    [ "${STATE_STRICT:-false}" = "true" ] && { log "FATAL: strict mode — aborting"; exit 1; }
    return 0
  fi
}

# --- State machine: lock and transition ---
if [ -x "$STATE_CMD" ]; then
  if [ -n "$TARGET_GROUP" ]; then
    _state "lock (group=$TARGET_GROUP)" \
      env GROUP="$TARGET_GROUP" "$STATE_CMD" lock --holder "try-full-config" --ttl 300
    _state "transition to TRANSITIONING (group=$TARGET_GROUP)" \
      env GROUP="$TARGET_GROUP" "$STATE_CMD" transition --to TRANSITIONING --reason "try-full-config" --by "try-full-config"
  else
    _state "lock" "$STATE_CMD" lock --holder "try-full-config" --ttl 300
    _state "transition to TRANSITIONING" "$STATE_CMD" transition --to TRANSITIONING --reason "try-full-config" --by "try-full-config"
  fi
fi

# --- Regenerate full config ---
apply_full_config() {
  case "$ISOLATION" in
    session|container)
      if [ -n "$TARGET_GROUP" ]; then
        log "Regenerating config for group ${TARGET_GROUP}"
        generate_group_config "$TARGET_GROUP"
      else
        # Regenerate configs for all groups
        local groups="${ISOLATION_GROUPS:-${HC_SESSION_GROUPS:-}}"
        IFS=',' read -ra _groups <<< "$groups"
        for grp in "${_groups[@]}"; do
          log "Regenerating config for group ${grp}"
          generate_group_config "$grp"
        done
      fi
      ;;
    *)
      # none mode: restore saved full config
      log "Restoring full config from backup"
      cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
      chown "${USERNAME:-bot}:${USERNAME:-bot}" "$H/.openclaw/openclaw.json"
      chmod 600 "$H/.openclaw/openclaw.json"
      ;;
  esac
}

# --- Restart services ---
restart_services() {
  case "$ISOLATION" in
    session|container)
      if [ -n "$TARGET_GROUP" ]; then
        log "Restarting group ${TARGET_GROUP}"
        ISOLATION="$(get_group_isolation "$TARGET_GROUP")" hc_restart_service "$TARGET_GROUP"
      else
        local groups="${ISOLATION_GROUPS:-${HC_SESSION_GROUPS:-}}"
        IFS=',' read -ra _groups <<< "$groups"
        for grp in "${_groups[@]}"; do
          log "Restarting group ${grp}"
          ISOLATION="$(get_group_isolation "$grp")" hc_restart_service "$grp"
        done
      fi
      ;;
    *)
      log "Restarting openclaw.service"
      hc_restart_service ""
      ;;
  esac
}

# --- Execute ---
apply_full_config
restart_services

# --- Wait for health ---
# Uses hc_wait_for_http() from lib-health-check.sh (auto-scales timeout by isolation mode).
# For multi-group, waits for each group individually since they may have different
# isolation modes and network configurations.
HEALTHY=false

wait_for_all_groups() {
  case "$ISOLATION" in
    session|container)
      if [ -n "$TARGET_GROUP" ]; then
        local iso net port
        iso=$(get_group_isolation "$TARGET_GROUP")
        net=$(get_group_network "$TARGET_GROUP" 2>/dev/null)
        port=$(get_group_port "$TARGET_GROUP")
        ISOLATION="$iso" NETWORK_MODE="$net" GROUP_PORT="${port:-18789}" \
          hc_wait_for_http "$TARGET_GROUP"
      else
        local groups="${ISOLATION_GROUPS:-${HC_SESSION_GROUPS:-}}"
        IFS=',' read -ra _groups <<< "$groups"
        for grp in "${_groups[@]}"; do
          local iso net port
          iso=$(get_group_isolation "$grp")
          net=$(get_group_network "$grp" 2>/dev/null)
          port=$(get_group_port "$grp")
          log "Waiting for group ${grp}..."
          if ! ISOLATION="$iso" NETWORK_MODE="$net" GROUP_PORT="${port:-18789}" \
            hc_wait_for_http "$grp"; then
            return 1
          fi
        done
      fi
      ;;
    *)
      hc_wait_for_http ""
      ;;
  esac
}

if wait_for_all_groups; then
  HEALTHY=true
fi

# --- Handle result ---
state_transition() {
  local state="$1" reason="$2"
  [ -x "$STATE_CMD" ] || return 0
  if [ -n "$TARGET_GROUP" ]; then
    _state "transition to $state (group=$TARGET_GROUP)" \
      env GROUP="$TARGET_GROUP" "$STATE_CMD" transition --to "$state" --reason "$reason" --by "try-full-config"
    _state "unlock (group=$TARGET_GROUP)" \
      env GROUP="$TARGET_GROUP" "$STATE_CMD" unlock
  else
    _state "transition to $state" "$STATE_CMD" transition --to "$state" --reason "$reason" --by "try-full-config"
    _state "unlock" "$STATE_CMD" unlock
  fi
}

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

  state_transition "HEALTHY" "full-config-restored"
  exit 0
else
  log "FAILED: Rolling back to safe-mode config"

  # Rollback: restore safe-mode config
  if [ "$ISOLATION" = "none" ] && [ -f "$H/.openclaw/openclaw.minimal.json" ]; then
    cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
    chown "${USERNAME:-bot}:${USERNAME:-bot}" "$H/.openclaw/openclaw.json"
    chmod 600 "$H/.openclaw/openclaw.json"
  fi
  restart_services

  state_transition "SAFE_MODE" "full-config-failed"

  log "Check logs: hc_service_logs '${TARGET_GROUP:-}' 50"
  exit 1
fi
