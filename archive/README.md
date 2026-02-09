# Archive

This directory contains archived files that are no longer actively used.

## hatch-full.yaml

The original monolithic cloud-init template with all scripts embedded inline (~2100 lines).

**Archived:** 2026-02-09

**Reason:** Consolidated to the slim approach where `hatch.yaml` contains minimal boot config and `bootstrap.sh` fetches scripts from the repo. This eliminates the maintenance burden of keeping two YAML files in sync.

**Reference:** The slim approach ensures:
- Single source of truth for scripts (in `scripts/` directory)
- Smaller user_data payload
- Easier maintenance and updates
