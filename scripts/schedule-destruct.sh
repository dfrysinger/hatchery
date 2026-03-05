#!/bin/bash
# =============================================================================
# schedule-destruct.sh -- Schedule droplet self-destruction
# =============================================================================
# Creates persistent systemd timer/service that survives reboot.
# Uses OnBootSec so the countdown starts from (last) boot time.
# Safe to call during provisioning (before reboot).
#
# NOTE: OnBootSec counts from the SECOND boot (after cloud-init power_state
# reboots). Provisioning time (~7 min) does not count against the timer.
# For very short DESTRUCT_MINS values, the timer fires shortly after services
# come up on the second boot. This is intentional -- the destruct window
# starts when the droplet is usable, not when provisioning began.
#
# Inputs:   /etc/droplet.env, /etc/habitat-parsed.env (DESTRUCT_MINS)
# Outputs:  /etc/systemd/system/self-destruct.{service,timer}
# =============================================================================
set -euo pipefail

for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-env.sh" ] && { source "$_lib_path/lib-env.sh"; break; }
done
type d &>/dev/null || { echo "FATAL: lib-env.sh not found" >&2; exit 1; }
env_load

[ ! -f /etc/habitat-parsed.env ] && python3 /usr/local/bin/parse-habitat.py 2>/dev/null
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

M="${DESTRUCT_MINS:-0}"

if [ -z "$M" ] || [ "$M" = "0" ] || ! [ "$M" -gt 0 ] 2>/dev/null; then
  echo "[schedule-destruct] No destruct timer configured (DESTRUCT_MINS=${M:-unset})"
  exit 0
fi

echo "[schedule-destruct] Scheduling self-destruct in ${M} minutes after boot"

# Create persistent service unit
cat > /etc/systemd/system/self-destruct.service <<EOF
[Unit]
Description=Self-destruct droplet

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kill-droplet.sh
EOF

# Create persistent timer unit (OnBootSec counts from system boot)
cat > /etc/systemd/system/self-destruct.timer <<EOF
[Unit]
Description=Self-destruct timer (${M} minutes after boot)

[Timer]
OnBootSec=${M}m

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable self-destruct.timer 2>/dev/null || true

# Start only if systemd is fully operational (not during shutdown)
systemctl start self-destruct.timer 2>/dev/null \
  || echo "[schedule-destruct] Timer enabled but not started (will activate on next boot)"

echo "[schedule-destruct] Self-destruct timer set for ${M} minutes after boot"
