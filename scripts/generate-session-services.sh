#!/bin/bash
# =============================================================================
# generate-session-services.sh — Generate per-group systemd service units
# =============================================================================
# Generates systemd .service files for each session isolation group.
# This is a thin generator: it only writes unit files and does NOT create
# config JSON or state directories (orchestrator concerns).
#
# Two modes:
#   Manifest mode: MANIFEST is set and points to a valid openclaw-groups.json.
#     Uses manifest for ports, config paths, state paths, and env files.
#   Fallback mode: MANIFEST not set or absent.
#     Derives configuration from AGENT*_ISOLATION_GROUP env vars.
#     Computes paths from HOME_DIR and group name conventions.
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
#
# Outputs:
#   ${OUTPUT_DIR}/openclaw-{group}.service — one systemd unit per group
#
# Env:
#   SESSION_OUTPUT_DIR — output directory (default: /etc/systemd/system)
#   DRY_RUN            — if set, write units only (no systemctl)
#   START_SERVICES     — if "true", also start services after enabling
# =============================================================================
set -euo pipefail
umask 022

# Capture caller-provided MANIFEST value BEFORE lib-isolation.sh sets a default
MANIFEST_CALLER="${MANIFEST:-}"

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

# Fail fast: when caller explicitly sets MANIFEST to a non-existent path, fail before processing.
if [ -n "${MANIFEST_CALLER:-}" ] && [ ! -f "${MANIFEST_CALLER}" ]; then
    echo "ERROR: MANIFEST='${MANIFEST_CALLER}' is set but file not found" >&2
    exit 1
fi

# --- Compute port for a group ---
# Reads from manifest; falls back to position-based offset from 18790.
_manifest_group_value() {
  local target_group="$1"
  local jq_expr="$2"
  local field_name="$3"
  local _manifest="${MANIFEST_CALLER:-${MANIFEST:-}}"
  local value=""

  if ! value=$(jq -er --arg g "$target_group" "$jq_expr" "${_manifest}" 2>/dev/null); then
    echo "ERROR: manifest missing ${field_name} for group '${target_group}' in ${_manifest}" >&2
    return 1
  fi

  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "ERROR: manifest has empty ${field_name} for group '${target_group}' in ${_manifest}" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

_get_port_for_group() {
  local target_group="$1"
  local _manifest="${MANIFEST_CALLER:-${MANIFEST:-}}"
  # Manifest mode: try to read port from manifest JSON
  if [ -n "${_manifest}" ] && [ -f "${_manifest}" ]; then
    _manifest_group_value "$target_group" '.groups[$g].port' "port"
    return
  fi
  # Fallback: compute from position in SESSION_GROUPS array (first group = 18790)
  local idx=0
  for _g in "${SESSION_GROUPS[@]}"; do
    [ "$_g" = "$target_group" ] && { echo $((18790 + idx)); return; }
    idx=$((idx + 1))
  done
  echo "18790"
}

# --- Generate systemd .service per group ---
for group in "${SESSION_GROUPS[@]}"; do
    port=$(_get_port_for_group "$group")

    # Determine config/state/env paths
    config_path=""
    state_path=""
    env_file=""

    # Manifest mode: read paths from manifest (use the caller's MANIFEST if set)
    _manifest="${MANIFEST_CALLER:-${MANIFEST:-}}"
    if [ -n "${_manifest}" ] && [ -f "${_manifest}" ]; then
        config_path=$(_manifest_group_value "$group" '.groups[$g].configPath' "configPath")
        state_path=$(_manifest_group_value "$group" '.groups[$g].statePath' "statePath")
        env_file=$(_manifest_group_value "$group" '.groups[$g].envFile' "envFile")
        port=$(_manifest_group_value "$group" '.groups[$g].port' "port")
    fi

    # Fallback mode: derive paths from HOME_DIR and group name
    if [ -z "$config_path" ]; then
        config_path="${HOME_DIR}/.openclaw/configs/${group}/openclaw.session.json"
    fi
    if [ -z "$state_path" ]; then
        state_path="${HOME_DIR}/.openclaw-sessions/${group}"
    fi
    if [ -z "$env_file" ]; then
        env_file="${HOME_DIR}/.openclaw/configs/${group}/group.env"
    fi

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
ExecStartPost=+/bin/bash -c 'GROUP=${group} GROUP_PORT=${port} RUN_MODE=execstartpost /usr/local/bin/gateway-health-check.sh'
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=2
TimeoutStartSec=180
EnvironmentFile=${env_file}
Environment=CI=true
Environment=NODE_ENV=production
Environment=PATH=/usr/local/bin:/usr/bin
Environment=DISPLAY=:10
Environment=GROUP=${group}
Environment=GROUP_PORT=${port}
Environment=OPENCLAW_CONFIG_PATH=${config_path}
Environment=OPENCLAW_STATE_DIR=${state_path}

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
