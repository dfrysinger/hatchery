#!/bin/bash
# =============================================================================
# generate-session-services.sh — Generate per-group systemd services
# =============================================================================
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
#             {group}/openclaw.session.json
#
# Env:      SESSION_OUTPUT_DIR  — output directory (default: /etc/systemd/system)
#           DRY_RUN             — if set, write to SESSION_OUTPUT_DIR only
#
# Original: scripts/generate-session-services.sh
# =============================================================================

set -euo pipefail

# --- Validate required inputs ---
if [ -z "${AGENT_COUNT:-}" ]; then
    echo "ERROR: AGENT_COUNT is required" >&2
    exit 1
fi

ISOLATION="${ISOLATION_DEFAULT:-none}"
ISO_GROUPS="${ISOLATION_GROUPS:-}"
SVC_USER="${USERNAME:-bot}"
HABITAT="${HABITAT_NAME:-default}"
SHARED="${ISOLATION_SHARED_PATHS:-}"
PLATFORM="${PLATFORM:-telegram}"
OUTPUT_DIR="${SESSION_OUTPUT_DIR:-/etc/systemd/system}"
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

HOME_DIR="/home/${SVC_USER}"

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
group_index=0
for group in "${SESSION_GROUPS[@]}"; do
    port=$((BASE_PORT + group_index))
    group_dir="${OUTPUT_DIR}/${group}"
    mkdir -p "$group_dir"

    # Collect agents for this group
    agent_list_json="["
    agent_count_in_group=0
    for i in $(seq 1 "$AGENT_COUNT"); do
        agent_group_var="AGENT${i}_ISOLATION_GROUP"
        agent_name_var="AGENT${i}_NAME"
        agent_model_var="AGENT${i}_MODEL"
        agent_group="${!agent_group_var:-}"
        agent_name="${!agent_name_var:-Agent${i}}"
        agent_model="${!agent_model_var:-anthropic/claude-opus-4-5}"

        if [ "$agent_group" = "$group" ]; then
            [ $agent_count_in_group -gt 0 ] && agent_list_json="${agent_list_json},"
            is_default="false"
            [ $agent_count_in_group -eq 0 ] && is_default="true"
            agent_list_json="${agent_list_json}{\"id\":\"agent${i}\",\"default\":${is_default},\"name\":\"${agent_name}\",\"model\":\"${agent_model}\",\"workspace\":\"${HOME_DIR}/clawd/agents/agent${i}\"}"
            agent_count_in_group=$((agent_count_in_group + 1))
        fi
    done
    agent_list_json="${agent_list_json}]"

    # Generate OpenClaw session config
    cat > "${group_dir}/openclaw.session.json" <<SESSIONCFG
{
  "gateway": {
    "mode": "local",
    "port": ${port},
    "bind": "lan",
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
  "plugins": {
    "entries": {
      "telegram": {"enabled": $([ "$PLATFORM" = "telegram" ] || [ "$PLATFORM" = "both" ] && echo true || echo false)},
      "discord": {"enabled": $([ "$PLATFORM" = "discord" ] || [ "$PLATFORM" = "both" ] && echo true || echo false)}
    }
  }
}
SESSIONCFG

    # Generate systemd service
    cat > "${OUTPUT_DIR}/openclaw-${group}.service" <<SVCFILE
[Unit]
Description=OpenClaw Session - ${group} (${HABITAT})
After=network.target desktop.service
Wants=desktop.service

[Service]
Type=simple
User=${SVC_USER}
WorkingDirectory=${HOME_DIR}
ExecStart=/usr/local/bin/openclaw gateway --config ${group_dir}/openclaw.session.json --bind lan --port ${port}
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--experimental-sqlite
Environment=PATH=/usr/bin:/usr/local/bin
Environment=DISPLAY=:10

[Install]
WantedBy=multi-user.target
SVCFILE

    echo "  [${group}] port=${port} agents=${agent_count_in_group} → openclaw-${group}.service"
    group_index=$((group_index + 1))
done

# Install services if not dry-run
if [ -z "${DRY_RUN:-}" ]; then
    echo "Installing systemd services..."
    for group in "${SESSION_GROUPS[@]}"; do
        cp "${OUTPUT_DIR}/openclaw-${group}.service" /etc/systemd/system/
    done
    systemctl daemon-reload
    for group in "${SESSION_GROUPS[@]}"; do
        systemctl enable "openclaw-${group}.service"
        systemctl start "openclaw-${group}.service"
    done
    echo "Session services started."
else
    echo "DRY_RUN mode — services written to ${OUTPUT_DIR}"
fi

echo "Generated ${#SESSION_GROUPS[@]} session service(s) for habitat '${HABITAT}'"
