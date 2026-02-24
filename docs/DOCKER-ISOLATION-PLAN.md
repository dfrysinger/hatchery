# Docker Container Isolation — Implementation Plan v4

> Original v1 by ClaudeBot (2026-02-21). Reviewed by ChatGPTBot (11 comments).
> v2 by ClaudeBot (2026-02-21) — all review comments addressed.
> v3 by ClaudeBot (2026-02-24) — comprehensive rewrite with full implementation details.
> v4 by ClaudeBot (2026-02-24) — SSOT audit, shared code architecture, revised phases.
> v5 by ClaudeBot (2026-02-24) — integrated ChatGPT cross-mode audit (6 fixes + manifest).

---

## Table of Contents

1. [Architecture Decision](#architecture-decision)
2. [Current State Assessment](#current-state-assessment)
3. [SSOT Violations to Fix](#ssot-violations-to-fix)
4. [Target Architecture](#target-architecture)
5. [Pre-Implementation Checklist](#pre-implementation-checklist)
6. [Phase 1: Shared Foundation](#phase-1-shared-foundation)
7. [Phase 2: Fix Compose Generator](#phase-2-fix-compose-generator)
8. [Phase 3: Dockerfile + Docker Install](#phase-3-dockerfile--docker-install)
9. [Phase 4: Health Check Abstraction](#phase-4-health-check-abstraction)
10. [Phase 5: First Live Test](#phase-5-first-live-test)
11. [Phase 6: Network Isolation](#phase-6-network-isolation)
12. [Phase 7: Security Hardening + Resource Limits](#phase-7-security-hardening--resource-limits)
13. [Config Hot-Reload](#config-hot-reload)
14. [Rollback Procedures](#rollback-procedures)
15. [Container Lifecycle Management](#container-lifecycle-management)
16. [Debugging and Incident Triage](#debugging-and-incident-triage)
17. [Open Questions](#open-questions)
18. [Estimate](#estimate)

---

## Architecture Decision

**Host-orchestrated** — containers are runtime boundaries, not autonomous units.

| Concern | Runs on | Why |
|---------|---------|-----|
| Health checks | Host | Reuse `gateway-health-check.sh`, `gateway-e2e-check.sh` unchanged |
| Safe mode detection | Host | `.path` unit watches marker files on host filesystem |
| Safe mode recovery | Host | `safe-mode-handler.sh`, `safe-mode-recovery.sh` stay on host |
| Config generation | Host | `build-full-config.sh` → per-group configs + mode-specific artifacts |
| State machine | Host | `openclaw-state.sh` operates on host-local state files |
| OpenClaw gateway | Container | Only the runtime process is isolated |
| Agent workspace | Container (rw) | Bind-mounted from host for persistence |

**Why not self-contained (Option B)?** Self-contained containers would need health check scripts, `lib-*.sh`, marker files, and recovery tooling inside each container. This duplicates the entire host infrastructure, creates version drift, and defeats the purpose of isolation (containers would have full access to `/var/lib/init-status`, `/var/log`, etc.). Option A keeps containers thin and the host in control.

**Key adaptation surface:**
- `systemctl restart openclaw-{group}` → `docker compose -p openclaw-{group} restart`
- `systemctl stop openclaw-{group}` → `docker compose -p openclaw-{group} down`
- `journalctl -u openclaw-{group}` → `docker compose -p openclaw-{group} logs`
- `pgrep -f openclaw.gateway` → `docker inspect --format='{{.State.Running}}' openclaw-{group}`

---

## Current State Assessment

### What Exists

| Artifact | Status | Issues |
|----------|--------|--------|
| `generate-docker-compose.sh` | ⚠️ Scaffolded | Built for Option B — mounts scripts, state, logs into containers |
| `generate-session-services.sh` | ✅ Working | Contains logic that should be shared (config gen, auth, dirs, safeguard units) |
| `build-full-config.sh` | ✅ Working | Orchestrator, but delegates too much to generators |
| `generate-config.sh` | ✅ Working | `--mode session` for per-group configs, `--mode safe-mode` for recovery |
| `test_docker_compose.py` | ✅ 26 tests pass | Tests validate current (wrong) Option B behavior |
| `docs/specs/agent-isolation/` | ✅ Specs exist | `architecture.md` (corrupted), `data-model.md`, `api-contracts.md` |
| `examples/habitat-isolation-container.json` | ✅ Example | Good reference for container habitat config |
| `parse-habitat.py` | ✅ Outputs container vars | `AGENT{N}_ISOLATION`, `AGENT{N}_NETWORK`, `AGENT{N}_RESOURCES_*` |
| `safe-mode-handler.sh` | ⚠️ Partial | Has `docker restart`/`docker inspect` stubs (lines 298-309) |
| `lib-health-check.sh` | ✅ Working | Needs container-aware abstractions added |
| `lib-isolation.sh` | ❌ Missing | Shared group/agent/port functions don't exist yet |
| `Dockerfile` | ❌ Missing | `hatchery/agent:latest` referenced but never built |
| Docker install in provisioning | ❌ Missing | `provision.sh` doesn't install Docker |
| Container systemd units | ❌ Missing | No `openclaw-container-{group}.service` template |
| Port allocator | ❌ Missing | Two generators use different base ports |

---

## SSOT Violations to Fix

Six concerns are currently duplicated across isolation types. Phase 1 consolidates all of them.

### 1. Agent-per-group filtering (reimplemented 3×)

The pattern "iterate `AGENT{N}_ISOLATION_GROUP`, match against group name" exists in:
- `generate-session-services.sh` (lines 85-96)
- `generate-docker-compose.sh` (lines 68-82)
- `generate-docker-compose.sh` again in `get_group_network()`, `get_group_memory()`, `get_group_cpu()`, `get_group_agent_names()` (lines 110-170)

### 2. OpenClaw config generation (session-only)

`generate-session-services.sh` calls `generate-config.sh --mode session` to produce `openclaw.session.json`. `generate-docker-compose.sh` doesn't generate a config at all — it mounts a `./config/${group}` directory and hopes something else fills it.

### 3. Auth-profiles handling (3 different approaches)

- `build-full-config.sh` creates `agents/main/agent/auth-profiles.json`, symlinks to `agents/agent{N}/agent/`
- `generate-session-services.sh` copies auth-profiles into `${state_dir}/agents/agent{N}/agent/`
- Container mode (planned) would bind-mount from `configs/{group}/`

### 4. Port assignment (different base ports, will collide)

- `generate-session-services.sh`: `BASE_PORT=18790`, offset by group index within session groups
- `generate-docker-compose.sh`: `18789 + offset` within container groups
- Mixed mode = guaranteed collision

### 5. Safeguard/E2E units (session-only)

`generate-session-services.sh` generates safeguard `.path`, `.service`, and E2E check service per group. Container mode needs the same units (they run on the host). Currently no container equivalent exists.

### 6. Directory structure setup (scattered 3×)

Directory creation for configs, state, workspaces scattered across `build-full-config.sh`, `generate-session-services.sh`, and (planned) compose generator.

---

## Target Architecture

After Phase 1, the pipeline looks like this:

```
build-full-config.sh (orchestrator — single entry point)
  │
  ├── source lib-isolation.sh
  │     ├── get_group_agents(group)          → "agent1,agent3"
  │     ├── get_group_port(group)            → reads /etc/openclaw-ports.env
  │     ├── get_group_network(group)         → "host"|"internal"|"none"
  │     ├── get_group_resources(group)       → "512Mi 0.5"
  │     ├── get_group_isolation(group)       → "session"|"container"
  │     ├── get_groups_by_type(type)         → "council,workers"
  │     └── generate_safeguard_units(group, port, isolation, output_dir)
  │
  ├── allocate_ports()                       → /etc/openclaw-ports.env
  ├── generate_groups_manifest()             → /etc/openclaw-groups.json
  ├── validate_group_consistency(group)      → fail fast on mixed values
  │
  ├── FOR EACH group:
  │     ├── setup_group_directories(group)   → config dir, state dir, agent subdirs
  │     ├── generate_group_env(group)        → group.env (decoded secrets + metadata)
  │     ├── generate_group_config(group)     → openclaw.session.json (ALL modes)
  │     ├── setup_group_auth_profiles(group) → symlink master auth-profiles
  │     ├── generate_group_token(group)      → per-group gateway token
  │     └── generate_safeguard_units(group)  → .path + .service + E2E (ALL modes)
  │
  ├── generate-session-services.sh           → THIN: systemd unit files only
  │     (reads port from /etc/openclaw-ports.env, config/auth already exist)
  │
  └── generate-docker-compose.sh             → THIN: compose + container systemd unit only
        (reads port from /etc/openclaw-ports.env, config/auth already exist)
```

**Runtime manifest:** `build-full-config.sh` also writes `/etc/openclaw-groups.json` — the runtime source of truth for all group topology. Scripts that need to know "what groups exist, what ports, what isolation type" read this file instead of re-parsing env vars.

```json
{
  "generated": "2026-02-24T07:30:00Z",
  "groups": {
    "council": {
      "isolation": "session",
      "port": 18790,
      "network": "host",
      "agents": ["agent1", "agent3"],
      "configPath": "/home/bot/.openclaw/configs/council/openclaw.session.json",
      "statePath": "/home/bot/.openclaw-sessions/council",
      "envFile": "/home/bot/.openclaw/configs/council/group.env",
      "serviceName": "openclaw-council",
      "composePath": null
    },
    "sandbox": {
      "isolation": "container",
      "port": 18791,
      "network": "internal",
      "agents": ["agent2"],
      "configPath": "/home/bot/.openclaw/configs/sandbox/openclaw.session.json",
      "statePath": "/home/bot/.openclaw-sessions/sandbox",
      "envFile": "/home/bot/.openclaw/configs/sandbox/group.env",
      "serviceName": "openclaw-container-sandbox",
      "composePath": "/home/bot/.openclaw/compose/sandbox/docker-compose.yaml"
    }
  }
}
```

All consumers (`lib-health-check.sh`, `safe-mode-handler.sh`, `sync-openclaw-state.sh`, etc.) can read this manifest with `jq` instead of re-deriving topology from env vars.

**Key principle:** generators are thin. They produce ONLY mode-specific artifacts:
- Session: one systemd `.service` file per group
- Container: one `docker-compose.yaml` + one systemd `.service` file per group

Everything else (config, auth, ports, dirs, safeguard units) is centralized in `build-full-config.sh`.

---

## Pre-Implementation Checklist

Complete before writing Phase 1 code:

- [ ] **`COMPOSE_PROJECT_NAME` convention**: `openclaw-{group}`
- [ ] **File layout** (see [Appendix](#appendix-file-layout-reference))
- [ ] **Security baseline**: `cap_drop: ALL`, `no-new-privileges:true`, `read_only: true` + tmpfs
- [ ] **Port range**: 18790+ (18789 reserved for non-isolated default)
- [ ] **Rollback commands** documented per phase (see [Rollback Procedures](#rollback-procedures))

---

## Phase 1: Shared Foundation

**Goal:** Create `lib-isolation.sh`, centralize port allocation, extract shared concerns from generators into `build-full-config.sh`. Both generators become thin.

This is the most important phase. Everything else depends on it.

### 1.1 Create `lib-isolation.sh`

New shared library sourced by `build-full-config.sh` and both generators:

```bash
#!/bin/bash
# =============================================================================
# lib-isolation.sh — Shared functions for isolation group management
# =============================================================================
# Single source of truth for group/agent queries, port lookups, and
# generation of mode-agnostic systemd units (safeguard, E2E).
#
# Dependencies: lib-env.sh (env_load), lib-permissions.sh (ensure_bot_dir)
# =============================================================================

# --- Group/Agent Queries ---

# Get agent IDs belonging to a group (comma-separated).
# Usage: get_group_agents "council" → "agent1,agent3"
get_group_agents() {
    local group="$1"
    local agents=""
    for i in $(seq 1 "${AGENT_COUNT:?AGENT_COUNT required}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local iso_var="AGENT${i}_ISOLATION"
        local ag="${!ag_var:-}"
        local iso="${!iso_var:-}"
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
    for i in $(seq 1 "${AGENT_COUNT}"); do
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
get_group_network() {
    local group="$1"
    for i in $(seq 1 "${AGENT_COUNT}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        local net_var="AGENT${i}_NETWORK"
        if [ "${!ag_var:-}" = "$group" ] && [ -n "${!net_var:-}" ]; then
            echo "${!net_var}"
            return
        fi
    done
    echo "host"
}

# Get resource limits for a group: "memory cpu" (empty strings if unset).
get_group_resources() {
    local group="$1"
    local mem="" cpu=""
    for i in $(seq 1 "${AGENT_COUNT}"); do
        local ag_var="AGENT${i}_ISOLATION_GROUP"
        if [ "${!ag_var:-}" = "$group" ]; then
            local mem_var="AGENT${i}_RESOURCES_MEMORY"
            local cpu_var="AGENT${i}_RESOURCES_CPU"
            [ -z "$mem" ] && mem="${!mem_var:-}"
            [ -z "$cpu" ] && cpu="${!cpu_var:-}"
        fi
    done
    echo "$mem $cpu"
}

# Get groups filtered by isolation type.
# Usage: get_groups_by_type "session" → "council workers"
get_groups_by_type() {
    local type="$1"
    local result=""
    IFS=',' read -ra groups <<< "${ISOLATION_GROUPS:-}"
    for group in "${groups[@]}"; do
        if [ "$(get_group_isolation "$group")" = "$type" ]; then
            [ -n "$result" ] && result="${result} "
            result="${result}${group}"
        fi
    done
    echo "$result"
}

# --- Port Allocation ---

# Port file format: one "group=port" per line (not shell vars — safe for hyphenated names).
# Example:
#   code-sandbox=18790
#   council=18791
#   workers=18792
PORT_FILE="/etc/openclaw-ports.env"

# Read port for a group from the centralized port file.
# Uses grep, not shell variable expansion — safe for hyphenated group names.
# Usage: get_group_port "code-sandbox" → "18790"
get_group_port() {
    local group="$1"
    [ -f "$PORT_FILE" ] && grep "^${group}=" "$PORT_FILE" | cut -d= -f2
}

# Allocate ports for all groups. Deterministic: sorted alphabetically, BASE_PORT=18790.
# Writes /etc/openclaw-ports.env as the single source of truth.
allocate_ports() {
    local base_port=18790

    IFS=',' read -ra groups_array <<< "${ISOLATION_GROUPS:?ISOLATION_GROUPS required}"
    local groups_sorted
    groups_sorted=($(printf '%s\n' "${groups_array[@]}" | sort))

    {
        echo "# Generated by build-full-config.sh — do not edit"
        echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Format: group=port (sorted alphabetically, base=${base_port})"
        local offset=0
        for group in "${groups_sorted[@]}"; do
            echo "${group}=$((base_port + offset))"
            offset=$((offset + 1))
        done
    } > "$PORT_FILE"

    chmod 644 "$PORT_FILE"
}

# --- Manifest Generation ---

# Write /etc/openclaw-groups.json — the runtime source of truth for all group topology.
# All scripts read this instead of re-parsing env vars or port files.
generate_groups_manifest() {
    local manifest="/etc/openclaw-groups.json"
    local json='{"generated":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","groups":{'
    local first=true

    IFS=',' read -ra groups <<< "${ISOLATION_GROUPS:?}"
    for group in "${groups[@]}"; do
        local port isolation network agents service_name compose_path
        port=$(get_group_port "$group")
        isolation=$(get_group_isolation "$group")
        network=$(get_group_network "$group")
        agents=$(get_group_agents "$group")

        case "$isolation" in
            container) service_name="openclaw-container-${group}"
                       compose_path="${HOME_DIR}/.openclaw/compose/${group}/docker-compose.yaml" ;;
            session)   service_name="openclaw-${group}"
                       compose_path="null" ;;
            *)         service_name=""
                       compose_path="null" ;;
        esac

        # Convert comma-separated agents to JSON array
        local agents_json
        agents_json=$(echo "$agents" | tr ',' '\n' | jq -R . | jq -sc .)

        $first || json="${json},"
        first=false
        json="${json}\"${group}\":{"
        json="${json}\"isolation\":\"${isolation}\","
        json="${json}\"port\":${port},"
        json="${json}\"network\":\"${network}\","
        json="${json}\"agents\":${agents_json},"
        json="${json}\"configPath\":\"${CONFIG_BASE}/${group}/openclaw.session.json\","
        json="${json}\"statePath\":\"${STATE_BASE}/${group}\","
        json="${json}\"envFile\":\"${CONFIG_BASE}/${group}/group.env\","
        json="${json}\"serviceName\":\"${service_name}\","
        json="${json}\"composePath\":$([ "$compose_path" = "null" ] && echo 'null' || echo "\"${compose_path}\"")"
        json="${json}}"
    done

    json="${json}}}"
    echo "$json" | jq . > "$manifest"
    chmod 644 "$manifest"
}

# --- Group Validation (fail fast) ---

# Validate that all agents in a group have consistent isolation/network/resources.
# Mixed values within a group = hard error during generation.
validate_group_consistency() {
    local group="$1"
    local first_iso="" first_net=""
    for i in $(seq 1 "${AGENT_COUNT}"); do
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

# --- Backend Dispatch ---
# All three backends (none/session/container) use the same pipeline.
# The only difference is which service artifact is generated.
# "none" mode: single OpenClaw process, no per-group service. Config goes to default path.
# "session" mode: per-group systemd service.
# "container" mode: per-group compose file + systemd service wrapper.

# --- Per-Group Setup (mode-agnostic) ---

# Create all directories for a group.
setup_group_directories() {
    local group="$1"
    local config_dir="${CONFIG_BASE:?}/${group}"
    local state_dir="${STATE_BASE:?}/${group}"

    ensure_bot_dir "$config_dir" 700
    ensure_bot_dir "$state_dir" 700

    # Per-agent subdirs within the state dir (OpenClaw expects this layout)
    local agents
    IFS=',' read -ra agents <<< "$(get_group_agents "$group")"
    for agent_id in "${agents[@]}"; do
        ensure_bot_dir "${state_dir}/agents/${agent_id}/agent" 700
    done
}

# Set up auth-profiles for all agents in a group (symlink to master).
setup_group_auth_profiles() {
    local group="$1"
    local state_dir="${STATE_BASE:?}/${group}"
    local master="${HOME_DIR:?}/.openclaw/agents/main/agent/auth-profiles.json"

    if [ ! -f "$master" ]; then
        echo "WARNING: No master auth-profiles.json at $master" >&2
        return 1
    fi

    local agents
    IFS=',' read -ra agents <<< "$(get_group_agents "$group")"
    for agent_id in "${agents[@]}"; do
        local target="${state_dir}/agents/${agent_id}/agent/auth-profiles.json"
        ln -sf "$master" "$target"
    done
}

# Generate per-group gateway token.
generate_group_token() {
    local group="$1"
    local config_dir="${CONFIG_BASE:?}/${group}"
    local token_file="${config_dir}/gateway-token.txt"

    if [ ! -f "$token_file" ]; then
        openssl rand -hex 16 > "$token_file"
        chmod 600 "$token_file"
        chown "${SVC_USER:?}:${SVC_USER}" "$token_file" 2>/dev/null || true
    fi
    cat "$token_file"
}

# Write per-group environment file with decoded secrets and group metadata.
# Consumed by systemd EnvironmentFile= and compose env_file: — single source for both.
# No script should decode B64 independently; all use this pre-decoded file.
generate_group_env() {
    local group="$1"
    local config_dir="${CONFIG_BASE:?}/${group}"
    local port
    port=$(get_group_port "$group")
    local isolation
    isolation=$(get_group_isolation "$group")
    local network
    network=$(get_group_network "$group")
    local env_file="${config_dir}/group.env"

    cat > "$env_file" <<ENVFILE
# Generated per-group environment — do not edit
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
    chown "${SVC_USER}:${SVC_USER}" "$env_file" 2>/dev/null || true
}

# Generate OpenClaw config for a group (delegates to generate-config.sh).
generate_group_config() {
    local group="$1"
    local config_dir="${CONFIG_BASE:?}/${group}"
    local port
    port=$(get_group_port "$group")
    local token
    token=$(generate_group_token "$group")
    local agents
    agents=$(get_group_agents "$group")

    local gen_script=""
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

    chown "${SVC_USER}:${SVC_USER}" "${config_dir}/openclaw.session.json" 2>/dev/null || true
    chmod 600 "${config_dir}/openclaw.session.json" 2>/dev/null || true
}

# --- Systemd Unit Generation (mode-agnostic) ---

# Generate safeguard .path + .service for any group.
# These run on the host regardless of isolation mode.
generate_safeguard_units() {
    local group="$1"
    local port="$2"
    local isolation="$3"
    local output_dir="${4:-/etc/systemd/system}"

    local config_dir="${CONFIG_BASE:?}/${group}"

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

    # .service unit — reads all group metadata from EnvironmentFile (not hardcoded)
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
    local port="$2"
    local isolation="$3"
    local output_dir="${4:-/etc/systemd/system}"
    local config_dir="${CONFIG_BASE:?}/${group}"

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
```

### 1.2 Centralize in `build-full-config.sh`

Move the per-group setup loop into `build-full-config.sh`, before generator dispatch:

```bash
source /usr/local/sbin/lib-isolation.sh

# --- Centralized per-group setup (all modes) ---
if [ -n "${ISOLATION_GROUPS:-}" ]; then
    # 1. Allocate ports (single source of truth)
    allocate_ports

    # 2. Generate runtime manifest (single source of truth for group topology)
    generate_groups_manifest

    # 3. Validate group consistency (fail fast on mixed isolation/network within a group)
    IFS=',' read -ra ALL_GROUPS <<< "$ISOLATION_GROUPS"
    for group in "${ALL_GROUPS[@]}"; do
        validate_group_consistency "$group" || exit 1
    done

    # 4. Per-group setup (dirs, env, config, auth, tokens, safeguard units)
    for group in "${ALL_GROUPS[@]}"; do
        port=$(get_group_port "$group")
        isolation=$(get_group_isolation "$group")

        setup_group_directories "$group"
        generate_group_env "$group"           # secrets + metadata → group.env
        generate_group_config "$group"        # OpenClaw JSON config
        setup_group_auth_profiles "$group"    # symlink master auth-profiles
        generate_safeguard_units "$group" "$port" "$isolation"
        generate_e2e_unit "$group" "$port" "$isolation"

        echo "  [${group}] isolation=${isolation} port=${port} → configured"
    done

    # 5. Dispatch to mode-specific generators (thin — service definitions only)
    session_groups=$(get_groups_by_type "session")
    container_groups=$(get_groups_by_type "container")

    if [ -n "$session_groups" ]; then
        ISOLATION_GROUPS="$(echo "$session_groups" | tr ' ' ',')" \
            bash /usr/local/sbin/generate-session-services.sh
    fi
    if [ -n "$container_groups" ]; then
        ISOLATION_GROUPS="$(echo "$container_groups" | tr ' ' ',')" \
            bash /usr/local/sbin/generate-docker-compose.sh
    fi
fi
```

### 1.3 Slim Down `generate-session-services.sh`

Remove from `generate-session-services.sh`:
- ❌ Agent-per-group filtering loop (use `get_group_agents` from lib)
- ❌ `generate-config.sh` call (done by orchestrator)
- ❌ Auth-profiles copy (done by orchestrator)
- ❌ Directory creation (done by orchestrator)
- ❌ Safeguard/E2E unit generation (done by orchestrator)
- ❌ Port computation (read from `/etc/openclaw-ports.env`)

What remains:
- ✅ Generate the session-mode systemd `.service` file per group (the main service unit)
- ✅ Enable/start services (or skip if `DRY_RUN`)

The script drops from ~380 lines to ~80 lines.

### 1.4 Slim Down `generate-docker-compose.sh`

Remove from `generate-docker-compose.sh`:
- ❌ Agent-per-group filtering loop + `get_group_*` functions
- ❌ Port computation
- ❌ All Option B volume mounts

What remains:
- ✅ Generate `docker-compose.yaml` per group with correct Option A mounts
- ✅ Generate the container-mode systemd `.service` file per group
- ✅ Enable/start services (or skip if `DRY_RUN`)

### 1.5 Update Tests

**TDD approach:** Write new tests first (RED), then refactor (GREEN), then delete old tests.

New tests for `lib-isolation.sh`:
- `get_group_agents()` returns correct agents for each group
- `get_group_isolation()` returns correct type, falls back to `ISOLATION_DEFAULT`
- `get_group_network()` returns correct mode, defaults to "host"
- `get_group_resources()` returns memory/cpu or empty strings
- `get_groups_by_type()` correctly filters session vs container groups
- `allocate_ports()` is deterministic (same input → same output)
- `allocate_ports()` doesn't collide (unique ports for all groups)
- `generate_safeguard_units()` creates valid systemd units
- `generate_e2e_unit()` passes `ISOLATION` to environment

Updated tests for generators:
- Session generator only creates `.service` file (no config, no auth, no safeguard)
- Container generator only creates `docker-compose.yaml` + `.service` file
- Both read ports from `/etc/openclaw-ports.env` (not computed)

### Acceptance Criteria

- [ ] `lib-isolation.sh` passes `bash -n` syntax check
- [ ] All `get_group_*` functions return correct results for test fixtures
- [ ] `get_group_port` works with hyphenated group names (e.g., `code-sandbox`)
- [ ] `allocate_ports` is idempotent (same input → same ports)
- [ ] No port collisions in mixed mode (session + container groups)
- [ ] `validate_group_consistency` rejects mixed isolation/network within a group
- [ ] `/etc/openclaw-groups.json` manifest is valid JSON with all group metadata
- [ ] `group.env` files contain decoded secrets (no B64) + group metadata
- [ ] Safeguard/E2E units use `EnvironmentFile=` (not hardcoded `Environment=` lines)
- [ ] `generate-session-services.sh` does NOT call `generate-config.sh`
- [ ] `generate-session-services.sh` does NOT copy auth-profiles
- [ ] `generate-session-services.sh` does NOT generate safeguard/E2E units
- [ ] `generate-docker-compose.sh` does NOT have `get_group_*` functions
- [ ] Existing session isolation still works (regression test on real droplet)

### Rollback

```bash
# Revert all three scripts + new library
git checkout HEAD~1 -- scripts/lib-isolation.sh scripts/build-full-config.sh \
    scripts/generate-session-services.sh scripts/generate-docker-compose.sh
rm -f /etc/openclaw-ports.env
```

---

## Phase 2: Fix Compose Generator

**Goal:** `generate-docker-compose.sh` produces correct Option A compose files. (Now thin, since Phase 1 extracted shared concerns.)

### 2.1 Correct Volume Mounts

Containers get exactly these mounts (nothing more):

```yaml
volumes:
  # OpenClaw config (generated by orchestrator, read by container)
  - ${CONFIG_DIR}/openclaw.session.json:${HOME}/.openclaw/openclaw.json:ro
  # Gateway token (per-group)
  - ${CONFIG_DIR}/gateway-token.txt:${HOME}/.openclaw/gateway-token.txt:ro
  # Session state dir (transcripts, auth-profiles already symlinked inside)
  - ${STATE_DIR}:${HOME}/.openclaw-sessions/${GROUP}:rw
  # Agent workspaces (rw — agents write memory, transcripts, etc.)
  - ${HOME}/clawd/agents/${AGENT}:${HOME}/clawd/agents/${AGENT}:rw  # (one per agent)
  # Shared workspace (rw — cross-agent collaboration)
  - ${HOME}/clawd/shared:${HOME}/clawd/shared:rw
  # Additional shared paths from habitat config
  # (one entry per ISOLATION_SHARED_PATHS item)
```

Note: auth-profiles are already symlinked inside `${STATE_DIR}/agents/{agent}/agent/` by the orchestrator in Phase 1. No separate auth mount needed — the state dir mount covers it.

Mounts explicitly **removed** (Option B artifacts):
- ~~`/usr/local/bin/gateway-health-check.sh`~~
- ~~`/usr/local/bin/safe-mode-recovery.sh`~~
- ~~`/usr/local/bin/setup-safe-mode-workspace.sh`~~
- ~~`/usr/local/sbin/lib-permissions.sh`~~
- ~~`/etc/droplet.env`~~
- ~~`/etc/habitat-parsed.env`~~
- ~~`/var/lib/init-status`~~
- ~~`/var/log`~~

### 2.2 Entrypoint and Command

Container runs OpenClaw gateway only. Dockerfile sets `ENTRYPOINT ["openclaw", "gateway"]`, compose overrides only `CMD`:

```yaml
command: ["--bind", "loopback", "--port", "${GROUP_PORT}"]
```

### 2.3 Environment Variables

Use `env_file:` to load from the same `group.env` that systemd units use (single source for secrets + metadata). Add container-specific vars inline:

```yaml
env_file:
  - ${CONFIG_DIR}/group.env
environment:
  - NODE_ENV=production
  - NODE_OPTIONS=--experimental-sqlite
```

No per-script B64 decoding. `group.env` is pre-decoded by `generate_group_env()` in Phase 1.

### 2.4 Container Metadata

```yaml
container_name: openclaw-${GROUP}
restart: on-failure
user: "${BOT_UID}:${BOT_GID}"
```

### 2.5 Per-Group Compose Files

One compose file per group in a dedicated directory:

```
~/.openclaw/compose/council/docker-compose.yaml
~/.openclaw/compose/workers/docker-compose.yaml
~/.openclaw/compose/code-sandbox/docker-compose.yaml
```

Each uses `COMPOSE_PROJECT_NAME=openclaw-{group}`. The compose command:
```bash
docker compose -f ~/.openclaw/compose/${group}/docker-compose.yaml -p openclaw-${group} up -d
```

### 2.6 Container Systemd Unit Template

```ini
[Unit]
Description=OpenClaw Container - %i
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/home/${SVC_USER}

EnvironmentFile=/home/${SVC_USER}/.openclaw/configs/%i/group.env
ExecStart=/usr/bin/docker compose -f .openclaw/compose/%i/docker-compose.yaml -p openclaw-%i up -d --wait
ExecStop=/usr/bin/docker compose -f .openclaw/compose/%i/docker-compose.yaml -p openclaw-%i down
ExecStartPost=+/bin/bash -c 'source /home/${SVC_USER}/.openclaw/configs/%i/group.env && RUN_MODE=execstartpost /usr/local/bin/gateway-health-check.sh'

Restart=on-failure
RestartSec=10
RestartPreventExitStatus=2
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
```

Key differences from session mode unit:
- `Type=oneshot` + `RemainAfterExit=yes` (compose up returns immediately with `-d`)
- `Requires=docker.service`
- `User=root` (Docker socket; container runs as bot via compose `user:`)
- `ExecStop` runs `docker compose down`
- `--wait` blocks until containers are healthy

### Tests

Rewrite `test_docker_compose.py` for Option A:
- No script/state/log/secret mounts
- Config and gateway-token mounts are ro
- State dir mount is rw (contains auth-profiles symlinks)
- Workspace mounts are rw
- No bash wrapper entrypoint
- `container_name` follows `openclaw-{group}` convention
- Per-group compose files in `~/.openclaw/compose/{group}/`
- Environment includes API keys

### Acceptance Criteria

- [ ] `docker compose -f ~/.openclaw/compose/{group}/docker-compose.yaml config` validates
- [ ] Container systemd unit starts/stops cleanly
- [ ] No host scripts, state dirs, or log dirs mounted inside container
- [ ] `docker inspect` shows only the expected mounts
- [ ] `bash -n generate-docker-compose.sh` passes

### Rollback

```bash
git checkout HEAD~1 -- scripts/generate-docker-compose.sh
rm -rf ~/.openclaw/compose/
rm -f /etc/systemd/system/openclaw-container-*.service
systemctl daemon-reload
```

---

## Phase 3: Dockerfile + Docker Install

**Goal:** Build `hatchery/agent:latest` image and add Docker to the provisioning pipeline.

### 3.1 Dockerfile

```dockerfile
# hatchery/agent:latest — Minimal OpenClaw runtime
ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm-slim

ARG BOT_UID=1000
ARG BOT_GID=${BOT_UID}
ARG OPENCLAW_VERSION=latest

# System deps for OpenClaw + compose healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create bot user matching host UID (bind mount permissions)
RUN groupadd -g ${BOT_GID} bot 2>/dev/null || true \
    && useradd -u ${BOT_UID} -g ${BOT_GID} -m -s /bin/bash bot

# Install OpenClaw
RUN npm install -g openclaw@${OPENCLAW_VERSION}

USER bot
WORKDIR /home/bot
ENV NODE_ENV=production
ENV NODE_OPTIONS=--experimental-sqlite

# Health check for compose --wait
# Shell form required: GROUP_PORT is a runtime env var, not a build arg
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
    CMD curl -sf http://127.0.0.1:${GROUP_PORT:-18790}/ || exit 1

ENTRYPOINT ["openclaw", "gateway"]
CMD ["--bind", "loopback", "--port", "18790"]
```

Notes:
- `bookworm-slim` not alpine — native Node modules need glibc
- `BOT_UID` build arg matches host `bot` user for bind mount perms
- Browser variant (`hatchery/agent:full`) deferred to Phase 7
- Default CMD port overridden by compose `command:`

### 3.2 Docker Install in Provisioning

Add to `provision.sh` Stage 5, gated on isolation config:

```bash
if [ "$ISOLATION_DEFAULT" = "container" ] || group_needs_container; then
    # Official apt repo with version pinning (not curl|sh per AGENTS.md rules)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    usermod -aG docker "$USERNAME"
    systemctl enable docker && systemctl start docker

    # Configure log rotation
    cat > /etc/docker/daemon.json <<'DAEMON'
{
    "log-driver": "json-file",
    "log-opts": { "max-size": "50m", "max-file": "3" }
}
DAEMON
    systemctl restart docker

    # Build base image
    docker build \
        --build-arg BOT_UID="$(id -u "$USERNAME")" \
        --build-arg OPENCLAW_VERSION="$(openclaw --version 2>/dev/null || echo latest)" \
        -t hatchery/agent:latest \
        -f /opt/hatchery/Dockerfile /opt/hatchery/
fi
```

### Acceptance Criteria

- [ ] `docker build` succeeds with pinned OpenClaw version
- [ ] `docker run --rm hatchery/agent:latest --version` returns version
- [ ] Image size under 500MB
- [ ] Container runs as `bot` user (UID matches host)
- [ ] Compose healthcheck passes when gateway is running
- [ ] Log rotation configured (50MB × 3)

### Rollback

```bash
docker rmi hatchery/agent:latest
# Docker itself stays installed
```

---

## Phase 4: Health Check Abstraction

**Goal:** Health check scripts work identically for session and container modes via shared functions.

### 4.1 Service Abstraction Functions

Add to `lib-health-check.sh`:

```bash
# --- Isolation-aware service management ---
# All health check consumers use these functions — never direct systemctl/docker calls.

hc_restart_service() {
    local group="${1:?Usage: hc_restart_service <group>}"
    local isolation="${ISOLATION:-session}"
    case "$isolation" in
        container)
            docker compose -f "/home/${USERNAME}/.openclaw/compose/${group}/docker-compose.yaml" \
                -p "openclaw-${group}" restart ;;
        *)  systemctl restart "openclaw-${group}" ;;
    esac
}

hc_is_service_active() {
    local group="${1:?Usage: hc_is_service_active <group>}"
    local isolation="${ISOLATION:-session}"
    case "$isolation" in
        container)
            docker inspect --format='{{.State.Running}}' "openclaw-${group}" 2>/dev/null | grep -q 'true' ;;
        *)  systemctl is-active --quiet "openclaw-${group}" ;;
    esac
}

hc_service_logs() {
    local group="${1:?Usage: hc_service_logs <group>}"
    local lines="${2:-50}"
    local isolation="${ISOLATION:-session}"
    case "$isolation" in
        container)
            docker compose -f "/home/${USERNAME}/.openclaw/compose/${group}/docker-compose.yaml" \
                -p "openclaw-${group}" logs --tail="$lines" 2>/dev/null ;;
        *)  journalctl -u "openclaw-${group}" --no-pager -n "$lines" 2>/dev/null ;;
    esac
}

hc_stop_service() {
    local group="${1:?Usage: hc_stop_service <group>}"
    local isolation="${ISOLATION:-session}"
    case "$isolation" in
        container)
            docker compose -f "/home/${USERNAME}/.openclaw/compose/${group}/docker-compose.yaml" \
                -p "openclaw-${group}" down ;;
        *)  systemctl stop "openclaw-${group}" ;;
    esac
}
```

### 4.2 E2E Health Check for Containers

For `network_mode: host` — gateway reachable at `localhost:${GROUP_PORT}`, no change.
For `internal`/`none` modes — reach via `docker exec`:

```bash
if [ "$ISOLATION" = "container" ] && [ "$NETWORK_MODE" != "host" ]; then
    response=$(docker exec "openclaw-${GROUP}" \
        curl -sf "http://127.0.0.1:${GROUP_PORT}/api/health" 2>/dev/null)
else
    response=$(curl -sf "http://127.0.0.1:${GROUP_PORT}/api/health" 2>/dev/null)
fi
```

### 4.3 Update Existing Consumers

Replace all direct `systemctl`/`docker` calls in health check and safe mode scripts:

| Script | Replace | With |
|--------|---------|------|
| `safe-mode-handler.sh` (line 298-309) | `docker restart`, `docker inspect` | `hc_restart_service`, `hc_is_service_active` |
| `try-full-config.sh` | `systemctl restart openclaw-${GROUP}` | `hc_restart_service "$GROUP"` |
| `gateway-health-check.sh` | direct service checks | `hc_is_service_active "$GROUP"` |

### 4.4 Health Check Timeouts

| Check | Timeout | Retries | Escalation |
|-------|---------|---------|------------|
| HTTP health (compose `HEALTHCHECK`) | 5s | 3 | Container marked unhealthy |
| HTTP health (`gateway-health-check.sh`) | 10s | 3 | Marks gateway unhealthy |
| E2E magic word (`gateway-e2e-check.sh`) | 60s | 1 | Triggers safe mode |
| `docker compose restart` | 30s | — | Systemd `RestartSec` kicks in |
| `docker compose up --wait` | 180s | — | `TimeoutStartSec`, then safe mode |

### Acceptance Criteria

- [ ] `hc_restart_service` works for both `ISOLATION=session` and `ISOLATION=container`
- [ ] `hc_is_service_active` returns correct status for both modes
- [ ] No direct `systemctl`/`docker` calls remain in health check or safe mode scripts
- [ ] E2E health check passes for container with `network_mode: host`
- [ ] E2E health check passes for container with `internal` network (via `docker exec`)
- [ ] Identical pass/fail semantics: same failures trigger same recovery regardless of mode

### Rollback

```bash
git checkout HEAD~1 -- scripts/lib-health-check.sh scripts/safe-mode-handler.sh \
    scripts/try-full-config.sh scripts/gateway-health-check.sh scripts/gateway-e2e-check.sh
```

---

## Phase 5: First Live Test

**Goal:** Validate Phases 1-4 on a real droplet.

### Test Habitat

Use `habitat-isolation-container.json` example with real tokens. Include at least one session group and one container group (mixed mode).

### Test Sequence

1. Provision fresh droplet with Docker + mixed isolation habitat
2. Verify: `/etc/openclaw-ports.env` has all groups with unique ports
3. Verify: `~/.openclaw/configs/{group}/openclaw.session.json` exists for ALL groups
4. Verify: auth-profiles symlinked in state dirs for ALL groups
5. Verify: safeguard `.path` + `.service` exist for ALL groups (session AND container)
6. Verify: `docker compose config` validates for each container group
7. Verify: `systemctl start openclaw-container-{group}` succeeds
8. Verify: container is running and healthy
9. Verify: HTTP health check passes from host
10. Verify: E2E magic word test passes
11. Verify: `systemctl stop` cleanly removes container
12. Verify: session groups still work as before (regression)
13. Verify: `docker inspect` shows no host scripts/state/log mounts
14. Verify: restarting one group doesn't affect another (cross-mode isolation)

### Acceptance Criteria

- [ ] All 14 verification steps pass
- [ ] No regressions in session isolation mode
- [ ] Safe mode triggers correctly for a deliberately broken container group

### Rollback

Full rollback procedure in [Rollback Procedures](#rollback-procedures).

---

## Phase 6: Network Isolation

**Goal:** Three network modes with correct semantics.

### Network Mode Definitions

| Mode | Docker Implementation | Egress | LLM APIs | Loopback | Use Case |
|------|----------------------|--------|----------|----------|----------|
| `host` | `network_mode: host` | Full | Yes | Yes | Default — same as session mode |
| `internal` | Custom bridge, `internal: true` | None | No | Yes | Code sandbox with shared FS IPC |
| `none` | Custom bridge, no IP masquerade | Blocked | No | Yes | Maximum isolation, shared FS only |

**Critical:** `none` is NOT Docker's `network_mode: none` (kills loopback). It's an isolated bridge with egress blocked.

### Implementation

```yaml
# host mode (default):
services:
  council:
    network_mode: host

# internal mode:
services:
  sandbox:
    networks: [isolated-sandbox]
    ports: ["${GROUP_PORT}:${GROUP_PORT}"]  # Expose to host for health checks

networks:
  isolated-sandbox:
    driver: bridge
    internal: true

# none mode:
services:
  lockdown:
    networks: [blocked-lockdown]
    ports: ["${GROUP_PORT}:${GROUP_PORT}"]
    dns: []

networks:
  blocked-lockdown:
    driver: bridge
    internal: true
    driver_opts:
      com.docker.network.bridge.enable_ip_masquerade: "false"
```

For `internal`/`none`: gateway port explicitly mapped so host health check can reach it.

### Acceptance Criteria

- [ ] `host`: container reaches external APIs
- [ ] `internal`: no external access, loopback works, health check works from host
- [ ] `none`: no external access, loopback works, health check works from host
- [ ] `internal`/`none` agents fail gracefully on LLM calls (error, not crash)

### Rollback

Regenerate compose files with `host` network only.

---

## Phase 7: Security Hardening + Resource Limits

**Goal:** Enforce resource boundaries and minimize container attack surface.

### 7.1 Security Baseline (All Containers)

Applied by default to every container:

```yaml
cap_drop: [ALL]
security_opt: ["no-new-privileges:true"]
read_only: true
tmpfs:
  - /tmp:size=256M
  - /run:size=64M
```

`read_only: true` exceptions (bind mounts):
- Agent workspace: `rw` (agents write memory, transcripts)
- Shared workspace: `rw`
- Session state dir: `rw` (transcripts)

### 7.2 Resource Limits

From habitat config:

```yaml
deploy:
  resources:
    limits:
      memory: ${RESOURCES_MEMORY}
      cpus: "${RESOURCES_CPU}"
    reservations:
      memory: ${RESOURCES_MEMORY_HALF}
      cpus: "${RESOURCES_CPU_HALF}"
```

### 7.3 Browser Variant (Future)

```dockerfile
FROM hatchery/agent:latest
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb chromium fonts-liberation && rm -rf /var/lib/apt/lists/*
ENV DISPLAY=:99
```

### Acceptance Criteria

- [ ] `docker inspect` shows `CapDrop: [ALL]`, `SecurityOpt: [no-new-privileges]`, `ReadonlyRootfs: true`
- [ ] Container cannot write to root filesystem
- [ ] Memory/CPU limits enforced and observable via `docker stats`
- [ ] Resource-constrained container still passes health check under normal load

### Rollback

Regenerate compose files without security options / resource limits.

---

## Config Hot-Reload

```
Host: build-full-config.sh regenerates configs
  → Writes new openclaw.session.json to ~/.openclaw/configs/{group}/
  → For session mode: SIGUSR1 to gateway process (in-place reload)
  → For container mode: docker compose restart (container restarts, reads new bind-mounted config)
```

Use `docker compose restart` for config changes (keeps container, picks up new bind-mounted files). Use `docker compose up --force-recreate` for image updates (new container from new image).

---

## Rollback Procedures

### Per-Phase Quick Reference

| Phase | Rollback Command | Impact |
|-------|-----------------|--------|
| 1 | Revert `lib-isolation.sh`, `build-full-config.sh`, both generators | Back to pre-refactor |
| 2 | Revert `generate-docker-compose.sh`, remove compose dirs | Reverts to Option B scaffolding |
| 3 | `docker rmi hatchery/agent:latest` | Image removed, Docker stays |
| 4 | Revert health check scripts | Falls back to session-only health |
| 5 | — | Test phase, nothing to revert |
| 6 | Regenerate compose with `host` network | All containers on host network |
| 7 | Regenerate compose without security opts | No hardening |

### Full Rollback (Container → Session)

```bash
# 1. Stop all container services
for svc in /etc/systemd/system/openclaw-container-*.service; do
    systemctl stop "$(basename "$svc" .service)" 2>/dev/null || true
    systemctl disable "$(basename "$svc" .service)" 2>/dev/null || true
    rm -f "$svc"
done
systemctl daemon-reload

# 2. Remove compose files
rm -rf ~/.openclaw/compose/

# 3. Convert container groups to session in habitat config
# Edit habitat JSON: isolation: "container" → isolation: "session"

# 4. Regenerate
build-full-config.sh

# 5. Start session services
for group in $(echo "$ISOLATION_GROUPS" | tr ',' '\n'); do
    systemctl start "openclaw-${group}"
done
```

---

## Container Lifecycle Management

### Image Updates

```bash
docker build \
    --build-arg BOT_UID=$(id -u bot) \
    --build-arg OPENCLAW_VERSION=$(openclaw --version) \
    -t hatchery/agent:latest \
    -f /opt/hatchery/Dockerfile /opt/hatchery/

# Rolling restart (force-recreate for image update)
for group in $(get_groups_by_type "container"); do
    docker compose -f "~/.openclaw/compose/${group}/docker-compose.yaml" \
        -p "openclaw-${group}" up -d --force-recreate
    sleep 10  # Allow health check before next group
done
```

### Prune Policy

```bash
# Weekly cron: remove old images and stopped containers
docker image prune -f --filter "until=168h"
docker container prune -f --filter "until=168h"
```

---

## Debugging and Incident Triage

```bash
# Container status
docker ps --filter "name=openclaw-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Container logs
docker compose -p openclaw-council logs --tail=50

# Resource usage
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Verify mounts (should see NO host scripts/state/logs)
docker inspect openclaw-council \
    --format='{{range .Mounts}}{{.Source}} → {{.Destination}} ({{.Mode}}){{println}}{{end}}'

# Health check status
docker inspect openclaw-council --format='{{.State.Health.Status}}'

# Port assignments (single source of truth)
cat /etc/openclaw-ports.env

# State machine
openclaw-state.sh status --group council

# Exec into container
docker exec -it openclaw-council bash
```

---

## Open Questions

1. **Shared filesystem race conditions** — Multiple containers writing to `~/clawd/shared/`. Same risk as session mode. OpenClaw's file locking should handle it; stress test in Phase 5.

2. **`exec` tool inside containers** — Agents running shell commands get the container's toolset (minimal). Options: (a) fat image, (b) per-group image variants, (c) sidecar containers. Decide in Phase 3.

3. **Dropbox sync for container transcripts** — State at `~/.openclaw-sessions/{group}/` on host (bind-mounted). Sync script fix (`c724c76`) handles this. Verify in Phase 5.

4. **Safe mode runs on host** — When container group enters safe mode, the safe-mode bot runs on host (session mode), not in container. This means safe mode works even if Docker is broken. Confirm this is right.

5. **Graceful shutdown** — Docker sends SIGTERM then SIGKILL after `stop_grace_period` (10s). Verify OpenClaw shuts down in <10s or increase `stop_grace_period`.

6. **Browser in containers** — Deferred to Phase 7 `full` variant. Worth the complexity, or should browser agents always run in session mode?

7. **Container restart vs recreate** — `restart` keeps container (config reload). `up --force-recreate` makes new container (image update). Documented in Config Hot-Reload.

---

## Cross-Mode Success Criteria

These must hold true after Phase 1:

- Changing group topology requires edits in **one place** only (habitat JSON → rebuild)
- Health/recovery behavior is identical across modes — backend adapter differences only
- No duplicated group-filtering, port selection, or auth/config setup logic in generators
- `none → session → container` transitions require only backend selection changes, not new script paths
- All group metadata resolvable from `/etc/openclaw-groups.json` (no env var re-parsing)
- All secrets injected via `group.env` (no per-script B64 decoding)
- Hyphenated group names work everywhere (port file, systemd units, compose projects)

---

## Estimate

| Phase | Effort | Depends On |
|-------|--------|------------|
| Phase 1: Shared Foundation | 1.5 sessions | — |
| Phase 2: Fix Compose Generator | 0.5 session | Phase 1 |
| Phase 3: Dockerfile + Docker Install | 0.5 session | Phase 2 |
| Phase 4: Health Check Abstraction | 0.5 session | Phase 1 |
| Phase 5: First Live Test | 1 session | Phases 1-4 |
| Phase 6: Network Isolation | 0.5 session | Phase 5 |
| Phase 7: Security Hardening | 0.5 session | Phase 5 |
| **Total** | **5 sessions** | |

Live droplet tests at Phase 5 and Phase 7.

---

## Appendix: File Layout Reference

```
/home/bot/
├── .openclaw/
│   ├── openclaw.json                         # Default (non-isolated) config
│   ├── gateway-token.txt                     # Default gateway token
│   ├── compose/
│   │   └── {group}/
│   │       └── docker-compose.yaml           # Per-group compose (container mode)
│   ├── configs/
│   │   └── {group}/
│   │       ├── openclaw.session.json         # Per-group OpenClaw config (ALL modes)
│   │       ├── gateway-token.txt             # Per-group gateway token (ALL modes)
│   │       └── group.env                     # Per-group decoded secrets + metadata (ALL modes)
│   └── agents/
│       └── main/agent/
│           └── auth-profiles.json            # Master auth-profiles (symlinked everywhere)
├── .openclaw-sessions/
│   └── {group}/                              # Per-group session state (ALL modes)
│       └── agents/{agent}/
│           ├── agent/
│           │   └── auth-profiles.json → master  # Symlink to master
│           └── sessions/*.jsonl              # Transcripts
├── clawd/
│   ├── agents/{agent}/                       # Agent workspaces
│   │   ├── AGENTS.md, SOUL.md, etc.
│   │   └── memory/
│   └── shared/                               # Cross-agent shared workspace
├── Dockerfile                                # Agent base image (or in /opt/hatchery/)
/etc/
├── openclaw-ports.env                        # Port allocation (group=port format)
├── openclaw-groups.json                      # Runtime manifest (all group topology)
├── docker/daemon.json                        # Docker log rotation config
├── systemd/system/
│   ├── openclaw-{group}.service              # Session mode main service
│   ├── openclaw-container-{group}.service    # Container mode main service
│   ├── openclaw-safeguard-{group}.path       # Safe mode watcher (ALL modes)
│   ├── openclaw-safeguard-{group}.service    # Safe mode handler (ALL modes)
│   └── openclaw-e2e-{group}.service          # E2E health check (ALL modes)
/var/lib/openclaw/
├── state-{group}.json                        # State machine per group
└── events-{group}.jsonl                      # Event log per group
/usr/local/sbin/
├── lib-isolation.sh                          # NEW: shared group/port/unit functions
├── lib-health-check.sh                       # Updated: hc_restart_service, etc.
├── lib-env.sh                                # Unchanged
├── lib-permissions.sh                        # Unchanged
├── generate-config.sh                        # Unchanged (called by lib-isolation.sh)
├── generate-session-services.sh              # SLIMMED: systemd unit only
├── generate-docker-compose.sh                # SLIMMED: compose + systemd unit only
└── build-full-config.sh                      # EXPANDED: orchestrates all per-group setup
```
