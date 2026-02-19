#!/bin/bash
# =============================================================================
# try-full-config.sh -- Manually attempt switch to full openclaw config
# =============================================================================
# Purpose:  Interactive tool to switch from minimal/safe-mode config to full
#           config. Validates health and rolls back on failure.
#           Supports both standard and session isolation modes.
#
# Inputs:   /etc/droplet.env -- secrets and config
#           /etc/habitat-parsed.env -- parsed habitat config
#
# Outputs:  Removes SAFE_MODE.md and safe-mode marker on success
#           Restores minimal config on failure
#
# Dependencies: systemctl, curl, lib-auth.sh (optional, for resolve_config_path)
#
# Original: /usr/local/bin/try-full-config.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
[ -f /usr/local/sbin/lib-auth.sh ] && source /usr/local/sbin/lib-auth.sh

AC=${AGENT_COUNT:-1}
H="/home/$USERNAME"
ISOLATION="${ISOLATION_DEFAULT:-none}"

echo "Attempting full config at $(date)"
echo "  Isolation mode: $ISOLATION"

if [ "$ISOLATION" = "session" ]; then
  # Session isolation: each group has its own service and config
  GROUPS_STR="${ISOLATION_GROUPS:-}"
  if [ -z "$GROUPS_STR" ]; then
    echo "ERROR: Session isolation mode but ISOLATION_GROUPS not set"
    exit 1
  fi

  IFS=',' read -ra GROUP_ARRAY <<< "$GROUPS_STR"
  ALL_HEALTHY=true

  for group in "${GROUP_ARRAY[@]}"; do
    service="openclaw-${group}.service"
    config_dir="$H/.openclaw-sessions/${group}"
    config_path="${config_dir}/openclaw.session.json"
    full_config="${config_dir}/openclaw.session.full.json"
    minimal_config="${config_dir}/openclaw.session.minimal.json"
    # Determine port for this group (base 18790, offset by group index)
    group_idx=0
    for g in "${GROUP_ARRAY[@]}"; do
      [ "$g" = "$group" ] && break
      group_idx=$((group_idx + 1))
    done
    port=$((18790 + group_idx))

    echo "  Group: $group (service=$service port=$port)"

    if [ ! -f "$full_config" ]; then
      echo "  SKIP: No full config at $full_config"
      continue
    fi

    cp "$full_config" "$config_path"
    chown "$USERNAME:$USERNAME" "$config_path"
    chmod 600 "$config_path"
    systemctl restart "$service"

    HEALTHY=false
    for _ in $(seq 1 12); do
      sleep 5
      if systemctl is-active --quiet "$service"; then
        if curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
          HEALTHY=true
          break
        fi
      fi
    done

    if [ "$HEALTHY" = "true" ]; then
      echo "  ✅ $group healthy"
    else
      echo "  ❌ $group failed — rolling back"
      ALL_HEALTHY=false
      if [ -f "$minimal_config" ]; then
        cp "$minimal_config" "$config_path"
        chown "$USERNAME:$USERNAME" "$config_path"
        chmod 600 "$config_path"
        systemctl restart "$service"
      fi
    fi
  done

  if [ "$ALL_HEALTHY" = "true" ]; then
    for si in $(seq 1 $AC); do rm -f "$H/clawd/agents/agent${si}/SAFE_MODE.md"; done
    rm -f /var/lib/init-status/safe-mode
    echo "SUCCESS: Full config now active (all groups)"
    exit 0
  else
    echo "FAILED: Some groups rolled back. Check logs: journalctl -u 'openclaw-*'"
    exit 1
  fi

else
  # Standard mode: single service
  cp "$H/.openclaw/openclaw.full.json" "$H/.openclaw/openclaw.json"
  chown "$USERNAME:$USERNAME" "$H/.openclaw/openclaw.json"
  chmod 600 "$H/.openclaw/openclaw.json"
  systemctl restart openclaw

  HEALTHY=false
  for _ in $(seq 1 12); do
    sleep 5
    if systemctl is-active --quiet openclaw; then
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
    chown "$USERNAME:$USERNAME" "$H/.openclaw/openclaw.json"
    chmod 600 "$H/.openclaw/openclaw.json"
    systemctl restart openclaw
    echo "FAILED: Restored minimal config. Check logs: journalctl -u openclaw"
    exit 1
  fi
fi
