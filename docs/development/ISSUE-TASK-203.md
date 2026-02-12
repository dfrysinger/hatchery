# GitHub Issue: TASK-203 — Session mode (per-group OpenClaw instances)

**Title:** [R6] TASK-203: Session mode — per-group systemd services for isolation groups

**Labels:** `feature`, `isolation`, `R6`

## Description

Implement session isolation mode in the hatchery build pipeline. When `isolation: session` is configured, generate separate systemd services per isolation group, each running its own OpenClaw gateway instance on a unique port with only that group's agents.

## Acceptance Criteria

- [x] Group agents by `isolationGroup` value
- [x] For `isolation: none` — no extra services generated (current behavior)
- [x] For `isolation: session` — generate separate systemd services per group
- [x] Each service runs on a unique port (base 18790 + index)
- [x] Each service gets its own OpenClaw config with only its group's agents
- [x] Mixed isolation levels handled (session agents get services, container agents don't)
- [x] For `isolation: container` — no session services generated (TASK-204 handles this)
- [x] All 22 tests pass

## Architecture

```
habitat-parsed.env
  ├── ISOLATION_DEFAULT=session
  ├── ISOLATION_GROUPS=council,workers
  └── AGENT{N}_ISOLATION_GROUP=council|workers
         │
         ▼
  generate-session-services.sh
         │
         ├── openclaw-council.service  (port 18790)
         │   └── council/openclaw.session.json
         │       └── agents: [Opus, Claude]
         │
         └── openclaw-workers.service  (port 18791)
             └── workers/openclaw.session.json
                 └── agents: [Worker1, Worker2]
```

## New Files

- `scripts/generate-session-services.sh` — systemd service + config generator
- `tests/test_session_mode.py` — 22 TDD tests

## Test Classes (22 tests)

| Class | Tests | What it covers |
|-------|:-----:|---------------|
| `TestSessionModeNoOp` | 2 | Skips for none/empty groups |
| `TestSessionServiceGeneration` | 7 | Service files, ports, user, restart |
| `TestSessionConfig` | 5 | Per-group OpenClaw JSON configs |
| `TestSessionAgentGrouping` | 3 | Group matching, multi-group, mixed |
| `TestSessionSharedPaths` | 2 | Shared path handling |
| `TestSessionEdgeCases` | 3 | Container skip, missing inputs, summary |

## Test Command

```bash
python3 -m pytest tests/test_session_mode.py -v
```

## Result

```
22 passed
```

## Dependencies

- TASK-201 ✅ (needs parsed isolation fields)
- TASK-202 ✅ (needs isolation validation)
