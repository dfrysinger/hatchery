#!/bin/bash
set -a;source /etc/droplet.env;set +a
d(){ [ -n "$1" ]&&echo "$1"|base64 -d 2>/dev/null||echo "";}
[ -f /etc/habitat-parsed.env ]&&source /etc/habitat-parsed.env
DBT=$(d "$DROPBOX_TOKEN_B64");[ -z "$DBT" ]&&exit 0
H="/home/$USERNAME";R="dropbox:clawdbot-memory/${HABITAT_NAME:-default}";AC=${AGENT_COUNT:-1}
for f in MEMORY.md USER.md;do [ -f "$H/clawd/$f" ]&&su - $USERNAME -c "rclone copy '$H/clawd/$f' '$R/' 2>/dev/null"||true;done
for i in $(seq 1 $AC);do a="agent${i}";[ -d "$H/clawd/agents/$a" ]&&su - $USERNAME -c "rclone sync '$H/clawd/agents/$a/memory' '$R/agents/${a}/memory' 2>/dev/null"||true;done
for i in $(seq 1 $AC);do a="agent${i}";T="$H/.clawdbot/agents/$a/sessions";[ -d "$T" ]&&su - $USERNAME -c "rclone copy '$T/' '$R/agents/${a}/sessions/' --include '*.jsonl' 2>/dev/null"||true;done
