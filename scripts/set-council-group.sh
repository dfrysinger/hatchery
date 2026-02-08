#!/bin/bash
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
# PLATFORM must be explicitly set - no silent defaults
PLATFORM="${PLATFORM:-$(d "$PLATFORM_B64")}"
# Discord droplets don't have Telegram council config; no-op safely.
if [ "$PLATFORM" = "discord" ]; then
  exit 0
fi
exec /usr/local/bin/set-council-group.telegram.sh "$@"
