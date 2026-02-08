#!/bin/bash
# =============================================================================
# apply-config.sh -- Apply uploaded config and restart OpenClaw
# =============================================================================
# Purpose:  Reads /etc/habitat.json and /etc/agents.json (if they exist),
#           exports them as base64 env vars, re-runs parse-habitat.py and
#           build-full-config.sh, then restarts the clawdbot service.
#
# Called by: api-server.py POST /config/apply or /config/upload with apply=true
#
# Outputs:  /var/log/apply-config.log
#
# Original: /usr/local/bin/apply-config.sh (in hatch.yaml write_files)
# =============================================================================
set -e

LOG=/var/log/apply-config.log
exec >> "$LOG" 2>&1

echo "========================================"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Starting config apply"
echo "========================================"

# Source base environment
if [ -f /etc/droplet.env ]; then
    source /etc/droplet.env
    echo "Loaded /etc/droplet.env"
fi

# Source existing habitat-parsed.env if it exists (for backward compat)
if [ -f /etc/habitat-parsed.env ]; then
    source /etc/habitat-parsed.env
    echo "Loaded existing /etc/habitat-parsed.env"
fi

# If agents.json exists, export it as AGENT_LIB_B64
if [ -f /etc/agents.json ]; then
    export AGENT_LIB_B64=$(base64 -w0 /etc/agents.json)
    echo "Loaded agent library from /etc/agents.json ($(wc -c < /etc/agents.json) bytes)"
fi

# If habitat.json exists, export it as HABITAT_B64
if [ -f /etc/habitat.json ]; then
    export HABITAT_B64=$(base64 -w0 /etc/habitat.json)
    echo "Loaded habitat config from /etc/habitat.json ($(wc -c < /etc/habitat.json) bytes)"
fi

# Verify we have a habitat config
if [ -z "$HABITAT_B64" ]; then
    echo "ERROR: No HABITAT_B64 available (no /etc/habitat.json and no env var)"
    exit 1
fi

# Re-run parse-habitat to update /etc/habitat-parsed.env
echo "Running parse-habitat.py..."
python3 /usr/local/bin/parse-habitat.py
echo "parse-habitat.py complete"

# Source the newly generated env
source /etc/habitat-parsed.env
echo "Loaded updated /etc/habitat-parsed.env"

# Re-run build-full-config to regenerate OpenClaw config
echo "Running build-full-config.sh..."
/usr/local/bin/build-full-config.sh
echo "build-full-config.sh complete"

# Restart clawdbot service
echo "Restarting clawdbot service..."
systemctl restart clawdbot

# Wait a moment and check status
sleep 3
if systemctl is-active --quiet clawdbot; then
    echo "clawdbot service is active"
else
    echo "WARNING: clawdbot service may not be active"
    systemctl status clawdbot --no-pager || true
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Config apply complete"
echo "========================================"
