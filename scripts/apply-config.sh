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
    AGENT_LIB_B64=$(base64 -w0 /etc/agents.json)
    export AGENT_LIB_B64
    echo "Loaded agent library from /etc/agents.json ($(wc -c < /etc/agents.json) bytes)"
fi

# If habitat.json exists, export it as HABITAT_B64
if [ -f /etc/habitat.json ]; then
    HABITAT_B64=$(base64 -w0 /etc/habitat.json)
    export HABITAT_B64
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
/usr/local/sbin/build-full-config.sh
echo "build-full-config.sh complete"

# Rename Telegram bots to match config
echo "Renaming Telegram bots..."
/usr/local/bin/rename-bots.sh || echo "Warning: rename-bots.sh failed (non-fatal)"
echo "Bot renaming complete"

# Handle service restarts based on isolation mode
echo "Handling service restarts for isolation mode: ${ISOLATION_DEFAULT:-none}"
systemctl daemon-reload

case "${ISOLATION_DEFAULT:-none}" in
    session)
        echo "Session isolation mode - managing per-group services"
        # Stop the single clawdbot service if running
        systemctl stop clawdbot 2>/dev/null || true
        systemctl disable clawdbot 2>/dev/null || true
        
        # Start all openclaw-* group services
        for svc in /etc/systemd/system/openclaw-*.service; do
            [ -f "$svc" ] || continue
            svc_name=$(basename "$svc")
            echo "Starting $svc_name..."
            systemctl enable "$svc_name" 2>/dev/null || true
            systemctl restart "$svc_name"
        done
        ;;
    
    container)
        echo "Container isolation mode - managing docker-compose"
        # Stop the single clawdbot service if running
        systemctl stop clawdbot 2>/dev/null || true
        systemctl disable clawdbot 2>/dev/null || true
        
        # Start containers via docker-compose
        COMPOSE_FILE="/home/${USERNAME:-bot}/docker-compose.yaml"
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$(dirname "$COMPOSE_FILE")"
            docker-compose up -d
        else
            echo "WARNING: docker-compose.yaml not found at $COMPOSE_FILE"
        fi
        ;;
    
    *)
        echo "Standard mode - restarting clawdbot service"
        # Stop any isolation services that might be running
        for svc in /etc/systemd/system/openclaw-*.service; do
            [ -f "$svc" ] || continue
            svc_name=$(basename "$svc")
            systemctl stop "$svc_name" 2>/dev/null || true
            systemctl disable "$svc_name" 2>/dev/null || true
        done
        
        # Restart the single clawdbot service
        systemctl enable clawdbot 2>/dev/null || true
        systemctl restart clawdbot
        ;;
esac

# Wait a moment and check status
sleep 3
echo "Checking service status..."
case "${ISOLATION_DEFAULT:-none}" in
    session)
        for svc in /etc/systemd/system/openclaw-*.service; do
            [ -f "$svc" ] || continue
            svc_name=$(basename "$svc")
            if systemctl is-active --quiet "$svc_name"; then
                echo "  $svc_name: active"
            else
                echo "  $svc_name: INACTIVE"
                systemctl status "$svc_name" --no-pager 2>&1 | head -5 || true
            fi
        done
        ;;
    container)
        docker-compose ps 2>/dev/null || echo "docker-compose status unavailable"
        ;;
    *)
        if systemctl is-active --quiet clawdbot; then
            echo "clawdbot service is active"
        else
            echo "WARNING: clawdbot service may not be active"
            systemctl status clawdbot --no-pager || true
        fi
        ;;
esac

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Config apply complete"
echo "========================================"
