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
systemctl restart clawdbot
HEALTHY=false
for i in $(seq 1 12); do
  sleep 5
  if ! systemctl is-active --quiet clawdbot; then
    continue
  fi
  if curl -sf http://127.0.0.1:18789/ >> "$LOG" 2>&1; then
    HEALTHY=true
    break
  fi
done
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
  $TG "[OK] ${HN}${HDOM} fully operational. Full config applied. All systems ready." || true
else
  cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
  chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
  chmod 600 "$H/.openclaw/openclaw.json"
  touch /var/lib/init-status/safe-mode
  for si in $(seq 1 $AC); do
  cat > "$H/clawd/agents/agent${si}/SAFE_MODE.md" <<'SAFEMD'
# SAFE MODE - Full config failed health checks
The full openclaw config failed to start. You are running minimal config.
Try: sudo /usr/local/bin/try-full-config.sh
Check: journalctl -u clawdbot -n 100
If that fails, check openclaw.full.json for errors.
SAFEMD
  chown $USERNAME:$USERNAME "$H/clawd/agents/agent${si}/SAFE_MODE.md"
done
  systemctl restart clawdbot
  sleep 5
  rm -f /var/lib/init-status/needs-post-boot-check
  $TG "[SAFE MODE] Running minimal config. Full config failed health checks. Bot is attempting repairs." || true
fi
