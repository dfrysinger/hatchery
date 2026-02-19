#!/bin/bash
# test-auth-headers.sh - Verify correct auth headers for different credential types
source "$(dirname "$0")/test-helpers.sh"
#
# Tests that:
# - Anthropic API keys (sk-ant-api*) use x-api-key header
# - Anthropic OAuth tokens (sk-ant-oat*) use Authorization: Bearer header
# - OpenAI always uses Authorization: Bearer header
# - Google API keys use ?key= query parameter
# - Google OAuth uses Authorization: Bearer header

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_PASSED=0
TEST_FAILED=0

# Colors



section() {
  echo ""
  echo -e "${YELLOW}=== $1 ===${NC}"
}

# =============================================================================
# Source actual auth functions from lib-auth.sh (not reimplementations)
# =============================================================================
source "$REPO_DIR/scripts/lib-auth.sh"

# OpenAI auth header (always Bearer) — not in lib-auth.sh yet, simple enough inline
get_openai_auth_header() {
  local key="$1"
  echo "Authorization: Bearer ${key}"
}

# Google auth method — not in lib-auth.sh yet
get_google_auth_method() {
  local key="$1"
  local is_oauth="${2:-false}"
  if [ "$is_oauth" = "true" ]; then
    echo "header:Authorization: Bearer ${key}"
  else
    echo "query:key=${key}"
  fi
}

# =============================================================================
# Anthropic Tests
# =============================================================================

section "Anthropic Auth Header Tests"

# Test 1: Anthropic API key (sk-ant-api03-...)
test_key="sk-ant-api03-abcdefghijklmnop"
expected="x-api-key: ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Anthropic API key (sk-ant-api03-*) uses x-api-key header"
else
  fail "Anthropic API key (sk-ant-api03-*) uses x-api-key header" "$expected" "$actual"
fi

# Test 2: Anthropic OAuth token (sk-ant-oat01-...)
test_key="sk-ant-oat01-abcdefghijklmnop"
expected="Authorization: Bearer ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Anthropic OAuth token (sk-ant-oat01-*) uses Bearer header"
else
  fail "Anthropic OAuth token (sk-ant-oat01-*) uses Bearer header" "$expected" "$actual"
fi

# Test 3: Anthropic OAuth token (sk-ant-oat02-... future version)
test_key="sk-ant-oat02-abcdefghijklmnop"
expected="Authorization: Bearer ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Anthropic OAuth token (sk-ant-oat02-*) uses Bearer header"
else
  fail "Anthropic OAuth token (sk-ant-oat02-*) uses Bearer header" "$expected" "$actual"
fi

# Test 4: Anthropic API key (sk-ant-api04-... future version)
test_key="sk-ant-api04-abcdefghijklmnop"
expected="x-api-key: ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Anthropic API key (sk-ant-api04-*) uses x-api-key header"
else
  fail "Anthropic API key (sk-ant-api04-*) uses x-api-key header" "$expected" "$actual"
fi

# Test 5: Unknown Anthropic key format defaults to x-api-key
test_key="sk-ant-unknown-abcdefghijklmnop"
expected="x-api-key: ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Unknown Anthropic key format defaults to x-api-key header"
else
  fail "Unknown Anthropic key format defaults to x-api-key header" "$expected" "$actual"
fi

# Test 6: Empty key still works (defensive)
test_key=""
expected="x-api-key: "
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Empty Anthropic key defaults to x-api-key header"
else
  fail "Empty Anthropic key defaults to x-api-key header" "$expected" "$actual"
fi

# =============================================================================
# OpenAI Tests
# =============================================================================

section "OpenAI Auth Header Tests"

# Test 7: OpenAI API key
test_key="sk-proj-abcdefghijklmnop"
expected="Authorization: Bearer ${test_key}"
actual=$(get_openai_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "OpenAI API key uses Bearer header"
else
  fail "OpenAI API key uses Bearer header" "$expected" "$actual"
fi

# Test 8: OpenAI OAuth token (same format)
test_key="ya29.a0AfH6SMBxxxxxxx"
expected="Authorization: Bearer ${test_key}"
actual=$(get_openai_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "OpenAI OAuth token uses Bearer header"
else
  fail "OpenAI OAuth token uses Bearer header" "$expected" "$actual"
fi

# =============================================================================
# Google Tests
# =============================================================================

section "Google Auth Method Tests"

# Test 9: Google API key uses query parameter
test_key="AIzaSyAbcdefghijklmnop"
expected="query:key=${test_key}"
actual=$(get_google_auth_method "$test_key" "false")
if [ "$actual" = "$expected" ]; then
  pass "Google API key uses query parameter"
else
  fail "Google API key uses query parameter" "$expected" "$actual"
fi

# Test 10: Google OAuth uses Bearer header
test_key="ya29.a0AfH6SMBxxxxxxx"
expected="header:Authorization: Bearer ${test_key}"
actual=$(get_google_auth_method "$test_key" "true")
if [ "$actual" = "$expected" ]; then
  pass "Google OAuth token uses Bearer header"
else
  fail "Google OAuth token uses Bearer header" "$expected" "$actual"
fi

# =============================================================================
# Integration Tests: Verify actual script logic
# =============================================================================

section "Integration Tests: gateway-health-check.sh"

# Source the actual script in a way that lets us test its functions
# We need to extract and test the actual bash patterns used

# Test 11: Verify the pattern in gateway-health-check.sh matches our logic
if grep -q 'if \[\[ "\${ANTHROPIC_API_KEY}" == sk-ant-oat\* \]\]' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null || \
   grep -q 'if \[\[ "$key" == sk-ant-oat\* \]\]' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null; then
  pass "gateway-health-check.sh contains OAuth token detection pattern"
else
  fail "gateway-health-check.sh contains OAuth token detection pattern" "pattern exists" "pattern not found"
fi

# Test 12: Verify safe-mode-recovery.sh has the pattern
if grep -q 'if \[\[ "$key" == sk-ant-oat\* \]\]' "$SCRIPT_DIR/../../scripts/safe-mode-recovery.sh" 2>/dev/null; then
  pass "safe-mode-recovery.sh contains OAuth token detection pattern"
else
  fail "safe-mode-recovery.sh contains OAuth token detection pattern" "pattern exists" "pattern not found"
fi

# Test 13: Verify x-api-key is used for non-OAuth Anthropic
if grep -q 'x-api-key:' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null; then
  pass "gateway-health-check.sh uses x-api-key for Anthropic API keys"
else
  fail "gateway-health-check.sh uses x-api-key for Anthropic API keys" "x-api-key found" "not found"
fi

# Test 14: Verify OpenAI always uses Bearer
openai_bearer_count=$(grep -c 'Authorization: Bearer.*OPENAI\|Authorization: Bearer.*cfg_openai\|Authorization: Bearer.*openai' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null || echo 0)
if [ "$openai_bearer_count" -ge 1 ]; then
  pass "gateway-health-check.sh uses Bearer for OpenAI ($openai_bearer_count occurrences)"
else
  fail "gateway-health-check.sh uses Bearer for OpenAI" "at least 1" "$openai_bearer_count"
fi

# Test 15: Verify Google uses query parameter for API key
if grep -q 'key=\${.*GOOGLE\|key=\${cfg_google' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null; then
  pass "gateway-health-check.sh uses query param for Google API key"
else
  fail "gateway-health-check.sh uses query param for Google API key" "?key= found" "not found"
fi

# Test 16: Verify no x-api-key used for OpenAI (it should always be Bearer)
if grep -q 'x-api-key.*OPENAI\|x-api-key.*openai' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null; then
  fail "gateway-health-check.sh should NOT use x-api-key for OpenAI" "no x-api-key" "x-api-key found"
else
  pass "gateway-health-check.sh does NOT use x-api-key for OpenAI"
fi

# Test 17: Verify no x-api-key used for Google (it should be query param or Bearer)
if grep -q 'x-api-key.*GOOGLE\|x-api-key.*google' "$SCRIPT_DIR/../../scripts/gateway-health-check.sh" 2>/dev/null; then
  fail "gateway-health-check.sh should NOT use x-api-key for Google" "no x-api-key" "x-api-key found"
else
  pass "gateway-health-check.sh does NOT use x-api-key for Google"
fi

# =============================================================================
# Integration Tests: safe-mode-recovery.sh
# =============================================================================

section "Integration Tests: safe-mode-recovery.sh"

# Test 18: Verify OpenAI uses Bearer in recovery script
if grep -q 'Authorization: Bearer.*key.*openai\|openai.*Bearer' "$SCRIPT_DIR/../../scripts/safe-mode-recovery.sh" 2>/dev/null; then
  pass "safe-mode-recovery.sh uses Bearer for OpenAI"
else
  # Check the case statement
  if grep -A3 'openai)' "$SCRIPT_DIR/../../scripts/safe-mode-recovery.sh" | grep -q 'Authorization: Bearer'; then
    pass "safe-mode-recovery.sh uses Bearer for OpenAI (in case statement)"
  else
    fail "safe-mode-recovery.sh uses Bearer for OpenAI" "Bearer found" "not found"
  fi
fi

# Test 19: Verify Google uses query param in recovery script
if grep -A3 'google)' "$SCRIPT_DIR/../../scripts/safe-mode-recovery.sh" | grep -q 'key=\${key}'; then
  pass "safe-mode-recovery.sh uses query param for Google API key"
else
  fail "safe-mode-recovery.sh uses query param for Google API key" "?key= found" "not found"
fi

# Test 20: Verify test_oauth_token uses Bearer for all providers
oauth_bearer_count=$(grep -A5 'test_oauth_token()' "$SCRIPT_DIR/../../scripts/safe-mode-recovery.sh" -A50 | grep -c 'Authorization: Bearer' || echo 0)
if [ "$oauth_bearer_count" -ge 3 ]; then
  pass "safe-mode-recovery.sh test_oauth_token uses Bearer for all providers ($oauth_bearer_count occurrences)"
else
  fail "safe-mode-recovery.sh test_oauth_token uses Bearer for all providers" "at least 3" "$oauth_bearer_count"
fi

# =============================================================================
# Edge Cases
# =============================================================================

section "Edge Case Tests"

# Test 21: Anthropic key with extra characters after prefix
test_key="sk-ant-oat01-with-many-extra-chars-1234567890abcdef"
expected="Authorization: Bearer ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Long Anthropic OAuth token uses Bearer header"
else
  fail "Long Anthropic OAuth token uses Bearer header" "$expected" "$actual"
fi

# Test 22: Anthropic key that looks like OAuth but isn't exactly
test_key="sk-ant-oat-no-version"
expected="Authorization: Bearer ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Anthropic key starting with sk-ant-oat (no version) uses Bearer"
else
  fail "Anthropic key starting with sk-ant-oat (no version) uses Bearer" "$expected" "$actual"
fi

# Test 23: Anthropic key with api in wrong position
test_key="sk-api-ant-03-abcdef"
expected="x-api-key: ${test_key}"
actual=$(get_anthropic_auth_header "$test_key")
if [ "$actual" = "$expected" ]; then
  pass "Malformed key (sk-api-ant-*) defaults to x-api-key"
else
  fail "Malformed key (sk-api-ant-*) defaults to x-api-key" "$expected" "$actual"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo -e "Test Results: ${GREEN}${TEST_PASSED} passed${NC}, ${RED}${TEST_FAILED} failed${NC}"
echo "=============================================="

if [ $TEST_FAILED -gt 0 ]; then
  exit 1
else
  exit 0
fi
