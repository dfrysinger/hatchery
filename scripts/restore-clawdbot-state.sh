#!/bin/bash
# =============================================================================
# restore-clawdbot-state.sh — Restore bot memory and transcripts from Dropbox
# =============================================================================
# Purpose:  Restores MEMORY.md, USER.md, agent memory dirs, and session
#           transcripts (*.jsonl) from Dropbox cloud storage on boot.
#           Retries once if initial restore gets zero transcripts.
#
# Inputs:   /etc/droplet.env — DROPBOX_TOKEN_B64
#           /etc/habitat-parsed.env — HABITAT_NAME, AGENT_COUNT, USERNAME
#
# Outputs:  $HOME/clawd/MEMORY.md, USER.md — shared memory files
#           $HOME/clawd/agents/*/memory/ — per-agent memory
#           $HOME/.clawdbot/agents/*/sessions/*.jsonl — chat transcripts
#
# Dependencies: rclone, tg-notify.sh, parse-habitat.py
#
# Original: /usr/local/bin/restore-clawdbot-state.sh (in hatch.yaml write_files)
# =============================================================================
LOG="/var/log/clawdbot-restore.log"
exec > >(tee -a "$LOG") 2>&1
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
TG="/usr/local/bin/tg-notify.sh"
DBT=$(d "$DROPBOX_TOKEN_B64")
if [ -z "$DBT" ]; then
  echo "SKIP: no Dropbox token"
  $TG "[WARN] Memory restore skipped - no Dropbox token provided. Bot will start with empty memory." || true
  exit 0
fi
HN="${HABITAT_NAME:-default}"
H="/home/$USERNAME"; R="dropbox:clawdbot-memory/${HN}"
AC=${AGENT_COUNT:-1}
FAIL=0
echo "Restoring from $R"
for f in MEMORY.md USER.md; do
  echo "  memory: $f"
  su - $USERNAME -c "rclone copy '$R/$f' '$H/clawd/' -v" || { echo "  WARN: $f failed"; FAIL=$((FAIL+1)); }
done
for i in $(seq 1 $AC); do
  a="agent${i}"
  AD="$H/clawd/agents/$a"; [ -d "$AD" ] || continue
  echo "  agent memory: $a"
  su - $USERNAME -c "rclone copy '$R/agents/${a}/memory/' '$AD/memory/' -v" || { echo "  WARN: $a memory failed"; FAIL=$((FAIL+1)); }
done
for i in $(seq 1 $AC); do
  a="agent${i}"
  TD="$H/.clawdbot/agents/$a/sessions"; mkdir -p "$TD"
  echo "  sessions: $a"
  su - $USERNAME -c "rclone copy '$R/agents/${a}/sessions/' '$TD/' --include '*.jsonl' -v" || { echo "  WARN: $a sessions failed"; FAIL=$((FAIL+1)); }
done
chown -R $USERNAME:$USERNAME $H/clawd $H/.clawdbot
TC=$(find $H/.clawdbot -name '*.jsonl' 2>/dev/null | wc -l)
echo "Restored $TC transcript files ($FAIL warnings)"
MC=$(find $H/clawd -name 'MEMORY.md' -o -name 'USER.md' 2>/dev/null | xargs -I{} sh -c '[ -s "{}" ] && echo 1' | wc -l)
if [ "$TC" -eq 0 ] && [ "$FAIL" -gt 0 ]; then
  echo "RETRY: No transcripts restored, retrying in 5s..."
  sleep 5
  for i in $(seq 1 $AC); do
    a="agent${i}"
    TD="$H/.clawdbot/agents/$a/sessions"; mkdir -p "$TD"
    su - $USERNAME -c "rclone copy '$R/agents/${a}/sessions/' '$TD/' --include '*.jsonl' -v" || true
  done
  chown -R $USERNAME:$USERNAME $H/.clawdbot
  TC2=$(find $H/.clawdbot -name '*.jsonl' 2>/dev/null | wc -l)
  echo "After retry: $TC2 transcript files"
  TC=$TC2
fi
if [ "$TC" -eq 0 ] && [ "$MC" -eq 0 ]; then
  echo "WARNING: Nothing restored - possible Dropbox token issue"
  $TG "[WARN] Memory restore got 0 files. Dropbox token may be invalid. Bot starting with empty memory." || true
fi
