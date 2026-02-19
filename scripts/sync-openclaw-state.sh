#!/bin/bash
# =============================================================================
# sync-openclaw-state.sh -- Sync bot workspace, memory and transcripts to Dropbox
# =============================================================================
# Purpose:  Uploads workspace files (AGENTS.md, SOUL.md, etc.), memory dirs,
#           and session transcripts (*.jsonl) to Dropbox cloud storage.
#           Includes path validation to prevent dangerous operations.
#
# Inputs:   /etc/droplet.env -- DROPBOX_TOKEN_B64
#           /etc/habitat-parsed.env -- HABITAT_NAME, AGENT_COUNT, USERNAME
#
# Outputs:  Files uploaded to dropbox:openclaw-memory/${HABITAT_NAME}/
#
# Dependencies: rclone, rclone-validate.sh
#
# Original: /usr/local/bin/sync-openclaw-state.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

# shellcheck source=./rclone-validate.sh
source "$(dirname "$0")/rclone-validate.sh"

DBT=$(d "$DROPBOX_TOKEN_B64")
[ -z "$DBT" ] && exit 0

# Validate required variables
if [ -z "$USERNAME" ]; then
    echo "ERROR: USERNAME not set - refusing to sync" >&2
    exit 1
fi

HN="${HABITAT_NAME:-default}"
H="/home/$USERNAME"
R="dropbox:openclaw-memory/${HN}"
AC=${AGENT_COUNT:-1}

# Workspace files to sync per-agent
WORKSPACE_FILES="AGENTS.md BOOT.md BOOTSTRAP.md IDENTITY.md SOUL.md USER.md"

# Shared files to sync (from clawd root)
SHARED_FILES="TOOLS.md HEARTBEAT.md"

# Sync shared workspace files
for f in MEMORY.md USER.md $SHARED_FILES; do
    SRC="$H/clawd/$f"
    DST="$R/"
    # Skip symlinks to avoid duplicating shared files
    [ -L "$SRC" ] && continue
    if [ -f "$SRC" ]; then
        safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" 2>/dev/null || true
    fi
done

# Sync shared directory
if [ -d "$H/clawd/shared" ] && [ ! -L "$H/clawd/shared" ]; then
    safe_rclone_su_copy "$USERNAME" "$H/clawd/shared/" "$R/shared/" 2>/dev/null || true
fi

# Sync per-agent workspace files
for i in $(seq 1 $AC); do
    a="agent${i}"
    AD="$H/clawd/agents/$a"
    [ -d "$AD" ] || continue
    
    for f in $WORKSPACE_FILES; do
        SRC="$AD/$f"
        DST="$R/agents/${a}/"
        # Skip symlinks to avoid duplicating shared files
        [ -L "$SRC" ] && continue
        if [ -f "$SRC" ]; then
            safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" 2>/dev/null || true
        fi
    done
done

# Sync per-agent memory directories
for i in $(seq 1 $AC); do
    a="agent${i}"
    SRC="$H/clawd/agents/$a/memory"
    DST="$R/agents/${a}/memory"
    if [ -d "$SRC" ]; then
        safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" 2>/dev/null || true
    fi
done

# Sync session transcripts
for i in $(seq 1 $AC); do
    a="agent${i}"
    SRC="$H/.openclaw/agents/$a/sessions"
    DST="$R/agents/${a}/sessions/"
    if [ -d "$SRC" ]; then
        safe_rclone_su_copy "$USERNAME" "$SRC/" "$DST" --include '*.jsonl' 2>/dev/null || true
    fi
done
