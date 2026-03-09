#!/bin/bash
# =============================================================================
# generate-session-services.sh — Generate per-group systemd service units
# =============================================================================
# Generates systemd .service files, session config JSON, and state directories
# for each session isolation group.
#
# Two modes:
#   Manifest mode: MANIFEST is set and points to a valid openclaw-groups.json.
#     Uses manifest for ports, config paths, state paths, and env files.
#   Fallback mode: MANIFEST not set or absent.
#     Derives configuration from AGENT*_ISOLATION_GROUP env vars.
#     Creates config JSON and state directories itself.
#
# Inputs:
#   MANIFEST         — path to /etc/openclaw-groups.json (manifest mode)
#   ISOLATION_GROUPS — comma-separated list of session groups to generate
#   ISOLATION_DEFAULT — must be "session" for this generator
#   USERNAME / SVC_USER — system user running the gateway
#   HOME_DIR         — home directory
#   HABITAT_NAME     — habitat name (for unit descriptions)
#   AGENT_COUNT      — number of agents (fallback mode)
#   AGENT{n}_*       — per-agent vars (fallback mode)
#   ANTHROPIC_API_KEY — API key (embedded in service env)
#
# Outputs:
#   ${OUTPUT_DIR}/openclaw-{group}.service — one systemd unit per group
#   ${OUTPUT_DIR}/{group}/openclaw.session.json — session config (fallback)
#   ${HOME_DIR}/.openclaw-sessions/{group}/agents/agent{n}/agent — state dirs
#
# Env:
#   SESSION_OUTPUT_DIR — output directory (default: /etc/systemd/system)
#   DRY_RUN            — if set, write units only (no systemctl)
#   START_SERVICES     — if "true", also start services after enabling
# =============================================================================
set -euo pipefail
umask 022

# --- Source lib-isolation for manifest reading (optional) ---
for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-isolation.sh" ] && { source "$_lib_path/lib-isolation.sh"; break; }
done

# --- Configuration ---
export ISOLATION="${ISOLATION_DEFAULT:-none}"
ISO_GROUPS="${ISOLATION_GROUPS:-}"
SVC_USER="${SVC_USER:-${USERNAME:-bot}}"
HOME_DIR="${HOME_DIR:-/home/${SVC_USER}}"
HABITAT="${HABITAT_NAME:-default}"
OUTPUT_DIR="${SESSION_OUTPUT_DIR:-/etc/systemd/system}"

# --- Skip if no groups ---
# NOTE: Do NOT gate on ISOLATION_DEFAULT here. In mixed-mode habitats,
# ISOLATION_DEFAULT may be "container" but some groups use "session".
# The caller (build-full-config.sh) pre-filters and only passes session
# groups via ISOLATION_GROUPS. Trust the caller.

if [ -z "$ISO_GROUPS" ]; then
    echo "No isolation groups defined — no session services needed."
    exit 0
fi

IFS=',' read -ra SESSION_GROUPS <<< "$ISO_GROUPS"

if [ ${#SESSION_GROUPS[@]} -eq 0 ]; then
    echo "No session groups — nothing to do."
    exit 0
fi

echo "Generating session services for ${#SESSION_GROUPS[@]} group(s)..."

# --- Compute port for a group ---
# BASE_PORT=18790; first group gets 18790, second gets 18791, etc.
_get_port_for_group() {
  local target_group="$1"
  # Manifest mode: try to read from manifest
  if type get_group_port &>/dev/null && [ -n "${MANIFEST:-}" ] && [ -f "${MANIFEST}" ]; then
    local mp
    mp=$(get_group_port "$target_group")
    [ -n "$mp" ] && { echo "$mp"; return; }
  fi
  # Fallback: compute from position in SESSION_GROUPS array (BASE_PORT=18790)
  local idx=0
  for _g in "${SESSION_GROUPS[@]}"; do
    [ "$_g" = "$target_group" ] && { echo $((18790 + idx)); return; }
    idx=$((idx + 1))
  done
  echo "18790"
}

# --- Build session config JSON from AGENT* env vars ---
_build_group_config() {
  local group="$1"
  local port="$2"
  local ac="${AGENT_COUNT:-1}"
  local platform="${PLATFORM:-telegram}"
  local agents_json="[]"
  local tg_accounts="{}"
  local dc_accounts="{}"

  for i in $(seq 1 "$ac"); do
    local grp_var="AGENT${i}_ISOLATION_GROUP"
    local agent_grp="${!grp_var:-}"
    [ "$agent_grp" = "$group" ] || continue

    local name_var="AGENT${i}_NAME"
    local model_var="AGENT${i}_MODEL"
    local agent_name="${!name_var:-agent${i}}"
    local agent_model="${!model_var:-anthropic/claude-opus-4-5}"
    local agent_ws="${HOME_DIR}/.openclaw-sessions/${group}/agents/agent${i}"

    agents_json=$(echo "$agents_json" | jq \
      --arg id "agent${i}" \
      --arg name "$agent_name" \
      --arg model "$agent_model" \
      --arg ws "$agent_ws" \
      '. + [{"id":$id,"name":$name,"model":{"primary":$model},"workspace":$ws}]')

    case "$platform" in
      telegram|both)
        local tok_var="AGENT${i}_BOT_TOKEN"
        local tok="${!tok_var:-}"
        if [ -n "$tok" ]; then
          local oid="${TELEGRAM_OWNER_ID:-}"
          tg_accounts=$(echo "$tg_accounts" | jq \
            --arg id "agent${i}" --arg tok "$tok" --arg oid "$oid" \
            '. + {($id):{"botToken":$tok,"dmPolicy":"allowlist","allowFrom":[$oid]}}')
        fi
        ;;
    esac

    case "$platform" in
      discord|both)
        local dc_var="AGENT${i}_DISCORD_BOT_TOKEN"
        local dtok="${!dc_var:-}"
        if [ -n "$dtok" ]; then
          dc_accounts=$(echo "$dc_accounts" | jq \
            --arg id "agent${i}" --arg tok "$dtok" \
            '. + {($id):{"token":$tok}}')
        fi
        ;;
    esac
  done

  local tg_channel dc_channel
  case "$platform" in
    telegram|both)
      local oid="${TELEGRAM_OWNER_ID:-}"
      tg_channel=$(jq -n \
        --argjson accts "$tg_accounts" --arg oid "$oid" \
        '{"enabled":true,"dmPolicy":"allowlist","allowFrom":[$oid],"accounts":$accts}')
      ;;
    *) tg_channel='{"enabled":false}' ;;
  esac

  case "$platform" in
    discord|both)
      dc_channel=$(jq -n \
        --argjson accts "$dc_accounts" \
        '{"enabled":true,"accounts":$accts}')
      ;;
    *) dc_channel='{"enabled":false}' ;;
  esac

  jq -n \
    --argjson agents "$agents_json" \
    --argjson tg "$tg_channel" \
    --argjson dc "$dc_channel" \
    --argjson port "$port" \
    '{
      "agents": {"list": $agents},
      "gateway": {"mode": "local", "port": $port, "bind": "loopback"},
      "channels": {"telegram": $tg, "discord": $dc}
    }'
}

# --- Generate systemd .service per group ---
for group in "${SESSION_GROUPS[@]}"; do
    port=$(_get_port_for_group "$group")

    # Determine config/state/env paths
    config_path=""
    state_path=""
    env_file=""

    # Manifest mode: read paths from manifest
    if [ -n "${MANIFEST:-}" ] && [ -f "${MANIFEST}" ]; then
        config_path=$(jq -r --arg g "$group" '.groups[$g].configPath // empty' "$MANIFEST" 2>/dev/null)
        state_path=$(jq -r --arg g "$group" '.groups[$g].statePath // empty' "$MANIFEST" 2>/dev/null)
        env_file=$(jq -r --arg g "$group" '.groups[$g].envFile // empty' "$MANIFEST" 2>/dev/null)
    fi

    # Fallback mode: derive paths from HOME_DIR and group name
    if [ -z "$config_path" ]; then
        config_path="${OUTPUT_DIR}/${group}/openclaw.session.json"
    fi
    if [ -z "$state_path" ]; then
        state_path="${HOME_DIR}/.openclaw-sessions/${group}"
    fi
    if [ -z "$env_file" ]; then
        env_file="${HOME_DIR}/.openclaw-sessions/${group}/group.env"
    fi

    # Create config JSON directory and file (fallback: manifest doesn't have it)
    if [ ! -f "$config_path" ]; then
        mkdir -p "$(dirname "$config_path")"
        _build_group_config "$group" "$port" > "$config_path"
        echo "  [${group}] created config: $config_path"
    fi

    # Create per-agent state directories
    agent_count="${AGENT_COUNT:-1}"
    for i in $(seq 1 "$agent_count"); do
        group_var_name="AGENT${i}_ISOLATION_GROUP"
        agent_group="${!group_var_name:-}"
        if [ -z "${MANIFEST:-}" ] || [ ! -f "${MANIFEST}" ]; then
            # In fallback mode, create state dirs for agents in this group
            [ "$agent_group" = "$group" ] || continue
        fi
        mkdir -p "${state_path}/agents/agent${i}/agent"
    done

    # Generate the systemd service unit
    cat > "${OUTPUT_DIR}/openclaw-${group}.service" <<SVCFILE
[Unit]
Description=OpenClaw Session - ${group} (${HABITAT})
After=network.target desktop.service
Wants=desktop.service
StartLimitBurst=5
StartLimitIntervalSec=1800

[Service]
Type=simple
User=${SVC_USER}
WorkingDirectory=${HOME_DIR}
ExecStart=/usr/local/bin/openclaw gateway --bind loopback --port ${port}
ExecStartPost=+/bin/bash -c 'source ${env_file} && GROUP=${group} GROUP_PORT=${port} RUN_MODE=execstartpost /usr/local/bin/gateway-health-check.sh'
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=2
TimeoutStartSec=180
EnvironmentFile=-${env_file}
Environment=CI=true
Environment=NODE_ENV=production
Environment=PATH=/usr/local/bin:/usr/bin
Environment=DISPLAY=:10
Environment=GROUP=${group}
Environment=GROUP_PORT=${port}
Environment=OPENCLAW_CONFIG_PATH=${config_path}
Environment=OPENCLAW_STATE_DIR=${state_path}
Environment=ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}

[Install]
WantedBy=multi-user.target
SVCFILE

    echo "  [${group}] port=${port} → openclaw-${group}.service"
done

# --- Install and enable services ---
if [ -z "${DRY_RUN:-}" ]; then
    echo "Installing systemd services..."
    if [ "$OUTPUT_DIR" != "/etc/systemd/system" ]; then
        for group in "${SESSION_GROUPS[@]}"; do
            cp "${OUTPUT_DIR}/openclaw-${group}.service" /etc/systemd/system/
        done
    fi
    systemctl daemon-reload

    # Stop main openclaw service — session isolation replaces it
    echo "Stopping main openclaw service (replaced by session services)..."
    systemctl stop openclaw 2>/dev/null || true
    systemctl disable openclaw 2>/dev/null || true

    for group in "${SESSION_GROUPS[@]}"; do
        systemctl enable "openclaw-${group}.service"
        if [ "${START_SERVICES:-false}" = "true" ]; then
            systemctl start "openclaw-${group}.service" || {
                echo "  [${group}] Service start returned non-zero (health check may have triggered safe mode)"
            }
        else
            echo "  [${group}] Service enabled (caller will start)"
        fi
    done

    echo "Session services enabled${START_SERVICES:+ and started}."
else
    echo "DRY_RUN mode — services written to ${OUTPUT_DIR}"
fi

echo "Generated ${#SESSION_GROUPS[@]} session service(s) for habitat '${HABITAT}'"
