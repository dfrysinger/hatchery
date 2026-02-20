#!/bin/bash
# =============================================================================
# test-simplification-pr6.sh -- PR 6: Separate E2E test from agent intro
# =============================================================================
# TDD tests ensuring the E2E check uses a deterministic test prompt
# (not "introduce yourself"), intros are separate, and safe-mode/normal
# E2E paths are unified.
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

E2E_CHECK="$REPO_DIR/scripts/gateway-e2e-check.sh"

# =============================================================================
echo ""
echo "=== PR6: E2E check exists ==="
# =============================================================================

if [ -f "$E2E_CHECK" ]; then
  pass "gateway-e2e-check.sh exists"
else
  fail "gateway-e2e-check.sh does not exist"
  echo "=== Summary ==="
  echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
  exit $FAILED
fi

# =============================================================================
echo ""
echo "=== PR6: E2E test uses deterministic prompt (not intro) ==="
# =============================================================================

# The E2E test should use a prompt like "HEALTH_CHECK_OK" that can be
# verified deterministically, NOT "introduce yourself"
if grep -q 'HEALTH_CHECK_OK\|health.check.ok\|HEALTHCHECK' "$E2E_CHECK"; then
  pass "E2E uses deterministic health check prompt"
else
  fail "E2E should use deterministic prompt containing HEALTH_CHECK_OK"
fi

# The old "introduce yourself" pattern should NOT be the test prompt
# (it's fine in a separate intro function)
# Look for "introduce yourself" used directly with openclaw CLI as a health check
if grep -A2 'check_agents_e2e\|check_agent_e2e\|e2e_test_agent' "$E2E_CHECK" | grep -q 'introduce yourself'; then
  fail "E2E test function still uses 'introduce yourself' as the test prompt"
else
  pass "E2E test does not use 'introduce yourself' as test prompt"
fi

# =============================================================================
echo ""
echo "=== PR6: E2E test does NOT use --deliver ==="
# =============================================================================

# The health check test should NOT use --deliver (that sends to the user)
# Only the intro function should use --deliver
# Check the test function specifically — not the whole file

# Find the test function and check it doesn't use --deliver
test_fn_lines=$(sed -n '/check_agents_e2e\|e2e_test_single_agent/,/^}/p' "$E2E_CHECK" 2>/dev/null || true)

if [ -n "$test_fn_lines" ]; then
  if echo "$test_fn_lines" | grep -q '\-\-deliver'; then
    fail "E2E test function uses --deliver (should only test, not deliver)"
  else
    pass "E2E test function does not use --deliver"
  fi
else
  # If we can't find the function, check the overall approach
  # The script should have separate test and intro phases
  if grep -q 'send_agent_intros\|deliver_intro\|send_intro' "$E2E_CHECK"; then
    pass "Script has separate intro delivery function"
  else
    fail "Script should have separate intro delivery (send_agent_intros or similar)"
  fi
fi

# =============================================================================
echo ""
echo "=== PR6: Separate intro function exists ==="
# =============================================================================

if grep -q 'send_agent_intros\|deliver_intros\|send_intros' "$E2E_CHECK"; then
  pass "Separate intro function exists"
else
  fail "Should have a separate send_agent_intros() function"
fi

# =============================================================================
echo ""
echo "=== PR6: Intro only runs on fresh boot ==="
# =============================================================================

# The intro function should check for a "fresh boot" condition
# (e.g., not re-check, not already introduced)
if grep -q 'FRESH_BOOT\|fresh_boot\|FIRST_BOOT\|intro.*marker\|already.*introduced\|intro.*sent' "$E2E_CHECK"; then
  pass "Intro has fresh-boot guard"
else
  fail "Intro should only run on fresh boot (needs guard)"
fi

# =============================================================================
echo ""
echo "=== PR6: Unified E2E path (normal + safe-mode) ==="
# =============================================================================

# There should NOT be a separate check_safe_mode_e2e function
# The main check_agents_e2e should accept agent list as parameter
if grep -q 'check_safe_mode_e2e()' "$E2E_CHECK"; then
  fail "Still has separate check_safe_mode_e2e() — should use unified check_agents_e2e"
else
  pass "No separate check_safe_mode_e2e function"
fi

# The safe mode path should call the same function with "safe-mode" arg
if grep -q 'check_agents_e2e.*safe-mode\|check_agents_e2e.*"safe-mode"' "$E2E_CHECK"; then
  pass "Safe mode uses same check_agents_e2e with safe-mode arg"
else
  # Alternative: check if safe mode uses the unified path somehow
  if grep -q 'hc_is_in_safe_mode.*check_agents_e2e\|safe.*mode.*e2e_test' "$E2E_CHECK"; then
    pass "Safe mode integrates with unified E2E path"
  else
    fail "Safe mode should use unified check_agents_e2e with safe-mode argument"
  fi
fi

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
