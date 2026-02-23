#!/bin/bash
# =============================================================================
# test_state_machine.sh -- Tests for openclaw-state.sh state machine
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_SCRIPT="${SCRIPT_DIR}/../scripts/openclaw-state.sh"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

# Override state paths for testing
export OPENCLAW_STATE_DIR="$TEST_DIR"
export OPENCLAW_STATE_LOG="$TEST_DIR/events.jsonl"
export GROUP=""

# Use fast thresholds for testing
export OPENCLAW_DEGRADE_AFTER=1
export OPENCLAW_RECOVER_AFTER=2
export OPENCLAW_RECOVERY_COOLDOWN=1
export OPENCLAW_MAX_RECOVERY=2
export OPENCLAW_HEALTHY_STREAK=2
export OPENCLAW_TRANSITION_TIMEOUT=5

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

run() { bash "$STATE_SCRIPT" "$@" 2>&1; }

assert_state() {
  local expected="$1"
  local actual
  actual=$(run get --field state)
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ State is $expected"
    PASS=$((PASS + 1))
  else
    echo "  ✗ Expected state=$expected, got state=$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_field() {
  local field="$1" expected="$2"
  local actual
  actual=$(run get --field "$field")
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $field = $expected"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $field: expected=$expected, got=$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local output="$1" expected="$2"
  if echo "$output" | grep -q "$expected"; then
    echo "  ✓ Output contains '$expected'"
    PASS=$((PASS + 1))
  else
    echo "  ✗ Output does not contain '$expected': $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_fails() {
  local output
  if output=$(run "$@" 2>&1); then
    echo "  ✗ Expected failure but succeeded: $output"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ Correctly failed: $(echo "$output" | head -1)"
    PASS=$((PASS + 1))
  fi
}

# ===== TEST SUITE =====

echo "=== Test: Init ==="
# Create isolated marker dir so init bootstraps to BOOTING
export OPENCLAW_MARKER_DIR="$TEST_DIR/markers"
mkdir -p "$OPENCLAW_MARKER_DIR"
run init >/dev/null
assert_state "BOOTING"
assert_field "version" "1"
assert_field "generation" "1"
echo ""

echo "=== Test: Basic Transitions ==="
run transition --to HEALTHY --reason "Boot complete" --by "test"
assert_state "HEALTHY"
assert_field "generation" "2"
assert_field "reason" "Boot complete"
echo ""

echo "=== Test: Invalid Transition ==="
assert_fails transition --to SAFE_MODE --reason "should fail"
echo ""

echo "=== Test: Health Report - Pass ==="
run report-health --status pass
assert_field "health.healthy_streak" "1"
assert_field "health.consecutive_failures" "0"
echo ""

echo "=== Test: Health Report - Fail triggers DEGRADED ==="
run report-health --status fail --failed-agents "agent2"
assert_state "DEGRADED"
assert_field "health.consecutive_failures" "1"
echo ""

echo "=== Test: Health Report - Pass in DEGRADED returns to HEALTHY ==="
run report-health --status pass
assert_state "HEALTHY"
assert_field "health.consecutive_failures" "0"
echo ""

echo "=== Test: Multiple failures trigger RECOVERING ==="
run report-health --status fail --failed-agents "agent2"
assert_state "DEGRADED"
# Need to wait past cooldown (1s for tests)
sleep 2
run report-health --status fail --failed-agents "agent2"
assert_state "RECOVERING"
assert_field "recovery.attempts" "1"
echo ""

echo "=== Test: Recovery -> Transitioning ==="
run transition --to TRANSITIONING --reason "Recovery complete" --by "recovery-handler"
assert_state "TRANSITIONING"
echo ""

echo "=== Test: Transitioning -> Healthy on pass ==="
run report-health --status pass
assert_state "HEALTHY"
assert_field "recovery.attempts" "0"
echo ""

echo "=== Test: Max recovery attempts -> SAFE_MODE ==="
# Fail twice to get to DEGRADED then RECOVERING
run report-health --status fail --failed-agents "agent2"
assert_state "DEGRADED"
sleep 2
run report-health --status fail --failed-agents "agent2"
assert_state "RECOVERING"
# Simulate recovery -> transition -> fail
run transition --to TRANSITIONING --reason "attempt 1"
run report-health --status fail --failed-agents "agent2"
assert_state "SAFE_MODE"
echo ""

echo "=== Test: Lock Management ==="
run lock --holder "test-suite" --ttl 10
assert_field "lock.holder" "test-suite"

# Another holder should fail
assert_fails lock --holder "other-holder" --ttl 10

# Unlock
run unlock --holder "test-suite"
assert_field "lock.holder" ""
echo ""

echo "=== Test: Lock prevents unauthorized transitions ==="
# Reset to SAFE_MODE for this test
run lock --holder "manual-fix" --ttl 10
assert_fails transition --to TRANSITIONING --by "e2e-check"
# Lock holder can transition
run transition --to TRANSITIONING --reason "Manual fix" --by "manual-fix"
assert_state "TRANSITIONING"
run unlock --holder "manual-fix"
echo ""

echo "=== Test: Event log ==="
local_count=$(wc -l < "$TEST_DIR/events.jsonl")
if [ "$local_count" -gt 0 ]; then
  echo "  ✓ Event log has $local_count entries"
  PASS=$((PASS + 1))
else
  echo "  ✗ Event log is empty"
  FAIL=$((FAIL + 1))
fi
echo ""

echo "=== Test: History command ==="
output=$(run history --limit 20)
assert_contains "$output" "lock"
echo ""

echo "=== Test: Generation monotonically increases ==="
gen=$(run get --field generation)
if [ "$gen" -gt 5 ]; then
  echo "  ✓ Generation is $gen (monotonically increasing)"
  PASS=$((PASS + 1))
else
  echo "  ✗ Generation unexpectedly low: $gen"
  FAIL=$((FAIL + 1))
fi
echo ""

# ===== RESULTS =====
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
