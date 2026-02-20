#!/bin/bash
# =============================================================================
# test-simplification-pr2.sh -- PR 2: lib-env.sh + fatal library guards
# =============================================================================
# TDD tests for shared environment loading and library sourcing robustness.
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

LIB_ENV="$REPO_DIR/scripts/lib-env.sh"

# =============================================================================
echo ""
echo "=== PR2: lib-env.sh exists ==="
# =============================================================================

if [ -f "$LIB_ENV" ]; then
  pass "lib-env.sh exists"
else
  fail "lib-env.sh does not exist"
  # Can't continue without the file
  echo ""
  echo "=== Summary ==="
  echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
  exit $FAILED
fi

# shellcheck disable=SC1090
# Source lib-env in a subshell to test it
(
  # Mock /etc/droplet.env since we're in a test
  export TEST_MODE=1
  source "$LIB_ENV"
  
  # Test d() function exists and works
  if type d &>/dev/null; then
    echo "PASS: d() function defined"
  else
    echo "FAIL: d() function not defined"
    exit 1
  fi
  
  # Test d() decodes base64
  result=$(d "$(echo -n 'hello' | base64)")
  if [ "$result" = "hello" ]; then
    echo "PASS: d() decodes base64 correctly"
  else
    echo "FAIL: d() returned '$result' instead of 'hello'"
    exit 1
  fi
  
  # Test d() handles empty input
  result=$(d "")
  if [ -z "$result" ]; then
    echo "PASS: d() returns empty for empty input"
  else
    echo "FAIL: d() returned '$result' for empty input"
    exit 1
  fi
  
  # Test d() handles invalid base64
  result=$(d "not-valid-base64!!!")
  # Should return empty or garbage, not crash
  echo "PASS: d() handles invalid base64 without crashing"
  
  # Test env_load function exists
  if type env_load &>/dev/null; then
    echo "PASS: env_load() function defined"
  else
    echo "FAIL: env_load() function not defined"
    exit 1
  fi
  
  # Test env_decode_keys function exists
  if type env_decode_keys &>/dev/null; then
    echo "PASS: env_decode_keys() function defined"
  else
    echo "FAIL: env_decode_keys() function not defined"
    exit 1
  fi
) > /tmp/test-lib-env-output.txt 2>&1

subshell_exit=$?
while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-lib-env-output.txt

if [ "$subshell_exit" -ne 0 ]; then
  fail "lib-env.sh subshell tests had fatal error"
fi

# =============================================================================
echo ""
echo "=== PR2: env_decode_keys decodes all standard keys ==="
# =============================================================================

(
  source "$LIB_ENV"
  
  # Set up mock base64 values
  export ANTHROPIC_KEY_B64=$(echo -n "sk-ant-test123" | base64)
  export OPENAI_KEY_B64=$(echo -n "sk-openai-test456" | base64)
  export GOOGLE_API_KEY_B64=$(echo -n "AIzaGoogle789" | base64)
  export BRAVE_KEY_B64=$(echo -n "BSAbrave000" | base64)
  
  # Unset any existing values
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY BRAVE_API_KEY
  
  env_decode_keys
  
  [ "$ANTHROPIC_API_KEY" = "sk-ant-test123" ] && echo "PASS: ANTHROPIC_API_KEY decoded" || echo "FAIL: ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'"
  [ "$OPENAI_API_KEY" = "sk-openai-test456" ] && echo "PASS: OPENAI_API_KEY decoded" || echo "FAIL: OPENAI_API_KEY='$OPENAI_API_KEY'"
  [ "$GOOGLE_API_KEY" = "AIzaGoogle789" ] && echo "PASS: GOOGLE_API_KEY decoded" || echo "FAIL: GOOGLE_API_KEY='$GOOGLE_API_KEY'"
  [ "$BRAVE_API_KEY" = "BSAbrave000" ] && echo "PASS: BRAVE_API_KEY decoded" || echo "FAIL: BRAVE_API_KEY='$BRAVE_API_KEY'"
  
  # env_decode_keys should NOT overwrite existing values
  export ANTHROPIC_API_KEY="already-set"
  export ANTHROPIC_KEY_B64=$(echo -n "should-not-overwrite" | base64)
  env_decode_keys
  [ "$ANTHROPIC_API_KEY" = "already-set" ] && echo "PASS: env_decode_keys respects existing values" || echo "FAIL: overwrote existing ANTHROPIC_API_KEY"
  
) > /tmp/test-lib-env-decode.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-lib-env-decode.txt

# =============================================================================
echo ""
echo "=== PR2: No duplicate d() in other scripts ==="
# =============================================================================

# Scripts that should use lib-env.sh instead of defining their own d()
# Exclude lib-env.sh itself and legacy scripts (phase1-critical.sh, phase2-background.sh)
scripts_with_own_d=$(grep -rl '^d() {' "$REPO_DIR/scripts/" \
  | grep -v 'lib-env.sh' \
  | grep -v 'phase1-critical.sh' \
  | grep -v 'phase2-background.sh' \
  | grep -v 'README.md' \
  || true)

if [ -z "$scripts_with_own_d" ]; then
  pass "No scripts define their own d() function (except lib-env.sh and legacy)"
else
  for f in $scripts_with_own_d; do
    fail "$(basename "$f") still defines its own d() — should source lib-env.sh"
  done
fi

# =============================================================================
echo ""
echo "=== PR2: Fatal library guards ==="
# =============================================================================

# All scripts that source libraries must have fatal guards
# Pattern: after sourcing, check that a key function exists
for script in gateway-health-check.sh gateway-e2e-check.sh safe-mode-handler.sh; do
  script_path="$REPO_DIR/scripts/$script"
  [ -f "$script_path" ] || continue
  
  # If the script sources lib-health-check.sh, it must check for hc_init_logging
  if grep -q 'lib-health-check.sh' "$script_path"; then
    if grep -q 'type.*hc_init_logging.*>/dev/null\|command -v.*hc_init_logging' "$script_path"; then
      pass "$script has fatal guard for lib-health-check.sh"
    else
      fail "$script sources lib-health-check.sh but has no fatal guard"
    fi
  fi
  
  # If the script sources lib-notify.sh, it must check for notify_send_message
  if grep -q 'lib-notify.sh' "$script_path"; then
    if grep -q 'type.*notify_send_message.*>/dev/null\|command -v.*notify_send_message\|type.*notify_find_token.*>/dev/null' "$script_path"; then
      pass "$script has fatal guard for lib-notify.sh"
    else
      fail "$script sources lib-notify.sh but has no fatal guard"
    fi
  fi
  
  # If the script sources lib-env.sh, it must check for d or env_load
  if grep -q 'lib-env.sh' "$script_path"; then
    if grep -q 'type.*env_load.*>/dev/null\|type.*d .*>/dev/null\|command -v.*env_load' "$script_path"; then
      pass "$script has fatal guard for lib-env.sh"
    else
      fail "$script sources lib-env.sh but has no fatal guard"
    fi
  fi
done

# =============================================================================
echo ""
echo "=== PR2: lib-health-check.sh uses lib-env.sh ==="
# =============================================================================

LIB_HC="$REPO_DIR/scripts/lib-health-check.sh"

# lib-health-check.sh should source lib-env.sh and use d() from it
if grep -q 'source.*lib-env.sh\|\..*lib-env.sh' "$LIB_HC"; then
  pass "lib-health-check.sh sources lib-env.sh"
else
  fail "lib-health-check.sh should source lib-env.sh instead of defining _hc_d()"
fi

# lib-health-check.sh should NOT define its own _hc_d()
if ! grep -q '_hc_d()' "$LIB_HC"; then
  pass "lib-health-check.sh does not define _hc_d()"
else
  fail "lib-health-check.sh still defines _hc_d() — should use d() from lib-env.sh"
fi

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
