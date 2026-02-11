# Habitat Schema v3 — Isolation Support

This document defines the v3 habitat schema with per-agent isolation support.

## Schema Overview

```json
{
  "name": "MyHabitat",
  "platform": "discord",
  "domain": "bot.example.com",
  
  "isolation": "container",
  "sharedPaths": ["/clawd/shared"],
  
  "agents": [
    {
      "agent": "Opus",
      "isolationGroup": "council"
    },
    {
      "agent": "Claude",
      "isolationGroup": "council"
    },
    {
      "agent": "code-executor",
      "isolation": "container",
      "isolationGroup": "workers",
      "network": "none"
    },
    {
      "agent": "researcher",
      "isolationGroup": "workers",
      "capabilities": ["web_search"]
    }
  ]
}
```

## New Fields

### Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `isolation` | string | `"none"` | Default isolation level for all agents |
| `sharedPaths` | string[] | `[]` | Paths shared across isolation boundaries |

### Per-Agent Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `isolation` | string | (inherits) | Override isolation level for this agent |
| `isolationGroup` | string | (agent name) | Agents in same group share isolation boundary |
| `network` | string | `"host"` | Network mode for container/droplet isolation |
| `capabilities` | string[] | (all) | Restrict agent's tool access |
| `resources` | object | `{}` | Resource limits (memory, cpu) |

## Isolation Levels

| Level | Description | Use Case |
|-------|-------------|----------|
| `none` | Shared process, shared filesystem | Current behavior, trusted agents |
| `session` | Separate OpenClaw session, shared filesystem | Different contexts, same tools |
| `container` | Docker container, explicit shared volumes | Production, untrusted code execution |
| `droplet` | Separate DigitalOcean droplet | Multi-tenant, full isolation |

## Isolation Groups

Agents with the same `isolationGroup` share their isolation boundary:

```json
{
  "isolation": "container",
  "agents": [
    {"agent": "A", "isolationGroup": "team1"},  // Container 1
    {"agent": "B", "isolationGroup": "team1"},  // Container 1 (same)
    {"agent": "C", "isolationGroup": "team2"}   // Container 2
  ]
}
```

If `isolationGroup` is not specified, each agent gets its own boundary.

## Network Modes

Only applicable for `container` and `droplet` isolation:

| Mode | Description |
|------|-------------|
| `host` | Full network access (default) |
| `internal` | Can reach other containers, not internet |
| `none` | No network access |

## Shared Paths

Explicit directories shared across isolation boundaries:

```json
{
  "isolation": "container",
  "sharedPaths": [
    "/clawd/shared",
    "/clawd/shared/reports"
  ]
}
```

These are mounted read-write into all containers.

## Backward Compatibility

v2 habitats (without isolation fields) continue to work:

```json
// v2 habitat - still valid
{
  "name": "OldHabitat",
  "agents": [
    {"agent": "Claude"}
  ]
}
```

Interpreted as:
- `isolation: "none"` (shared process)
- Each agent in its own implicit group
- No shared path restrictions

## Examples

### Single Agent (v2 compatible)

```json
{
  "name": "SimpleBot",
  "platform": "telegram",
  "agents": [
    {"agent": "Claude"}
  ]
}
```

### Multi-Agent Council (shared)

```json
{
  "name": "Council",
  "platform": "discord",
  "isolation": "none",
  "agents": [
    {"agent": "Opus", "isolationGroup": "council"},
    {"agent": "Claude", "isolationGroup": "council"},
    {"agent": "ChatGPT", "isolationGroup": "council"}
  ]
}
```

### Code Execution Sandbox

```json
{
  "name": "CodeRunner",
  "platform": "discord",
  "isolation": "container",
  "sharedPaths": ["/clawd/shared/code"],
  "agents": [
    {
      "agent": "orchestrator",
      "isolation": "session",
      "isolationGroup": "trusted"
    },
    {
      "agent": "code-executor",
      "isolationGroup": "sandbox",
      "network": "none",
      "capabilities": ["exec"]
    }
  ]
}
```

### Full Isolation (Multi-Tenant)

```json
{
  "name": "MultiTenant",
  "isolation": "droplet",
  "agents": [
    {"agent": "TenantA-Bot", "isolationGroup": "tenant-a"},
    {"agent": "TenantB-Bot", "isolationGroup": "tenant-b"}
  ]
}
```

## Implementation Notes

### parse-habitat.py

Must extract:
- `isolation` (top-level, default "none")
- `sharedPaths` (top-level, default [])
- Per-agent: `isolation`, `isolationGroup`, `network`, `capabilities`, `resources`

### build-full-config.sh

Must generate:
- For `isolation: "none"` — current behavior
- For `isolation: "session"` — separate OpenClaw sessions
- For `isolation: "container"` — docker-compose.yaml
- For `isolation: "droplet"` — separate provisioning calls

### Validation

- `isolation` must be one of: `none`, `session`, `container`, `droplet`
- `network` must be one of: `host`, `internal`, `none`
- `network` only valid when `isolation` is `container` or `droplet`
- `isolationGroup` must be alphanumeric + hyphens
