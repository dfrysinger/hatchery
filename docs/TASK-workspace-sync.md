# Task: Full Workspace Sync for Agent State Persistence

## Problem Statement

Currently, the sync/restore scripts only handle a subset of agent state:
- ✅ MEMORY.md, USER.md (shared)
- ✅ Per-agent memory directories (`agents/*/memory/`)
- ✅ Session transcripts (`*.jsonl`)

But critical workspace files are **NOT** synced:
- ❌ AGENTS.md (agent personality/instructions)
- ❌ BOOT.md (boot-time instructions)
- ❌ BOOTSTRAP.md (first-run tasks)
- ❌ IDENTITY.md (agent identity context)
- ❌ SOUL.md (agent persona)
- ❌ Per-agent USER.md (user preferences)
- ❌ Shared files (TOOLS.md, HEARTBEAT.md, shared/*)

**Impact:** When a droplet is recreated, agents lose their customized personalities,
learned preferences, and accumulated context - only raw memory files survive.

## Goals

1. **Complete state persistence** - All user-editable workspace files survive droplet recreation
2. **Backward compatible** - Existing backups continue to work
3. **Efficient** - Only sync files that matter, avoid large binary files
4. **Safe** - Don't overwrite fresh templates with stale backups on first boot

## Acceptance Criteria

### Sync (upload to Dropbox)
1. ✅ Syncs per-agent workspace files: AGENTS.md, BOOT.md, BOOTSTRAP.md, IDENTITY.md, SOUL.md, USER.md
2. ✅ Syncs shared workspace files: TOOLS.md, HEARTBEAT.md
3. ✅ Syncs shared directory contents: shared/*
4. ✅ Continues to sync memory dirs and transcripts (no regression)
5. ✅ Skips symlinks (don't duplicate shared files per-agent)
6. ✅ Handles missing files gracefully (no errors if file doesn't exist)

### Restore (download from Dropbox)
1. ✅ Restores per-agent workspace files to correct locations
2. ✅ Restores shared workspace files
3. ✅ Restores shared directory contents
4. ✅ Continues to restore memory dirs and transcripts (no regression)
5. ✅ Preserves file ownership (bot:bot)
6. ✅ Only restores if backup exists (don't fail on fresh habitats)

### Safety
1. ✅ Never sync/restore files larger than 1MB (prevents accidental large file sync)
2. ✅ Validate paths before operations (existing rclone-validate.sh)
3. ✅ Log what was synced/restored for debugging

## Non-Goals

- Syncing browser profiles or cache
- Syncing installed packages or system state
- Real-time sync (timer-based is sufficient)
- Conflict resolution (last-write-wins is acceptable)

## Files to Modify

- `scripts/sync-openclaw-state.sh` - Add workspace file sync
- `scripts/restore-openclaw-state.sh` - Add workspace file restore
- `hatch.yaml` - Update inline versions of both scripts

## Test Plan

Unit tests in `tests/test_workspace_sync.py`:
1. Sync script includes all workspace files
2. Restore script includes all workspace files
3. Both scripts handle per-agent iteration correctly
4. Symlinks are skipped (not synced as separate files)
5. File size limits are enforced
6. Shared directory sync is included

## Implementation Notes

Workspace files to sync per-agent:
```
WORKSPACE_FILES="AGENTS.md BOOT.md BOOTSTRAP.md IDENTITY.md SOUL.md USER.md"
```

Shared files to sync:
```
SHARED_FILES="TOOLS.md HEARTBEAT.md"
SHARED_DIR="shared"
```

Skip symlinks with: `[ -L "$file" ] && continue`
