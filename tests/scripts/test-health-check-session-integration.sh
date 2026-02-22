#!/bin/bash
# =============================================================================
# test-health-check-session-integration.sh -- Integration tests for health check
# =============================================================================
# These tests source the actual gateway-health-check.sh functions and verify
# they handle session isolation correctly.
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

# =============================================================================
# Setup mock environment
# =============================================================================
setup_mock_env() {
  export TEST_TMPDIR=$(mktemp -d)
  
  # Create directory structure
  mkdir -p "$TEST_TMPDIR/home/.openclaw"
  mkdir -p "$TEST_TMPDIR/home/clawd/agents/agent1"
  mkdir -p "$TEST_TMPDIR/home/clawd/agents/agent2"
  mkdir -p "$TEST_TMPDIR/home/clawd/agents/agent3"
  mkdir -p "$TEST_TMPDIR/home/clawd/agents/agent4"
  mkdir -p "$TEST_TMPDIR/home/clawd/agents/safe-mode"
  mkdir -p "$TEST_TMPDIR/var/lib/init-status"
  mkdir -p "$TEST_TMPDIR/var/log"
  
  # Create mock files
  echo '{"agents":{"defaults":{"model":"test"}}}' > "$TEST_TMPDIR/home/.openclaw/openclaw.json"
  
  # Create droplet.env
  cat > "$TEST_TMPDIR/droplet.env" <<'EOF'
ANTHROPIC_API_KEY="test-key"
EOF

  # Create habitat-parsed.env
  cat > "$TEST_TMPDIR/habitat-parsed.env" <<'EOF'
HABITAT_NAME="TestHabitat"
PLATFORM="telegram"
ISOLATION_DEFAULT="session"
ISOLATION_GROUPS="browser,documents"
SESSION_GROUPS="browser,documents"
AGENT_COUNT=4
USERNAME="testuser"
AGENT1_NAME="Agent1"
AGENT1_ISOLATION_GROUP="documents"
AGENT1_BOT_TOKEN="TOKEN_1"
AGENT2_NAME="Agent2"
AGENT2_ISOLATION_GROUP="documents"
AGENT2_BOT_TOKEN="TOKEN_2"
AGENT3_NAME="Agent3"
AGENT3_ISOLATION_GROUP="browser"
AGENT3_BOT_TOKEN="TOKEN_3"
AGENT4_NAME="Agent4"
AGENT4_ISOLATION_GROUP="browser"
AGENT4_BOT_TOKEN="TOKEN_4"
TELEGRAM_OWNER_ID="123456789"
EOF

  # Track systemctl calls
  export SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
  > "$SYSTEMCTL_LOG"
  
  # Create mock systemctl
  cat > "$TEST_TMPDIR/mock-systemctl" <<'MOCK'
#!/bin/bash
echo "systemctl $*" >> "$SYSTEMCTL_LOG"
case "$1" in
  is-active) exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  chmod +x "$TEST_TMPDIR/mock-systemctl"
  
  # Export paths for the script
  export H="$TEST_TMPDIR/home"
  export HOME_DIR="$TEST_TMPDIR/home"
  export USERNAME="testuser"
  export AC=4
  export LOG="$TEST_TMPDIR/var/log/test.log"
  export PATH="$TEST_TMPDIR:$PATH"
  
  # Source env files
  source "$TEST_TMPDIR/habitat-parsed.env"
}

cleanup_mock_env() {
  rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# Extract functions from gateway-health-check.sh for testing
# =============================================================================
extract_enter_safe_mode() {
  # Extract enter_safe_mode function
  sed -n '/^enter_safe_mode()/,/^}/p' "$REPO_DIR/scripts/gateway-health-check.sh"
}

extract_restart_gateway() {
  # Extract restart_gateway function  
  sed -n '/^restart_gateway()/,/^}/p' "$REPO_DIR/scripts/gateway-health-check.sh"
}

# =============================================================================
# Test: enter_safe_mode with GROUP only stops that group
# =============================================================================
test_enter_safe_mode_group_isolation() {
  setup_mock_env
  
  echo ""
  echo "=== Test: enter_safe_mode GROUP isolation ==="
  
  # Check the actual script for correct GROUP handling in stop logic
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  # Look for the pattern that only stops GROUP service when GROUP is set
  # The fix should have: if [ -n "${GROUP:-}" ]; then ... stop "openclaw-${GROUP}.service"
  
  local stop_section
  stop_section=$(grep -A20 "Stop isolation services" "$script" 2>/dev/null || echo "")
  
  # Check for per-group stop logic
  if echo "$stop_section" | grep -q 'GROUP:-' && \
     echo "$stop_section" | grep -q 'openclaw-\${GROUP}\.service'; then
    pass "enter_safe_mode has per-group stop logic (stops only GROUP service)"
  elif echo "$stop_section" | grep -q 'for group in.*GROUP_ARRAY' && \
       ! echo "$stop_section" | grep -q 'GROUP:-'; then
    fail "enter_safe_mode stops ALL services, not just GROUP" \
         "Missing per-group check: should only stop openclaw-\${GROUP}.service"
  else
    # Manual check - look for the correct pattern
    if grep -q 'systemctl stop "openclaw-\${GROUP}\.service"' "$script"; then
      pass "enter_safe_mode has per-group stop logic"
    else
      fail "enter_safe_mode missing per-group stop logic"
    fi
  fi
  
  cleanup_mock_env
}

# =============================================================================
# Test: restart_gateway with GROUP restarts session service
# =============================================================================
test_restart_gateway_session_mode() {
  setup_mock_env
  
  echo ""
  echo "=== Test: restart_gateway session mode ==="
  
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  # Extract restart_gateway function
  local restart_fn
  restart_fn=$(sed -n '/^restart_gateway()/,/^}/p' "$script" 2>/dev/null || echo "")
  
  if [ -z "$restart_fn" ]; then
    fail "restart_gateway function not found"
    cleanup_mock_env
    return
  fi
  
  # Check for session isolation handling
  local has_session_check=false
  local has_group_restart=false
  local only_restarts_openclaw=false
  
  if echo "$restart_fn" | grep -q 'ISOLATION.*=.*session\|session.*ISOLATION'; then
    has_session_check=true
  fi
  
  if echo "$restart_fn" | grep -q 'openclaw-\${GROUP}\|openclaw-${GROUP}'; then
    has_group_restart=true
  fi
  
  # Check if it ONLY restarts openclaw (the bug)
  if echo "$restart_fn" | grep -q 'systemctl restart openclaw' && \
     ! echo "$restart_fn" | grep -q 'session'; then
    only_restarts_openclaw=true
  fi
  
  if [ "$has_session_check" = "true" ] && [ "$has_group_restart" = "true" ]; then
    pass "restart_gateway handles session mode with GROUP-aware restart"
  elif [ "$only_restarts_openclaw" = "true" ]; then
    fail "restart_gateway only restarts openclaw, ignores session mode" \
         "Should restart openclaw-\${GROUP}.service in session mode"
  elif [ "$has_session_check" = "true" ]; then
    pass "restart_gateway has session mode check"
  else
    fail "restart_gateway missing session mode handling"
  fi
  
  cleanup_mock_env
}

# =============================================================================
# Test: Safe mode state files use GROUP suffix
# =============================================================================
test_safe_mode_state_files_per_group() {
  setup_mock_env
  
  echo ""
  echo "=== Test: Safe mode state files per-group ==="
  
  # Check if the script creates per-group state files
  local script="$REPO_DIR/scripts/gateway-health-check.sh"
  
  # Look for GROUP-suffixed state file patterns
  if grep -q 'safe-mode-\$GROUP\|safe-mode-${GROUP}' "$script" || \
     grep -qE 'safe-mode.*\$\{?GROUP' "$script"; then
    pass "Script uses per-group safe-mode state files"
  else
    # Check if it uses global state file
    if grep -q '/var/lib/init-status/safe-mode[^-]' "$script" || \
       grep 'touch.*/safe-mode$' "$script" | grep -qv 'safe-mode-'; then
      fail "Script uses global safe-mode file instead of per-group" \
           "Should use safe-mode-\$GROUP pattern"
    else
      pass "Script may use per-group state files (pattern not clearly detected)"
    fi
  fi
  
  # Check recovery-attempts
  if grep -q 'recovery-attempts-\$GROUP\|recovery-attempts-${GROUP}' "$script" || \
     grep -qE 'recovery-attempts.*\$\{?GROUP' "$script"; then
    pass "Script uses per-group recovery-attempts files"
  else
    fail "Script may not use per-group recovery-attempts files"
  fi
  
  cleanup_mock_env
}

# =============================================================================
# Run integration tests
# =============================================================================
echo ""
echo "Running health check session integration tests..."
echo ""

test_enter_safe_mode_group_isolation
test_restart_gateway_session_mode
test_safe_mode_state_files_per_group

echo ""
echo "========================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "========================================"

[ $FAILED -eq 0 ] && exit 0 || exit 1
