#!/bin/bash
# =============================================================================
# post-boot-check.sh -- Post-reboot health check and config upgrade
# =============================================================================
# Purpose:  Runs after reboot (via systemd oneshot). Upgrades from minimal
#           config to full config, validates health, and enters safe mode
#           if full config fails health checks.
#
# Inputs:   /etc/droplet.env, /etc/habitat-parsed.env
# Outputs:  /var/lib/init-status/setup-complete or safe-mode markers
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

d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

if [ -f /etc/habitat-parsed.env ]; then
  source /etc/habitat-parsed.env
else
  log "ERROR: /etc/habitat-parsed.env not found"
  exit 1
fi

# Set working variables
AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
TG="/usr/local/bin/tg-notify.sh"
ISOLATION="${ISOLATION_DEFAULT:-none}"
# NOTE: Do NOT use "GROUPS" - it's a bash built-in array variable that causes conflicts
SESSION_GROUPS="${ISOLATION_GROUPS:-}"

log "Config: isolation=$ISOLATION groups=$SESSION_GROUPS agents=$AC"

# Check for trigger file
if [ ! -f /var/lib/init-status/needs-post-boot-check ]; then
  log "No trigger file - exiting"
  exit 0
fi

log "Trigger file found, waiting 15s for services to settle..."
sleep 15

# Check for full config
if [ ! -f "$H/.openclaw/openclaw.full.json" ]; then
  log "No full config found - exiting"
  rm -f /var/lib/init-status/needs-post-boot-check
  exit 0
fi

# Apply full config
log "Applying full config..."
cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
chmod 600 "$H/.openclaw/openclaw.json"

# Health check function for a single service/port
check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-12}"
  
  log "Health check: $service on port $port"
  
  for i in $(seq 1 $max_attempts); do
    sleep 5
    
    # Check systemd status
    local active
    active=$(systemctl is-active "$service" 2>&1)
    if [ "$active" != "active" ]; then
      log "  attempt $i/$max_attempts: not active ($active)"
      continue
    fi
    
    # Try curl
    if curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      log "  HEALTHY after $i attempts"
      return 0
    fi
    log "  attempt $i/$max_attempts: curl failed"
  done
  
  log "  FAILED after $max_attempts attempts"
  return 1
}

HEALTHY=false

if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  log "Session isolation mode"
  
  # Ensure state directories have correct permissions
  STATE_BASE="$H/.openclaw-sessions"
  if [ -d "$STATE_BASE" ]; then
    chown -R $USERNAME:$USERNAME "$STATE_BASE" 2>/dev/null || true
    chmod -R u+rwX "$STATE_BASE" 2>/dev/null || true
  fi
  
  # Parse groups and restart services
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  log "Processing ${#GROUP_ARRAY[@]} group(s): ${GROUP_ARRAY[*]}"
  
  for group in "${GROUP_ARRAY[@]}"; do
    log "Restarting openclaw-${group}.service"
    systemctl restart "openclaw-${group}.service" 2>&1 || true
  done
  
  # Check if at least one session service is healthy
  BASE_PORT=18790
  group_index=0
  for group in "${GROUP_ARRAY[@]}"; do
    port=$((BASE_PORT + group_index))
    if check_service_health "openclaw-${group}.service" "$port" 12; then
      HEALTHY=true
      log "Session service healthy: $group"
      break
    fi
    group_index=$((group_index + 1))
  done

elif [ "$ISOLATION" = "container" ]; then
  log "Container isolation mode"
  systemctl restart openclaw-containers.service 2>/dev/null || true
  sleep 10
  if check_service_health "openclaw-containers.service" 18790 12; then
    HEALTHY=true
  fi

else
  log "Standard mode (no isolation)"
  systemctl restart clawdbot 2>&1 || true
  if check_service_health "clawdbot" 18789 12; then
    HEALTHY=true
  fi
fi

if [ "$HEALTHY" = "true" ]; then
  log "SUCCESS - marking setup complete"
  rm -f /var/lib/init-status/needs-post-boot-check
  rm -f /var/lib/init-status/safe-mode
  for si in $(seq 1 $AC); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  touch /var/lib/init-status/setup-complete
  echo '11' > /var/lib/init-status/stage
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=11 DESC=ready" >> /var/log/init-stages.log
  touch /var/lib/init-status/boot-complete
  HN="${HABITAT_NAME:-default}"
  HDOM="${HABITAT_DOMAIN:+ ($HABITAT_DOMAIN)}"
  $TG "[OK] ${HN}${HDOM} fully operational. Full config applied (isolation=$ISOLATION). All systems ready." || true
else
  log "FAILURE - entering SAFE MODE with smart recovery"
  touch /var/lib/init-status/safe-mode
  
  # Source smart recovery functions
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$SCRIPT_DIR/safe-mode-recovery.sh" ]; then
    source "$SCRIPT_DIR/safe-mode-recovery.sh"
  elif [ -f "/usr/local/bin/safe-mode-recovery.sh" ]; then
    source "/usr/local/bin/safe-mode-recovery.sh"
  fi
  
  # Try full recovery escalation (token hunting + API fallback + doctor + state cleanup)
  SMART_RECOVERY_SUCCESS=false
  if type run_full_recovery_escalation &>/dev/null; then
    log "Attempting full recovery escalation..."
    export HOME_DIR="$H"
    export USERNAME="$USERNAME"
    export RECOVERY_LOG="$LOG"
    
    if recovery_result=$(run_full_recovery_escalation 2>&1); then
      log "Full recovery escalation succeeded: $recovery_result"
      SMART_RECOVERY_SUCCESS=true
    else
      log "Full recovery escalation failed, falling back to minimal config"
    fi
  elif type run_smart_recovery &>/dev/null; then
    log "Attempting smart recovery (token hunting + API fallback)..."
    export HOME_DIR="$H"
    export USERNAME="$USERNAME"
    export RECOVERY_LOG="$LOG"
    
    if recovery_result=$(run_smart_recovery 2>&1); then
      log "Smart recovery succeeded: $recovery_result"
      SMART_RECOVERY_SUCCESS=true
    else
      log "Smart recovery failed, falling back to minimal config"
    fi
  else
    log "Smart recovery not available, using minimal config"
  fi
  
  # If all recovery failed, fall back to minimal config
  if [ "$SMART_RECOVERY_SUCCESS" = "false" ]; then
    log "All recovery attempts failed, restoring minimal config..."
    cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
    chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
    chmod 600 "$H/.openclaw/openclaw.json"
  fi
  
  # Create SAFE_MODE.md for each agent
  RECOVERY_STATUS="minimal config"
  [ "$SMART_RECOVERY_SUCCESS" = "true" ] && RECOVERY_STATUS="smart recovery (found working credentials)"
  
  for si in $(seq 1 $AC); do
    cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Full config failed health checks

The full openclaw config failed to start. Recovery method: **${RECOVERY_STATUS}**

**Isolation mode:** $ISOLATION
**Session groups:** $SESSION_GROUPS
**Smart recovery:** $SMART_RECOVERY_SUCCESS

## What Happened

1. Full config was applied after reboot
2. Health checks failed (services didn't respond)
3. Safe mode activated with ${RECOVERY_STATUS}
4. You're now running on port 18789

## Troubleshooting

Check logs:
\`\`\`bash
cat /var/log/post-boot-check.log
cat /var/log/safe-mode-recovery.log
journalctl -u clawdbot -n 100
$([ "$ISOLATION" = "session" ] && echo "systemctl status openclaw-browser openclaw-documents")
\`\`\`

Try full config again:
\`\`\`bash
sudo /usr/local/bin/try-full-config.sh
\`\`\`

## Smart Recovery Details

Safe mode now automatically:
- Tries all bot tokens until one works
- Falls back through API providers (Anthropic → OpenAI → Gemini)
- Generates emergency config with working credentials
SAFEMD
    chown $USERNAME:$USERNAME "$H/clawd/agents/agent${si}/SAFE_MODE.md"
  done
  
  # Stop any session/container services and start clawdbot as fallback
  if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
    log "Stopping session services for safe mode fallback"
    IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
    for group in "${GROUP_ARRAY[@]}"; do
      systemctl stop "openclaw-${group}.service" 2>/dev/null || true
    done
  elif [ "$ISOLATION" = "container" ]; then
    log "Stopping container service for safe mode fallback"
    systemctl stop openclaw-containers.service 2>/dev/null || true
  fi
  
  log "Starting clawdbot as safe mode fallback"
  systemctl restart clawdbot
  sleep 5
  
  rm -f /var/lib/init-status/needs-post-boot-check
  $TG "[SAFE MODE] ${HABITAT_NAME:-default} running minimal config. Full config failed (isolation=$ISOLATION). Check /var/log/post-boot-check.log" || true
fi

# Generate boot report for all agents
log "Generating boot report..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/generate-boot-report.sh" ]; then
  source "$SCRIPT_DIR/generate-boot-report.sh"
  export HOME_DIR="$H"
  export HABITAT_JSON_PATH="/etc/habitat.json"
  export HABITAT_ENV_PATH="/etc/habitat-parsed.env"
  export CLAWDBOT_LOG="/var/log/clawdbot.log"
  export BOOT_REPORT_LOG="$LOG"
  run_boot_report_flow
  log "Boot report generated and distributed"
elif [ -f "/usr/local/bin/generate-boot-report.sh" ]; then
  source "/usr/local/bin/generate-boot-report.sh"
  export HOME_DIR="$H"
  export HABITAT_JSON_PATH="/etc/habitat.json"
  export HABITAT_ENV_PATH="/etc/habitat-parsed.env"
  export CLAWDBOT_LOG="/var/log/clawdbot.log"
  export BOOT_REPORT_LOG="$LOG"
  run_boot_report_flow
  log "Boot report generated and distributed"
else
  log "WARNING: generate-boot-report.sh not found, skipping boot report"
fi

log "========== POST-BOOT-CHECK COMPLETE =========="
