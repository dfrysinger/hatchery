# Agent Isolation - API Contracts

## Feature Issue
GitHub Issue #222 | Milestone: R6: Agent Isolation

## Overview

Agent Isolation does not introduce new HTTP API endpoints.
It operates at the build/provisioning layer via shell scripts
that consume environment variables and produce configuration files.

## Script Interfaces

### generate-session-services.sh

**Inputs (environment variables):**
- `ISOLATION_DEFAULT` — must be `session` to activate
- `ISOLATION_GROUPS` — comma-separated group names
- `AGENT_COUNT` — number of agents (required)
- `AGENT{N}_NAME`, `AGENT{N}_ISOLATION_GROUP`, `AGENT{N}_ISOLATION`
- `AGENT{N}_MODEL`, `AGENT{N}_BOT_TOKEN`, `AGENT{N}_NETWORK`
- `USERNAME`, `HABITAT_NAME`, `ISOLATION_SHARED_PATHS`, `PLATFORM`

**Configuration:**
- `SESSION_OUTPUT_DIR` — output directory (default: `/etc/systemd/system`)
- `DRY_RUN` — if set, skip systemctl commands

**Outputs:**
- `openclaw-{group}.service` per session group
- `{group}/openclaw.session.json` per session group

**Exit codes:**
- `0` — success (or skipped because mode is not session)
- `1` — AGENT_COUNT not set

### generate-docker-compose.sh

**Inputs (environment variables):**
- `ISOLATION_DEFAULT` — must be `container` to activate
- `ISOLATION_GROUPS` — comma-separated group names
- `AGENT_COUNT` — number of agents (required)
- `AGENT{N}_NAME`, `AGENT{N}_ISOLATION_GROUP`, `AGENT{N}_ISOLATION`
- `AGENT{N}_NETWORK`, `AGENT{N}_RESOURCES_MEMORY`, `AGENT{N}_RESOURCES_CPU`
- `USERNAME`, `HABITAT_NAME`, `ISOLATION_SHARED_PATHS`

**Configuration:**
- `COMPOSE_OUTPUT_DIR` — output directory (default: `/home/$USERNAME`)
- `CONTAINER_IMAGE` — base image (default: `hatchery/agent:latest`)
- `DRY_RUN` — if set, skip docker-compose up

**Outputs:**
- `docker-compose.yaml` in output directory

**Exit codes:**
- `0` — success (or skipped because mode is not container)
- `1` — AGENT_COUNT not set

## OpenClaw Session Config Format

Each session group gets a JSON config:

```json
{
  "gateway": {
    "mode": "local",
    "port": 18790,
    "bind": "lan",
    "controlUi": {"enabled": true, "allowInsecureAuth": true},
    "auth": {"mode": "token", "token": "session-{group}"}
  },
  "agents": {
    "defaults": {"model": {"primary": "anthropic/claude-opus-4-5"}},
    "list": [{"id": "agent1", "name": "AgentName", "model": "...", "workspace": "..."}]
  }
}
```

## Docker Compose Output Format

```yaml
version: '3.8'
services:
  {group}:
    image: hatchery/agent:latest
    network_mode: host|none
    mem_limit: 512Mi
    cpus: 0.5
    volumes:
      - ./config/{group}:/home/bot/.openclaw
      - .{sharedPath}:{sharedPath}
    environment:
      - AGENT_NAMES=Agent1,Agent2
networks:
  internal:
    driver: bridge
    internal: true
```
