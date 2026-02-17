#!/bin/bash
# Tests for gateway-health-check.sh channel connectivity logic

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}✓${NC} $msg"
    ((PASSED++))
  else
    echo -e "${RED}✗${NC} $msg"
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    ((FAILED++))
  fi
}

# =============================================================================
# Test Setup
# =============================================================================
TEST_TMPDIR=$(mktemp -d)
export TEST_TMPDIR
trap "rm -rf '$TEST_TMPDIR'" EXIT

# Define token constants
VALID_TG_TOKEN="valid-tg-token-123"
VALID_DC_TOKEN="valid-dc-token-456"
BROKEN_TG_TOKEN="INVALID_TELEGRAM_TOKEN_12345"
BROKEN_DC_TOKEN="broken-dc-token"

# Create mock validate functions
cat > "$TEST_TMPDIR/mock-validators.sh" << MOCK
# Mock token validators - check against expected values
validate_telegram_token_direct() {
  [ "\$1" = "$VALID_TG_TOKEN" ]
}

validate_discord_token_direct() {
  [ "\$1" = "$VALID_DC_TOKEN" ]
}

log() {
  echo "\$*" >> "$TEST_TMPDIR/health-check.log"
}

H="$TEST_TMPDIR/home"
MOCK

mkdir -p "$TEST_TMPDIR/home/.openclaw"

# Extract check_channel_connectivity function from the actual script
# Replace the habitat-parsed.env source with our test env
extract_function() {
  sed -n '/^check_channel_connectivity()/,/^}/p' "$REPO_DIR/scripts/gateway-health-check.sh" | \
    sed 's|/etc/habitat-parsed.env|$TEST_TMPDIR/env.sh|g'
}

# Run a test and capture exit code
run_check() {
  (
    source "$TEST_TMPDIR/mock-validators.sh"
    source "$TEST_TMPDIR/env.sh"
    eval "$(extract_function)"
    check_channel_connectivity "clawdbot"
  )
  echo $?
}

# =============================================================================
# Tests: Platform = telegram
# =============================================================================
echo ""
echo "=== Platform: telegram (single agent) ==="

# Test: Single agent with valid Telegram token
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="telegram"
AGENT_COUNT=1
AGENT1_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "0" "$result" "single_agent_valid_telegram: returns success"

# Test: Single agent with broken Telegram token
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="telegram"
AGENT_COUNT=1
AGENT1_TELEGRAM_BOT_TOKEN="$BROKEN_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "1" "$result" "single_agent_broken_telegram: returns failure"

# =============================================================================
# Tests: Multiple agents - ALL must be valid
# =============================================================================
echo ""
echo "=== Platform: telegram (multiple agents - ALL must be valid) ==="

# Test: 2 agents, both valid
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="telegram"
AGENT_COUNT=2
AGENT1_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
AGENT2_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "0" "$result" "multi_agent_both_valid: returns success"

# Test: 2 agents, first valid, second broken
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="telegram"
AGENT_COUNT=2
AGENT1_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
AGENT2_TELEGRAM_BOT_TOKEN="$BROKEN_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "1" "$result" "multi_agent_second_broken: FAILS even if first is valid"

# Test: 2 agents, first broken, second valid
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="telegram"
AGENT_COUNT=2
AGENT1_TELEGRAM_BOT_TOKEN="$BROKEN_TG_TOKEN"
AGENT2_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "1" "$result" "multi_agent_first_broken: FAILS even if second is valid"

# =============================================================================
# Tests: No cross-platform fallback in normal mode
# =============================================================================
echo ""
echo "=== No cross-platform fallback (platform: telegram) ==="

# Test: Agent has broken TG but valid Discord - should FAIL (no fallback)
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="telegram"
AGENT_COUNT=1
AGENT1_TELEGRAM_BOT_TOKEN="$BROKEN_TG_TOKEN"
AGENT1_DISCORD_BOT_TOKEN="$VALID_DC_TOKEN"
EOF
result=$(run_check)
assert_eq "1" "$result" "no_cross_platform_fallback: FAILS despite valid Discord token"

# =============================================================================
# Tests: Platform = both
# =============================================================================
echo ""
echo "=== Platform: both (agent needs at least one working token) ==="

# Test: Agent has valid TG only - should pass
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="both"
AGENT_COUNT=1
AGENT1_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "0" "$result" "platform_both_tg_only: passes with just Telegram"

# Test: Agent has valid DC only - should pass
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="both"
AGENT_COUNT=1
AGENT1_DISCORD_BOT_TOKEN="$VALID_DC_TOKEN"
EOF
result=$(run_check)
assert_eq "0" "$result" "platform_both_dc_only: passes with just Discord"

# Test: Agent has broken TG but valid DC - should pass with "both"
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="both"
AGENT_COUNT=1
AGENT1_TELEGRAM_BOT_TOKEN="$BROKEN_TG_TOKEN"
AGENT1_DISCORD_BOT_TOKEN="$VALID_DC_TOKEN"
EOF
result=$(run_check)
assert_eq "0" "$result" "platform_both_fallback: passes when one platform works"

# Test: Agent has both broken - should fail
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="both"
AGENT_COUNT=1
AGENT1_TELEGRAM_BOT_TOKEN="$BROKEN_TG_TOKEN"
AGENT1_DISCORD_BOT_TOKEN="$BROKEN_DC_TOKEN"
EOF
result=$(run_check)
assert_eq "1" "$result" "platform_both_all_broken: fails when both platforms broken"

# =============================================================================
# Tests: Multi-agent with platform = both
# =============================================================================
echo ""
echo "=== Platform: both (multiple agents) ==="

# Test: 2 agents, agent1 has TG, agent2 has DC - both should pass
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="both"
AGENT_COUNT=2
AGENT1_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
AGENT2_DISCORD_BOT_TOKEN="$VALID_DC_TOKEN"
EOF
result=$(run_check)
assert_eq "0" "$result" "multi_both_mixed_tokens: passes when each agent has at least one"

# Test: 2 agents, agent1 has valid TG, agent2 has nothing - should fail
cat > "$TEST_TMPDIR/env.sh" << EOF
PLATFORM="both"
AGENT_COUNT=2
AGENT1_TELEGRAM_BOT_TOKEN="$VALID_TG_TOKEN"
EOF
result=$(run_check)
assert_eq "1" "$result" "multi_both_one_missing: FAILS when one agent has no tokens"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "==================================="

[ "$FAILED" -eq 0 ]
