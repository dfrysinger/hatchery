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
LIB_SVC_USER="${SVC_USER:-bot}"
_LIB_HOME="${HOME_DIR:-/home/${LIB_SVC_USER}}"
MANIFEST="${MANIFEST:-/etc/openclaw-groups.json}"
CONFIG_BASE="${CONFIG_BASE:-${_LIB_HOME}/.openclaw/configs}"
STATE_BASE="${STATE_BASE:-${_LIB_HOME}/.openclaw-sessions}"
COMPOSE_BASE="${COMPOSE_BASE:-${_LIB_HOME}/.openclaw/compose}"

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
# Config Validation (Phase 0a — post-generation checks)
# =========================================================================

# Validate a generated openclaw config for a group.
# Checks:
#   1. Single-agent groups prefer per-agent account bindings (by agent ID);
#      a "default" account binding is allowed only as a backward-compatible fallback.
#   2. Multi-agent groups must have a binding for every agent
#   3. Every binding must reference an existing channel account
#
# Usage: validate_generated_config "group-name"
# Returns: 0 on valid, 1 on invalid (with diagnostic to stderr)
validate_generated_config() {
    local group="$1"
    local config_path
    config_path=$(get_group_config_path "$group" 2>/dev/null) || config_path=""

    # If config path not in manifest yet, try conventional path
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        local home="${HOME:-/home/bot}"
        local config_base="${home}/.openclaw/configs"
        config_path="${config_base}/${group}/openclaw.session.json"
    fi

    if [ ! -f "$config_path" ]; then
        echo "WARNING: validate_generated_config: config not found for group '$group' at $config_path" >&2
        # Non-fatal: returns success if config doesn't exist yet.
        # Callers must ensure config is generated BEFORE calling validation.
        # In build-full-config.sh this is guaranteed (step 3 generates, step 4 validates).
        return 0
    fi

    local agent_count
    agent_count=$(jq '.agents.list | length' "$config_path" 2>/dev/null) || agent_count=0

    # Check 1: Single-agent account naming (must use agent ID, e.g., "agent1")
    # Multi-agent mode uses each agent's ID as the account key.
    # The "default" key is only accepted for backward compat with deployed configs
    # that were generated before this policy change.
    if [ "$agent_count" -eq 1 ]; then
        for channel in telegram discord; do
            local acct_keys
            acct_keys=$(jq -r ".channels.$channel.accounts // {} | keys[]" "$config_path" 2>/dev/null) || continue
            # Reject only obviously wrong keys — empty configs or clearly wrong names
            # "default" is accepted for backward compat; agent IDs (agent1 etc.) are preferred
            if [ -n "$acct_keys" ] && [[ "$acct_keys" != "default" && "$acct_keys" != "agent"* && "$acct_keys" != "safe-mode" ]]; then
                echo "WARNING: group '$group' single-agent $channel account key is '$acct_keys' — expected agent ID like 'agent1'" >&2
            fi
        done
    fi

    # Check 2: Multi-agent binding completeness
    if [ "$agent_count" -gt 1 ]; then
        local agents_with_bindings
        agents_with_bindings=$(jq -r '.bindings[].agentId' "$config_path" 2>/dev/null | sort -u | wc -l) || agents_with_bindings=0

        if [ "$agents_with_bindings" -lt "$agent_count" ]; then
            echo "FATAL: group '$group' has $agent_count agents but only $agents_with_bindings have bindings — messages won't route" >&2
            return 1
        fi
    fi

    # Check 3: Binding-to-account consistency
    local binding_errors=0
    for channel in telegram discord; do
        local channel_accounts
        channel_accounts=$(jq -r ".channels.$channel.accounts // {} | keys[]" "$config_path" 2>/dev/null) || continue
        [ -z "$channel_accounts" ] && continue

        local bound_accounts
        bound_accounts=$(jq -r ".bindings[] | select(.match.channel == \"$channel\") | .match.accountId" "$config_path" 2>/dev/null) || continue

        for acct in $bound_accounts; do
            if ! echo "$channel_accounts" | grep -qx "$acct"; then
                echo "FATAL: group '$group' binding references $channel account '$acct' but config has: $(echo "$channel_accounts" | tr '\n' ' ')" >&2
                binding_errors=$((binding_errors + 1))
            fi
        done
    done

    [ "$binding_errors" -gt 0 ] && return 1
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
    mapfile -t groups < <(printf '%s\n' "${groups_unsorted[@]}" | sort)

    # Build JSON via jq for correctness (no manual string concatenation)
    local manifest_json
    manifest_json='{"generated":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","groups":{}}'
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

# Append decoded secrets to a group.env file.
# Called by generate_group_env after writing base vars.
# Expects caller to have decoded secrets in env (via env_decode_keys or manual export).
append_decoded_secrets() {
    local env_file="$1"
    cat >> "$env_file" <<SECRETS
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
GOOGLE_API_KEY=${GOOGLE_API_KEY:-}
GEMINI_API_KEY=${GOOGLE_API_KEY:-}
BRAVE_API_KEY=${BRAVE_API_KEY:-}
SECRETS
}

# Write per-group environment file with ALL habitat vars plus group-specific overrides.
# Consumed by systemd EnvironmentFile= and compose env_file:.
#
# Phase 1 (ENV-REFACTOR): group.env is now the SINGLE SOURCE OF TRUTH for runtime scripts.
# No runtime script should source habitat-parsed.env directly. All vars flow through group.env.
#
# Structure:
#   1. GROUP_ENV_VERSION=1 (allows future format detection)
#   2. All habitat-parsed.env vars (include-all approach)
#   3. Group-specific overrides (GROUP, GROUP_PORT, ISOLATION, etc.)
#   4. Decoded secrets (override B64 versions from habitat-parsed.env)
#
# Note: GROUP, GROUP_PORT, ISOLATION, NETWORK_MODE are derived from the manifest.
# Systemd EnvironmentFile= cannot read JSON, so these are duplicated here.
generate_group_env() {
    local group="$1"
    local config_dir="${CONFIG_BASE}/${group}"
    local svc_user="$LIB_SVC_USER"

    local port isolation network
    port=$(get_group_port "$group")
    isolation=$(get_group_isolation "$group")
    network=$(get_group_network "$group" 2>/dev/null)

    local env_file="${config_dir}/group.env"

    # Start fresh with version marker
    cat > "$env_file" <<HEADER
GROUP_ENV_VERSION=1
# Runtime environment for group '${group}' — GENERATED, DO NOT EDIT
# This is the SINGLE SOURCE OF TRUTH for runtime scripts.
# To change topology, update the habitat config and re-run build-full-config.sh.
HEADER

    # Include all vars from habitat-parsed.env (exclude comments and empty lines)
    if [ -f /etc/habitat-parsed.env ] && [ -r /etc/habitat-parsed.env ]; then
        grep -v '^#\|^$' /etc/habitat-parsed.env >> "$env_file" 2>/dev/null || true
    fi

    # Group-specific overrides (these take precedence over habitat-parsed.env values)
    cat >> "$env_file" <<OVERRIDES

# Group-specific overrides (derived from manifest)
GROUP=${group}
GROUP_PORT=${port}
ISOLATION=${isolation}
NETWORK_MODE=${network}
OPENCLAW_CONFIG_PATH=${config_dir}/openclaw.session.json
OPENCLAW_STATE_DIR=${STATE_BASE}/${group}
OVERRIDES

    # Decoded secrets (override B64 versions from habitat-parsed.env)
    append_decoded_secrets "$env_file"

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

[Install]
WantedBy=openclaw-${group}.service openclaw-container-${group}.service
E2EFILE
}
