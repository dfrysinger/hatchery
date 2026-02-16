#!/bin/bash
# =============================================================================
# test-health-check-bugs.sh -- Regression tests for health check bugs
# =============================================================================
# Tests specific bugs found and fixed in the safe mode implementation
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"

PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}✓${NC} $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

# =============================================================================
# Bug: is-active check fails in ExecStartPost mode (commit a858fc8)
# =============================================================================
echo ""
echo "=== Bug: is-active check in ExecStartPost mode ==="

# The fix: skip is-active check when RUN_MODE=execstartpost
HEALTH_CHECK="$REPO_DIR/scripts/gateway-health-check.sh"

if grep -q 'if \[ "\$RUN_MODE" != "execstartpost" \]' "$HEALTH_CHECK"; then
  pass "Health check skips is-active when RUN_MODE=execstartpost"
else
  fail "Health check should skip is-active in execstartpost mode"
fi

# Verify the conditional is around the is-active check
if grep -A2 'RUN_MODE.*!=.*execstartpost' "$HEALTH_CHECK" | grep -q 'is-active'; then
  pass "is-active check is inside RUN_MODE conditional"
else
  fail "is-active check should be guarded by RUN_MODE check"
fi

# =============================================================================
# Bug: Ready! notification sent when in safe mode (commit 5228bfd)
# =============================================================================
echo ""
echo "=== Bug: Ready! notification when in safe mode ==="

# The fix: check ALREADY_IN_SAFE_MODE before sending healthy notification
if grep -q 'HEALTHY.*true.*&&.*ALREADY_IN_SAFE_MODE.*true' "$HEALTH_CHECK"; then
  pass "Health check distinguishes safe-mode-healthy from full-healthy"
else
  fail "Should check ALREADY_IN_SAFE_MODE when HEALTHY=true"
fi

# Verify safe mode stable sends safe-mode notification, not healthy
if grep -B2 -A2 'ALREADY_IN_SAFE_MODE.*true' "$HEALTH_CHECK" | grep -q 'safe-mode'; then
  pass "Safe mode stable sends safe-mode notification"
else
  fail "Safe mode stable should send safe-mode notification, not healthy"
fi

# =============================================================================
# Bug: Intermediate notifications sent (commit 9805213)
# =============================================================================
echo ""
echo "=== Bug: Intermediate notifications ==="

# The fix: no notification when first entering safe mode (else branch)
if grep -A3 'Entering safe mode.*Run 1' "$HEALTH_CHECK" | grep -qv 'send_boot_notification'; then
  pass "No notification sent when first entering safe mode"
else
  fail "Should not send notification when first entering safe mode"
fi

# Verify comment explains the deferred notification
if grep -q 'notification deferred\|wait for Run 2' "$HEALTH_CHECK"; then
  pass "Comment explains deferred notification logic"
else
  fail "Should have comment explaining deferred notification"
fi

# =============================================================================
# Bug: Emergency config had wrong fallback logic (commit 0774d41)
# =============================================================================
echo ""
echo "=== Bug: Emergency config fallback logic ==="

PHASE1="$REPO_DIR/scripts/phase1-critical.sh"

# The fix: use AGENT1_MODEL directly, no custom fallback
if grep -q 'EMERGENCY_MODEL=.*AGENT1_MODEL' "$PHASE1"; then
  pass "Emergency config uses AGENT1_MODEL directly"
else
  fail "Emergency config should use AGENT1_MODEL, not custom fallback"
fi

# Verify no "prefer Google" logic
if ! grep -q 'prefer.*Google\|Google.*expire' "$PHASE1" | grep -v '^#'; then
  pass "Emergency config has no 'prefer Google' logic"
else
  fail "Emergency config should not have Google preference (that's smart recovery's job)"
fi

# Verify case statement for provider detection
if grep -q 'case.*EMERGENCY_MODEL.*in' "$PHASE1"; then
  pass "Emergency config picks API key based on model provider"
else
  fail "Should use case statement to pick API key based on model"
fi

# =============================================================================
# Bug: Undefined variable A1TK (commit 1c31bc5)
# =============================================================================
echo ""
echo "=== Bug: Undefined variable A1TK ==="

# The fix: use TBT (which is defined) not A1TK
if grep -q 'A1TK' "$PHASE1"; then
  fail "Should not use undefined variable A1TK"
else
  pass "No reference to undefined variable A1TK"
fi

if grep -q 'EMERGENCY_TOKEN=.*TBT' "$PHASE1"; then
  pass "Emergency token uses TBT variable"
else
  fail "Emergency token should use TBT variable"
fi

# =============================================================================
# Bug: apply-config.sh starts clawdbot before phase2 (commit 22f0434)
# =============================================================================
echo ""
echo "=== Bug: apply-config.sh premature start ==="

APPLY_CONFIG="$REPO_DIR/scripts/apply-config.sh"

if [ -f "$APPLY_CONFIG" ]; then
  # The fix: check for phase2-complete before restarting
  if grep -q 'phase2-complete' "$APPLY_CONFIG"; then
    pass "apply-config.sh checks for phase2-complete"
  else
    fail "apply-config.sh should check for phase2-complete before restart"
  fi
else
  echo "  (apply-config.sh not found, skipping)"
fi

# =============================================================================
# Bug: build-full-config.sh overwrites safe mode config (commit a464944)
# =============================================================================
echo ""
echo "=== Bug: build-full-config.sh overwrites safe mode ==="

BUILD_CONFIG="$REPO_DIR/scripts/build-full-config.sh"

if [ -f "$BUILD_CONFIG" ]; then
  # The fix: check for safe-mode flag before overwriting
  if grep -q 'safe-mode' "$BUILD_CONFIG"; then
    pass "build-full-config.sh checks for safe-mode flag"
  else
    fail "build-full-config.sh should check safe-mode flag before overwriting"
  fi
  
  # Verify it skips overwrite when in safe mode
  if grep -B5 -A5 'safe-mode' "$BUILD_CONFIG" | grep -q 'skip\|exit\|return'; then
    pass "build-full-config.sh skips overwrite when in safe mode"
  else
    fail "Should skip config overwrite when safe-mode flag exists"
  fi
else
  echo "  (build-full-config.sh not found, skipping)"
fi

# =============================================================================
# Bug: Exit code 2 doesn't prevent restart loop (commit 2557354)
# =============================================================================
echo ""
echo "=== Bug: Exit code 2 restart loop ==="

# The fix: RestartPreventExitStatus=2 in service file
if grep -q 'RestartPreventExitStatus=2\|RestartPreventExitStatus.*2' "$PHASE1"; then
  pass "Service file has RestartPreventExitStatus=2"
else
  fail "Service file should have RestartPreventExitStatus=2"
fi

# Verify health check uses exit code 2 for critical
if grep -q 'EXIT_CODE=2' "$HEALTH_CHECK"; then
  pass "Health check uses exit code 2 for critical failure"
else
  fail "Health check should use exit code 2 for critical"
fi

# =============================================================================
# Bug: Bootstrap notification sent (commit c139224)
# =============================================================================
echo ""
echo "=== Bug: Bootstrap notification removed ==="

BOOTSTRAP="$REPO_DIR/scripts/bootstrap.sh"

if [ -f "$BOOTSTRAP" ]; then
  if ! grep -q 'notify.*starting phase1\|notify.*installed' "$BOOTSTRAP"; then
    pass "Bootstrap notification removed"
  else
    fail "Bootstrap should not send notification"
  fi
else
  echo "  (bootstrap.sh not found, skipping)"
fi

# Check hatch.yaml too
HATCH_YAML="$REPO_DIR/hatch.yaml"
if [ -f "$HATCH_YAML" ]; then
  if ! grep -q 'notify.*starting phase1' "$HATCH_YAML"; then
    pass "hatch.yaml bootstrap notification removed"
  else
    fail "hatch.yaml should not have bootstrap notification"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================"
echo "Health Check Bug Tests Complete"
echo "================================"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo ""

exit $FAILED
