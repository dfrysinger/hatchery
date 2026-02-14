#!/bin/bash
# =============================================================================
# run-tests.sh -- Run all Hatchery tests
# =============================================================================
# Usage: ./tests/run-tests.sh [test-name]
#   - No args: run all tests
#   - With arg: run specific test (e.g., "parse-habitat")
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_SCRIPTS_DIR="$SCRIPT_DIR/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TOTAL_PASSED=0
TOTAL_FAILED=0

run_test() {
  local test_script="$1"
  local test_name=$(basename "$test_script" .sh | sed 's/^test-//')
  
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}Running: $test_name${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  
  if bash "$test_script"; then
    echo -e "${GREEN}$test_name: PASSED${NC}"
    return 0
  else
    echo -e "${RED}$test_name: FAILED${NC}"
    return 1
  fi
}

# Check for dependencies
check_deps() {
  local missing=()
  
  for cmd in jq python3 base64; do
    if ! command -v $cmd &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
    exit 1
  fi
}

check_deps

# Get test to run
TEST_FILTER="${1:-}"

# Find and run tests
for test_script in "$TESTS_SCRIPTS_DIR"/test-*.sh; do
  [ -f "$test_script" ] || continue
  
  test_name=$(basename "$test_script" .sh | sed 's/^test-//')
  
  # Filter if specified
  if [ -n "$TEST_FILTER" ] && [[ "$test_name" != *"$TEST_FILTER"* ]]; then
    continue
  fi
  
  chmod +x "$test_script"
  
  if run_test "$test_script"; then
    TOTAL_PASSED=$((TOTAL_PASSED + 1))
  else
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
done

# Summary
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                           TEST SUMMARY${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Passed: ${GREEN}$TOTAL_PASSED${NC}"
echo -e "  Failed: ${RED}$TOTAL_FAILED${NC}"
echo ""

if [ $TOTAL_FAILED -gt 0 ]; then
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
