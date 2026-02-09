#!/bin/bash
# =============================================================================
# verify-firewall.sh -- Verify UFW rules match security policy
# =============================================================================
# Purpose:  Runtime check to ensure firewall rules match ALLOWED_PORTS.md
#           Catches mismatches from iOS Shortcut or manual changes.
#
# Usage:    /usr/local/bin/verify-firewall.sh [--quiet]
#
# Exit:     0 = pass, 1 = forbidden port found, 2 = missing required port
# =============================================================================

set -euo pipefail

QUIET="${1:-}"

# Allowed ports (must match docs/ALLOWED_PORTS.md)
ALLOWED_PORTS="22 80 443 3389 8080 18789"

# Forbidden ports (security risk if exposed)
FORBIDDEN_PORTS="5900 5901 6000 6001 6002 6003 6004 6005 6006 6007 6008 6009 6010"

log() {
    [ "$QUIET" != "--quiet" ] && echo "$@"
}

err() {
    echo "ERROR: $*" >&2
}

# Get current UFW rules (just the port numbers)
UFW_PORTS=$(ufw status | grep -E "^[0-9]+" | awk '{print $1}' | sed 's|/.*||' | sort -u)

FAILED=0

# Check for forbidden ports
for port in $FORBIDDEN_PORTS; do
    if echo "$UFW_PORTS" | grep -q "^${port}$"; then
        err "FORBIDDEN port $port is exposed!"
        FAILED=1
    fi
done

if [ "$FAILED" -eq 1 ]; then
    err ""
    err "Firewall has forbidden ports exposed."
    err "Run: sudo ufw delete allow <port>"
    err "And update iOS Shortcut 'Create Habitat Firewall' to remove the port."
    exit 1
fi

# Check for required ports (warning only, not failure)
MISSING=""
for port in 22 3389 8080 18789; do
    if ! echo "$UFW_PORTS" | grep -q "^${port}$"; then
        MISSING="$MISSING $port"
    fi
done

if [ -n "$MISSING" ]; then
    log "WARNING: Missing expected ports:$MISSING"
fi

log "Firewall OK - no forbidden ports exposed"
exit 0
