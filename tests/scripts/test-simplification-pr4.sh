#!/bin/bash
# =============================================================================
# test-simplification-pr4.sh -- PR 4: lib-auth.sh + slim safe-mode-recovery.sh
# =============================================================================
# TDD tests for shared auth library and recovery script reduction.
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

LIB_AUTH="$REPO_DIR/scripts/lib-auth.sh"
RECOVERY="$REPO_DIR/scripts/safe-mode-recovery.sh"
E2E_CHECK="$REPO_DIR/scripts/gateway-e2e-check.sh"
SM_HANDLER="$REPO_DIR/scripts/safe-mode-handler.sh"

# =============================================================================
echo ""
echo "=== PR4: lib-auth.sh exists ==="
# =============================================================================

if [ -f "$LIB_AUTH" ]; then
  pass "lib-auth.sh exists"
else
  fail "lib-auth.sh does not exist"
  echo ""
  echo "=== Summary ==="
  echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
  exit $FAILED
fi

# =============================================================================
echo ""
echo "=== PR4: lib-auth.sh exports required functions ==="
# =============================================================================

# Source in subshell and check each function
(
  # Mock dependencies
  log() { :; }
  export HC_LOG="/dev/null"
  export HC_RUN_ID="test"
  d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
  
  source "$LIB_AUTH" 2>/dev/null
  
  for fn in validate_telegram_token validate_discord_token validate_api_key \
            get_auth_header find_working_telegram_token find_working_discord_token \
            find_working_platform_token find_working_api_provider \
            get_provider_from_model get_provider_order; do
    if type "$fn" &>/dev/null; then
      echo "PASS: $fn defined"
    else
      echo "FAIL: $fn not defined in lib-auth.sh"
    fi
  done
  
) > /tmp/test-lib-auth-functions.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-lib-auth-functions.txt

# =============================================================================
echo ""
echo "=== PR4: get_auth_header returns correct headers ==="
# =============================================================================

(
  log() { :; }
  d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
  source "$LIB_AUTH" 2>/dev/null
  
  # Anthropic OAuth token → Authorization: Bearer
  header=$(get_auth_header "anthropic" "sk-ant-oat01-test-token")
  if echo "$header" | grep -q "Authorization: Bearer sk-ant-oat01-test-token"; then
    echo "PASS: OAuth token gets Bearer header"
  else
    echo "FAIL: OAuth header='$header'"
  fi
  
  # Anthropic API key → x-api-key
  header=$(get_auth_header "anthropic" "sk-ant-api03-test-key")
  if echo "$header" | grep -q "x-api-key: sk-ant-api03-test-key"; then
    echo "PASS: Anthropic API key gets x-api-key header"
  else
    echo "FAIL: Anthropic key header='$header'"
  fi
  
  # OpenAI → Authorization: Bearer
  header=$(get_auth_header "openai" "sk-openai-test")
  if echo "$header" | grep -q "Authorization: Bearer sk-openai-test"; then
    echo "PASS: OpenAI gets Bearer header"
  else
    echo "FAIL: OpenAI header='$header'"
  fi
  
  # Google → x-goog-api-key
  header=$(get_auth_header "google" "AIza-google-test")
  if echo "$header" | grep -q "x-goog-api-key: AIza-google-test"; then
    echo "PASS: Google gets x-goog-api-key header"
  else
    echo "FAIL: Google header='$header'"
  fi
  
) > /tmp/test-lib-auth-headers.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-lib-auth-headers.txt

# =============================================================================
echo ""
echo "=== PR4: get_provider_from_model extracts provider ==="
# =============================================================================

(
  log() { :; }
  d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
  source "$LIB_AUTH" 2>/dev/null
  
  result=$(get_provider_from_model "anthropic/claude-opus-4-5")
  [ "$result" = "anthropic" ] && echo "PASS: anthropic extracted" || echo "FAIL: got '$result'"
  
  result=$(get_provider_from_model "openai/gpt-5.2")
  [ "$result" = "openai" ] && echo "PASS: openai extracted" || echo "FAIL: got '$result'"
  
  result=$(get_provider_from_model "google/gemini-2.5-pro")
  [ "$result" = "google" ] && echo "PASS: google extracted" || echo "FAIL: got '$result'"
  
) > /tmp/test-lib-auth-provider.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-lib-auth-provider.txt

# =============================================================================
echo ""
echo "=== PR4: OAuth tokens trusted without API call ==="
# =============================================================================

(
  log() { :; }
  d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
  source "$LIB_AUTH" 2>/dev/null
  
  # validate_api_key should return 0 for OAuth tokens without making an API call
  # (since we can't validate them via API)
  if validate_api_key "anthropic" "sk-ant-oat01-real-oauth-token" 2>/dev/null; then
    echo "PASS: OAuth token trusted"
  else
    echo "FAIL: OAuth token rejected"
  fi
  
) > /tmp/test-lib-auth-oauth.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-lib-auth-oauth.txt

# =============================================================================
echo ""
echo "=== PR4: safe-mode-recovery.sh line count ==="
# =============================================================================

if [ -f "$RECOVERY" ]; then
  lines=$(wc -l < "$RECOVERY")
  if [ "$lines" -le 600 ]; then
    pass "safe-mode-recovery.sh is $lines lines (≤600)"
  else
    fail "safe-mode-recovery.sh is $lines lines (should be ≤600 after lib-auth.sh extraction)"
  fi
else
  fail "safe-mode-recovery.sh not found"
fi

# =============================================================================
echo ""
echo "=== PR4: safe-mode-recovery.sh sources lib-auth.sh ==="
# =============================================================================

if grep -q 'source.*lib-auth.sh\|\..*lib-auth.sh' "$RECOVERY"; then
  pass "safe-mode-recovery.sh sources lib-auth.sh"
else
  fail "safe-mode-recovery.sh should source lib-auth.sh"
fi

# No duplicated validation functions in recovery
for fn in validate_telegram_token_direct validate_discord_token_direct; do
  if grep -q "^${fn}()\|^  ${fn}()" "$RECOVERY"; then
    fail "safe-mode-recovery.sh still defines $fn (should use lib-auth.sh)"
  else
    pass "safe-mode-recovery.sh does not duplicate $fn"
  fi
done

# No generate_emergency_config function (moved to generate-config.sh)
if grep -q 'generate_emergency_config()' "$RECOVERY"; then
  fail "safe-mode-recovery.sh still has generate_emergency_config() — moved to generate-config.sh"
else
  pass "generate_emergency_config removed from recovery"
fi

# =============================================================================
echo ""
echo "=== PR4: gateway-e2e-check.sh uses lib-auth.sh ==="
# =============================================================================

if grep -q 'source.*lib-auth.sh\|\..*lib-auth.sh' "$E2E_CHECK"; then
  pass "gateway-e2e-check.sh sources lib-auth.sh"
else
  fail "gateway-e2e-check.sh should source lib-auth.sh"
fi

# =============================================================================
echo ""
echo "=== PR4: safe-mode-handler.sh has no local_* at top scope ==="
# =============================================================================

if [ -f "$SM_HANDLER" ]; then
  # Check for local_* vars outside of functions
  # Simple heuristic: local_* assignments not indented (top-level)
  bad_locals=$(grep -n '^local_' "$SM_HANDLER" || true)
  if [ -z "$bad_locals" ]; then
    pass "No local_* variables at top scope in safe-mode-handler.sh"
  else
    fail "safe-mode-handler.sh has local_* at top scope: $(echo "$bad_locals" | head -3)"
  fi
else
  fail "safe-mode-handler.sh not found"
fi

# =============================================================================
echo ""
echo "=== PR4: No duplicate auth functions across scripts ==="
# =============================================================================

# get_auth_header / get_anthropic_auth_header should only be in lib-auth.sh
for fn_pattern in "get_anthropic_auth_header\|get_auth_header_for_provider\|get_auth_header"; do
  found_in=$(grep -rl "${fn_pattern}()" "$REPO_DIR/scripts/" \
    | grep -v 'lib-auth.sh' \
    | grep -v 'phase1-critical.sh' \
    | grep -v 'phase2-background.sh' \
    || true)
  
  if [ -z "$found_in" ]; then
    pass "Auth header function only defined in lib-auth.sh"
  else
    for f in $found_in; do
      fail "$(basename "$f") defines auth header function — should use lib-auth.sh"
    done
  fi
done

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
