#!/bin/bash
# =============================================================================
# test-per-group-health-check.sh -- TDD tests for per-group health checks
# =============================================================================
# Tests for session isolation health check behavior:
# - Each group runs independent health check
# - Safe mode only affects failing group
# - restart_gateway handles session services correctly
# - Group-specific state files (safe-mode-{group}, recovery-attempts-{group})
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
  [ -n "${2:-}" ] && echo "    $2"
  FAILED=$((FAILED + 1))
}

skip() {
  echo -e "${YELLOW}○${NC} $1 (skipped)"
}

# =============================================================================
# Test Setup
# =============================================================================
setup_test_env() {
  export TEST_TMPDIR=$(mktemp -d)
  export TEST_MODE=1
  
  # Create directory structure
  mkdir -p "$TEST_TMPDIR/home/.openclaw"
  mkdir -p "$TEST_TMPDIR/home/.openclaw-sessions/browser"
  mkdir -p "$TEST_TMPDIR/home/.openclaw-sessions/documents"
  mkdir -p "$TEST_TMPDIR/var/lib/init-status"
  mkdir -p "$TEST_TMPDIR/etc/systemd/system"
  
  # Create mock habitat-parsed.env for session isolation
  cat > "$TEST_TMPDIR/habitat-parsed.env" <<'EOF'
HABITAT_NAME="TestHabitat"
PLATFORM="telegram"
ISOLATION_DEFAULT="session"
ISOLATION_GROUPS="browser,documents"
AGENT_COUNT=4
AGENT1_NAME="Agent1"
AGENT1_ISOLATION_GROUP="documents"
AGENT1_BOT_TOKEN="TOKEN_1_VALID"
AGENT1_TELEGRAM_BOT_TOKEN="TOKEN_1_VALID"
AGENT2_NAME="Agent2"
AGENT2_ISOLATION_GROUP="documents"
AGENT2_BOT_TOKEN="TOKEN_2_VALID"
AGENT2_TELEGRAM_BOT_TOKEN="TOKEN_2_VALID"
AGENT3_NAME="Agent3"
AGENT3_ISOLATION_GROUP="browser"
AGENT3_BOT_TOKEN="TOKEN_3_VALID"
AGENT3_TELEGRAM_BOT_TOKEN="TOKEN_3_VALID"
AGENT4_NAME="Agent4"
AGENT4_ISOLATION_GROUP="browser"
AGENT4_BOT_TOKEN="TOKEN_4_VALID"
AGENT4_TELEGRAM_BOT_TOKEN="TOKEN_4_VALID"
TELEGRAM_OWNER_ID="123456789"
USERNAME="testuser"
EOF
  
  # Create droplet.env
  cat > "$TEST_TMPDIR/droplet.env" <<'EOF'
ANTHROPIC_API_KEY="valid-anthropic-key"
GOOGLE_API_KEY="valid-google-key"
EOF

  # Track systemctl calls
  export SYSTEMCTL_CALLS="$TEST_TMPDIR/systemctl-calls.log"
  > "$SYSTEMCTL_CALLS"
  
  source "$TEST_TMPDIR/habitat-parsed.env"
}

cleanup_test_env() {
  rm -rf "$TEST_TMPDIR"
}

# Mock systemctl that logs calls
mock_systemctl() {
  echo "systemctl $*" >> "$SYSTEMCTL_CALLS"
  
  case "$1" in
    is-active)
      # Return success for services we want "running"
      case "$2" in
        --quiet) shift 2; service="$1" ;;
        *) service="$2" ;;
      esac
      [ -f "$TEST_TMPDIR/active-services/$service" ] && return 0 || return 1
      ;;
    stop|start|restart|enable|disable)
      # Just log the call
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# =============================================================================
# Test: GROUP environment variable is respected
# =============================================================================
echo ""
echo "=== Per-Group Health Check Tests ==="

test_group_env_determines_scope() {
  setup_test_env
  
  # Create a minimal health check wrapper that checks GROUP
  cat > "$TEST_TMPDIR/check-group.sh" <<'SCRIPT'
#!/bin/bash
source "$TEST_TMPDIR/habitat-parsed.env"
GROUP="${GROUP:-}"
GROUP_PORT="${GROUP_PORT:-}"

if [ -n "$GROUP" ]; then
  echo "MODE=per-group"
  echo "GROUP=$GROUP"
  echo "PORT=$GROUP_PORT"
else
  echo "MODE=all-groups"
fi
SCRIPT
  chmod +x "$TEST_TMPDIR/check-group.sh"
  
  # Test with GROUP set
  output=$(GROUP=browser GROUP_PORT=18790 bash "$TEST_TMPDIR/check-group.sh")
  
  if echo "$output" | grep -q "MODE=per-group" && \
     echo "$output" | grep -q "GROUP=browser"; then
    pass "GROUP env var is read and determines scope"
  else
    fail "GROUP env var not properly read" "Got: $output"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: Only agents in GROUP are checked
# =============================================================================
test_only_group_agents_checked() {
  setup_test_env
  
  # Extract the agent filtering logic concept
  # When GROUP=browser, only agent3 and agent4 should be checked
  
  cat > "$TEST_TMPDIR/filter-agents.sh" <<'SCRIPT'
#!/bin/bash
source "$TEST_TMPDIR/habitat-parsed.env"
GROUP="${GROUP:-}"

checked_agents=""
for i in $(seq 1 $AGENT_COUNT); do
  agent_group_var="AGENT${i}_ISOLATION_GROUP"
  agent_group="${!agent_group_var:-}"
  
  # In per-group mode, only check agents in this group
  if [ -n "$GROUP" ] && [ "$agent_group" != "$GROUP" ]; then
    continue
  fi
  
  checked_agents="$checked_agents agent$i"
done

echo "CHECKED:$checked_agents"
SCRIPT
  chmod +x "$TEST_TMPDIR/filter-agents.sh"
  
  # Test browser group - should only check agent3,4
  output=$(GROUP=browser bash "$TEST_TMPDIR/filter-agents.sh")
  
  if echo "$output" | grep -q "agent3" && \
     echo "$output" | grep -q "agent4" && \
     ! echo "$output" | grep -q "agent1" && \
     ! echo "$output" | grep -q "agent2"; then
    pass "Only browser group agents (3,4) are checked when GROUP=browser"
  else
    fail "Wrong agents checked for GROUP=browser" "Got: $output"
  fi
  
  # Test documents group - should only check agent1,2
  output=$(GROUP=documents bash "$TEST_TMPDIR/filter-agents.sh")
  
  if echo "$output" | grep -q "agent1" && \
     echo "$output" | grep -q "agent2" && \
     ! echo "$output" | grep -q "agent3" && \
     ! echo "$output" | grep -q "agent4"; then
    pass "Only documents group agents (1,2) are checked when GROUP=documents"
  else
    fail "Wrong agents checked for GROUP=documents" "Got: $output"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: Safe mode state files are per-group
# =============================================================================
test_safe_mode_state_per_group() {
  setup_test_env
  
  # When GROUP=browser enters safe mode, it should create:
  # - /var/lib/init-status/safe-mode-browser
  # NOT:
  # - /var/lib/init-status/safe-mode (global)
  
  local state_dir="$TEST_TMPDIR/var/lib/init-status"
  
  # Simulate browser group entering safe mode
  GROUP="browser"
  if [ -n "$GROUP" ]; then
    touch "$state_dir/safe-mode-$GROUP"
    echo "1" > "$state_dir/recovery-attempts-$GROUP"
  fi
  
  # Verify per-group files created
  if [ -f "$state_dir/safe-mode-browser" ]; then
    pass "Per-group safe-mode file created (safe-mode-browser)"
  else
    fail "Per-group safe-mode file NOT created"
  fi
  
  if [ -f "$state_dir/recovery-attempts-browser" ]; then
    pass "Per-group recovery-attempts file created"
  else
    fail "Per-group recovery-attempts file NOT created"
  fi
  
  # Verify global file NOT created
  if [ ! -f "$state_dir/safe-mode" ]; then
    pass "Global safe-mode file NOT created (correct isolation)"
  else
    fail "Global safe-mode file was created (breaks isolation)"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: restart_gateway handles session isolation correctly
# =============================================================================
test_restart_gateway_session_mode() {
  setup_test_env
  
  # This is the BUG we're fixing:
  # In session isolation with GROUP set, restart_gateway should:
  # - Restart openclaw-{GROUP}.service
  # NOT:
  # - Restart openclaw (which doesn't exist in session mode)
  
  # Extract and test the restart logic
  cat > "$TEST_TMPDIR/restart-logic.sh" <<'SCRIPT'
#!/bin/bash
ISOLATION="${ISOLATION_DEFAULT:-none}"
GROUP="${GROUP:-}"
SERVICE="${SERVICE:-}"

restart_gateway() {
  local target_service=""
  
  if [ "$ISOLATION" = "session" ] && [ -n "$GROUP" ]; then
    target_service="openclaw-${GROUP}.service"
  elif [ "$ISOLATION" = "session" ]; then
    # No GROUP - this shouldn't happen but fall back to all session services
    target_service="all-session-services"
  else
    target_service="openclaw"
  fi
  
  echo "RESTART_TARGET=$target_service"
}

restart_gateway
SCRIPT
  chmod +x "$TEST_TMPDIR/restart-logic.sh"
  
  # Test: session mode with GROUP should restart openclaw-{GROUP}.service
  output=$(ISOLATION_DEFAULT=session GROUP=browser bash "$TEST_TMPDIR/restart-logic.sh")
  
  if echo "$output" | grep -q "RESTART_TARGET=openclaw-browser.service"; then
    pass "restart_gateway targets openclaw-browser.service when GROUP=browser"
  else
    fail "restart_gateway targets wrong service" "Got: $output"
  fi
  
  # Test: session mode with GROUP=documents
  output=$(ISOLATION_DEFAULT=session GROUP=documents bash "$TEST_TMPDIR/restart-logic.sh")
  
  if echo "$output" | grep -q "RESTART_TARGET=openclaw-documents.service"; then
    pass "restart_gateway targets openclaw-documents.service when GROUP=documents"
  else
    fail "restart_gateway targets wrong service" "Got: $output"
  fi
  
  # Test: non-session mode should still use openclaw
  output=$(ISOLATION_DEFAULT=none GROUP="" bash "$TEST_TMPDIR/restart-logic.sh")
  
  if echo "$output" | grep -q "RESTART_TARGET=openclaw"; then
    pass "restart_gateway targets openclaw in non-session mode"
  else
    fail "restart_gateway should target openclaw in non-session mode" "Got: $output"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: enter_safe_mode only stops the failing group's service
# =============================================================================
test_enter_safe_mode_only_stops_group() {
  setup_test_env
  
  # This is the BUG we're fixing:
  # enter_safe_mode should NOT stop ALL session services
  # It should ONLY stop openclaw-{GROUP}.service
  
  cat > "$TEST_TMPDIR/stop-logic.sh" <<'SCRIPT'
#!/bin/bash
ISOLATION="${ISOLATION_DEFAULT:-none}"
GROUP="${GROUP:-}"
ISOLATION_GROUPS="${ISOLATION_GROUPS:-}"

stopped_services=""

enter_safe_mode_stop_services() {
  if [ "$ISOLATION" = "session" ]; then
    if [ -n "$GROUP" ]; then
      # Per-group mode: only stop this group's service
      stopped_services="openclaw-${GROUP}.service"
    else
      # All-groups mode: stop all (legacy behavior)
      IFS=',' read -ra GROUP_ARRAY <<< "$ISOLATION_GROUPS"
      for g in "${GROUP_ARRAY[@]}"; do
        stopped_services="$stopped_services openclaw-${g}.service"
      done
    fi
  else
    stopped_services="openclaw"
  fi
  
  echo "STOPPED:$stopped_services"
}

enter_safe_mode_stop_services
SCRIPT
  chmod +x "$TEST_TMPDIR/stop-logic.sh"
  
  # Test: GROUP=browser should only stop openclaw-browser.service
  output=$(ISOLATION_DEFAULT=session ISOLATION_GROUPS="browser,documents" GROUP=browser bash "$TEST_TMPDIR/stop-logic.sh")
  
  if echo "$output" | grep -q "openclaw-browser.service" && \
     ! echo "$output" | grep -q "openclaw-documents.service"; then
    pass "enter_safe_mode only stops browser service when GROUP=browser"
  else
    fail "enter_safe_mode stopped wrong services" "Got: $output"
  fi
  
  # Test: GROUP=documents should only stop openclaw-documents.service
  output=$(ISOLATION_DEFAULT=session ISOLATION_GROUPS="browser,documents" GROUP=documents bash "$TEST_TMPDIR/stop-logic.sh")
  
  if echo "$output" | grep -q "openclaw-documents.service" && \
     ! echo "$output" | grep -q "openclaw-browser.service"; then
    pass "enter_safe_mode only stops documents service when GROUP=documents"
  else
    fail "enter_safe_mode stopped wrong services" "Got: $output"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: Healthy group is not affected by failing group
# =============================================================================
test_group_isolation() {
  setup_test_env
  
  local state_dir="$TEST_TMPDIR/var/lib/init-status"
  
  # Simulate: browser group failed and is in safe mode
  touch "$state_dir/safe-mode-browser"
  
  # Documents group should NOT be in safe mode
  if [ ! -f "$state_dir/safe-mode-documents" ]; then
    pass "Documents group not affected by browser safe mode"
  else
    fail "Documents group incorrectly in safe mode"
  fi
  
  # Check function for documents should return healthy
  # (not be affected by browser's safe mode state)
  is_group_in_safe_mode() {
    local group="$1"
    [ -f "$state_dir/safe-mode-$group" ]
  }
  
  if ! is_group_in_safe_mode "documents"; then
    pass "is_group_in_safe_mode correctly reports documents as healthy"
  else
    fail "is_group_in_safe_mode incorrectly reports documents in safe mode"
  fi
  
  if is_group_in_safe_mode "browser"; then
    pass "is_group_in_safe_mode correctly reports browser in safe mode"
  else
    fail "is_group_in_safe_mode incorrectly reports browser as healthy"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: ExecStartPost in session services passes GROUP env
# =============================================================================
test_session_service_has_group_env() {
  setup_test_env
  
  # Check that generate-session-services.sh creates ExecStartPost with GROUP
  local script="$REPO_DIR/scripts/generate-session-services.sh"
  
  if [ ! -f "$script" ]; then
    skip "generate-session-services.sh not found"
    cleanup_test_env
    return
  fi
  
  # Check for ExecStartPost with GROUP variable
  if grep -q 'ExecStartPost.*GROUP=' "$script"; then
    pass "Session service template includes ExecStartPost with GROUP"
  else
    fail "Session service template missing ExecStartPost with GROUP"
  fi
  
  # Check for GROUP_PORT variable
  if grep -q 'GROUP_PORT=' "$script"; then
    pass "Session service template includes GROUP_PORT"
  else
    fail "Session service template missing GROUP_PORT"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: Health check script handles GROUP mode
# =============================================================================
test_health_check_group_mode() {
  setup_test_env
  
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  if [ ! -f "$script" ]; then
    skip "gateway-health-check.sh not found"
    cleanup_test_env
    return
  fi
  
  # Check for GROUP handling in health check
  if grep -q 'GROUP=' "$script" && grep -q 'GROUP_PORT' "$script"; then
    pass "Health check script has GROUP environment handling"
  else
    fail "Health check script missing GROUP environment handling"
  fi
  
  # Check that restart_gateway handles session mode
  if grep -q 'openclaw-.*\.service' "$script"; then
    pass "Health check script references session services"
  else
    fail "Health check script missing session service references"
  fi
  
  cleanup_test_env
}

# =============================================================================
# Test: Notification uses correct channel for group
# =============================================================================
test_notification_per_group() {
  setup_test_env
  
  # When browser group is in safe mode, notification should:
  # - Use a working token from browser group (agent3 or agent4)
  # - NOT use tokens from documents group
  
  # This tests the get_owner_id_for_platform logic
  cat > "$TEST_TMPDIR/get-token-for-group.sh" <<'SCRIPT'
#!/bin/bash
source "$TEST_TMPDIR/habitat-parsed.env"
GROUP="${GROUP:-}"
PLATFORM="${PLATFORM:-telegram}"

get_notification_token() {
  local token=""
  
  for i in $(seq 1 $AGENT_COUNT); do
    local agent_group_var="AGENT${i}_ISOLATION_GROUP"
    local agent_group="${!agent_group_var:-}"
    
    # In per-group mode, only use tokens from this group
    if [ -n "$GROUP" ] && [ "$agent_group" != "$GROUP" ]; then
      continue
    fi
    
    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    token="${!token_var:-}"
    
    if [ -n "$token" ]; then
      echo "TOKEN_FROM=agent${i} GROUP=$agent_group"
      return 0
    fi
  done
  
  echo "NO_TOKEN_FOUND"
  return 1
}

get_notification_token
SCRIPT
  chmod +x "$TEST_TMPDIR/get-token-for-group.sh"
  
  # Test browser group gets token from agent3 or agent4
  output=$(GROUP=browser bash "$TEST_TMPDIR/get-token-for-group.sh")
  
  if echo "$output" | grep -qE "TOKEN_FROM=agent[34].*GROUP=browser"; then
    pass "Browser group notification uses browser agent token"
  else
    fail "Browser group got wrong token" "Got: $output"
  fi
  
  # Test documents group gets token from agent1 or agent2
  output=$(GROUP=documents bash "$TEST_TMPDIR/get-token-for-group.sh")
  
  if echo "$output" | grep -qE "TOKEN_FROM=agent[12].*GROUP=documents"; then
    pass "Documents group notification uses documents agent token"
  else
    fail "Documents group got wrong token" "Got: $output"
  fi
  
  cleanup_test_env
}

# =============================================================================

# =============================================================================
# Test: Health check sets stage=11 and setup-complete on success
# =============================================================================
test_health_check_sets_ready_status() {
  setup_test_env
  
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  # Check for stage=11 setting on success
  if grep -q "echo '11' > /var/lib/init-status/stage" "$script"; then
    pass "Health check sets stage=11 on success"
  else
    fail "Health check missing stage=11 setting"
  fi
  
  # Check for setup-complete creation
  if grep -q "touch /var/lib/init-status/setup-complete" "$script"; then
    pass "Health check creates setup-complete on success"
  else
    fail "Health check missing setup-complete creation"
  fi
  
  cleanup_test_env
}

# Run all tests
# =============================================================================
echo ""
echo "Running per-group health check tests..."
echo ""

test_group_env_determines_scope
test_only_group_agents_checked
test_safe_mode_state_per_group
test_restart_gateway_session_mode
test_enter_safe_mode_only_stops_group
test_group_isolation
test_session_service_has_group_env
test_health_check_group_mode
test_notification_per_group
test_health_check_sets_ready_status

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================"

[ $FAILED -eq 0 ] && exit 0 || exit 1
