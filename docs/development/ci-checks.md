# CI Checks

This document describes the automated checks that run on every pull request and push to `main`.

## Test Suite

All tests in `tests/` are run via pytest. Tests must pass before merging.

## Drift Detection

### parse-habitat.py Sync Check

**Purpose:** Ensures `scripts/parse-habitat.py` stays synchronized with the embedded version in `hatch.yaml`.

**Why:** The `parse-habitat.py` script exists in two places:
1. **Standalone:** `scripts/parse-habitat.py` (for local testing and development)
2. **Embedded:** In `hatch.yaml` under `write_files` → `/usr/local/bin/parse-habitat.py` (deployed to droplets)

If these diverge, config builds will produce inconsistent results between local testing and production deployments.

**Test:** `tests/test_drift_detection.py::test_parse_habitat_drift`

**How it works:**
1. Extracts the embedded `parse-habitat.py` content from `hatch.yaml`
2. Compares it byte-for-byte with `scripts/parse-habitat.py`
3. **Fails** if any differences are detected

**Keeping them synchronized:**

When modifying `parse-habitat.py` logic:

```bash
# Edit the standalone version
vim scripts/parse-habitat.py

# Sync to hatch.yaml
python3 << 'EOF'
import yaml

# Read standalone version
with open('scripts/parse-habitat.py', 'r') as f:
    content = f.read()

# Update hatch.yaml
with open('hatch.yaml', 'r') as f:
    data = yaml.safe_load(f)

for entry in data['write_files']:
    if entry['path'] == '/usr/local/bin/parse-habitat.py':
        entry['content'] = content
        break

# Write back
with open('hatch.yaml', 'w') as f:
    yaml.safe_dump(data, f, sort_keys=False, allow_unicode=True)
EOF

# Verify sync
pytest tests/test_drift_detection.py::test_parse_habitat_drift
```

**Failure example:**

```
AssertionError: DRIFT DETECTED: parse-habitat.py differs between hatch.yaml and scripts/

Line 42 differs:
  Embedded:   'def get_platform_config(hab, platform_name):'
  Standalone: 'def get_platform_config(hab, platform_name, fallback=True):'
...

INSTRUCTIONS: Keep hatch.yaml and scripts/parse-habitat.py synchronized.
Update both files when making changes to parse-habitat logic.
```

## Security Scanning

**Tool:** `pip-audit`

Scans Python dependencies for known vulnerabilities. Fails on high-severity issues.

## Future Checks

Additional drift detection checks may be added for:
- `api-server.py` (if embedded in future)
- Other inline scripts in `hatch.yaml`
