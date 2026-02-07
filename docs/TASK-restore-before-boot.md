# Task: Ensure Memory Restore Completes Before Bot Starts

## Problem Statement

Currently, the bot starts in Phase 1 with empty memory, and the restore from Dropbox 
happens later in Phase 2. This means:

1. Bot wakes up with no context from previous sessions
2. Chat transcripts aren't available for continuity
3. MEMORY.md and USER.md are missing on first boot
4. User gets a "fresh" bot that doesn't remember anything

**Root Cause:** `clawdbot.service` starts in Phase 1 (line ~167 of phase1-critical.sh),
but `restore-openclaw-state.sh` runs in Phase 2 (line ~215 of phase2-background.sh).
Since rclone isn't installed until Phase 2, the restore can't happen earlier.

## Acceptance Criteria

1. ✅ Memory files (MEMORY.md, USER.md) are restored BEFORE clawdbot.service starts
2. ✅ Chat transcripts (*.jsonl) are restored BEFORE clawdbot.service starts  
3. ✅ Per-agent memory directories are restored BEFORE clawdbot.service starts
4. ✅ If restore fails or no backup exists, bot starts anyway (graceful degradation)
5. ✅ Restore timeout doesn't block boot indefinitely (max 60s)
6. ✅ Works on fresh droplets with no prior backups (no errors, just skips)
7. ✅ Existing sync timer continues to work (backup every 2 min)
8. ✅ No regression in Phase 1 boot time (restore happens in parallel where possible)

## Solution Design

Add a new systemd service `openclaw-restore.service` that:
- Runs `restore-openclaw-state.sh` 
- Is a dependency of `clawdbot.service` (After=, Wants=)
- Only runs once per boot (Type=oneshot, RemainAfterExit=yes)
- Has reasonable timeout (TimeoutStartSec=60)

**Changes required:**

1. `hatch.yaml`: Add new service file in write_files
2. `scripts/phase2-background.sh`: Remove standalone restore call (now handled by service)
3. `hatch.yaml`: Update clawdbot.service to depend on restore service (both definitions)

## Test Plan

1. **Unit tests** (test_restore_service.py):
   - Service file has correct dependencies
   - Service runs restore script
   - clawdbot.service depends on restore service
   - Timeout is configured

2. **Integration test** (manual):
   - Deploy fresh droplet
   - Verify transcripts exist before first bot message
   - Verify MEMORY.md is present on boot

## Files to Modify

- `hatch.yaml` (add service, update clawdbot.service deps)
- `scripts/phase2-background.sh` (remove duplicate restore call)

## Related

- Issue: Memory not persisting across droplet recreations
- Scripts: restore-openclaw-state.sh, sync-openclaw-state.sh
