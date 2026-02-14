#!/bin/bash
# =============================================================================
# test-parse-habitat.sh -- Unit tests for parse-habitat.py
# =============================================================================
# Tests habitat parsing produces correct environment variables
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"
FIXTURES_DIR="$TESTS_DIR/fixtures"

PASSED=0
FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((PASSED++)) || true
}

fail() {
  echo -e "${RED}✗${NC} $1"
  ((FAILED++)) || true
}

assert_env() {
  local var="$1"
  local expected="$2"
  local actual="${!var:-}"
  
  if [ "$actual" = "$expected" ]; then
    pass "$var = '$expected'"
  else
    fail "$var: expected '$expected', got '$actual'"
  fi
}

assert_env_not_empty() {
  local var="$1"
  local actual="${!var:-}"
  
  if [ -n "$actual" ]; then
    pass "$var is set ('$actual')"
  else
    fail "$var is empty/unset"
  fi
}

assert_env_contains() {
  local var="$1"
  local expected="$2"
  local actual="${!var:-}"
  
  if [[ "$actual" == *"$expected"* ]]; then
    pass "$var contains '$expected'"
  else
    fail "$var should contain '$expected', got '$actual'"
  fi
}

# Test function
run_test() {
  local fixture="$1"
  local test_name="$2"
  
  echo ""
  echo "=== Test: $test_name ==="
  
  # Create temp output directory
  local tmpdir=$(mktemp -d)
  local habitat_b64=$(base64 -w0 < "$FIXTURES_DIR/$fixture")
  
  # Run parse-habitat.py with output to temp dir
  if ! HABITAT_B64="$habitat_b64" HABITAT_OUTPUT_DIR="$tmpdir" python3 "$REPO_DIR/scripts/parse-habitat.py" > /dev/null 2>&1; then
    fail "parse-habitat.py failed"
    rm -rf "$tmpdir"
    return 1
  fi
  
  # Source the output
  source "$tmpdir/habitat-parsed.env"
  rm -rf "$tmpdir"
  
  return 0
}

# =============================================================================
# Test 1: Single agent Telegram
# =============================================================================
run_test "habitat-single-agent-telegram.json" "Single Agent Telegram"

assert_env "HABITAT_NAME" "TestHabitat-SingleTelegram"
assert_env "PLATFORM" "telegram"
assert_env "AGENT_COUNT" "1"
assert_env "AGENT1_NAME" "TestBot"
assert_env "AGENT1_BOT_TOKEN" "TEST_BOT_TOKEN_1"
assert_env "TELEGRAM_OWNER_ID" "123456789"
# No isolation set in habitat, defaults to "none"
assert_env "ISOLATION_DEFAULT" "none"

# =============================================================================
# Test 2: Multi-agent Session Isolation
# =============================================================================
run_test "habitat-multi-agent-session.json" "Multi Agent Session Isolation"

assert_env "HABITAT_NAME" "TestHabitat-MultiSession"
assert_env "PLATFORM" "telegram"
assert_env "AGENT_COUNT" "3"
assert_env "ISOLATION_DEFAULT" "session"
assert_env "AGENT1_ISOLATION_GROUP" "group-a"
assert_env "AGENT2_ISOLATION_GROUP" "group-a"
assert_env "AGENT3_ISOLATION_GROUP" "group-b"
assert_env_not_empty "ISOLATION_GROUPS"

# Verify ISOLATION_GROUPS contains both groups
assert_env_contains "ISOLATION_GROUPS" "group-a"
assert_env_contains "ISOLATION_GROUPS" "group-b"

# =============================================================================
# Test 3: Single agent Discord
# =============================================================================
run_test "habitat-single-agent-discord.json" "Single Agent Discord"

assert_env "HABITAT_NAME" "TestHabitat-SingleDiscord"
assert_env "PLATFORM" "discord"
assert_env "AGENT_COUNT" "1"
assert_env "AGENT1_DISCORD_BOT_TOKEN" "TEST_DISCORD_TOKEN_1"
assert_env "DISCORD_OWNER_ID" "987654321"
assert_env "DISCORD_GUILD_ID" "1234567890"

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
