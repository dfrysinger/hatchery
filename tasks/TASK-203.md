# TASK-203: Update build-full-config.sh for isolation groups

## Summary
Modify config generation to respect isolation groups and generate appropriate configurations.

## Acceptance Criteria
- [x] Group agents by `isolationGroup` value
- [x] For `isolation: none` — current single-process behavior unchanged
- [x] For `isolation: session` — generate separate session configs per group
- [x] Agents without `isolationGroup` get their own implicit group (agent name)
- [x] Set `ISOLATION_GROUPS` env var with comma-separated list of unique groups
- [x] All tests pass (22 tests in test_session_mode.py)

## Files Modified
- `scripts/build-full-config.sh`

## New Files
- `scripts/generate-session-services.sh` — per-group systemd service generator
- `tests/test_session_mode.py` — 22 TDD tests

## Test Command
```bash
python3 -m pytest tests/test_isolation_schema.py::TestIsolationGroupLogic -v
```

## Branch
`feature/TASK-203-isolation-groups`

## Dependencies
- TASK-201 (needs parsed isolation fields)
