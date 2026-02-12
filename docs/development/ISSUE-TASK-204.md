# GitHub Issue: TASK-204 — Container mode (Docker Compose generation)

**Title:** [R6] TASK-204: Container mode — Docker Compose generation for isolation groups

**Labels:** `feature`, `isolation`, `docker`, `R6`

## Description

Implement container isolation mode by generating a `docker-compose.yaml` when `isolation: container` is configured. Each isolation group becomes a Docker service with proper volume mounts, network modes, and resource limits.

## Acceptance Criteria

- [x] Detect `isolation: container` and generate `docker-compose.yaml`
- [x] Create one service per unique `isolationGroup`
- [x] Mount `sharedPaths` as volumes in each container
- [x] Apply `network` mode per service:
  - `host` → `network_mode: host` (default)
  - `internal` → custom bridge network, no external
  - `none` → `network_mode: none`
- [x] Apply `resources.memory` as `mem_limit`
- [x] Apply `resources.cpu` as `cpus`
- [x] Use `hatchery/agent:latest` base image (configurable via `CONTAINER_IMAGE`)
- [x] Include volume for per-group OpenClaw config
- [x] Agent names listed in service environment
- [x] Mixed isolation filtering (only container groups get compose services)
- [x] All 26 tests pass

## Example Output

```yaml
version: '3.8'
services:
  council:
    image: hatchery/agent:latest
    network_mode: host
    volumes:
      - ./config/council:/home/bot/.openclaw
      - ./clawd/shared:/clawd/shared
    environment:
      - AGENT_NAMES=Opus,Claude,ChatGPT

  workers:
    image: hatchery/agent:latest
    network_mode: none
    mem_limit: 512Mi
    volumes:
      - ./config/workers:/home/bot/.openclaw
      - ./clawd/shared:/clawd/shared
    environment:
      - AGENT_NAMES=Worker-1,Worker-2
```

## New Files

- `scripts/generate-docker-compose.sh` — Docker Compose generator
- `tests/test_docker_compose.py` — 26 TDD tests

## Test Classes (26 tests)

| Class | Tests | What it covers |
|-------|:-----:|---------------|
| `TestContainerModeNoOp` | 3 | Skips for none/session/empty |
| `TestDockerComposeStructure` | 6 | File, version, services, image |
| `TestDockerComposeVolumes` | 4 | Shared paths, config volume |
| `TestDockerComposeNetwork` | 4 | host, none, internal, mixed |
| `TestDockerComposeResources` | 3 | Memory, CPU, omission |
| `TestDockerComposeAgents` | 3 | Agent names, group counts |
| `TestDockerComposeEdgeCases` | 3 | Missing inputs, filtering, summary |

## Test Command

```bash
python3 -m pytest tests/test_docker_compose.py -v
```

## Result

```
26 passed
```

## Dependencies

- TASK-201 ✅ (needs parsed isolation fields)
- TASK-203 ✅ (needs isolation group logic)
