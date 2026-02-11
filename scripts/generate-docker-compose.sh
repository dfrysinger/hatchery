#!/bin/bash
# =============================================================================
# generate-docker-compose.sh -- Generate docker-compose.yaml for container isolation
# =============================================================================
# Purpose:  When isolation mode is 'container', generate docker-compose.yaml
#           with services per isolation group, volumes, networks, and resource limits.
#
# Inputs:   /etc/habitat-parsed.env -- parsed habitat with v3 isolation fields
#           ISOLATION_DEFAULT -- top-level isolation mode
#           ISOLATION_GROUPS -- comma-separated list of unique groups
#           AGENT{N}_ISOLATION, AGENT{N}_ISOLATION_GROUP, AGENT{N}_NETWORK, etc.
#
# Outputs:  docker-compose.yaml -- in current directory
#
# Usage:    source /etc/habitat-parsed.env && ./generate-docker-compose.sh
# =============================================================================

set -e

[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

# Check if container mode is used
NEEDS_COMPOSE="false"
for i in $(seq 1 ${AGENT_COUNT:-1}); do
  IV="AGENT${i}_ISOLATION"
  if [ "${!IV}" = "container" ]; then
    NEEDS_COMPOSE="true"
    break
  fi
done

if [ "$NEEDS_COMPOSE" != "true" ] && [ "$ISOLATION_DEFAULT" != "container" ]; then
  echo "[generate-docker-compose] No container isolation needed, skipping" >&2
  exit 0
fi

echo "[generate-docker-compose] Generating docker-compose.yaml for container mode..." >&2

# Parse shared paths (comma-separated)
IFS=',' read -ra SHARED_PATHS_ARRAY <<< "$SHARED_PATHS"

# Start building docker-compose.yaml
cat > docker-compose.yaml << 'YAML_HEADER'
version: '3.8'

services:
YAML_HEADER

# Build service for each isolation group
IFS=',' read -ra GROUPS <<< "$ISOLATION_GROUPS"
for group in "${GROUPS[@]}"; do
  # Find agents in this group
  AGENTS_IN_GROUP=""
  NETWORK_MODE="host"  # Default
  MEM_LIMIT=""
  
  for i in $(seq 1 ${AGENT_COUNT:-1}); do
    GV="AGENT${i}_ISOLATION_GROUP"
    IV="AGENT${i}_ISOLATION"
    if [ "${!GV}" = "$group" ] && [ "${!IV}" = "container" ]; then
      NV="AGENT${i}_NAME"
      AGENT_NAME="${!NV}"
      [ -n "$AGENTS_IN_GROUP" ] && AGENTS_IN_GROUP="$AGENTS_IN_GROUP,"
      AGENTS_IN_GROUP="$AGENTS_IN_GROUP$AGENT_NAME"
      
      # Get network mode (use first agent's setting in group)
      if [ -z "$NETWORK_MODE_SET" ]; then
        NMV="AGENT${i}_NETWORK"
        NETWORK_MODE="${!NMV:-host}"
        NETWORK_MODE_SET="true"
      fi
      
      # Get memory limit (use first agent's setting in group)
      if [ -z "$MEM_LIMIT" ]; then
        RMV="AGENT${i}_RESOURCES_MEMORY"
        MEM_LIMIT="${!RMV}"
      fi
    fi
  fi
  
  [ -z "$AGENTS_IN_GROUP" ] && continue
  
  # Write service definition
  cat >> docker-compose.yaml << EOF
  ${group}:
    image: hatchery/agent:latest
EOF
  
  # Network mode
  case "$NETWORK_MODE" in
    none)
      echo "    network_mode: none" >> docker-compose.yaml
      ;;
    internal)
      echo "    networks:" >> docker-compose.yaml
      echo "      - internal" >> docker-compose.yaml
      ;;
    host|*)
      echo "    network_mode: host" >> docker-compose.yaml
      ;;
  esac
  
  # Memory limit
  if [ -n "$MEM_LIMIT" ]; then
    echo "    mem_limit: $MEM_LIMIT" >> docker-compose.yaml
  fi
  
  # Volumes
  echo "    volumes:" >> docker-compose.yaml
  for path in "${SHARED_PATHS_ARRAY[@]}"; do
    [ -n "$path" ] && echo "      - .${path}:${path}" >> docker-compose.yaml
  done
  echo "      - ./config/${group}:/home/bot/.openclaw" >> docker-compose.yaml
  
  # Environment
  echo "    environment:" >> docker-compose.yaml
  echo "      - AGENT_NAMES=${AGENTS_IN_GROUP}" >> docker-compose.yaml
  echo "" >> docker-compose.yaml
done

# Add networks section if internal network is used
if grep -q "networks:" docker-compose.yaml 2>/dev/null; then
  cat >> docker-compose.yaml << 'YAML_NETWORKS'
networks:
  internal:
    driver: bridge
    internal: true
YAML_NETWORKS
fi

echo "[generate-docker-compose] docker-compose.yaml generated successfully" >&2
