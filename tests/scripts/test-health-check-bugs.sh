#!/bin/bash
# =============================================================================
# test-health-check-bugs.sh -- Regression tests for health check bugs fixed
# =============================================================================
# Tests for bugs fixed on 2026-02-16:
# - a858fc8: Skip is-active check in ExecStartPost mode
# - 5228bfd: Don't send Ready! notification when in safe mode
# - 9805213: Only notify on final state (no notification on Run 1)
# - 22f0434: apply-config.sh checks phase2-complete before restart
# - a464944: build-full-config.sh respects safe mode flag
# - 2557354: RestartPreventExitStatus=2 prevents infinite loop
# - 0774d41: Emergency config uses agent1's exact settings
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
# BUG a858fc8: Skip is-active check in ExecStartPost mode
# =============================================================================
echo ""
echo "=== Bug a858fc8: Skip is-active in ExecStartPost ==="

test_skip_is_active_in_execstartpost() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "skip_is_active_in_execstartpost: gateway-health-check.sh not found"
    return
  fi
  
  # Check that the script has the RUN_MODE check before is-active
  if grep -q 'RUN_MODE.*execstartpost' "$script" && \
     grep -A5 'RUN_MODE.*execstartpost' "$script" | grep -q 'is-active'; then
    pass "skip_is_active_in_execstartpost: RUN_MODE check exists before is-active"
  else
    fail "skip_is_active_in_execstartpost: missing RUN_MODE check before is-active"
  fi
  
  # Verify the logic skips is-active when RUN_MODE=execstartpost
  if grep -q 'if \[ "\$RUN_MODE" != "execstartpost" \]' "$script"; then
    pass "skip_is_active_in_execstartpost: correctly skips is-active in execstartpost mode"
  else
    fail "skip_is_active_in_execstartpost: is-active skip logic not found"
  fi
}
test_skip_is_active_in_execstartpost

# =============================================================================
# BUG 5228bfd: Don't send Ready! notification when in safe mode
# =============================================================================
echo ""
echo "=== Bug 5228bfd: No Ready! in safe mode ==="

test_no_ready_notification_in_safe_mode() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "no_ready_notification_in_safe_mode: gateway-health-check.sh not found"
    return
  fi
  
  # Check that HEALTHY=true AND ALREADY_IN_SAFE_MODE=true sends safe-mode notification
  if grep -q 'HEALTHY.*true.*ALREADY_IN_SAFE_MODE.*true' "$script" || \
     grep -q 'ALREADY_IN_SAFE_MODE.*true.*HEALTHY.*true' "$script"; then
    pass "no_ready_notification_in_safe_mode: checks both HEALTHY and ALREADY_IN_SAFE_MODE"
  else
    fail "no_ready_notification_in_safe_mode: missing combined check"
  fi
  
  # Verify it sends safe-mode notification in this case (check the notification section)
  if grep -q 'send_boot_notification "safe-mode"' "$script"; then
    pass "no_ready_notification_in_safe_mode: sends safe-mode notification"
  else
    fail "no_ready_notification_in_safe_mode: should send safe-mode notification"
  fi
}
test_no_ready_notification_in_safe_mode

# =============================================================================
# BUG 9805213: Only notify on final state
# =============================================================================
echo ""
echo "=== Bug 9805213: Only notify on final state ==="

test_no_notification_on_first_safe_mode_entry() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "no_notification_on_first_safe_mode_entry: gateway-health-check.sh not found"
    return
  fi
  
  # Check that the else branch (entering safe mode) does NOT send notification
  # It should log "notification deferred" instead
  if grep -q 'notification deferred\|Entering safe mode.*no notification' "$script"; then
    pass "no_notification_on_first_safe_mode_entry: defers notification when entering safe mode"
  else
    fail "no_notification_on_first_safe_mode_entry: should defer notification on first entry"
  fi
}
test_no_notification_on_first_safe_mode_entry

# =============================================================================
# BUG 22f0434: apply-config.sh checks phase2-complete
# =============================================================================
echo ""
echo "=== Bug 22f0434: apply-config.sh phase2 check ==="

test_apply_config_checks_phase2() {
  local script="$REPO_DIR/scripts/apply-config.sh"
  
  if [ ! -f "$script" ]; then
    fail "apply_config_checks_phase2: apply-config.sh not found"
    return
  fi
  
  # Check for phase2-complete check
  if grep -q 'phase2-complete' "$script"; then
    pass "apply_config_checks_phase2: checks for phase2-complete"
  else
    fail "apply_config_checks_phase2: missing phase2-complete check"
  fi
  
  # Check that it skips restart when phase2 not complete
  if grep -q 'Phase 2 not complete\|skipping restart' "$script"; then
    pass "apply_config_checks_phase2: skips restart when phase2 not complete"
  else
    fail "apply_config_checks_phase2: should skip restart before phase2"
  fi
}
test_apply_config_checks_phase2

# =============================================================================
# BUG a464944: build-full-config.sh respects safe mode
# =============================================================================
echo ""
echo "=== Bug a464944: build-full-config.sh safe mode check ==="

test_build_config_respects_safe_mode() {
  local script="$REPO_DIR/scripts/build-full-config.sh"
  
  if [ ! -f "$script" ]; then
    fail "build_config_respects_safe_mode: build-full-config.sh not found"
    return
  fi
  
  # Check for safe-mode flag check
  if grep -q 'safe-mode' "$script"; then
    pass "build_config_respects_safe_mode: checks for safe-mode flag"
  else
    fail "build_config_respects_safe_mode: missing safe-mode check"
  fi
  
  # Check that it skips overwrite when in safe mode
  if grep -q 'safe mode.*skip\|not overwriting.*safe' "$script" || \
     grep -B5 -A5 'safe-mode' "$script" | grep -qi 'skip\|abort\|exit\|return'; then
    pass "build_config_respects_safe_mode: skips overwrite in safe mode"
  else
    fail "build_config_respects_safe_mode: should skip overwrite in safe mode"
  fi
}
test_build_config_respects_safe_mode

# =============================================================================
# BUG 2557354: RestartPreventExitStatus=2
# =============================================================================
echo ""
echo "=== Bug 2557354: RestartPreventExitStatus=2 ==="

test_restart_prevent_exit_status() {
  local script="$REPO_DIR/scripts/phase1-critical.sh"
  
  if [ ! -f "$script" ]; then
    fail "restart_prevent_exit_status: phase1-critical.sh not found"
    return
  fi
  
  # Check for RestartPreventExitStatus=2 in service file generation
  if grep -q 'RestartPreventExitStatus=2' "$script"; then
    pass "restart_prevent_exit_status: RestartPreventExitStatus=2 is set"
  else
    fail "restart_prevent_exit_status: missing RestartPreventExitStatus=2"
  fi
  
  # Verify exit code 2 is documented as critical
  if grep -q '2 = critical\|2.*critical failure\|EXIT_CODE=2.*critical' "$REPO_DIR/scripts/gateway-health-check.sh"; then
    pass "restart_prevent_exit_status: exit code 2 documented as critical"
  else
    fail "restart_prevent_exit_status: exit code 2 should be documented"
  fi
}
test_restart_prevent_exit_status

# =============================================================================
# BUG 0774d41: Emergency config uses agent1's exact settings
# =============================================================================
echo ""
echo "=== Bug 0774d41: Emergency config uses agent1 settings ==="

test_emergency_config_uses_agent1_model() {
  local script="$REPO_DIR/scripts/phase1-critical.sh"
  
  if [ ! -f "$script" ]; then
    fail "emergency_config_uses_agent1_model: phase1-critical.sh not found"
    return
  fi
  
  # Check that AGENT1_MODEL is used for emergency config
  if grep -q 'AGENT1_MODEL' "$script" && \
     grep -q 'EMERGENCY_MODEL.*AGENT1_MODEL' "$script"; then
    pass "emergency_config_uses_agent1_model: uses AGENT1_MODEL"
  else
    fail "emergency_config_uses_agent1_model: should use AGENT1_MODEL"
  fi
  
  # Check that it picks API key based on model provider
  if grep -q 'case.*EMERGENCY_MODEL' "$script"; then
    pass "emergency_config_uses_agent1_model: picks API key based on model provider"
  else
    fail "emergency_config_uses_agent1_model: should pick API key based on model"
  fi
}
test_emergency_config_uses_agent1_model

test_emergency_config_no_fallback_logic() {
  local script="$REPO_DIR/scripts/phase1-critical.sh"
  
  if [ ! -f "$script" ]; then
    fail "emergency_config_no_fallback_logic: phase1-critical.sh not found"
    return
  fi
  
  # Emergency config should NOT have "prefer Google" or similar fallback logic
  # It should just use agent1's exact settings
  if grep -B5 -A10 'emergency config' "$script" | grep -qi 'prefer.*google\|google.*first'; then
    fail "emergency_config_no_fallback_logic: should not prefer Google (use agent1 settings)"
  else
    pass "emergency_config_no_fallback_logic: no hardcoded provider preference"
  fi
}
test_emergency_config_no_fallback_logic

# =============================================================================
# BUG 1c31bc5: Correct variable TBT for emergency token
# =============================================================================
echo ""
echo "=== Bug 1c31bc5: Correct variable for emergency token ==="

test_emergency_token_uses_tbt() {
  local script="$REPO_DIR/scripts/phase1-critical.sh"
  
  if [ ! -f "$script" ]; then
    fail "emergency_token_uses_tbt: phase1-critical.sh not found"
    return
  fi
  
  # Should use TBT (AGENT1_BOT_TOKEN), not A1TK
  if grep -q 'EMERGENCY_TOKEN.*TBT\|EMERGENCY_TOKEN=.*\$TBT' "$script"; then
    pass "emergency_token_uses_tbt: uses TBT variable"
  else
    fail "emergency_token_uses_tbt: should use TBT variable"
  fi
  
  # Should NOT use undefined A1TK
  if grep -q 'A1TK' "$script"; then
    fail "emergency_token_uses_tbt: still references undefined A1TK"
  else
    pass "emergency_token_uses_tbt: no reference to undefined A1TK"
  fi
}
test_emergency_token_uses_tbt

# =============================================================================
# Additional regression tests
# =============================================================================
echo ""
echo "=== Additional Regression Tests ==="

# Test: Notification deduplication by status type
test_notification_deduplication() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "notification_deduplication: gateway-health-check.sh not found"
    return
  fi
  
  # Check for notification-sent-${status} pattern
  if grep -q 'notification-sent-\${status}\|notification-sent-.*status' "$script"; then
    pass "notification_deduplication: uses per-status deduplication files"
  else
    fail "notification_deduplication: missing per-status deduplication"
  fi
}
test_notification_deduplication

# Test: Health check exit codes documented
test_exit_codes_documented() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "exit_codes_documented: gateway-health-check.sh not found"
    return
  fi
  
  # Check all three exit codes are documented
  local exit_0=$(grep -c 'exit.*0\|EXIT_CODE=0' "$script")
  local exit_1=$(grep -c 'exit.*1\|EXIT_CODE=1' "$script")
  local exit_2=$(grep -c 'exit.*2\|EXIT_CODE=2' "$script")
  
  if [ "$exit_0" -gt 0 ] && [ "$exit_1" -gt 0 ] && [ "$exit_2" -gt 0 ]; then
    pass "exit_codes_documented: all three exit codes (0, 1, 2) are used"
  else
    fail "exit_codes_documented: missing exit codes (0=$exit_0, 1=$exit_1, 2=$exit_2)"
  fi
}
test_exit_codes_documented

# Test: Safe mode flag is set during recovery
test_safe_mode_flag_set() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "safe_mode_flag_set: gateway-health-check.sh not found"
    return
  fi
  
  # Check that safe-mode flag is touched/created
  if grep -q 'touch.*/var/lib/init-status/safe-mode' "$script"; then
    pass "safe_mode_flag_set: creates safe-mode flag"
  else
    fail "safe_mode_flag_set: should create safe-mode flag"
  fi
}
test_safe_mode_flag_set

# Test: Safe mode flag is cleared on full health
test_safe_mode_flag_cleared() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "safe_mode_flag_cleared: gateway-health-check.sh not found"
    return
  fi
  
  # Check that safe-mode flag is removed when healthy
  if grep -q 'rm.*safe-mode\|rm -f.*/var/lib/init-status/safe-mode' "$script"; then
    pass "safe_mode_flag_cleared: removes safe-mode flag when healthy"
  else
    fail "safe_mode_flag_cleared: should remove safe-mode flag when healthy"
  fi
}
test_safe_mode_flag_cleared

# Test: Recovery counter prevents infinite loops
test_recovery_counter() {
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    fail "recovery_counter: gateway-health-check.sh not found"
    return
  fi
  
  # Check for recovery attempt counter
  if grep -q 'recovery-attempts\|RECOVERY_ATTEMPTS\|MAX_RECOVERY_ATTEMPTS' "$script"; then
    pass "recovery_counter: tracks recovery attempts"
  else
    fail "recovery_counter: should track recovery attempts"
  fi
  
  # Check for max attempts check
  if grep -q 'RECOVERY_ATTEMPTS.*MAX\|retries.*MAX\|attempts.*ge.*MAX' "$script"; then
    pass "recovery_counter: checks against max attempts"
  else
    fail "recovery_counter: should check against max attempts"
  fi
}
test_recovery_counter

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "==================================="

if [ $FAILED -gt 0 ]; then
  exit 1
fi
exit 0
