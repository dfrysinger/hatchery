# TASK-204: Add docker-compose generation for container mode

## Summary
Generate docker-compose.yaml when isolation mode is `container`.

## Acceptance Criteria
- [x] Detect `isolation: container` and generate `docker-compose.yaml`
- [x] Create one service per unique `isolationGroup`
- [x] Mount `sharedPaths` as volumes in each container
- [x] Apply `network` mode per service:
  - `host` → `network_mode: host`
  - `internal` → custom bridge network, no external
  - `none` → `network_mode: none`
- [x] Apply `resources.memory` as `mem_limit`
- [x] Use `hatchery/agent:latest` base image (or configurable)
- [x] Include volume for OpenClaw config
- [x] All tests pass (26 tests in test_docker_compose.py)

## Files to Modify
- `scripts/build-full-config.sh`

## New Files
- `scripts/generate-docker-compose.sh` — Docker Compose generator
- `tests/test_docker_compose.py` — 26 TDD tests

## Test Command
```bash
python3 -m pytest tests/test_isolation_schema.py::TestComplexScenarios -v
```

## Branch
`feature/TASK-204-docker-compose`

## Dependencies
- TASK-201 (needs parsed isolation fields)
- TASK-203 (needs isolation group logic)

## Example Output
```yaml
version: '3.8'
services:
  council:
    image: hatchery/agent:latest
    network_mode: host
    volumes:
      - ./shared:/clawd/shared
      - ./config/council:/home/bot/.openclaw
    environment:
      - AGENT_NAMES=Opus,Claude,ChatGPT
      
  workers:
    image: hatchery/agent:latest
    network_mode: none
    mem_limit: 512m
    volumes:
      - ./shared:/clawd/shared:ro
      - ./config/workers:/home/bot/.openclaw
    environment:
      - AGENT_NAMES=Worker-1,Worker-2
```
