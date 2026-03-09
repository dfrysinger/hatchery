#!/bin/bash
# =============================================================================
# test-session-services.sh -- Unit tests for generate-session-services.sh
# =============================================================================
# Tests that session service generation works correctly.
# The script is a thin generator: it reads from a manifest and writes .service
# files. Config/state directories are created by the orchestrator, not here.
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
# Test: Session services generation (dry run with manifest)
# =============================================================================
echo ""
echo "=== Test: Generate Session Services ==="

# Create temp directories
TMPDIR=$(mktemp -d)
OUTPUT_DIR="$TMPDIR/systemd"
HOME_DIR_TEST="$TMPDIR/home/bot"
CONFIG_DIR="$HOME_DIR_TEST/.openclaw/configs/test-group"
STATE_DIR="$HOME_DIR_TEST/.openclaw-sessions/test-group"
ENV_FILE="$CONFIG_DIR/group.env"
CONFIG_FILE="$CONFIG_DIR/openclaw.session.json"

# Create pre-existing config/state (as orchestrator would)
mkdir -p "$OUTPUT_DIR" "$CONFIG_DIR" "$STATE_DIR/agents/agent1/agent" "$STATE_DIR/agents/agent2/agent"
echo '{}' > "$CONFIG_FILE"
echo 'PLATFORM=telegram' > "$ENV_FILE"

# Create manifest (as build-full-config.sh would)
MANIFEST_FILE="$TMPDIR/groups.json"
cat > "$MANIFEST_FILE" <<EOF
{
  "generated": "2026-01-01T00:00:00Z",
  "groups": {
    "test-group": {
      "isolation": "session",
      "port": 18790,
      "network": "host",
      "agents": ["agent1", "agent2"],
      "configPath": "$CONFIG_FILE",
      "statePath": "$STATE_DIR",
      "envFile": "$ENV_FILE",
      "serviceName": "openclaw-test-group",
      "composePath": null
    }
  }
}
EOF

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
export HOME_DIR="$HOME_DIR_TEST"
export MANIFEST="$MANIFEST_FILE"
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

# Check gateway port in service (read from manifest)
if grep -q -- "--port 18790" "$OUTPUT_DIR/openclaw-test-group.service" 2>/dev/null; then
  pass "Gateway port is 18790"
else
  fail "Gateway port should be 18790"
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

  if grep -q "GROUP=test-group" "$OUTPUT_DIR/openclaw-test-group.service"; then
    pass "Service file sets GROUP"
  else
    fail "Service file should set GROUP"
  fi
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
unset MANIFEST 2>/dev/null || true
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
