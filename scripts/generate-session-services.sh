#!/bin/bash
# =============================================================================
# generate-session-services.sh — Generate per-group systemd services
# =============================================================================

# Source permission utilities
[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh
# Purpose:  For session isolation mode, generates one systemd service per
#           isolation group, each running its own OpenClaw gateway instance
#           on a unique port with only that group's agents.
#
# Inputs:   Environment variables from habitat-parsed.env:
#             ISOLATION_DEFAULT  — must be "session" to generate services
#             ISOLATION_GROUPS   — comma-separated list of group names
#             AGENT_COUNT        — number of agents
#             AGENT{N}_NAME, AGENT{N}_ISOLATION_GROUP, AGENT{N}_ISOLATION,
#             AGENT{N}_MODEL, AGENT{N}_BOT_TOKEN, AGENT{N}_NETWORK
#             USERNAME           — system user
#             HABITAT_NAME       — habitat name
#             ISOLATION_SHARED_PATHS — comma-separated shared paths
#             PLATFORM           — telegram/discord/both
#
# Outputs:  Per-group systemd service files and OpenClaw configs
#             openclaw-{group}.service
#             ~/.openclaw/configs/{group}/openclaw.session.json
#
# Env:      SESSION_OUTPUT_DIR  — output directory (default: /etc/systemd/system)
#           DRY_RUN             — if set, write to SESSION_OUTPUT_DIR only
#
# Original: scripts/generate-session-services.sh
# =============================================================================

set -euo pipefail

# --- Source environment files (may be called standalone or from another script) ---
[ -r /etc/droplet.env ] && source /etc/droplet.env || true
[ -r /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env || true

# --- Validate required inputs ---
if [ -z "${AGENT_COUNT:-}" ]; then
    echo "ERROR: AGENT_COUNT is required" >&2
    exit 1
fi

ISOLATION="${ISOLATION_DEFAULT:-none}"
ISO_GROUPS="${ISOLATION_GROUPS:-}"
SVC_USER="${USERNAME:-bot}"
HOME_DIR="${HOME_DIR:-/home/${SVC_USER}}"
HABITAT="${HABITAT_NAME:-default}"
# shellcheck disable=SC2034  # Reserved for future shared path mounting
SHARED="${ISOLATION_SHARED_PATHS:-}"
PLATFORM="${PLATFORM:-telegram}"
OUTPUT_DIR="${SESSION_OUTPUT_DIR:-/etc/systemd/system}"
# Config files go in bot-owned space (not /etc/systemd/system/) so OpenClaw
# can persist changes (atomic writes, auto-enable plugins) without root.
CONFIG_BASE="${HOME_DIR}/.openclaw/configs"
BASE_PORT=18790

# --- Skip if not session mode or no groups ---
if [ "$ISOLATION" != "session" ]; then
    echo "Isolation mode is '$ISOLATION' — no session services needed."
    exit 0
fi

if [ -z "$ISO_GROUPS" ]; then
    echo "No isolation groups defined — no session services needed."
    exit 0
fi

# HOME_DIR can be overridden for testing
HOME_DIR="${HOME_DIR:-/home/${SVC_USER}}"

# --- Filter groups: only generate services for session-mode groups ---
IFS=',' read -ra ALL_GROUPS <<< "$ISO_GROUPS"

# Determine which groups should get session services
# A group gets a session service if:
#   1. The default isolation is session, OR
#   2. At least one agent in the group has isolation=session
SESSION_GROUPS=()
for group in "${ALL_GROUPS[@]}"; do
    is_session=false
    for i in $(seq 1 "$AGENT_COUNT"); do
        agent_group_var="AGENT${i}_ISOLATION_GROUP"
        agent_iso_var="AGENT${i}_ISOLATION"
        agent_group="${!agent_group_var:-}"
        agent_iso="${!agent_iso_var:-}"

        if [ "$agent_group" = "$group" ]; then
            # Agent explicitly set to container? Skip this group for session
            if [ "$agent_iso" = "container" ]; then
                continue
            fi
            # Agent explicitly set to session, or inherits session default
            if [ "$agent_iso" = "session" ] || [ -z "$agent_iso" ]; then
                is_session=true
            fi
        fi
    done
    if [ "$is_session" = true ]; then
        SESSION_GROUPS+=("$group")
    fi
done

if [ ${#SESSION_GROUPS[@]} -eq 0 ]; then
    echo "No session-mode groups found — no session services needed."
    exit 0
fi

mkdir -p "$OUTPUT_DIR"

echo "Generating session services for ${#SESSION_GROUPS[@]} group(s)..."

# --- Generate per-group service and config ---
# Ensure parent state directory exists and is owned by service user
STATE_BASE="${HOME_DIR}/.openclaw-sessions"
if type ensure_bot_dir &>/dev/null; then
  ensure_bot_dir "$STATE_BASE" 700
else
  mkdir -p "$STATE_BASE"
  [ -z "${DRY_RUN:-}" ] && chown "${SVC_USER}:${SVC_USER}" "$STATE_BASE" && chmod 700 "$STATE_BASE"
fi

group_index=0
for group in "${SESSION_GROUPS[@]}"; do
    port=$((BASE_PORT + group_index))
    config_dir="${CONFIG_BASE}/${group}"
    state_dir="${STATE_BASE}/${group}"
    
    # Create directories with proper ownership
    # Config dir is under ~/.openclaw/ so bot owns it naturally
    if type ensure_bot_dir &>/dev/null; then
      ensure_bot_dir "$state_dir" 700
      ensure_bot_dir "$config_dir" 700
    else
      mkdir -p "$config_dir" "$state_dir"
      if [ -z "${DRY_RUN:-}" ]; then
        chown -R "${SVC_USER}:${SVC_USER}" "$state_dir" && chmod 700 "$state_dir"
        chown "${SVC_USER}:${SVC_USER}" "$config_dir" && chmod 700 "$config_dir"
      fi
    fi

    # Collect agents for this group
    agent_list_json="["
    telegram_accounts_json=""
    discord_accounts_json=""
    bindings_json=""
    agent_count_in_group=0
    
    for i in $(seq 1 "$AGENT_COUNT"); do
        agent_group_var="AGENT${i}_ISOLATION_GROUP"
        agent_name_var="AGENT${i}_NAME"
        agent_model_var="AGENT${i}_MODEL"
        agent_bot_token_var="AGENT${i}_BOT_TOKEN"
        agent_dc_token_var="AGENT${i}_DISCORD_TOKEN"
        
        agent_group="${!agent_group_var:-}"
        agent_name="${!agent_name_var:-Agent${i}}"
        agent_model="${!agent_model_var:-anthropic/claude-opus-4-5}"
        agent_bot_token="${!agent_bot_token_var:-}"
        agent_dc_token="${!agent_dc_token_var:-}"

        if [ "$agent_group" = "$group" ]; then
            [ $agent_count_in_group -gt 0 ] && agent_list_json="${agent_list_json},"
            is_default="false"
            [ $agent_count_in_group -eq 0 ] && is_default="true"
            # Don't set agentDir - rely on OPENCLAW_STATE_DIR env var instead
            # agentDir in config causes session path validation issues
            agent_list_json="${agent_list_json}{\"id\":\"agent${i}\",\"default\":${is_default},\"name\":\"${agent_name}\",\"model\":\"${agent_model}\",\"workspace\":\"${HOME_DIR}/clawd/agents/agent${i}\"}"
            
            # Create agent directory structure (OpenClaw will create sessions/ inside)
            if type ensure_bot_dir &>/dev/null; then
              ensure_bot_dir "${state_dir}/agents/agent${i}/agent" 700
            else
              mkdir -p "${state_dir}/agents/agent${i}/agent"
            fi
            
            # Copy auth-profiles.json from main agent directory if it exists
            main_auth="${HOME_DIR}/.openclaw/agents/agent${i}/agent/auth-profiles.json"
            session_auth="${state_dir}/agents/agent${i}/agent/auth-profiles.json"
            if [ -f "$main_auth" ]; then
                cp "$main_auth" "$session_auth"
                echo "  [agent${i}] Copied auth-profiles.json from main agent dir"
            else
                echo "  [agent${i}] WARNING: No auth-profiles.json found at $main_auth"
            fi
            
            # Fix ownership
            if type fix_session_state &>/dev/null && [ -z "${DRY_RUN:-}" ]; then
              chown -R "${SVC_USER}:${SVC_USER}" "${state_dir}/agents/agent${i}" 2>/dev/null || true
              [ -f "$session_auth" ] && chmod 600 "$session_auth"
            elif [ -z "${DRY_RUN:-}" ]; then
              chown -R "${SVC_USER}:${SVC_USER}" "${state_dir}/agents/agent${i}"
            fi
            
            # Build Telegram account for this agent
            if [ -n "$agent_bot_token" ]; then
                [ -n "$telegram_accounts_json" ] && telegram_accounts_json="${telegram_accounts_json},"
                telegram_accounts_json="${telegram_accounts_json}\"agent${i}\":{\"name\":\"${agent_name}\",\"botToken\":\"${agent_bot_token}\"}"
                
                # Build binding for this agent
                [ -n "$bindings_json" ] && bindings_json="${bindings_json},"
                bindings_json="${bindings_json}{\"agentId\":\"agent${i}\",\"match\":{\"channel\":\"telegram\",\"accountId\":\"agent${i}\"}}"
            fi
            
            # Build Discord account for this agent
            if [ -n "$agent_dc_token" ]; then
                [ -n "$discord_accounts_json" ] && discord_accounts_json="${discord_accounts_json},"
                discord_accounts_json="${discord_accounts_json}\"agent${i}\":{\"name\":\"${agent_name}\",\"botToken\":\"${agent_dc_token}\"}"
                
                # Build Discord binding (always add comma if bindings already exist)
                [ -n "$bindings_json" ] && bindings_json="${bindings_json},"
                bindings_json="${bindings_json}{\"agentId\":\"agent${i}\",\"match\":{\"channel\":\"discord\",\"accountId\":\"agent${i}\"}}"
            fi
            
            agent_count_in_group=$((agent_count_in_group + 1))
        fi
    done
    agent_list_json="${agent_list_json}]"

    # Get owner IDs (from habitat-parsed.env)
    telegram_owner_id="${TELEGRAM_OWNER_ID:-}"
    discord_owner_id="${DISCORD_OWNER_ID:-}"

    # Generate OpenClaw session config
    cat > "${config_dir}/openclaw.session.json" <<SESSIONCFG
{
  "gateway": {
    "mode": "local",
    "port": ${port},
    "bind": "loopback",
    "controlUi": {"enabled": true, "allowInsecureAuth": true},
    "auth": {"mode": "token", "token": "$(openssl rand -hex 16)"}
  },
  "agents": {
    "defaults": {
      "model": {"primary": "anthropic/claude-opus-4-5"},
      "maxConcurrent": 4,
      "workspace": "${HOME_DIR}/clawd"
    },
    "list": ${agent_list_json}
  },
  "channels": {
    "telegram": {
      "enabled": $([ "$PLATFORM" = "telegram" ] || [ "$PLATFORM" = "both" ] && echo true || echo false),
      "dmPolicy": "allowlist",
      "allowFrom": ["${telegram_owner_id}"],
      "accounts": {${telegram_accounts_json}}
    },
    "discord": {
      "enabled": $([ "$PLATFORM" = "discord" ] || [ "$PLATFORM" = "both" ] && echo true || echo false),
      "groupPolicy": "allowlist",
      "dm": {"enabled": true, "policy": "allowlist", "allowFrom": ["${discord_owner_id}"]},
      "accounts": {${discord_accounts_json}}
    }
  },
  "bindings": [${bindings_json}],
  "plugins": {
    "entries": {
      "telegram": {"enabled": $([ "$PLATFORM" = "telegram" ] || [ "$PLATFORM" = "both" ] && echo true || echo false)},
      "discord": {"enabled": $([ "$PLATFORM" = "discord" ] || [ "$PLATFORM" = "both" ] && echo true || echo false)}
    }
  }
}
SESSIONCFG
    # Secure config file — bot-owned, read/write only by owner
    chown "${SVC_USER}:${SVC_USER}" "${config_dir}/openclaw.session.json" 2>/dev/null || true
    chmod 600 "${config_dir}/openclaw.session.json" 2>/dev/null || true
    
    # Final ownership fix for entire state tree (ensure all subdirs are accessible)
    if [ -z "${DRY_RUN:-}" ]; then
        if type fix_session_state &>/dev/null; then
          fix_session_state "${state_dir}"
        else
          chown -R "${SVC_USER}:${SVC_USER}" "${state_dir}"
          chmod -R u+rwX "${state_dir}"
        fi
        echo "  [${group}] state_dir permissions:"
        ls -la "${state_dir}" 2>&1 | head -5
    fi

    # Generate systemd service
    # Note: Health check derives agents from habitat-parsed.env using GROUP name
    cat > "${OUTPUT_DIR}/openclaw-${group}.service" <<SVCFILE
[Unit]
Description=OpenClaw Session - ${group} (${HABITAT})
After=network.target desktop.service
Wants=desktop.service

[Service]
Type=simple
User=${SVC_USER}
WorkingDirectory=${HOME_DIR}
ExecStart=/usr/local/bin/openclaw gateway --bind loopback --port ${port}
ExecStartPost=+/bin/bash -c 'GROUP=${group} GROUP_PORT=${port} RUN_MODE=execstartpost /usr/local/bin/gateway-health-check.sh'
# on-failure (not always): clean exit 0 means intentional shutdown (e.g., config reload),
# exit 2 is excluded via RestartPreventExitStatus to allow permanent stop on fatal errors.
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=2
TimeoutStartSec=420
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--experimental-sqlite
Environment=PATH=/usr/bin:/usr/local/bin
Environment=DISPLAY=:10
Environment=OPENCLAW_CONFIG_PATH=${config_dir}/openclaw.session.json
Environment=OPENCLAW_STATE_DIR=${state_dir}
Environment=ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
Environment=GOOGLE_API_KEY=${GOOGLE_API_KEY:-}
Environment=BRAVE_API_KEY=${BRAVE_API_KEY:-}

[Install]
WantedBy=multi-user.target
SVCFILE

    # Generate safeguard .path unit (watches for unhealthy marker)
    cat > "${OUTPUT_DIR}/openclaw-safeguard-${group}.path" <<PATHFILE
[Unit]
Description=Watch for unhealthy marker - ${group}

[Path]
PathExists=/var/lib/init-status/unhealthy-${group}
# Only trigger once per marker creation
MakeDirectory=no

[Install]
WantedBy=multi-user.target
PATHFILE

    # Generate safeguard .service unit (runs recovery)
    cat > "${OUTPUT_DIR}/openclaw-safeguard-${group}.service" <<SGFILE
[Unit]
Description=Safe mode handler - ${group}
After=openclaw-${group}.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/safe-mode-handler.sh
Environment=GROUP=${group}
Environment=GROUP_PORT=${port}
Environment=RUN_MODE=path-triggered
SGFILE

    echo "  [${group}] port=${port} agents=${agent_count_in_group} → openclaw-${group}.service"
    group_index=$((group_index + 1))
done

# Install services if not dry-run
if [ -z "${DRY_RUN:-}" ]; then
    echo "Installing systemd services..."
    # Only copy if OUTPUT_DIR is not already /etc/systemd/system
    if [ "$OUTPUT_DIR" != "/etc/systemd/system" ]; then
        for group in "${SESSION_GROUPS[@]}"; do
            cp "${OUTPUT_DIR}/openclaw-${group}.service" /etc/systemd/system/
        done
    fi
    systemctl daemon-reload
    
    # Stop main openclaw service - session isolation replaces it
    echo "Stopping main openclaw service (replaced by session services)..."
    systemctl stop openclaw 2>/dev/null || true
    systemctl disable openclaw 2>/dev/null || true
    
    # Check if boot is complete - only START services after boot finishes
    # During initial boot, just ENABLE them; they'll auto-start after reboot
    boot_complete=false
    [ -f /var/lib/init-status/boot-complete ] && boot_complete=true
    
    for group in "${SESSION_GROUPS[@]}"; do
        systemctl enable "openclaw-${group}.service"
        systemctl enable "openclaw-safeguard-${group}.path" 2>/dev/null || true
        
        if [ "$boot_complete" = "true" ]; then
            # Boot complete - this is a config update, start services now
            systemctl start "openclaw-${group}.service" || {
                echo "  [${group}] Service start returned non-zero (health check may have triggered safe mode)"
                echo "  [${group}] Service will restart automatically via systemd"
            }
            systemctl start "openclaw-safeguard-${group}.path" 2>/dev/null || true
        else
            echo "  [${group}] Boot not complete - service enabled but not started (will start after reboot)"
        fi
    done
    
    if [ "$boot_complete" = "true" ]; then
        echo "Session services started (or pending health check restart)."
    else
        echo "Session services enabled (will start automatically after reboot)."
    fi
else
    echo "DRY_RUN mode — services written to ${OUTPUT_DIR}"
fi

echo "Generated ${#SESSION_GROUPS[@]} session service(s) for habitat '${HABITAT}'"
