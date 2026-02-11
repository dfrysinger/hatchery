# TASK-202: Add isolation validation to parse-habitat.py

## Summary
Add validation rules for isolation-related fields with warnings (not failures) for backward compatibility.

## Acceptance Criteria
- [ ] Validate `isolation` is one of: `none`, `session`, `container`, `droplet`
- [ ] Validate `network` is one of: `host`, `internal`, `none`
- [ ] Warn if `network` is set but `isolation` is not `container` or `droplet`
- [ ] Validate `isolationGroup` is alphanumeric + hyphens only
- [ ] Log warnings to stderr, don't fail parsing
- [ ] All tests in `TestSchemaValidation` pass

## Files to Modify
- `scripts/parse-habitat.py`

## Test Command
```bash
python3 -m pytest tests/test_isolation_schema.py::TestSchemaValidation -v
```

## Branch
`feature/TASK-202-isolation-validation`

## Dependencies
- TASK-201 (needs extraction before validation)
