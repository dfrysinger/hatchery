# Agent Isolation - Architecture

## Feature Issue
GitHub Issue #222 | Milestone: R6: Agent Isolation

## Overview

Agent Isolation adds three isolation levels to hatchery habitats, allowing
operators to run agent groups in separate processes (session mode) or Docker
containers (container mode), while preserving backward compatibility with v2
schemas. A fourth level (droplet) is reserved but not yet implemented.

Each agent belongs to an **isolation group** — agents in the same group share
an isolation boundary. The group name defaults to the sanitized agent name
but can be overridden via `isolationGroup` in `habitat.json`.

When isolation is `none` (the default), all agents run in a single OpenClaw
gateway process — identical to pre-isolation behavior.

## Isolation Levels

| Level | Boundary | Use Case | Status |
|-------|----------|----------|--------|
| `none` | Shared process | All agents in one OpenClaw gateway; default for v2 schemas | **Stable** |
| `session` | Systemd unit (separate process) | Agents need process-level separation on the same VM; each group gets its own gateway on a unique port | **Stable** |
| `container` | Docker container | Agents need filesystem/network isolation; each group runs in its own container with configurable network mode and resource limits | **Stable** |
| `droplet` | Separate VM | Full machine-level isolation for untrusted workloads | **Reserved** — rejected at validation |

## Session Mode Architecture

**Script:** `scripts/generate-session-services.sh`

Session mode creates one systemd service per isolation group. Each service
runs an independent OpenClaw gateway process on a unique port, with only
that group's agents loaded.

### How it works

1. The script reads environment variables from `/etc/habitat-parsed.env`
   (produced by `parse-habitat.py`).
2. It validates `AGENT_COUNT` is set (exits 1 if missing).
3. If `ISOLATION_DEFAULT` is not `session`, the script exits 0 (no-op).
4. It iterates `ISOLATION_GROUPS` and filters to only groups that contain
   at least one agent with `isolation=session` (or inheriting the default).
   Agents explicitly set to `container` are excluded from session groups.
5. For each session group, starting from base port 18790:
   - **Config**: Writes `{group}/openclaw.session.json` containing gateway
     settings, auth token, and the filtered agent list.
   - **Service**: Writes `openclaw-{group}.service` systemd unit pointing
     at the session config.
6. Unless `DRY_RUN` is set, copies service files to `/etc/systemd/system`,
   runs `systemctl daemon-reload`, then enables and starts each service.

### Auth tokens

Each session group receives a unique authentication token generated via:

```bash
openssl rand -hex 16
```

This produces a cryptographically random 32-character hex string. Tokens are
**never** derived from the group name or any other predictable input (see
Design Decisions below).

### Generated artifacts

| Artifact | Path | Contents |
|----------|------|----------|
| Session config | `{group}/openclaw.session.json` | Gateway port, auth token, agent list, plugin config |
| Systemd unit | `openclaw-{group}.service` | ExecStart pointing at the session config with `--bind lan --port {port}` |

## Container Mode Architecture

**Script:** `scripts/generate-docker-compose.sh`

Container mode produces a `docker-compose.yaml` with one service definition
per isolation group. Each container runs the agent image with only that
group's agents.

### How it works

1. The script reads environment variables from `/etc/habitat-parsed.env`.
2. It validates `AGENT_COUNT` is set (exits 1 if missing).
3. If `ISOLATION_DEFAULT` is not `container`, the script exits 0 (no-op).
4. It iterates `ISOLATION_GROUPS` and filters to only groups containing
   agents with `isolation=container` (or inheriting the default). Agents
   explicitly set to `session` or `none` are excluded.
5. For each container group it writes a service block with:
   - **Image**: `CONTAINER_IMAGE` (default: `hatchery/agent:latest`)
   - **Network mode**: per-group, derived from the first agent in the group
     with a `network` setting (default: `host`)
   - **Resource limits**: `mem_limit` and `cpus` from agent resource settings
   - **Volumes**: per-group config mount + shared path mounts from
     `ISOLATION_SHARED_PATHS`
   - **Environment**: `AGENT_NAMES` listing comma-separated agent names
6. If any group uses `network=internal`, an internal bridge network
   definition is appended.
7. The compose file does **not** include a top-level `version` field
   (see Design Decisions).

### Network modes

| Mode | Behavior |
|------|----------|
| `host` | Container shares the host network stack (default) |
| `internal` | Container joins a bridge network with `internal: true` — no external access |
| `none` | Container has no network access |

### Generated artifacts

| Artifact | Path | Contents |
|----------|------|----------|
| Compose file | `docker-compose.yaml` | Services, volumes, networks |

## Pipeline Integration

**Script:** `scripts/build-full-config.sh` (lines ~385–390)

After `build-full-config.sh` generates the main OpenClaw configuration
(`openclaw.full.json`) and systemd service, it conditionally invokes the
isolation scripts based on `ISOLATION_DEFAULT`:

```bash
# --- Agent Isolation: wire isolation scripts into pipeline ---
if [ "$ISOLATION_DEFAULT" = "session" ]; then
  bash /usr/local/sbin/generate-session-services.sh || {
    echo "FATAL: session isolation setup failed" >&2; exit 1;
  }
elif [ "$ISOLATION_DEFAULT" = "container" ]; then
  bash /usr/local/sbin/generate-docker-compose.sh || {
    echo "FATAL: container isolation setup failed" >&2; exit 1;
  }
fi
```

Key properties:
- **Conditional dispatch**: Only the matching isolation script runs.
- **Fail-fast**: The `|| exit 1` pattern ensures any script failure
  immediately halts the entire build pipeline with a non-zero exit code.
- **Environment inheritance**: The isolation scripts inherit all environment
  variables already loaded by `build-full-config.sh` from
  `/etc/habitat-parsed.env`.
- **Idempotent**: When `ISOLATION_DEFAULT=none` (or unset), neither script
  is invoked and the pipeline continues as before.

## Data Flow Diagram

```
hatch.yaml
    │
    ▼
parse-habitat.py
    │
    ▼
/etc/habitat-parsed.env
    │
    ▼
build-full-config.sh
    │
    ├── (always) openclaw.full.json + openclaw.service
    │
    ├── ISOLATION_DEFAULT=session?
    │   └── generate-session-services.sh
    │       ├── {group}/openclaw.session.json
    │       └── openclaw-{group}.service
    │
    └── ISOLATION_DEFAULT=container?
        └── generate-docker-compose.sh
            └── docker-compose.yaml
```

## Design Decisions

### (a) Group-based isolation over per-agent

Agents are grouped into isolation boundaries rather than each agent getting
its own boundary. This reduces resource overhead — multiple agents that
trust each other can share a process or container. The `isolationGroup`
field lets operators explicitly co-locate agents while keeping the default
(one group per agent) secure by default.

### (b) Random tokens over deterministic

Session auth tokens are generated with `openssl rand -hex 16` rather than
derived from the group name (e.g., `"token": "session-${group}"`). This
prevents token guessing if an attacker learns group names. Each gateway
invocation receives a fresh token.

### (c) No version field in compose

The generated `docker-compose.yaml` omits the top-level `version` field.
Docker Compose v2+ treats `version` as deprecated and ignores it. Omitting
it avoids deprecation warnings and follows the modern Compose specification.

### (d) Fail-fast error propagation

Both isolation scripts are invoked with `|| exit 1` in the build pipeline.
If session service generation or compose file generation fails, the entire
`build-full-config.sh` pipeline halts immediately rather than continuing
with a partially configured habitat. This prevents silent deployment of
broken configurations.

