#!/bin/bash
# =============================================================================
# post-boot-check.sh -- Boot-time config upgrade and health check trigger
# =============================================================================
# Purpose:  Runs once after system boot (via systemd oneshot). Upgrades from
#           minimal config to full config, then calls gateway-health-check.sh.
#
# Inputs:   /etc/droplet.env, /etc/habitat-parsed.env
# Outputs:  /var/lib/init-status/setup-complete (on success)
#
# Note:     All health check and safe mode recovery logic is in
#           gateway-health-check.sh which runs on every gateway restart.
# =============================================================================

LOG="/var/log/post-boot-check.log"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"
}

log "========== POST-BOOT-CHECK STARTING =========="

# Source environment
if [ -f /etc/droplet.env ]; then
  set -a; source /etc/droplet.env; set +a
else
  log "ERROR: /etc/droplet.env not found"
  exit 1
fi

if [ -f /etc/habitat-parsed.env ]; then
  source /etc/habitat-parsed.env
else
  log "ERROR: /etc/habitat-parsed.env not found"
  exit 1
fi

# Set working variables
USERNAME="${USERNAME:-bot}"
H="/home/$USERNAME"
ISOLATION="${ISOLATION_DEFAULT:-none}"
SESSION_GROUPS="${ISOLATION_GROUPS:-}"

# Check for trigger file (only run once per boot)
if [ ! -f /var/lib/init-status/needs-post-boot-check ]; then
  log "No trigger file - exiting (already ran or not needed)"
  exit 0
fi

log "Boot trigger file found"

# Check for full config to apply
if [ ! -f "$H/.openclaw/openclaw.full.json" ]; then
  log "No full config found - marking complete and exiting"
  rm -f /var/lib/init-status/needs-post-boot-check
  touch /var/lib/init-status/setup-complete
  exit 0
fi

# Skip full config if safe mode is active (health check already found issues)
if [ -f /var/lib/init-status/safe-mode ]; then
  log "Safe mode active - NOT applying full config (emergency config in use)"
  rm -f /var/lib/init-status/needs-post-boot-check
  # Don't mark setup-complete since we're in safe mode
  exit 0
fi

# Apply full config (upgrade from minimal bootstrap config)
log "Applying full config..."
cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
chmod 600 "$H/.openclaw/openclaw.json"

# Restart the appropriate service(s) with full config
if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  log "Session isolation mode - restarting session services"
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  for group in "${GROUP_ARRAY[@]}"; do
    log "Restarting openclaw-${group}.service"
    systemctl restart "openclaw-${group}.service" 2>&1 || true
  done
elif [ "$ISOLATION" = "container" ]; then
  log "Container isolation mode - restarting container service"
  systemctl restart openclaw-containers.service 2>/dev/null || true
else
  log "Standard mode - restarting clawdbot"
  systemctl restart clawdbot 2>&1 || true
fi

# Run the universal health check (handles safe mode recovery if needed)
log "Running gateway health check..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK_SCRIPT=""
[ -f "$SCRIPT_DIR/gateway-health-check.sh" ] && HEALTH_CHECK_SCRIPT="$SCRIPT_DIR/gateway-health-check.sh"
[ -z "$HEALTH_CHECK_SCRIPT" ] && [ -f "/usr/local/bin/gateway-health-check.sh" ] && HEALTH_CHECK_SCRIPT="/usr/local/bin/gateway-health-check.sh"

if [ -n "$HEALTH_CHECK_SCRIPT" ]; then
  export HEALTH_CHECK_LOG="$LOG"
  bash "$HEALTH_CHECK_SCRIPT"
  HEALTH_EXIT=$?
  log "Gateway health check completed (exit=$HEALTH_EXIT)"
else
  log "ERROR: gateway-health-check.sh not found!"
  HEALTH_EXIT=1
fi

# Clean up boot marker
rm -f /var/lib/init-status/needs-post-boot-check

# Set final status based on health check result
if [ "$HEALTH_EXIT" -eq 0 ]; then
  log "Boot successful - marking setup complete"
  touch /var/lib/init-status/setup-complete
  touch /var/lib/init-status/boot-complete
  echo '11' > /var/lib/init-status/stage
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=11 DESC=ready" >> /var/log/init-stages.log
  
  # Update bot display names
  log "Updating bot display names..."
  /usr/local/bin/rename-bots.sh >> "$LOG" 2>&1 || log "Warning: rename-bots.sh failed (non-fatal)"
fi
# Note: Safe mode stages (12, 13) are set by gateway-health-check.sh

log "========== POST-BOOT-CHECK COMPLETE =========="
