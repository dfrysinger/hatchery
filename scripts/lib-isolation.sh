#!/bin/bash
# =============================================================================
# lib-isolation.sh — Shared functions for isolation group management
# =============================================================================
# Single source of truth for group/agent queries, port lookups, manifest
# generation, group validation, and mode-agnostic systemd unit generation.
#
# Dependencies: lib-env.sh (env_load), lib-permissions.sh (ensure_bot_dir)
# Env requirements: AGENT_COUNT, ISOLATION_GROUPS, ISOLATION_DEFAULT
#
# Usage:
#   source /usr/local/sbin/lib-isolation.sh
# =============================================================================
set -euo pipefail

# --- Constants ---
MANIFEST="${MANIFEST:-/etc/openclaw-groups.json}"
CONFIG_BASE="${CONFIG_BASE:-${HOME_DIR:-/home/bot}/.openclaw/configs}"
STATE_BASE="${STATE_BASE:-${HOME_DIR:-/home/bot}/.openclaw-sessions}"
COMPOSE_BASE="${COMPOSE_BASE:-${HOME_DIR:-/home/bot}/.openclaw/compose}"
LIB_SVC_USER="${SVC_USER:-bot}"

# =========================================================================
# Group/Agent Queries
# =========================================================================

# Get agent IDs belonging to a group (comma-separated).
# Usage: get_group_agents "council" → "agent1,agent3"
get_group_agents() {
    local group="$1"
    local agents=""
    local i
    for i in $(seq 1 "${AGENT_COUNT:?AGENT_COUNT required}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local ag="${!ag_var:-}"
        if [ "$ag" = "$group" ]; then
            [ -n "$agents" ] && agents="${agents},"
            agents="${agents}agent${i}"
        fi
    done
    echo "$agents"
}

# Get the isolation type for a group (first agent's type, or ISOLATION_DEFAULT).
# Usage: get_group_isolation "council" → "session"
get_group_isolation() {
    local group="$1"
    local i
    for i in $(seq 1 "${AGENT_COUNT:?}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local iso_var="AGENT${i}_ISOLATION"
        local ag="${!ag_var:-}"
        local iso="${!iso_var:-}"
        if [ "$ag" = "$group" ] && [ -n "$iso" ]; then
            echo "$iso"
            return
        fi
    done
    echo "${ISOLATION_DEFAULT:-none}"
}

# Get network mode for a group (first agent with a setting, default "host").
# Maps deprecated "none"/"internal" to "isolated".
get_group_network() {
    local group="$1"
    local raw=""
    local i
    for i in $(seq 1 "${AGENT_COUNT:?}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local net_var="AGENT${i}_NETWORK"
        if [ "${!ag_var:-}" = "$group" ] && [ -n "${!net_var:-}" ]; then
            raw="${!net_var}"
            break
        fi
    done
    raw="${raw:-host}"
    # Normalize: both "internal" and "none" map to "isolated"
    case "$raw" in
        internal|none)
            echo "WARNING: network '$raw' deprecated, use 'isolated'" >&2
            echo "isolated" ;;
        *) echo "$raw" ;;
    esac
}

# Get resource limits for a group: "memory|cpu" (pipe-delimited, empty strings if unset).
# Usage: IFS='|' read -r mem cpu <<< "$(get_group_resources "sandbox")"
get_group_resources() {
    local group="$1"
    local mem="" cpu=""
    local i
    for i in $(seq 1 "${AGENT_COUNT:?}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        if [ "${!ag_var:-}" = "$group" ]; then
            local mem_var="AGENT${i}_RESOURCES_MEMORY"
            local cpu_var="AGENT${i}_RESOURCES_CPU"
            [ -z "$mem" ] && mem="${!mem_var:-}"
            [ -z "$cpu" ] && cpu="${!cpu_var:-}"
        fi
    done
    echo "${mem}|${cpu}"
}

# Get groups filtered by isolation type.
# Usage: get_groups_by_type "session" → "council workers" (space-separated)
get_groups_by_type() {
    local type="$1"
    local result=""
    local groups
    IFS=',' read -ra groups <<< "${ISOLATION_GROUPS:-}"
    local group
    for group in "${groups[@]}"; do
        if [ "$(get_group_isolation "$group")" = "$type" ]; then
            [ -n "$result" ] && result="${result} "
            result="${result}${group}"
        fi
    done
    echo "$result"
}

# =========================================================================
# Group Validation
# =========================================================================

# Validate that all agents in a group have consistent isolation and network settings.
# Mixed isolation or network within a group = hard error during generation.
# Resources (memory/cpu) are per-agent hints; first agent's values are used.
validate_group_consistency() {
    local group="$1"
    local first_iso="" first_net=""
    local i
    for i in $(seq 1 "${AGENT_COUNT:?}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        [ "${!ag_var:-}" = "$group" ] || continue
        local iso_var="AGENT${i}_ISOLATION"
        local net_var="AGENT${i}_NETWORK"
        local iso="${!iso_var:-${ISOLATION_DEFAULT:-none}}"
        local net="${!net_var:-host}"
        if [ -z "$first_iso" ]; then
            first_iso="$iso"; first_net="$net"
        else
            if [ "$iso" != "$first_iso" ]; then
                echo "FATAL: group '${group}' has mixed isolation: agent${i}=${iso} vs ${first_iso}" >&2
                return 1
            fi
            if [ "$net" != "$first_net" ]; then
                echo "FATAL: group '${group}' has mixed network: agent${i}=${net} vs ${first_net}" >&2
                return 1
            fi
        fi
    done
    return 0
}

# =========================================================================
# Port Allocation
# =========================================================================

# Compute port for a group by index. BASE_PORT=18790.
_compute_group_port() {
    local index="$1"
    echo $((18790 + index))
}

# Read port for a group from the manifest.
# Usage: get_group_port "code-sandbox" → "18790"
get_group_port() {
    local group="$1"
    if [ -f "$MANIFEST" ]; then
        jq -r --arg g "$group" '.groups[$g].port // empty' "$MANIFEST" 2>/dev/null
    fi
}

# =========================================================================
# Manifest Generation
# =========================================================================

# Write /etc/openclaw-groups.json — the runtime source of truth.
generate_groups_manifest() {
    local home_dir="${HOME_DIR:-/home/bot}"
    local svc_user="$LIB_SVC_USER"

    # Sort groups alphabetically for deterministic port assignment
    local groups_unsorted groups
    IFS=',' read -ra groups_unsorted <<< "${ISOLATION_GROUPS:?ISOLATION_GROUPS required}"
    groups=($(printf '%s\n' "${groups_unsorted[@]}" | sort))

    # Build JSON via jq for correctness (no manual string concatenation)
    local manifest_json='{"generated":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","groups":{}}'
    local port_index=0
    local group
    for group in "${groups[@]}"; do
        local port isolation network agents_csv service_name compose_path
        port=$(_compute_group_port "$port_index")
        port_index=$((port_index + 1))
        isolation=$(get_group_isolation "$group")
        network=$(get_group_network "$group" 2>/dev/null)  # suppress deprecation warning
        agents_csv=$(get_group_agents "$group")

        case "$isolation" in
            container)
                service_name="openclaw-container-${group}"
                compose_path="${home_dir}/.openclaw/compose/${group}/docker-compose.yaml" ;;
            session)
                service_name="openclaw-${group}"
                compose_path="" ;;
            *)
                service_name=""
                compose_path="" ;;
        esac

        # Convert comma-separated agents to JSON array
        local agents_json
        agents_json=$(echo "$agents_csv" | tr ',' '\n' | jq -R . | jq -sc .)

        # Get resource limits for this group
        local resources
        resources=$(get_group_resources "$group")
        local res_mem res_cpu
        IFS='|' read -r res_mem res_cpu <<< "$resources"

        manifest_json=$(echo "$manifest_json" | jq \
            --arg g "$group" \
            --arg iso "$isolation" \
            --argjson port "$port" \
            --arg net "$network" \
            --argjson agents "$agents_json" \
            --arg cfgPath "${CONFIG_BASE}/${group}/openclaw.session.json" \
            --arg statePath "${STATE_BASE}/${group}" \
            --arg envFile "${CONFIG_BASE}/${group}/group.env" \
            --arg svcName "$service_name" \
            --arg composePath "$compose_path" \
            --arg resMem "$res_mem" \
            --arg resCpu "$res_cpu" \
            '.groups[$g] = {
                isolation: $iso,
                port: $port,
                network: $net,
                agents: $agents,
                configPath: $cfgPath,
                statePath: $statePath,
                envFile: $envFile,
                serviceName: $svcName,
                composePath: (if $composePath == "" then null else $composePath end),
                resources: (if ($resMem == "" and $resCpu == "") then null
                           else {memory: (if $resMem == "" then null else $resMem end),
                                 cpu: (if $resCpu == "" then null else $resCpu end)} end)
            }')
    done

    echo "$manifest_json" | jq . > "$MANIFEST"
    chmod 644 "$MANIFEST"
}

# =========================================================================
# Per-Group Setup (mode-agnostic)
# =========================================================================

# Create all directories for a group.
setup_group_directories() {
    local group="$1"
    local config_dir="${CONFIG_BASE}/${group}"
    local state_dir="${STATE_BASE}/${group}"

    if type ensure_bot_dir &>/dev/null; then
        ensure_bot_dir "$config_dir" 700
        ensure_bot_dir "$state_dir" 700
    else
        mkdir -p "$config_dir" "$state_dir"
    fi

    # Per-agent subdirs within the state dir (OpenClaw expects this layout)
    local agents_csv
    agents_csv=$(get_group_agents "$group")
    local agents
    IFS=',' read -ra agents <<< "$agents_csv"
    local agent_id
    for agent_id in "${agents[@]}"; do
        if type ensure_bot_dir &>/dev/null; then
            ensure_bot_dir "${state_dir}/agents/${agent_id}/agent" 700
        else
            mkdir -p "${state_dir}/agents/${agent_id}/agent"
        fi
    done

    # Compose directory (container groups only)
    local iso
    iso=$(get_group_isolation "$group")
    if [ "$iso" = "container" ]; then
        local compose_dir="${COMPOSE_BASE}/${group}"
        if type ensure_bot_dir &>/dev/null; then
            ensure_bot_dir "$compose_dir" 755
        else
            mkdir -p "$compose_dir"
        fi
    fi
}

# Set up auth-profiles for all agents in a group (symlink to master).
setup_group_auth_profiles() {
    local group="$1"
    local state_dir="${STATE_BASE}/${group}"
    local home_dir="${HOME_DIR:-/home/bot}"
    local master="${home_dir}/.openclaw/agents/main/agent/auth-profiles.json"

    if [ ! -f "$master" ]; then
        echo "WARNING: No master auth-profiles.json at $master" >&2
        return 1
    fi

    local agents_csv
    agents_csv=$(get_group_agents "$group")
    local agents
    IFS=',' read -ra agents <<< "$agents_csv"
    local agent_id
    for agent_id in "${agents[@]}"; do
        local target="${state_dir}/agents/${agent_id}/agent/auth-profiles.json"
        ln -sf "$master" "$target"
    done
}

# Generate per-group gateway token.
generate_group_token() {
    local group="$1"
    local config_dir="${CONFIG_BASE}/${group}"
    local token_file="${config_dir}/gateway-token.txt"
    local svc_user="$LIB_SVC_USER"

    if [ ! -f "$token_file" ]; then
        openssl rand -hex 16 > "$token_file"
        chmod 600 "$token_file"
        chown "${svc_user}:${svc_user}" "$token_file" 2>/dev/null || true
    fi
    cat "$token_file"
}

# Write per-group environment file with decoded secrets and group metadata.
# Consumed by systemd EnvironmentFile= and compose env_file:.
generate_group_env() {
    local group="$1"
    local config_dir="${CONFIG_BASE}/${group}"
    local svc_user="$LIB_SVC_USER"

    local port isolation network
    port=$(get_group_port "$group")
    isolation=$(get_group_isolation "$group")
    network=$(get_group_network "$group" 2>/dev/null)

    local env_file="${config_dir}/group.env"

    cat > "$env_file" <<ENVFILE
# Runtime environment for group '${group}' — do not edit
# Topology metadata: see /etc/openclaw-groups.json
GROUP=${group}
GROUP_PORT=${port}
ISOLATION=${isolation}
NETWORK_MODE=${network}
OPENCLAW_CONFIG_PATH=${config_dir}/openclaw.session.json
OPENCLAW_STATE_DIR=${STATE_BASE}/${group}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
GOOGLE_API_KEY=${GOOGLE_API_KEY:-}
GEMINI_API_KEY=${GOOGLE_API_KEY:-}
BRAVE_API_KEY=${BRAVE_API_KEY:-}
ENVFILE

    chmod 600 "$env_file"
    chown "${svc_user}:${svc_user}" "$env_file" 2>/dev/null || true
}

# Generate OpenClaw config for a group (delegates to generate-config.sh).
generate_group_config() {
    local group="$1"
    local config_dir="${CONFIG_BASE}/${group}"
    local svc_user="$LIB_SVC_USER"

    local port token agents
    port=$(get_group_port "$group")
    token=$(generate_group_token "$group")
    agents=$(get_group_agents "$group")

    local gen_script=""
    local p
    for p in /usr/local/sbin /usr/local/bin "$(dirname "${BASH_SOURCE[0]}")"; do
        [ -f "$p/generate-config.sh" ] && { gen_script="$p/generate-config.sh"; break; }
    done
    [ -z "$gen_script" ] && { echo "FATAL: generate-config.sh not found" >&2; return 1; }

    "$gen_script" --mode session \
        --group "$group" \
        --agents "$agents" \
        --port "$port" \
        --gateway-token "$token" \
        > "${config_dir}/openclaw.session.json"

    chown "${svc_user}:${svc_user}" "${config_dir}/openclaw.session.json" 2>/dev/null || true
    chmod 600 "${config_dir}/openclaw.session.json" 2>/dev/null || true
}

# =========================================================================
# Systemd Unit Generation (mode-agnostic)
# =========================================================================

# Generate safeguard .path + .service for any group.
# These run on the host regardless of isolation mode.
generate_safeguard_units() {
    local group="$1"
    local output_dir="${2:-/etc/systemd/system}"
    local config_dir="${CONFIG_BASE}/${group}"

    # .path unit — watches for unhealthy marker (identical for all modes)
    cat > "${output_dir}/openclaw-safeguard-${group}.path" <<PATHFILE
[Unit]
Description=Watch for ${group} unhealthy marker

[Path]
PathExists=/var/lib/init-status/unhealthy-${group}
Unit=openclaw-safeguard-${group}.service

[Install]
WantedBy=multi-user.target
PATHFILE

    # .service unit — reads all group metadata from EnvironmentFile
    cat > "${output_dir}/openclaw-safeguard-${group}.service" <<SGFILE
[Unit]
Description=OpenClaw Safe Mode Recovery - ${group}

[Service]
Type=oneshot
EnvironmentFile=${config_dir}/group.env
Environment=RUN_MODE=path-triggered
ExecStart=/usr/local/bin/safe-mode-handler.sh
SGFILE
}

# Generate E2E check service for any group.
generate_e2e_unit() {
    local group="$1"
    local output_dir="${2:-/etc/systemd/system}"
    local config_dir="${CONFIG_BASE}/${group}"

    cat > "${output_dir}/openclaw-e2e-${group}.service" <<E2EFILE
[Unit]
Description=OpenClaw E2E Check - ${group}
After=openclaw-${group}.service openclaw-container-${group}.service

[Service]
Type=oneshot
EnvironmentFile=${config_dir}/group.env
Environment=RUN_MODE=e2e-check
ExecStart=/usr/local/bin/gateway-e2e-check.sh
E2EFILE
}
