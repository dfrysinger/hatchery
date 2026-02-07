#!/bin/bash
# =============================================================================
# sync-openclaw-state.sh -- Sync bot memory and transcripts to Dropbox
# =============================================================================
# Purpose:  Uploads MEMORY.md, USER.md, agent memory dirs, and session
#           transcripts (*.jsonl) to Dropbox cloud storage for persistence.
#           Includes path validation to prevent dangerous operations.
#
# Inputs:   /etc/droplet.env -- DROPBOX_TOKEN_B64
#           /etc/habitat-parsed.env -- HABITAT_NAME, AGENT_COUNT, USERNAME
#
# Outputs:  Files uploaded to dropbox:clawdbot-memory/${HABITAT_NAME}/
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
R="dropbox:clawdbot-memory/${HN}"
AC=${AGENT_COUNT:-1}

# (prefix validation handled in rclone-validate.sh)

# Sync shared memory files
for f in MEMORY.md USER.md; do
    SRC="$H/clawd/$f"
    DST="$R/"
    if [ -f "$SRC" ]; then
        safe_rclone_su_copy "$USERNAME" "$SRC" "$DST" 2>/dev/null || true
    fi
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
