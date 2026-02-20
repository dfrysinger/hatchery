#!/bin/bash
# =============================================================================
# restore-openclaw-state.sh -- Restore bot workspace, memory and transcripts from Dropbox
# =============================================================================
# Purpose:  Restores workspace files (AGENTS.md, SOUL.md, etc.), memory dirs,
#           and session transcripts (*.jsonl) from Dropbox cloud storage on boot.
#           Retries once if initial restore gets zero transcripts.
#           Includes path validation to prevent dangerous operations.
#
# Inputs:   /etc/droplet.env -- DROPBOX_TOKEN_B64
#           /etc/habitat-parsed.env -- HABITAT_NAME, AGENT_COUNT, USERNAME
#
# Outputs:  $HOME/clawd/MEMORY.md, USER.md, TOOLS.md, HEARTBEAT.md -- shared files
#           $HOME/clawd/shared/ -- shared directory
#           $HOME/clawd/agents/*/{AGENTS,SOUL,IDENTITY,BOOT,BOOTSTRAP,USER}.md -- workspace
#           $HOME/clawd/agents/*/memory/ -- per-agent memory
#           $HOME/.openclaw/agents/*/sessions/*.jsonl -- chat transcripts
#
# Dependencies: rclone, tg-notify.sh, parse-habitat.py, rclone-validate.sh
#
# Original: /usr/local/bin/restore-openclaw-state.sh (in hatch.yaml write_files)
# =============================================================================
LOG="/var/log/openclaw-restore.log"
exec > >(tee -a "$LOG") 2>&1
for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-env.sh" ] && { source "$_lib_path/lib-env.sh"; break; }
done
type d &>/dev/null || { echo "FATAL: lib-env.sh not found" >&2; exit 1; }
env_load

# shellcheck source=./rclone-validate.sh
source "$(dirname "$0")/rclone-validate.sh"

TG="/usr/local/bin/tg-notify.sh"
DBT=$(d "$DROPBOX_TOKEN_B64")
if [ -z "$DBT" ]; then
    echo "SKIP: no Dropbox token"
    $TG "[WARN] Memory restore skipped - no Dropbox token provided. Bot will start with empty memory." || true
    exit 0
fi

# Validate required variables
if [ -z "$USERNAME" ]; then
    echo "ERROR: USERNAME not set - refusing to restore" >&2
    exit 1
fi

HN="${HABITAT_NAME:-default}"
H="/home/$USERNAME"
R="dropbox:openclaw-memory/${HN}"
AC=${AGENT_COUNT:-1}
FAIL=0

# One-time migration from old Dropbox path (clawdbot-memory → openclaw-memory)
OLD_R="dropbox:clawdbot-memory/${HN}"
if ! rclone lsf "$R" --max-depth 1 2>/dev/null | grep -q "."; then
  if rclone lsf "$OLD_R" --max-depth 1 2>/dev/null | grep -q "."; then
    echo "Migrating from clawdbot-memory to openclaw-memory..."
    rclone copy "$OLD_R" "$R" 2>/dev/null || echo "WARN: migration copy failed"
  fi
fi

# Workspace files to restore per-agent
WORKSPACE_FILES="AGENTS.md BOOT.md BOOTSTRAP.md IDENTITY.md SOUL.md USER.md"

# Shared files to restore (to clawd root)
SHARED_FILES="TOOLS.md HEARTBEAT.md"

# Validate remote path is not empty or dangerous
if [ -z "$HN" ] || [ "$HN" = "/" ]; then
    echo "ERROR: HABITAT_NAME is empty or invalid - refusing to restore" >&2
    exit 1
fi

echo "Restoring from $R"

# Restore shared memory and workspace files
for f in MEMORY.md USER.md $SHARED_FILES; do
    SRC="$R/$f"
    DST="$H/clawd/"
    echo "  shared: $f"
    safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" -v || { echo "  WARN: $f not found or failed"; }
done

# Restore shared directory
echo "  shared: shared/"
safe_rclone_su_copy "$USERNAME" "$R/shared/" "$H/clawd/shared/" -v || { echo "  WARN: shared/ not found or failed"; }

# Restore per-agent workspace files
for i in $(seq 1 $AC); do
    a="agent${i}"
    AD="$H/clawd/agents/$a"
    [ -d "$AD" ] || continue
    
    for f in $WORKSPACE_FILES; do
        SRC="$R/agents/${a}/$f"
        DST="$AD/"
        # Don't overwrite if destination is a symlink (shared files)
        [ -L "$AD/$f" ] && continue
        echo "  workspace: $a/$f"
        safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" -v || true
    done
done

# Restore per-agent memory directories
for i in $(seq 1 $AC); do
    a="agent${i}"
    AD="$H/clawd/agents/$a"
    [ -d "$AD" ] || continue
    SRC="$R/agents/${a}/memory/"
    DST="$AD/memory/"
    echo "  agent memory: $a"
    safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" -v || { echo "  WARN: $a memory failed"; FAIL=$((FAIL+1)); }
done

# Restore session transcripts
for i in $(seq 1 $AC); do
    a="agent${i}"
    TD="$H/.openclaw/agents/$a/sessions"
    mkdir -p "$TD"
    SRC="$R/agents/${a}/sessions/"
    DST="$TD/"
    echo "  sessions: $a"
    safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" --include '*.jsonl' -v || { echo "  WARN: $a sessions failed"; FAIL=$((FAIL+1)); }
done

chown -R "$USERNAME:$USERNAME" "$H/clawd" "$H/.openclaw"
TC=$(find "$H/.openclaw" -name '*.jsonl' 2>/dev/null | wc -l)
WC=$(find "$H/clawd/agents" -maxdepth 2 -name '*.md' ! -type l 2>/dev/null | wc -l)
echo "Restored $TC transcript files, $WC workspace files ($FAIL warnings)"

# Retry logic for failed restores
if [ "$TC" -eq 0 ] && [ "$FAIL" -gt 0 ]; then
    echo "RETRY: No transcripts restored, retrying in 5s..."
    sleep 5
    for i in $(seq 1 $AC); do
        a="agent${i}"
        TD="$H/.openclaw/agents/$a/sessions"
        mkdir -p "$TD"
        SRC="$R/agents/${a}/sessions/"
        DST="$TD/"
        safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" --include '*.jsonl' -v || true
    done
    chown -R "$USERNAME:$USERNAME" "$H/.openclaw"
    TC2=$(find "$H/.openclaw" -name '*.jsonl' 2>/dev/null | wc -l)
    echo "After retry: $TC2 transcript files"
    TC=$TC2
fi

if [ "$TC" -eq 0 ] && [ "$WC" -eq 0 ]; then
    echo "WARNING: Nothing restored - possible Dropbox token issue or fresh habitat"
    $TG "[WARN] Memory restore got 0 files. Dropbox token may be invalid or this is a fresh habitat." || true
fi
