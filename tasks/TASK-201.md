# TASK-201: Update parse-habitat.py for v3 schema

## Summary
Add extraction of new isolation-related fields from habitat JSON.

## Acceptance Criteria
- [ ] Extract `isolation` from top-level (default: `"none"`)
- [ ] Extract `sharedPaths` from top-level (default: `[]`)
- [ ] Per-agent extraction:
  - `isolation` (override, optional)
  - `isolationGroup` (optional)
  - `network` (optional, default `"host"`)
  - `capabilities` (optional)
  - `resources` (optional)
- [ ] Export as environment variables:
  - `ISOLATION_DEFAULT` — top-level isolation
  - `SHARED_PATHS` — comma-separated list
  - `AGENT{N}_ISOLATION` — per-agent isolation
  - `AGENT{N}_ISOLATION_GROUP` — per-agent group
  - `AGENT{N}_NETWORK` — per-agent network mode
  - `AGENT{N}_CAPABILITIES` — comma-separated list
  - `AGENT{N}_RESOURCES_MEMORY` — memory limit
- [ ] All tests in `TestIsolationTopLevel` pass

## Files to Modify
- `scripts/parse-habitat.py`

## Test Command
```bash
python3 -m pytest tests/test_isolation_schema.py::TestIsolationTopLevel -v
```

## Branch
`feature/TASK-201-parse-isolation`

## Dependencies
None (can start immediately)
