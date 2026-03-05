#!/bin/bash
# =============================================================================
# kill-droplet.sh — Self-destruct: sync state then delete this droplet
# =============================================================================
set -euo pipefail

set -a; source /etc/droplet.env; set +a
d(){ [ -n "${1:-}" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env

# Sync state to Dropbox before destruction
/usr/local/bin/sync-openclaw-state.sh || true

# Get droplet ID from metadata API (always accurate)
DROPLET_ID=$(curl -sf http://169.254.169.254/metadata/v1/id 2>/dev/null) || DROPLET_ID=""
DO_TOKEN=$(d "${DO_TOKEN_B64:-}")

if [ -z "$DO_TOKEN" ]; then
  echo "FATAL: No DO_TOKEN — cannot self-destruct" >&2
  exit 1
fi

if [ -n "$DROPLET_ID" ]; then
  # Primary: delete by droplet ID (reliable)
  echo "Deleting droplet by ID: $DROPLET_ID"
  HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: Bearer $DO_TOKEN" \
    "https://api.digitalocean.com/v2/droplets/$DROPLET_ID") || HTTP_CODE="000"

  if [ "$HTTP_CODE" = "204" ]; then
    echo "Droplet $DROPLET_ID deleted successfully"
    exit 0
  else
    echo "WARNING: Delete by ID returned HTTP $HTTP_CODE — trying tag fallback" >&2
  fi
fi

# Fallback: delete by tag (less reliable — tag must match exactly)
TAG="${HABITAT_NAME:-}"
if [ -n "$TAG" ]; then
  echo "Fallback: Deleting droplets by tag: $TAG"
  HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: Bearer $DO_TOKEN" \
    "https://api.digitalocean.com/v2/droplets?tag_name=$TAG") || HTTP_CODE="000"
  echo "Tag-based delete returned HTTP $HTTP_CODE"
else
  echo "FATAL: No DROPLET_ID and no HABITAT_NAME — cannot self-destruct" >&2
  exit 1
fi
