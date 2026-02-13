#!/bin/bash
# =============================================================================
# post-boot-check.sh -- Post-reboot health check and config upgrade
# =============================================================================
# Purpose:  Runs after reboot (via systemd oneshot). Upgrades from minimal
#           config to full config, validates health, and enters safe mode
#           if full config fails health checks.
#
# Inputs:   /etc/droplet.env -- all B64-encoded secrets and config
#           /etc/habitat-parsed.env -- parsed habitat config
#           $HOME/.openclaw/openclaw.full.json -- full config to apply
#           /var/lib/init-status/needs-post-boot-check -- trigger file
#
# Outputs:  /var/lib/init-status/setup-complete -- on success
#           /var/lib/init-status/safe-mode -- on failure (fallback to minimal)
#           SAFE_MODE.md in agent workspaces -- on failure
#
# Dependencies: tg-notify.sh, systemctl, curl
#
# Original: /usr/local/bin/post-boot-check.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
TG="/usr/local/bin/tg-notify.sh"
LOG="/var/log/post-boot-check.log"

# Determine isolation mode
ISOLATION="${ISOLATION_DEFAULT:-none}"
GROUPS="${ISOLATION_GROUPS:-}"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) post-boot-check starting (isolation=$ISOLATION, groups=$GROUPS)" >> "$LOG"

[ ! -f /var/lib/init-status/needs-post-boot-check ] && {
  exit 0
}
sleep 15

if [ ! -f "$H/.openclaw/openclaw.full.json" ]; then
  rm -f /var/lib/init-status/needs-post-boot-check
  exit 0
fi

cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
chmod 600 "$H/.openclaw/openclaw.json"

# Health check function for a single service/port
check_service_health() {
  local service="$1"
  local port="$2"
  local max_attempts="${3:-12}"
  
  for i in $(seq 1 $max_attempts); do
    sleep 5
    if ! systemctl is-active --quiet "$service"; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$service] not active (attempt $i/$max_attempts)" >> "$LOG"
      continue
    fi
    if curl -sf "http://127.0.0.1:${port}/" >> "$LOG" 2>&1; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$service] healthy on port $port" >> "$LOG"
      return 0
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$service] curl failed (attempt $i/$max_attempts)" >> "$LOG"
  done
  return 1
}

HEALTHY=false

if [ "$ISOLATION" = "session" ] && [ -n "$GROUPS" ]; then
  # Session isolation mode: restart and check session services
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Session isolation mode - checking session services" >> "$LOG"
  
  # Restart all session services
  IFS=',' read -ra GROUP_ARRAY <<< "$GROUPS"
  for group in "${GROUP_ARRAY[@]}"; do
    systemctl restart "openclaw-${group}.service" 2>/dev/null || true
  done
  
  # Check if at least one session service is healthy
  BASE_PORT=18790
  group_index=0
  for group in "${GROUP_ARRAY[@]}"; do
    port=$((BASE_PORT + group_index))
    if check_service_health "openclaw-${group}.service" "$port" 12; then
      HEALTHY=true
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) At least one session service healthy (${group})" >> "$LOG"
      break
    fi
    group_index=$((group_index + 1))
  done
  
  if [ "$HEALTHY" != "true" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: No session services responded" >> "$LOG"
  fi

elif [ "$ISOLATION" = "container" ]; then
  # Container isolation mode: check docker-compose services
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Container isolation mode - checking docker services" >> "$LOG"
  systemctl restart openclaw-containers.service 2>/dev/null || true
  
  # Give containers time to start
  sleep 10
  
  # Check if at least one container is healthy (first group on port 18790)
  if check_service_health "openclaw-containers.service" 18790 12; then
    HEALTHY=true
  fi

else
  # No isolation (default): check main clawdbot service
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) No isolation - checking clawdbot service" >> "$LOG"
  systemctl restart clawdbot
  
  if check_service_health "clawdbot" 18789 12; then
    HEALTHY=true
  fi
fi

if [ "$HEALTHY" = "true" ]; then
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
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Entering SAFE MODE" >> "$LOG"
  cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
  chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
  chmod 600 "$H/.openclaw/openclaw.json"
  touch /var/lib/init-status/safe-mode
  for si in $(seq 1 $AC); do
    cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<SAFEMD
# SAFE MODE - Full config failed health checks

The full openclaw config failed to start. You are running minimal config.

**Isolation mode:** $ISOLATION
**Groups:** $GROUPS

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
  systemctl restart clawdbot
  sleep 5
  rm -f /var/lib/init-status/needs-post-boot-check
  $TG "[SAFE MODE] ${HABITAT_NAME:-default} running minimal config. Full config failed (isolation=$ISOLATION). Check /var/log/post-boot-check.log" || true
fi
