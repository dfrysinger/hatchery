# Isolation Deployment Fix — Spec

## Issue
#229 — Bug: Isolation scripts deployed to wrong path

## Problem
`build-full-config.sh` calls `generate-session-services.sh` and `generate-docker-compose.sh`
from `/usr/local/sbin/`, but the `hatch.yaml` bootstrap copies them to `/usr/local/bin/` instead.
This causes session and container isolation to fail on deployed droplets.

## Root Cause
The `hatch.yaml` bootstrap case statement (line 133) only routes three scripts to `/usr/local/sbin/`:
- `phase1-critical.sh`
- `phase2-background.sh`
- `build-full-config.sh`

All other `.sh` scripts go to `/usr/local/bin/`. The isolation generator scripts were added
to the build pipeline at `/usr/local/sbin/` paths but never added to the deployment case.

## Fix
Add `generate-session-services.sh` and `generate-docker-compose.sh` to the sbin case in
both `hatch.yaml` and `scripts/bootstrap.sh`.

## Files Changed
- `hatch.yaml` — sbin case statement
- `scripts/bootstrap.sh` — sbin case statement
- `tests/test_path_alignment.py` — `SBIN_SCRIPTS` constant + `TestIsolationDeployment` class

## Test Plan
- `test_hatch_yaml_sbin_case_matches_constant` — cross-checks hatch.yaml with test constant
- `test_build_pipeline_isolation_scripts_in_sbin` — ensures all sbin refs in build script are deployed
- `test_isolation_scripts_deployed` — confirms generator scripts exist in repo
