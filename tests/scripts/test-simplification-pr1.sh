#!/bin/bash
# =============================================================================
# test-simplification-pr1.sh -- PR 1: Settle time 45s→10s + TimeoutStartSec
# =============================================================================
# TDD tests for the trivial but high-value timing changes.
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

HEALTH_CHECK="$REPO_DIR/scripts/gateway-health-check.sh"
BUILD_CONFIG="$REPO_DIR/scripts/build-full-config.sh"
GEN_SERVICES="$REPO_DIR/scripts/generate-session-services.sh"

# =============================================================================
echo ""
echo "=== PR1: Settle time default ==="
# =============================================================================

# The default settle time should be 10s, not 45s
if grep -q 'HEALTH_CHECK_SETTLE_SECS:-10' "$HEALTH_CHECK"; then
  pass "Default settle time is 10s"
else
  fail "Default settle time should be 10s (found: $(grep 'HEALTH_CHECK_SETTLE_SECS' "$HEALTH_CHECK" | head -1))"
fi

# Must still be overridable via env var
if grep -q 'HEALTH_CHECK_SETTLE_SECS' "$HEALTH_CHECK"; then
  pass "Settle time is env-var configurable"
else
  fail "Settle time must be configurable via HEALTH_CHECK_SETTLE_SECS"
fi

# No hardcoded 45 anywhere in the health check
if ! grep -q 'sleep 45\|SETTLE.*45\|:-45' "$HEALTH_CHECK"; then
  pass "No hardcoded 45s settle in health check"
else
  fail "Found hardcoded 45s in health check"
fi

# =============================================================================
echo ""
echo "=== PR1: TimeoutStartSec ==="
# =============================================================================

# build-full-config.sh should use 180s, not 420s or 120s
if grep -q 'TimeoutStartSec=180' "$BUILD_CONFIG"; then
  pass "build-full-config.sh uses TimeoutStartSec=180"
else
  current=$(grep -o 'TimeoutStartSec=[0-9]*' "$BUILD_CONFIG" | head -1)
  fail "build-full-config.sh should use TimeoutStartSec=180 (found: ${current:-none})"
fi

# generate-session-services.sh should also use 180s
if grep -q 'TimeoutStartSec=180' "$GEN_SERVICES"; then
  pass "generate-session-services.sh uses TimeoutStartSec=180"
else
  current=$(grep -o 'TimeoutStartSec=[0-9]*' "$GEN_SERVICES" | head -1)
  fail "generate-session-services.sh should use TimeoutStartSec=180 (found: ${current:-none})"
fi

# No 420s anywhere
if ! grep -rq 'TimeoutStartSec=420' "$REPO_DIR/scripts/"; then
  pass "No 420s TimeoutStartSec in any script"
else
  fail "Found TimeoutStartSec=420 in scripts"
fi

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
