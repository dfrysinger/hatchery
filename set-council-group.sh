#!/bin/bash
[ -z "$1" ] && { echo "Usage: set-council-group.sh <group_id>"; exit 1; }
GID="$1"; set -a; source /etc/droplet.env; set +a
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
H="/home/$USERNAME"; CFG="$H/.clawdbot/clawdbot.json"
[ ! -f "$CFG" ] && { echo "Config not found"; exit 1; }
cp "$CFG" "$CFG.bak"
if grep -q '"groups":{' "$CFG"; then
  sed -i "s|\"groups\":{[^}]*}|\"groups\":{\"${GID}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}|" "$CFG"
else
  sed -i "s|\"telegram\":{\"enabled\":true|\"telegram\":{\"enabled\":true,\"groups\":{\"${GID}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}|" "$CFG"
fi
echo "$GID" > "$H/clawd/.council-group-id"
echo "true" > "$H/clawd/.council-enabled"
chown $USERNAME:$USERNAME "$H/clawd/.council-group-id" "$H/clawd/.council-enabled"
systemctl restart clawdbot
sleep 3
systemctl is-active --quiet clawdbot && echo "Council group set to $GID. Clawdbot restarted." || { echo "Restart failed, restoring backup"; cp "$CFG.bak" "$CFG"; systemctl restart clawdbot; exit 1; }
