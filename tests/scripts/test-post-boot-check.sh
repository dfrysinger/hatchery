#!/bin/bash
# =============================================================================
# test-post-boot-check.sh -- Unit tests for post-boot-check.sh logic
# =============================================================================
# Tests variable handling and GROUPS collision fix
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

pass() {
  echo -e "${GREEN}✓${NC} $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

# =============================================================================
# Test: Bash GROUPS variable collision
# =============================================================================
echo ""
echo "=== Test: GROUPS variable collision ==="

# In bash, GROUPS is a built-in array. Setting GROUPS= should not work.
# But SESSION_GROUPS should work fine.

GROUPS="test-group"
if [ "$GROUPS" = "test-group" ]; then
  fail "GROUPS variable was set (should be bash built-in)"
else
  pass "GROUPS is bash built-in, cannot be set as string"
fi

SESSION_GROUPS="test-group"
if [ "$SESSION_GROUPS" = "test-group" ]; then
  pass "SESSION_GROUPS can be set correctly"
else
  fail "SESSION_GROUPS should be settable"
fi

# =============================================================================
# Test: Sourcing habitat-parsed.env with ISOLATION_GROUPS
# =============================================================================
echo ""
echo "=== Test: ISOLATION_GROUPS from env file ==="

TMPENV=$(mktemp)
cat > "$TMPENV" <<'EOF'
HABITAT_NAME="TestHabitat"
ISOLATION_DEFAULT="session"
ISOLATION_GROUPS="browser,documents"
AGENT_COUNT=2
EOF

# Unset any existing vars
unset HABITAT_NAME ISOLATION_DEFAULT ISOLATION_GROUPS AGENT_COUNT 2>/dev/null || true

source "$TMPENV"

if [ "$ISOLATION_GROUPS" = "browser,documents" ]; then
  pass "ISOLATION_GROUPS sourced correctly from env file"
else
  fail "ISOLATION_GROUPS should be 'browser,documents', got '${ISOLATION_GROUPS:-unset}'"
fi

if [ "$ISOLATION_DEFAULT" = "session" ]; then
  pass "ISOLATION_DEFAULT sourced correctly"
else
  fail "ISOLATION_DEFAULT should be 'session'"
fi

rm -f "$TMPENV"

# =============================================================================
# Test: Parsing ISOLATION_GROUPS into array
# =============================================================================
echo ""
echo "=== Test: Parsing groups into array ==="

SESSION_GROUPS="browser,documents,special"
IFS=',' read -ra GROUP_ARRAY <<< "$SESSION_GROUPS"

if [ "${#GROUP_ARRAY[@]}" = "3" ]; then
  pass "Parsed 3 groups from SESSION_GROUPS"
else
  fail "Should have parsed 3 groups, got ${#GROUP_ARRAY[@]}"
fi

if [ "${GROUP_ARRAY[0]}" = "browser" ]; then
  pass "First group is 'browser'"
else
  fail "First group should be 'browser'"
fi

if [ "${GROUP_ARRAY[1]}" = "documents" ]; then
  pass "Second group is 'documents'"
else
  fail "Second group should be 'documents'"
fi

if [ "${GROUP_ARRAY[2]}" = "special" ]; then
  pass "Third group is 'special'"
else
  fail "Third group should be 'special'"
fi

# =============================================================================
# Test: Port calculation
# =============================================================================
echo ""
echo "=== Test: Port calculation ==="

BASE_PORT=18790
group_index=0
for group in "${GROUP_ARRAY[@]}"; do
  port=$((BASE_PORT + group_index))
  case $group_index in
    0) 
      if [ "$port" = "18790" ]; then
        pass "Port for group 0: 18790"
      else
        fail "Port for group 0 should be 18790"
      fi
      ;;
    1)
      if [ "$port" = "18791" ]; then
        pass "Port for group 1: 18791"
      else
        fail "Port for group 1 should be 18791"
      fi
      ;;
    2)
      if [ "$port" = "18792" ]; then
        pass "Port for group 2: 18792"
      else
        fail "Port for group 2 should be 18792"
      fi
      ;;
  esac
  group_index=$((group_index + 1))
done

# =============================================================================
# Test: Mode detection
# =============================================================================
echo ""
echo "=== Test: Isolation mode detection ==="

# Test session mode
ISOLATION="session"
SESSION_GROUPS="group-a,group-b"

if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  pass "Correctly detected session isolation mode"
else
  fail "Should detect session isolation mode"
fi

# Test no isolation
ISOLATION="none"
SESSION_GROUPS=""

if [ "$ISOLATION" = "session" ] && [ -n "$SESSION_GROUPS" ]; then
  fail "Should NOT detect session mode when isolation=none"
else
  pass "Correctly skipped session mode when isolation=none"
fi

# Test container mode
ISOLATION="container"
SESSION_GROUPS=""

if [ "$ISOLATION" = "container" ]; then
  pass "Correctly detected container isolation mode"
else
  fail "Should detect container isolation mode"
fi

# =============================================================================
# Test: Channel connectivity check function (Telegram + Discord + generic)
# =============================================================================
echo ""
echo "=== Test: Channel connectivity check ==="

# Create mock log directory and file
MOCK_LOG_DIR=$(mktemp -d)
MOCK_DATE=$(date +%Y-%m-%d)
MOCK_LOG="$MOCK_LOG_DIR/openclaw-${MOCK_DATE}.log"

# Platform-agnostic connectivity check (mirrors post-boot-check.sh)
check_channel_connectivity_mock() {
  local service="$1"
  local openclaw_log="$2"
  
  # Same patterns as post-boot-check.sh
  local ERROR_PATTERNS="(getMe.*failed|telegram.*error|telegram.*failed|404.*Not Found|disallowed intents|Invalid.*token|discord.*error|discord.*failed|Unauthorized|channel.*failed|connection.*refused)"
  
  if [ -f "$openclaw_log" ]; then
    local log_errors
    log_errors=$(grep -iE "$ERROR_PATTERNS" "$openclaw_log" 2>/dev/null | head -5)
    
    if [ -n "$log_errors" ]; then
      return 1
    fi
  fi
  
  return 0
}

# Test 1: No errors in log - should pass
echo "Clean startup, waiting for messages..." > "$MOCK_LOG"
echo "Telegram: connected successfully" >> "$MOCK_LOG"

if check_channel_connectivity_mock "test-service" "$MOCK_LOG"; then
  pass "channel_check: passes when no errors in log"
else
  fail "channel_check: should pass when log has no errors"
fi

# Test 2: Telegram getMe error - should fail
echo "2025-01-01 Call to 'getMe' failed! (404: Not Found)" >> "$MOCK_LOG"

if check_channel_connectivity_mock "test-service" "$MOCK_LOG"; then
  fail "channel_check: should fail on Telegram getMe error"
else
  pass "channel_check: correctly detects Telegram getMe failure"
fi

# Test 3: Generic Telegram error - should fail
MOCK_LOG2="$MOCK_LOG_DIR/openclaw-${MOCK_DATE}-2.log"
echo "Starting up..." > "$MOCK_LOG2"
echo "telegram error: connection refused" >> "$MOCK_LOG2"

if check_channel_connectivity_mock "test-service" "$MOCK_LOG2"; then
  fail "channel_check: should fail on Telegram error"
else
  pass "channel_check: correctly detects generic Telegram error"
fi

# Test 4: Discord disallowed intents - should fail
MOCK_LOG3="$MOCK_LOG_DIR/openclaw-${MOCK_DATE}-3.log"
echo "Starting up..." > "$MOCK_LOG3"
echo "Used disallowed intents" >> "$MOCK_LOG3"

if check_channel_connectivity_mock "test-service" "$MOCK_LOG3"; then
  fail "channel_check: should fail on Discord disallowed intents"
else
  pass "channel_check: correctly detects Discord disallowed intents"
fi

# Test 5: Discord invalid token - should fail
MOCK_LOG4="$MOCK_LOG_DIR/openclaw-${MOCK_DATE}-4.log"
echo "Starting up..." > "$MOCK_LOG4"
echo "Error: Invalid token provided" >> "$MOCK_LOG4"

if check_channel_connectivity_mock "test-service" "$MOCK_LOG4"; then
  fail "channel_check: should fail on Discord invalid token"
else
  pass "channel_check: correctly detects Discord invalid token"
fi

# Test 6: Discord error - should fail
MOCK_LOG5="$MOCK_LOG_DIR/openclaw-${MOCK_DATE}-5.log"
echo "Starting up..." > "$MOCK_LOG5"
echo "discord error: gateway connection failed" >> "$MOCK_LOG5"

if check_channel_connectivity_mock "test-service" "$MOCK_LOG5"; then
  fail "channel_check: should fail on Discord error"
else
  pass "channel_check: correctly detects Discord gateway error"
fi

# Cleanup
rm -rf "$MOCK_LOG_DIR"

# =============================================================================
# Test: API key validation check function
# =============================================================================
echo ""
echo "=== Test: API key validation check ==="

# Create mock log directory for API tests
API_MOCK_LOG_DIR=$(mktemp -d)
API_MOCK_DATE=$(date +%Y-%m-%d)

# Mock API key validation function (mirrors post-boot-check.sh)
check_api_key_validity_mock() {
  local service="$1"
  local openclaw_log="$2"
  
  # Same patterns as post-boot-check.sh
  local AUTH_ERROR_PATTERNS="(authentication_error|Invalid.*bearer.*token|401|invalid.*api.*key|api.*key.*invalid)"
  
  if [ -f "$openclaw_log" ]; then
    local auth_errors
    auth_errors=$(grep -iE "$AUTH_ERROR_PATTERNS" "$openclaw_log" 2>/dev/null | head -5)
    
    if [ -n "$auth_errors" ]; then
      return 1
    fi
  fi
  
  return 0
}

# Test 1: No errors - should pass
API_MOCK_LOG1="$API_MOCK_LOG_DIR/openclaw-${API_MOCK_DATE}-1.log"
echo "Starting up..." > "$API_MOCK_LOG1"
echo "All systems normal" >> "$API_MOCK_LOG1"

if check_api_key_validity_mock "test-service" "$API_MOCK_LOG1"; then
  pass "api_key_check: passes when no auth errors in log"
else
  fail "api_key_check: should pass when no errors"
fi

# Test 2: Anthropic authentication_error - should fail
API_MOCK_LOG2="$API_MOCK_LOG_DIR/openclaw-${API_MOCK_DATE}-2.log"
echo "Starting up..." > "$API_MOCK_LOG2"
echo "HTTP 401: authentication_error: Invalid bearer token" >> "$API_MOCK_LOG2"

if check_api_key_validity_mock "test-service" "$API_MOCK_LOG2"; then
  fail "api_key_check: should fail on authentication_error"
else
  pass "api_key_check: correctly detects authentication_error"
fi

# Test 3: Invalid API key - should fail
API_MOCK_LOG3="$API_MOCK_LOG_DIR/openclaw-${API_MOCK_DATE}-3.log"
echo "Starting up..." > "$API_MOCK_LOG3"
echo "Error: Invalid API key provided" >> "$API_MOCK_LOG3"

if check_api_key_validity_mock "test-service" "$API_MOCK_LOG3"; then
  fail "api_key_check: should fail on invalid API key"
else
  pass "api_key_check: correctly detects invalid API key"
fi

# Test 4: HTTP 401 - should fail
API_MOCK_LOG4="$API_MOCK_LOG_DIR/openclaw-${API_MOCK_DATE}-4.log"
echo "Starting up..." > "$API_MOCK_LOG4"
echo "Request failed with status 401" >> "$API_MOCK_LOG4"

if check_api_key_validity_mock "test-service" "$API_MOCK_LOG4"; then
  fail "api_key_check: should fail on 401 status"
else
  pass "api_key_check: correctly detects 401 status"
fi

# Cleanup API test logs
rm -rf "$API_MOCK_LOG_DIR"

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
