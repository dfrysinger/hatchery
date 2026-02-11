# TASK-203: Update build-full-config.sh for isolation groups

## Summary
Modify config generation to respect isolation groups and generate appropriate configurations.

## Acceptance Criteria
- [ ] Group agents by `isolationGroup` value
- [ ] For `isolation: none` — current single-process behavior unchanged
- [ ] For `isolation: session` — generate separate session configs per group
- [ ] Agents without `isolationGroup` get their own implicit group (agent name)
- [ ] Set `ISOLATION_GROUPS` env var with comma-separated list of unique groups
- [ ] All tests in `TestIsolationGroupLogic` pass

## Files to Modify
- `scripts/build-full-config.sh`

## Test Command
```bash
python3 -m pytest tests/test_isolation_schema.py::TestIsolationGroupLogic -v
```

## Branch
`feature/TASK-203-isolation-groups`

## Dependencies
- TASK-201 (needs parsed isolation fields)
