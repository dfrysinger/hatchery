# TASK-205: Add backward compatibility tests

## Summary
Ensure v2 habitat schemas (without isolation fields) continue to work unchanged.

## Acceptance Criteria
- [ ] v2 schemas parse without errors
- [ ] Missing `isolation` defaults to `"none"`
- [ ] Missing `sharedPaths` defaults to `[]` (or `["/clawd/shared"]` for `none` mode)
- [ ] Missing `isolationGroup` uses agent name as implicit group
- [ ] Missing `network` defaults to `"host"`
- [ ] All tests in `TestBackwardCompatibility` pass
- [ ] Existing habitat files in `examples/` still work

## Files to Modify
- `scripts/parse-habitat.py` (ensure defaults)
- `tests/test_isolation_schema.py` (add more v2 examples)

## Test Command
```bash
python3 -m pytest tests/test_isolation_schema.py::TestBackwardCompatibility -v
```

## Branch
`feature/TASK-205-backward-compat`

## Dependencies
- TASK-201 (validates defaults are set correctly)

## Test Data
Create test habitats:
```json
// tests/fixtures/v2-simple.json
{
  "name": "SimpleBot",
  "agents": [{"agent": "Claude"}]
}

// tests/fixtures/v2-multi.json
{
  "name": "MultiBot",
  "platform": "discord",
  "agents": [
    {"agent": "Claude"},
    {"agent": "ChatGPT"}
  ]
}
```
