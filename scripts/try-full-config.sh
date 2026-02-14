#!/bin/bash
# =============================================================================
# try-full-config.sh -- Manually attempt switch to full openclaw config
# =============================================================================
# Purpose:  Interactive tool to switch from minimal/safe-mode config to full
#           config. Validates health and rolls back on failure.
#
# Inputs:   /etc/droplet.env -- secrets and config
#           /etc/habitat-parsed.env -- parsed habitat config
#           $HOME/.openclaw/openclaw.full.json -- full config to try
#
# Outputs:  Removes SAFE_MODE.md and safe-mode marker on success
#           Restores minimal config on failure
#
# Dependencies: systemctl, curl
#
# Original: /usr/local/bin/try-full-config.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
echo "Attempting full config at $(date)"
cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
chmod 600 "$H/.openclaw/openclaw.json"
systemctl restart clawdbot
HEALTHY=false
for _ in $(seq 1 12); do
  sleep 5
  if systemctl is-active --quiet clawdbot; then
    if curl -sf http://127.0.0.1:18789/ >/dev/null 2>&1; then
      HEALTHY=true
      break
    fi
  fi
done
if [ "$HEALTHY" = "true" ]; then
  for si in $(seq 1 $AC); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
  rm -f /var/lib/init-status/safe-mode
  echo "SUCCESS: Full config now active"
  exit 0
else
  cp "$H/.openclaw/openclaw.minimal.json" "$H/.openclaw/openclaw.json"
  chown $USERNAME:$USERNAME "$H/.openclaw/openclaw.json"
  chmod 600 "$H/.openclaw/openclaw.json"
  systemctl restart clawdbot
  echo "FAILED: Restored minimal config. Check logs: journalctl -u clawdbot"
  exit 1
fi
