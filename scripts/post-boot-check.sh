#!/bin/bash
# =============================================================================
# post-boot-check.sh -- Post-reboot health check and config upgrade
# =============================================================================
# Purpose:  Runs after reboot (via systemd oneshot). Upgrades from minimal
#           config to full config, validates health, and enters safe mode
#           if full config fails health checks.
#
# HEAVILY INSTRUMENTED VERSION FOR DEBUGGING ISOLATION_GROUPS ISSUE
# =============================================================================

LOG="/var/log/post-boot-check.log"

# Helper to log with timestamp
log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"
}

log "========== POST-BOOT-CHECK STARTING =========="
log "Script: $0"
log "PID: $$"
log "User: $(whoami)"
log "PWD: $(pwd)"

# Dump initial environment (isolation-related vars only to avoid secrets)
log "=== INITIAL ENVIRONMENT ==="
log "PATH=$PATH"
log "HOME=$HOME"
log "USER=$USER"
env | grep -iE '^(ISOLATION|AGENT|HABITAT|USERNAME|PLATFORM)' | while read line; do
  log "ENV: $line"
done

# Check what files exist
log "=== FILE EXISTENCE CHECKS ==="
for f in /etc/droplet.env /etc/habitat-parsed.env /etc/habitat.json; do
  if [ -f "$f" ]; then
    log "EXISTS: $f (size=$(stat -c%s "$f" 2>/dev/null || echo unknown), perms=$(stat -c%a "$f" 2>/dev/null || echo unknown))"
  else
    log "MISSING: $f"
  fi
done

# Source droplet.env
log "=== SOURCING /etc/droplet.env ==="
if [ -f /etc/droplet.env ]; then
  set -a
  source /etc/droplet.env
  set +a
  log "Sourced /etc/droplet.env"
  # Log non-secret vars
  log "After droplet.env: USERNAME='${USERNAME:-}' HABITAT_NAME='${HABITAT_NAME:-}'"
else
  log "ERROR: /etc/droplet.env not found"
fi

d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

# Check habitat-parsed.env contents BEFORE sourcing
log "=== HABITAT-PARSED.ENV INSPECTION ==="
if [ -f /etc/habitat-parsed.env ]; then
  log "File exists, dumping isolation-related lines:"
  grep -iE '^(ISOLATION|AGENT.*ISOLATION|PLATFORM)' /etc/habitat-parsed.env 2>/dev/null | while read line; do
    log "  RAW: $line"
  done
  
  log "Full file line count: $(wc -l < /etc/habitat-parsed.env)"
  log "File first 5 lines:"
  head -5 /etc/habitat-parsed.env 2>/dev/null | while read line; do
    log "  HEAD: $line"
  done
  log "File last 5 lines:"
  tail -5 /etc/habitat-parsed.env 2>/dev/null | while read line; do
    log "  TAIL: $line"
  done
else
  log "ERROR: /etc/habitat-parsed.env not found!"
  log "Checking if parse-habitat.py ran..."
  ls -la /etc/habitat*.* 2>&1 | while read line; do
    log "  LS: $line"
  done
  
  # Check phase1 log for parse errors
  if [ -f /var/log/phase1.log ]; then
    log "Last 20 lines of phase1.log:"
    tail -20 /var/log/phase1.log 2>/dev/null | while read line; do
      log "  PHASE1: $line"
    done
  fi
fi

# Now source habitat-parsed.env with verbose tracing
log "=== SOURCING /etc/habitat-parsed.env ==="
if [ -f /etc/habitat-parsed.env ]; then
  # Capture vars before
  BEFORE_ISOLATION="${ISOLATION_DEFAULT:-__UNSET__}"
  BEFORE_GROUPS="${ISOLATION_GROUPS:-__UNSET__}"
  
  log "BEFORE source: ISOLATION_DEFAULT='$BEFORE_ISOLATION' ISOLATION_GROUPS='$BEFORE_GROUPS'"
  
  # Source it
  source /etc/habitat-parsed.env
  RET=$?
  log "source command returned: $RET"
  
  # Capture vars after
  AFTER_ISOLATION="${ISOLATION_DEFAULT:-__UNSET__}"
  AFTER_GROUPS="${ISOLATION_GROUPS:-__UNSET__}"
  
  log "AFTER source: ISOLATION_DEFAULT='$AFTER_ISOLATION' ISOLATION_GROUPS='$AFTER_GROUPS'"
  
  # Also check with explicit eval
  log "Trying explicit grep+eval for ISOLATION_GROUPS..."
  EXPLICIT_GROUPS=$(grep '^ISOLATION_GROUPS=' /etc/habitat-parsed.env 2>/dev/null | cut -d= -f2- | tr -d '"')
  log "Explicit grep result: ISOLATION_GROUPS='$EXPLICIT_GROUPS'"
  
  # If source didn't work but grep did, use grep result
  if [ -z "${ISOLATION_GROUPS:-}" ] && [ -n "$EXPLICIT_GROUPS" ]; then
    log "WORKAROUND: Using explicit grep result since source didn't set the var"
    ISOLATION_GROUPS="$EXPLICIT_GROUPS"
    export ISOLATION_GROUPS
  fi
else
  log "ERROR: Cannot source - file not found"
fi

# Final variable state
log "=== FINAL VARIABLE STATE ==="
log "ISOLATION_DEFAULT='${ISOLATION_DEFAULT:-}'"
log "ISOLATION_GROUPS='${ISOLATION_GROUPS:-}'"
log "ISOLATION_SHARED_PATHS='${ISOLATION_SHARED_PATHS:-}'"
log "AGENT_COUNT='${AGENT_COUNT:-}'"
log "USERNAME='${USERNAME:-}'"
log "HABITAT_NAME='${HABITAT_NAME:-}'"
log "PLATFORM='${PLATFORM:-}'"

# Log per-agent isolation settings
AC=${AGENT_COUNT:-0}
for i in $(seq 1 $AC); do
  grp_var="AGENT${i}_ISOLATION_GROUP"
  iso_var="AGENT${i}_ISOLATION"
  name_var="AGENT${i}_NAME"
  log "Agent $i: name='${!name_var:-}' isolation='${!iso_var:-}' group='${!grp_var:-}'"
done

# Set working variables
AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
TG="/usr/local/bin/tg-notify.sh"
ISOLATION="${ISOLATION_DEFAULT:-none}"
# NOTE: Do NOT use "GROUPS" - it's a bash built-in array variable that causes conflicts
SESSION_GROUPS="${ISOLATION_GROUPS:-}"

log "=== WORKING VARIABLES ==="
log "AC=$AC H=$H ISOLATION=$ISOLATION SESSION_GROUPS=$SESSION_GROUPS"

# Check for trigger file
log "=== TRIGGER FILE CHECK ==="
if [ ! -f /var/lib/init-status/needs-post-boot-check ]; then
  log "Trigger file not found, exiting normally"
  exit 0
fi
log "Trigger file exists, proceeding after 15s sleep"
sleep 15

# Check for full config
log "=== CONFIG FILE CHECK ==="
if [ ! -f "$H/.openclaw/openclaw.full.json" ]; then
  log "No full config found at $H/.openclaw/openclaw.full.json, exiting"
  rm -f /var/lib/init-status/needs-post-boot-check
  exit 0
fi
log "Full config found, size=$(stat -c%s "$H/.openclaw/openclaw.full.json" 2>/dev/null || echo unknown)"

# Apply full config
log "Copying full config to openclaw.json"
cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
chmod 600 "$H/.openclaw/openclaw.json"

# Health check function for a single service/port
check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-12}"
  
  log "Checking health: service=$service port=$port max_attempts=$max_attempts"
  
  for i in $(seq 1 $max_attempts); do
    sleep 5
    
    # Check systemd status
    local active=$(systemctl is-active "$service" 2>&1)
    log "[$service] attempt $i/$max_attempts: systemctl is-active = '$active'"
    
    if [ "$active" != "active" ]; then
      # Get more details on why not active
      local status=$(systemctl status "$service" 2>&1 | head -10)
      log "[$service] status: $status"
      continue
    fi
    
    # Try curl
    local curl_out=$(curl -sf "http://127.0.0.1:${port}/" 2>&1)
    local curl_ret=$?
    log "[$service] curl returned $curl_ret"
    
    if [ $curl_ret -eq 0 ]; then
      log "[$service] HEALTHY on port $port"
      return 0
    fi
  done
  
  log "[$service] FAILED health check after $max_attempts attempts"
  return 1
}

HEALTHY=false

log "=== SERVICE HEALTH CHECKS ==="
log "Isolation mode: '$ISOLATION'"
log "Session groups: '$SESSION_GROUPS'"

if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  log "SESSION ISOLATION MODE"
  
  # List session service files
  log "Looking for session service files:"
  ls -la /etc/systemd/system/openclaw-*.service 2>&1 | while read line; do
    log "  $line"
  done
  
  # Ensure state directories have correct permissions before starting
  STATE_BASE="$H/.openclaw-sessions"
  log "State base: $STATE_BASE"
  if [ -d "$STATE_BASE" ]; then
    log "State dir exists, fixing permissions"
    chown -R $USERNAME:$USERNAME "$STATE_BASE" 2>/dev/null || true
    chmod -R u+rwX "$STATE_BASE" 2>/dev/null || true
    ls -la "$STATE_BASE" 2>&1 | while read line; do
      log "  STATE: $line"
    done
  else
    log "State dir does not exist yet"
  fi
  
  # Parse groups and restart services
  IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"
  log "Parsed ${#GROUP_ARRAY[@]} groups: ${GROUP_ARRAY[*]}"
  
  for group in "${GROUP_ARRAY[@]}"; do
    log "Restarting openclaw-${group}.service"
    systemctl restart "openclaw-${group}.service" 2>&1 | while read line; do
      log "  RESTART: $line"
    done
  done
  
  # Check if at least one session service is healthy
  BASE_PORT=18790
  group_index=0
  for group in "${GROUP_ARRAY[@]}"; do
    port=$((BASE_PORT + group_index))
    log "Checking group '$group' on port $port"
    if check_service_health "openclaw-${group}.service" "$port" 12; then
      HEALTHY=true
      log "Session service healthy: $group"
      break
    fi
    group_index=$((group_index + 1))
  done
  
  if [ "$HEALTHY" != "true" ]; then
    log "FAILED: No session services responded"
  fi

elif [ "$ISOLATION" = "container" ]; then
  log "CONTAINER ISOLATION MODE"
  systemctl restart openclaw-containers.service 2>/dev/null || true
  sleep 10
  if check_service_health "openclaw-containers.service" 18790 12; then
    HEALTHY=true
  fi

else
  log "NO ISOLATION MODE (default) - checking clawdbot"
  
  # Check if clawdbot service exists
  if systemctl list-unit-files | grep -q clawdbot; then
    log "clawdbot service exists"
  else
    log "WARNING: clawdbot service not found in unit files"
  fi
  
  log "Restarting clawdbot"
  systemctl restart clawdbot 2>&1 | while read line; do
    log "  RESTART: $line"
  done
  
  if check_service_health "clawdbot" 18789 12; then
    HEALTHY=true
  fi
fi

log "=== FINAL RESULT ==="
log "HEALTHY=$HEALTHY"

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
  $TG "[OK] ${HN}${HDOM} fully operational. Full config applied (isolation=$ISOLATION, groups=$SESSION_GROUPS). All systems ready." || true
else
  log "FAILURE - entering SAFE MODE"
  cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
  chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
  chmod 600 "$H/.openclaw/openclaw.json"
  touch /var/lib/init-status/safe-mode
  for si in $(seq 1 $AC); do
    cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Full config failed health checks

The full openclaw config failed to start. You are running minimal config.

**Isolation mode:** $ISOLATION
**Session groups:** $SESSION_GROUPS

## Debug Info
- Check \`/var/log/post-boot-check.log\` for detailed diagnostics
- ISOLATION_DEFAULT was: ${ISOLATION_DEFAULT:-NOT_SET}
- ISOLATION_GROUPS was: ${ISOLATION_GROUPS:-NOT_SET}

## Troubleshooting

Try: \`sudo /usr/local/bin/try-full-config.sh\`

Check logs:
- \`journalctl -u clawdbot -n 100\`
- \`cat /var/log/post-boot-check.log\`
$([ "$ISOLATION" = "session" ] && echo "- \`systemctl status openclaw-browser openclaw-documents\`")
$([ "$ISOLATION" = "container" ] && echo "- \`docker-compose -f /etc/openclaw/docker-compose.yml logs\`")

If that fails, check openclaw.full.json for errors.
SAFEMD
    chown $USERNAME:$USERNAME "$H/clawd/agents/agent${si}/SAFE_MODE.md"
  done
  
  # Restart main clawdbot as fallback
  log "Restarting clawdbot as fallback"
  systemctl restart clawdbot
  sleep 5
  rm -f /var/lib/init-status/needs-post-boot-check
  $TG "[SAFE MODE] ${HABITAT_NAME:-default} running minimal config. Full config failed (isolation=$ISOLATION, groups=$SESSION_GROUPS). Check /var/log/post-boot-check.log" || true
fi

log "========== POST-BOOT-CHECK COMPLETE =========="
