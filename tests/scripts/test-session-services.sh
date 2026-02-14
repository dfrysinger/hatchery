#!/bin/bash
# =============================================================================
# test-session-services.sh -- Unit tests for generate-session-services.sh
# =============================================================================
# Tests that session service generation works correctly
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"

PASSED=0
FAILED=0

# Colors
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
# Test: Session services generation (dry run)
# =============================================================================
echo ""
echo "=== Test: Generate Session Services ==="

# Create temp directories
TMPDIR=$(mktemp -d)
OUTPUT_DIR="$TMPDIR/systemd"
HOME_DIR="$TMPDIR/home/bot"
mkdir -p "$OUTPUT_DIR" "$HOME_DIR/.openclaw/agents/agent1/agent" "$HOME_DIR/.openclaw/agents/agent2/agent"

# Create mock auth-profiles.json
echo '{"version":1,"profiles":{}}' > "$HOME_DIR/.openclaw/agents/agent1/agent/auth-profiles.json"
echo '{"version":1,"profiles":{}}' > "$HOME_DIR/.openclaw/agents/agent2/agent/auth-profiles.json"

# Set up environment
export AGENT_COUNT=2
export ISOLATION_DEFAULT="session"
export ISOLATION_GROUPS="test-group"
export USERNAME="bot"
export HABITAT_NAME="TestHabitat"
export PLATFORM="telegram"
export TELEGRAM_OWNER_ID="123456789"

export AGENT1_NAME="Agent1"
export AGENT1_MODEL="anthropic/claude-opus-4-5"
export AGENT1_BOT_TOKEN="TEST_TOKEN_1"
export AGENT1_ISOLATION_GROUP="test-group"
export AGENT1_ISOLATION=""

export AGENT2_NAME="Agent2"
export AGENT2_MODEL="anthropic/claude-opus-4-5"
export AGENT2_BOT_TOKEN="TEST_TOKEN_2"
export AGENT2_ISOLATION_GROUP="test-group"
export AGENT2_ISOLATION=""

export ANTHROPIC_API_KEY="test-api-key"
export GOOGLE_API_KEY=""
export BRAVE_API_KEY=""

export SESSION_OUTPUT_DIR="$OUTPUT_DIR"
export HOME_DIR="$HOME_DIR"
export DRY_RUN=1

# Run the script
if bash "$REPO_DIR/scripts/generate-session-services.sh" >/dev/null 2>&1; then
  pass "generate-session-services.sh ran without errors"
else
  fail "generate-session-services.sh failed"
fi

# Check service file was created
if [ -f "$OUTPUT_DIR/openclaw-test-group.service" ]; then
  pass "Service file created: openclaw-test-group.service"
else
  fail "Service file not created"
fi

# Check config file was created
if [ -f "$OUTPUT_DIR/test-group/openclaw.session.json" ]; then
  pass "Config file created: test-group/openclaw.session.json"
else
  fail "Config file not created"
fi

# Validate config is valid JSON
if [ -f "$OUTPUT_DIR/test-group/openclaw.session.json" ]; then
  if jq . "$OUTPUT_DIR/test-group/openclaw.session.json" >/dev/null 2>&1; then
    pass "Config file is valid JSON"
  else
    fail "Config file is not valid JSON"
  fi
fi

# Check config contains expected fields
if [ -f "$OUTPUT_DIR/test-group/openclaw.session.json" ]; then
  # Check agents list
  agent_count=$(jq '.agents.list | length' "$OUTPUT_DIR/test-group/openclaw.session.json" 2>/dev/null || echo 0)
  if [ "$agent_count" = "2" ]; then
    pass "Config contains 2 agents"
  else
    fail "Config should have 2 agents, got $agent_count"
  fi
  
  # Check telegram is enabled
  tg_enabled=$(jq '.channels.telegram.enabled' "$OUTPUT_DIR/test-group/openclaw.session.json" 2>/dev/null || echo false)
  if [ "$tg_enabled" = "true" ]; then
    pass "Telegram channel enabled"
  else
    fail "Telegram channel should be enabled"
  fi
  
  # Check port
  port=$(jq '.gateway.port' "$OUTPUT_DIR/test-group/openclaw.session.json" 2>/dev/null || echo 0)
  if [ "$port" = "18790" ]; then
    pass "Gateway port is 18790"
  else
    fail "Gateway port should be 18790, got $port"
  fi
fi

# Check service file contents
if [ -f "$OUTPUT_DIR/openclaw-test-group.service" ]; then
  if grep -q "OPENCLAW_STATE_DIR" "$OUTPUT_DIR/openclaw-test-group.service"; then
    pass "Service file sets OPENCLAW_STATE_DIR"
  else
    fail "Service file should set OPENCLAW_STATE_DIR"
  fi
  
  if grep -q "ANTHROPIC_API_KEY" "$OUTPUT_DIR/openclaw-test-group.service"; then
    pass "Service file sets ANTHROPIC_API_KEY"
  else
    fail "Service file should set ANTHROPIC_API_KEY"
  fi
fi

# Check state directories were created
if [ -d "$HOME_DIR/.openclaw-sessions/test-group/agents/agent1/agent" ]; then
  pass "State directory created for agent1"
else
  fail "State directory not created for agent1"
fi

# Cleanup
rm -rf "$TMPDIR"

# =============================================================================
# Test: No isolation mode should skip
# =============================================================================
echo ""
echo "=== Test: Skip when not session mode ==="

TMPDIR=$(mktemp -d)
OUTPUT_DIR="$TMPDIR/systemd"
mkdir -p "$OUTPUT_DIR"

export ISOLATION_DEFAULT="none"
export ISOLATION_GROUPS=""
export SESSION_OUTPUT_DIR="$OUTPUT_DIR"
export DRY_RUN=1

output=$(bash "$REPO_DIR/scripts/generate-session-services.sh" 2>&1)
if [[ "$output" == *"no session services needed"* ]]; then
  pass "Script correctly skips when isolation=none"
else
  fail "Script should skip when isolation=none"
fi

rm -rf "$TMPDIR"

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
