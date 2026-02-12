# Agent Isolation - Data Model

## Feature Issue
GitHub Issue #222 | Milestone: R6: Agent Isolation

## Schema Changes (v2 to v3)

### New Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `isolation` | string | `"none"` | Default isolation level |
| `sharedPaths` | string[] | `[]` | Paths shared across boundaries |

### New Per-Agent Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `isolation` | string | (inherits top-level) | Override isolation for agent |
| `isolationGroup` | string | (agent name) | Group boundary |
| `network` | string | `"host"` | Network mode (container only) |
| `capabilities` | string[] | (all) | Tool access restrictions |
| `resources` | object | `{}` | Resource limits |
| `resources.memory` | string | (none) | Memory limit e.g. `"512Mi"` |
| `resources.cpu` | string | (none) | CPU limit e.g. `"0.5"` |

## Parsed Environment Variables

`parse-habitat.py` writes these to `/etc/habitat-parsed.env`:

| Variable | Example | Source |
|----------|---------|--------|
| `ISOLATION_DEFAULT` | `session` | `habitat.isolation` |
| `ISOLATION_GROUPS` | `council,workers` | Unique agent groups |
| `ISOLATION_SHARED_PATHS` | `/clawd/shared` | `habitat.sharedPaths` |
| `AGENT{N}_ISOLATION_GROUP` | `council` | `agent.isolationGroup` |
| `AGENT{N}_ISOLATION` | `session` | `agent.isolation` |
| `AGENT{N}_NETWORK` | `host` | `agent.network` |
| `AGENT{N}_RESOURCES_MEMORY` | `512Mi` | `agent.resources.memory` |
| `AGENT{N}_RESOURCES_CPU` | `0.5` | `agent.resources.cpu` |

## Generated Artifacts

### Session Mode
- `openclaw-{group}.service` — systemd unit file
- `{group}/openclaw.session.json` — OpenClaw config with group's agents

### Container Mode
- `docker-compose.yaml` — Docker Compose file with one service per group

## Validation Rules

- `isolation` must be: `none`, `session`, `container` (or `droplet`, rejected)
- `network` must be: `host`, `internal`, `none`
- `network` only valid when isolation is `container` or `droplet`
- `isolationGroup` must be alphanumeric + hyphens
- Invalid `isolationGroup` values are sanitized with warning

## Backward Compatibility

v2 schemas (without isolation fields) continue to work:
- Missing `isolation` defaults to `"none"`
- Missing `sharedPaths` defaults to `[]`
- Missing `isolationGroup` uses sanitized agent name
- Missing `network` defaults to `"host"`
