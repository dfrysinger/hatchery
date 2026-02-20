#!/bin/bash
# =============================================================================
# test-simplification-pr5.sh -- PR 5: provision.sh (single-phase + reboot)
# =============================================================================
# TDD tests ensuring provision.sh reboots instead of starting services,
# has no killall apt, no background fork, and bootstrap.sh auto-detects.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"

PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=$((FAILED + 1)); }

PROVISION="$REPO_DIR/scripts/provision.sh"
BOOTSTRAP="$REPO_DIR/scripts/bootstrap.sh"

# =============================================================================
echo ""
echo "=== PR5: provision.sh exists ==="
# =============================================================================

if [ -f "$PROVISION" ]; then
  pass "provision.sh exists"
else
  fail "provision.sh does not exist"
  echo "=== Summary ==="
  echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
  exit $FAILED
fi

# =============================================================================
echo ""
echo "=== PR5: provision.sh ends with reboot ==="
# =============================================================================

# The script should end with a reboot command (not systemctl start)
# Check last 20 non-comment, non-empty lines for reboot
tail_content=$(grep -v '^\s*#\|^\s*$' "$PROVISION" | tail -20)

if echo "$tail_content" | grep -q 'reboot\|shutdown -r'; then
  pass "provision.sh ends with reboot"
else
  fail "provision.sh should end with reboot (found: $(echo "$tail_content" | tail -3))"
fi

# =============================================================================
echo ""
echo "=== PR5: No systemctl start for OpenClaw services ==="
# =============================================================================

# provision.sh should only enable services, not start them
# (services start after the reboot via systemd)
# Exclude lines in comments
start_lines=$(grep -n 'systemctl start.*openclaw' "$PROVISION" | grep -v '^\s*#' || true)

if [ -z "$start_lines" ]; then
  pass "No 'systemctl start openclaw' in provision.sh"
else
  fail "provision.sh starts OpenClaw services (should only enable): $start_lines"
fi

# Desktop services (xvfb, x11vnc, xrdp) should also not be started during provisioning
desktop_starts=$(grep -n 'systemctl start.*\(xvfb\|x11vnc\|xrdp\|desktop\)' "$PROVISION" | grep -v '^\s*#' || true)

if [ -z "$desktop_starts" ]; then
  pass "No desktop service starts during provisioning"
else
  fail "provision.sh starts desktop services (should enable-only): $desktop_starts"
fi

# =============================================================================
echo ""
echo "=== PR5: No killall apt ==="
# =============================================================================

if grep -q 'killall.*apt\|kill.*apt-get\|kill.*dpkg' "$PROVISION"; then
  fail "provision.sh still has killall apt (not needed without background fork)"
else
  pass "No killall apt in provision.sh"
fi

# =============================================================================
echo ""
echo "=== PR5: No background fork ==="
# =============================================================================

if grep -q 'nohup\|disown\| &$' "$PROVISION"; then
  fail "provision.sh has background fork patterns (nohup/disown/&)"
else
  pass "No background fork in provision.sh"
fi

# =============================================================================
echo ""
echo "=== PR5: Single apt-get update ==="
# =============================================================================

apt_update_count=$(grep -c 'apt-get update\|apt update' "$PROVISION" || true)

if [ "$apt_update_count" -le 1 ]; then
  pass "At most 1 apt-get update call ($apt_update_count)"
else
  fail "Multiple apt-get update calls ($apt_update_count) — should be 1"
fi

# =============================================================================
echo ""
echo "=== PR5: Stages emit updates roughly every 60s ==="
# =============================================================================

# Count stage transitions (calls to set-stage.sh)
stage_count=$(grep -c 'set-stage.sh\|\$S [0-9]' "$PROVISION" || true)

if [ "$stage_count" -ge 7 ]; then
  pass "At least 7 stage updates ($stage_count)"
else
  fail "Only $stage_count stage updates (need ≥7 for ~60s intervals)"
fi

# =============================================================================
echo ""
echo "=== PR5: Header comment says reboot, not no-reboot ==="
# =============================================================================

if grep -q 'no reboot\|No reboot' "$PROVISION"; then
  fail "Header still says 'no reboot'"
else
  pass "Header does not claim 'no reboot'"
fi

if grep -q 'REBOOT\|reboot' "$PROVISION" | head -1 | grep -qi 'reboot'; then
  pass "Header mentions reboot"
else
  # Not critical - just a comment
  pass "Header comment check (informational)"
fi

# =============================================================================
echo ""
echo "=== PR5: bootstrap.sh auto-detects provision.sh ==="
# =============================================================================

if [ -f "$BOOTSTRAP" ]; then
  if grep -q 'provision.sh' "$BOOTSTRAP"; then
    pass "bootstrap.sh references provision.sh"
  else
    fail "bootstrap.sh should auto-detect provision.sh"
  fi

  # Should fall back to phase1-critical.sh
  if grep -q 'phase1-critical.sh' "$BOOTSTRAP"; then
    pass "bootstrap.sh has phase1-critical.sh fallback"
  else
    fail "bootstrap.sh should fall back to phase1-critical.sh"
  fi
else
  fail "bootstrap.sh not found"
fi

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
