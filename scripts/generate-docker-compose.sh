#!/bin/bash
# =============================================================================
# generate-docker-compose.sh — Generate docker-compose.yaml for container mode
# =============================================================================
# Purpose:  For container isolation mode, generates a docker-compose.yaml with
#           one service per isolation group, proper volume mounts for shared
#           paths, network modes, and resource limits.
#
# Inputs:   Environment variables from habitat-parsed.env:
#             ISOLATION_DEFAULT     — must be "container" to generate
#             ISOLATION_GROUPS      — comma-separated list of group names
#             AGENT_COUNT           — number of agents
#             AGENT{N}_NAME, AGENT{N}_ISOLATION_GROUP, AGENT{N}_ISOLATION,
#             AGENT{N}_NETWORK, AGENT{N}_RESOURCES_MEMORY, AGENT{N}_RESOURCES_CPU
#             USERNAME              — system user
#             HABITAT_NAME          — habitat name
#             ISOLATION_SHARED_PATHS    — comma-separated shared paths
#             CONTAINER_IMAGE       — base image (default: hatchery/agent:latest)
#
# Outputs:  docker-compose.yaml in COMPOSE_OUTPUT_DIR
#
# Env:      COMPOSE_OUTPUT_DIR — output directory (default: /home/$USERNAME)
#           DRY_RUN            — if set, only write files (no docker-compose up)
#           CONTAINER_IMAGE    — base Docker image
#
# Original: scripts/generate-docker-compose.sh
# =============================================================================

set -euo pipefail

# --- Source environment files (may be called standalone or from another script) ---
[ -f /etc/droplet.env ] && source /etc/droplet.env
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

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
BASE_IMAGE="${CONTAINER_IMAGE:-hatchery/agent:latest}"
OUTPUT_DIR="${COMPOSE_OUTPUT_DIR:-/home/${SVC_USER}}"
HOME_DIR="/home/${SVC_USER}"

# --- Skip if not container mode or no groups ---
if [ "$ISOLATION" != "container" ]; then
    echo "Isolation mode is '$ISOLATION' — no docker-compose needed."
    exit 0
fi

if [ -z "$ISO_GROUPS" ]; then
    echo "No isolation groups defined — no docker-compose needed."
    exit 0
fi

# --- Filter groups: only include container-mode groups ---
IFS=',' read -ra ALL_GROUPS <<< "$ISO_GROUPS"

CONTAINER_GROUPS=()
for group in "${ALL_GROUPS[@]}"; do
    is_container=false
    for i in $(seq 1 "$AGENT_COUNT"); do
        agent_group_var="AGENT${i}_ISOLATION_GROUP"
        agent_iso_var="AGENT${i}_ISOLATION"
        agent_group="${!agent_group_var:-}"
        agent_iso="${!agent_iso_var:-}"

        if [ "$agent_group" = "$group" ]; then
            # Skip agents explicitly set to non-container modes
            if [ "$agent_iso" = "session" ] || [ "$agent_iso" = "none" ]; then
                continue
            fi
            # Agent inherits container default or is explicitly container
            if [ "$agent_iso" = "container" ] || [ -z "$agent_iso" ]; then
                is_container=true
            fi
        fi
    done
    if [ "$is_container" = true ]; then
        CONTAINER_GROUPS+=("$group")
    fi
done

if [ ${#CONTAINER_GROUPS[@]} -eq 0 ]; then
    echo "No container-mode groups found — no docker-compose needed."
    exit 0
fi

mkdir -p "$OUTPUT_DIR"

echo "Generating docker-compose.yaml for ${#CONTAINER_GROUPS[@]} group(s)..."

# --- Build shared paths volumes ---
SHARED_VOLUMES=""
if [ -n "$SHARED" ]; then
    IFS=',' read -ra PATHS <<< "$SHARED"
    for sp in "${PATHS[@]}"; do
        SHARED_VOLUMES="${SHARED_VOLUMES}      - .${sp}:${sp}
"
    done
fi

# --- Determine network mode for a group ---
# Uses the first agent in the group with a network setting, or defaults to "host"
get_group_network() {
    local group="$1"
    for i in $(seq 1 "$AGENT_COUNT"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local net_var="AGENT${i}_NETWORK"
        local ag="${!ag_var:-}"
        local net="${!net_var:-}"
        if [ "$ag" = "$group" ] && [ -n "$net" ]; then
            echo "$net"
            return
        fi
    done
    echo "host"
}

# --- Determine resource limits for a group ---
# Uses the first agent in the group with resource settings
get_group_memory() {
    local group="$1"
    for i in $(seq 1 "$AGENT_COUNT"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local mem_var="AGENT${i}_RESOURCES_MEMORY"
        local ag="${!ag_var:-}"
        local mem="${!mem_var:-}"
        if [ "$ag" = "$group" ] && [ -n "$mem" ]; then
            echo "$mem"
            return
        fi
    done
    echo ""
}

get_group_cpu() {
    local group="$1"
    for i in $(seq 1 "$AGENT_COUNT"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local cpu_var="AGENT${i}_RESOURCES_CPU"
        local ag="${!ag_var:-}"
        local cpu="${!cpu_var:-}"
        if [ "$ag" = "$group" ] && [ -n "$cpu" ]; then
            echo "$cpu"
            return
        fi
    done
    echo ""
}

# --- Collect agent names per group ---
get_group_agent_names() {
    local group="$1"
    local names=""
    for i in $(seq 1 "$AGENT_COUNT"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local name_var="AGENT${i}_NAME"
        local ag="${!ag_var:-}"
        local name="${!name_var:-Agent${i}}"
        if [ "$ag" = "$group" ]; then
            [ -n "$names" ] && names="${names},"
            names="${names}${name}"
        fi
    done
    echo "$names"
}

# --- Write docker-compose.yaml ---
COMPOSE_FILE="${OUTPUT_DIR}/docker-compose.yaml"

# Initialize compose file
: > "$COMPOSE_FILE"
# Check if we need an internal network
needs_internal=false
for group in "${CONTAINER_GROUPS[@]}"; do
    net=$(get_group_network "$group")
    if [ "$net" = "internal" ]; then
        needs_internal=true
        break
    fi
done

echo "services:" >> "$COMPOSE_FILE"

for group in "${CONTAINER_GROUPS[@]}"; do
    net=$(get_group_network "$group")
    mem=$(get_group_memory "$group")
    cpu=$(get_group_cpu "$group")
    agent_names=$(get_group_agent_names "$group")

    cat >> "$COMPOSE_FILE" <<SVC
  ${group}:
    image: ${BASE_IMAGE}
SVC

    # Network mode
    if [ "$net" = "internal" ]; then
        cat >> "$COMPOSE_FILE" <<NET
    networks:
      - internal
NET
    else
        cat >> "$COMPOSE_FILE" <<NET
    network_mode: ${net}
NET
    fi

    # Resource limits
    if [ -n "$mem" ]; then
        echo "    mem_limit: ${mem}" >> "$COMPOSE_FILE"
    fi
    if [ -n "$cpu" ]; then
        echo "    cpus: ${cpu}" >> "$COMPOSE_FILE"
    fi

    # Volumes — include config, scripts, and env files needed by health check
    echo "    volumes:" >> "$COMPOSE_FILE"
    echo "      - ./config/${group}:${HOME_DIR}/.openclaw" >> "$COMPOSE_FILE"
    echo "      - /usr/local/bin/gateway-health-check.sh:/usr/local/bin/gateway-health-check.sh:ro" >> "$COMPOSE_FILE"
    echo "      - /usr/local/bin/safe-mode-recovery.sh:/usr/local/bin/safe-mode-recovery.sh:ro" >> "$COMPOSE_FILE"
    echo "      - /usr/local/bin/setup-safe-mode-workspace.sh:/usr/local/bin/setup-safe-mode-workspace.sh:ro" >> "$COMPOSE_FILE"
    echo "      - /usr/local/sbin/lib-permissions.sh:/usr/local/sbin/lib-permissions.sh:ro" >> "$COMPOSE_FILE"
    echo "      - /etc/droplet.env:/etc/droplet.env:ro" >> "$COMPOSE_FILE"
    echo "      - /etc/habitat-parsed.env:/etc/habitat-parsed.env:ro" >> "$COMPOSE_FILE"
    echo "      - /var/lib/init-status:/var/lib/init-status" >> "$COMPOSE_FILE"
    echo "      - /var/log:/var/log" >> "$COMPOSE_FILE"
    echo "      - ${HOME_DIR}/clawd:${HOME_DIR}/clawd" >> "$COMPOSE_FILE"
    if [ -n "$SHARED" ]; then
        IFS=',' read -ra PATHS <<< "$SHARED"
        for sp in "${PATHS[@]}"; do
            echo "      - .${sp}:${sp}" >> "$COMPOSE_FILE"
        done
    fi

    # Port for this group (base 18789, offset by group index)
    local group_idx=0
    for g in "${CONTAINER_GROUPS[@]}"; do
        [ "$g" = "$group" ] && break
        group_idx=$((group_idx + 1))
    done
    local group_port=$((18789 + group_idx))

    # Environment — pass GROUP and GROUP_PORT so health check is universal
    cat >> "$COMPOSE_FILE" <<ENV
    environment:
      - AGENT_NAMES=${agent_names}
      - GROUP=${group}
      - GROUP_PORT=${group_port}
      - ISOLATION=container
      - RUN_MODE=execstartpost
    container_name: openclaw-${group}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:${group_port}/"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 60s
ENV

    # Entrypoint: start gateway, then run health check (like ExecStart + ExecStartPost)
    cat >> "$COMPOSE_FILE" <<'ENTRY'
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        # Start gateway in background
        openclaw gateway --bind loopback --port $${GROUP_PORT} &
        GW_PID=$$!
        # Wait for gateway to be ready, then run health check
        sleep 30
        /usr/local/bin/gateway-health-check.sh
        # Keep gateway running
        wait $$GW_PID
ENTRY

    echo "  [${group}] network=${net} port=${group_port} agents=${agent_names} → docker-compose.yaml"
done

# Add internal network definition if needed
if [ "$needs_internal" = true ]; then
    cat >> "$COMPOSE_FILE" <<NETS
networks:
  internal:
    driver: bridge
    internal: true
NETS
fi

echo "Generated docker-compose.yaml with ${#CONTAINER_GROUPS[@]} service(s) for habitat '${HABITAT}'"
