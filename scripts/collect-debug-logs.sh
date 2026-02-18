#!/bin/bash
# collect-debug-logs.sh - Collect all relevant logs for debugging
# Usage: collect-debug-logs.sh [output_file]
#
# Collects:
# - Health check logs (all groups)
# - Safe mode recovery logs
# - Systemd journal entries
# - Init status files
# - OpenClaw service status

set -e

OUTPUT="${1:-/tmp/habitat-debug-$(date +%Y%m%d-%H%M%S).txt}"

{
  echo "=========================================="
  echo "HABITAT DEBUG LOG COLLECTION"
  echo "=========================================="
  echo "Collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Hostname: $(hostname)"
  echo ""

  # Init status files
  echo "=== Init Status Files ==="
  for f in /var/lib/init-status/*; do
    [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f" 2>/dev/null || echo '(empty)')"
  done
  echo ""

  # OpenClaw service status
  echo "=== OpenClaw Service Status ==="
  systemctl list-units 'openclaw*' --all --no-pager 2>/dev/null || true
  echo ""

  # Health check logs (all groups)
  echo "=== Health Check Logs ==="
  for logfile in /var/log/gateway-health-check*.log; do
    if [ -f "$logfile" ]; then
      echo ""
      echo "--- $logfile ---"
      cat "$logfile" 2>/dev/null || echo "(could not read)"
    fi
  done
  echo ""

  # Safe mode recovery log
  echo "=== Safe Mode Recovery Log ==="
  if [ -f /var/log/safe-mode-recovery.log ]; then
    cat /var/log/safe-mode-recovery.log 2>/dev/null || echo "(could not read)"
  else
    echo "(not found)"
  fi
  echo ""

  # Safe mode diagnostics
  echo "=== Safe Mode Diagnostics ==="
  if [ -f /var/log/safe-mode-diagnostics.txt ]; then
    cat /var/log/safe-mode-diagnostics.txt 2>/dev/null || echo "(could not read)"
  else
    echo "(not found)"
  fi
  echo ""

  # Init stages
  echo "=== Init Stages ==="
  if [ -f /var/log/init-stages.log ]; then
    cat /var/log/init-stages.log 2>/dev/null || echo "(could not read)"
  else
    echo "(not found)"
  fi
  echo ""

  # Journald entries for health check
  echo "=== Journald: Health Check (last 100 entries) ==="
  journalctl -t health-check -t health-check-browser -t health-check-documents --no-pager -n 100 2>/dev/null || echo "(no entries)"
  echo ""

  # Journald entries for openclaw services
  echo "=== Journald: OpenClaw Services (last 50 entries each) ==="
  for svc in clawdbot openclaw openclaw-browser openclaw-documents; do
    if systemctl list-units --all | grep -q "$svc"; then
      echo ""
      echo "--- $svc ---"
      journalctl -u "$svc" --no-pager -n 50 2>/dev/null || echo "(no entries)"
    fi
  done
  echo ""

  # Config files (sanitized - no tokens)
  echo "=== Config Files (structure only) ==="
  for cfg in /home/*/.openclaw/openclaw.json /home/*/.openclaw-sessions/*/openclaw.session.json; do
    if [ -f "$cfg" ]; then
      echo ""
      echo "--- $cfg ---"
      jq 'del(.channels[][].token, .channels[][].botToken, .channels[].token, .channels[].botToken, .env)' "$cfg" 2>/dev/null || echo "(could not parse)"
    fi
  done
  echo ""

  echo "=========================================="
  echo "END OF DEBUG LOG COLLECTION"
  echo "=========================================="

} > "$OUTPUT" 2>&1

echo "Debug logs collected to: $OUTPUT"
echo "Upload with: rclone copy '$OUTPUT' dropbox:Droplets/Debug/"
