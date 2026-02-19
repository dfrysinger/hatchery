#!/bin/bash
# =============================================================================
# test-helpers.sh -- Shared test utilities for bash test scripts
# =============================================================================
# Usage: source "$(dirname "$0")/test-helpers.sh"
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
SKIPPED=0

pass() {
  echo -e "${GREEN}✓${NC} $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

skip() {
  echo -e "${YELLOW}⊘${NC} $1 (skipped)"
  SKIPPED=$((SKIPPED + 1))
}

# Print summary and exit with appropriate code
test_summary() {
  local label="${1:-Tests}"
  echo ""
  echo "================================"
  echo "$label: $PASSED passed, $FAILED failed, $SKIPPED skipped"
  echo "================================"
  [ "$FAILED" -eq 0 ]
}

# Assert string contains substring
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-expected to contain '$needle'}"
  if echo "$haystack" | grep -q "$needle"; then
    return 0
  else
    return 1
  fi
}

# Assert string does NOT contain substring
assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if echo "$haystack" | grep -q "$needle"; then
    return 1
  else
    return 0
  fi
}

# Assert file exists
assert_file_exists() {
  [ -f "$1" ]
}

# Assert file contains string
assert_file_contains() {
  local file="$1"
  local needle="$2"
  [ -f "$file" ] && grep -q "$needle" "$file"
}

# Resolve repo root (parent of tests/)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Common script paths
HEALTH_CHECK="$REPO_DIR/scripts/gateway-health-check.sh"
BUILD_CONFIG="$REPO_DIR/scripts/build-full-config.sh"
SAFE_MODE_RECOVERY="$REPO_DIR/scripts/safe-mode-recovery.sh"
SETUP_SAFE_MODE="$REPO_DIR/scripts/setup-safe-mode-workspace.sh"
GENERATE_SESSIONS="$REPO_DIR/scripts/generate-session-services.sh"
GENERATE_COMPOSE="$REPO_DIR/scripts/generate-docker-compose.sh"
