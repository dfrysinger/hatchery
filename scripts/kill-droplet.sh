#!/bin/bash
set -a;source /etc/droplet.env;set +a
d(){ [ -n "$1" ]&&echo "$1"|base64 -d 2>/dev/null||echo "";}
[ -f /etc/habitat-parsed.env ]&&source /etc/habitat-parsed.env
/usr/local/bin/sync-clawdbot-state.sh
curl -X DELETE -H "Authorization: Bearer $(d "$DO_TOKEN_B64")" "https://api.digitalocean.com/v2/droplets?tag_name=${HABITAT_NAME}"
