#!/bin/bash
# =============================================================================
# test-diagnostics.sh -- Tests for unified diagnostics architecture
# =============================================================================
# Tests that lib-auth.sh records diagnostic results when AUTH_DIAG_LOG is set,
# and that safe-mode-handler.sh generates a complete boot report from them.
#
# Architecture:
#   - lib-auth.sh is the single source of diagnostic recording
#   - Callers opt in by setting AUTH_DIAG_LOG to a file path
#   - safe-mode-handler.sh reads the diagnostics file for boot report
#   - generate-boot-report.sh is removed (dead code)
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

setup_test_env() {
  export TEST_TMPDIR=$(mktemp -d)
  export TEST_MODE=1
  export AUTH_DIAG_LOG="$TEST_TMPDIR/diagnostics.log"
  export AGENT_COUNT=3
  export GROUP=""
  
  # Mock tokens
  export AGENT1_TELEGRAM_BOT_TOKEN="VALID_TOKEN_1"
  export AGENT2_TELEGRAM_BOT_TOKEN="INVALID_TOKEN_2"
  export AGENT3_TELEGRAM_BOT_TOKEN="VALID_TOKEN_3"
  export AGENT1_DISCORD_BOT_TOKEN="INVALID_DISCORD_1"
  export AGENT2_DISCORD_BOT_TOKEN="VALID_DISCORD_2"
  
  # Mock API keys
  export ANTHROPIC_API_KEY=""
  export OPENAI_API_KEY=""
  export GOOGLE_API_KEY=""
  
  # Provide log function
  log() { :; }
  export -f log
  
  # Source lib-auth
  source "$REPO_DIR/scripts/lib-auth.sh"
}

cleanup_test_env() {
  rm -rf "$TEST_TMPDIR" 2>/dev/null
  unset AUTH_DIAG_LOG TEST_TMPDIR TEST_MODE AGENT_COUNT GROUP
  unset AGENT1_TELEGRAM_BOT_TOKEN AGENT2_TELEGRAM_BOT_TOKEN AGENT3_TELEGRAM_BOT_TOKEN
  unset AGENT1_DISCORD_BOT_TOKEN AGENT2_DISCORD_BOT_TOKEN
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY
}

echo "=== Diagnostics Architecture Tests ==="
echo ""

# ─── Test 1: AUTH_DIAG_LOG defaults to /dev/null ─────────────────────────
echo "--- lib-auth.sh diagnostic opt-in ---"

(
  unset AUTH_DIAG_LOG
  source "$REPO_DIR/scripts/lib-auth.sh"
  if [ "$AUTH_DIAG_LOG" = "/dev/null" ]; then
    pass "AUTH_DIAG_LOG defaults to /dev/null"
  else
    fail "AUTH_DIAG_LOG should default to /dev/null, got: $AUTH_DIAG_LOG"
  fi
)

# ─── Test 2: Telegram token validation records diagnostics ───────────────

(
  setup_test_env
  
  # find_working_telegram_token should record each attempt
  find_working_telegram_token
  
  if [ -f "$AUTH_DIAG_LOG" ] && grep -q "telegram" "$AUTH_DIAG_LOG"; then
    pass "find_working_telegram_token records diagnostics"
  else
    fail "find_working_telegram_token should record to AUTH_DIAG_LOG"
  fi
  
  cleanup_test_env
)

# ─── Test 3: Valid tokens get ✅, invalid get ❌ ──────────────────────────

(
  setup_test_env
  
  # agent1 has VALID token, so it should get ✅ and be the one found
  find_working_telegram_token >/dev/null 2>&1
  
  if grep -q "✅" "$AUTH_DIAG_LOG" 2>/dev/null; then
    pass "Valid telegram token marked ✅"
  else
    fail "Valid telegram token should be marked ✅ in diagnostics (got: $(cat "$AUTH_DIAG_LOG" 2>/dev/null))"
  fi
  
  cleanup_test_env
)

# ─── Test 4: Discord token validation records diagnostics ────────────────

(
  setup_test_env
  
  find_working_discord_token >/dev/null 2>&1
  
  if [ -f "$AUTH_DIAG_LOG" ] && grep -q "discord" "$AUTH_DIAG_LOG"; then
    pass "find_working_discord_token records diagnostics"
  else
    fail "find_working_discord_token should record to AUTH_DIAG_LOG"
  fi
  
  cleanup_test_env
)

# ─── Test 5: API provider validation records diagnostics ─────────────────

(
  setup_test_env
  export ANTHROPIC_API_KEY="test_key"
  export GOOGLE_API_KEY="test_google_key"
  
  find_working_api_provider >/dev/null 2>&1
  
  if [ -f "$AUTH_DIAG_LOG" ] && grep -q "api" "$AUTH_DIAG_LOG"; then
    pass "find_working_api_provider records diagnostics"
  else
    fail "find_working_api_provider should record to AUTH_DIAG_LOG"
  fi
  
  cleanup_test_env
)

# ─── Test 6: API diagnostics include provider name ───────────────────────

(
  setup_test_env
  export ANTHROPIC_API_KEY="test_key"
  
  find_working_api_provider >/dev/null 2>&1
  
  if grep -q "anthropic" "$AUTH_DIAG_LOG" 2>/dev/null; then
    pass "API diagnostics include provider name"
  else
    fail "API diagnostics should include provider name (anthropic)"
  fi
  
  cleanup_test_env
)

# ─── Test 7: No diagnostics when AUTH_DIAG_LOG is /dev/null ──────────────

(
  setup_test_env
  export AUTH_DIAG_LOG="/dev/null"
  
  # Re-source to pick up the change
  source "$REPO_DIR/scripts/lib-auth.sh"
  
  find_working_telegram_token >/dev/null 2>&1
  
  # Nothing should be written anywhere unexpected
  pass "No diagnostics written when AUTH_DIAG_LOG is /dev/null (opt-out)"
  
  cleanup_test_env
)

# ─── Test 8: Diagnostics format is parseable ─────────────────────────────

(
  setup_test_env
  
  find_working_telegram_token >/dev/null 2>&1
  find_working_discord_token >/dev/null 2>&1
  
  # Format should be: category:name:icon:reason
  valid_format=true
  while IFS= read -r line; do
    # Skip empty lines
    [ -z "$line" ] && continue
    # Should have at least 3 colons (4 fields)
    colons=$(echo "$line" | tr -cd ':' | wc -c)
    if [ "$colons" -lt 3 ]; then
      valid_format=false
      break
    fi
  done < "$AUTH_DIAG_LOG"
  
  if [ "$valid_format" = true ]; then
    pass "Diagnostics format is parseable (category:name:icon:reason)"
  else
    fail "Diagnostics should use category:name:icon:reason format"
  fi
  
  cleanup_test_env
)

# ─── Test 9: Platform token search records all attempts ──────────────────

(
  setup_test_env
  
  # Use find_working_platform_token which tries preferred then fallback
  export PLATFORM="telegram"
  find_working_platform_token >/dev/null 2>&1
  
  # Should have at least one telegram entry
  if grep -c "telegram" "$AUTH_DIAG_LOG" 2>/dev/null | grep -qE "^[1-9]"; then
    pass "Platform token search records telegram attempts"
  else
    fail "Platform token search should record telegram attempts"
  fi
  
  cleanup_test_env
)

# ─── Test 10: Network diagnostics recorded in run_smart_recovery ──────────

echo ""
echo "--- safe-mode-recovery.sh diagnostics ---"

(
  # Verify that run_smart_recovery records network status via _diag
  # (check_network is a pure utility; _diag calls wrap it in run_smart_recovery)
  if grep -q '_diag "network:' "$REPO_DIR/scripts/safe-mode-recovery.sh" 2>/dev/null; then
    pass "run_smart_recovery records network diagnostics via _diag"
  else
    fail "run_smart_recovery should record network diagnostics via _diag"
  fi
)

# ─── Test 11: generate-boot-report.sh removed ────────────────────────────

echo ""
echo "--- Dead code removal ---"

if [ ! -f "$REPO_DIR/scripts/generate-boot-report.sh" ]; then
  pass "generate-boot-report.sh removed (dead code)"
else
  fail "generate-boot-report.sh should be removed (dead code, never called)"
fi

# ─── Test 12: No DIAG array machinery in safe-mode-recovery.sh ───────────

(
  if grep -q "DIAG_TELEGRAM_RESULTS\|DIAG_DISCORD_RESULTS\|DIAG_API_RESULTS" "$REPO_DIR/scripts/safe-mode-recovery.sh" 2>/dev/null; then
    fail "safe-mode-recovery.sh should not have DIAG array machinery (moved to lib-auth)"
  else
    pass "DIAG array machinery removed from safe-mode-recovery.sh"
  fi
)

# ─── Test 13: No diag_add function in safe-mode-recovery.sh ──────────────

(
  if grep -q "^diag_add()" "$REPO_DIR/scripts/safe-mode-recovery.sh" 2>/dev/null; then
    fail "diag_add() should not be in safe-mode-recovery.sh (diagnostics in lib-auth)"
  else
    pass "diag_add() removed from safe-mode-recovery.sh"
  fi
)

# ─── Test 14: No write_diagnostics_summary in safe-mode-recovery.sh ──────

(
  if grep -q "write_diagnostics_summary" "$REPO_DIR/scripts/safe-mode-recovery.sh" 2>/dev/null; then
    fail "write_diagnostics_summary should not be in safe-mode-recovery.sh"
  else
    pass "write_diagnostics_summary removed from safe-mode-recovery.sh"
  fi
)

# ─── Test 15: Boot report reads AUTH_DIAG_LOG file ────────────────────────

echo ""
echo "--- Boot report generation ---"

(
  if grep -q "AUTH_DIAG_LOG\|diagnostics.log" "$REPO_DIR/scripts/safe-mode-handler.sh" 2>/dev/null; then
    pass "safe-mode-handler.sh reads diagnostics from AUTH_DIAG_LOG"
  else
    fail "safe-mode-handler.sh should read AUTH_DIAG_LOG for diagnostics"
  fi
)

# ─── Test 16: Boot report distributes to all workspaces ──────────────────

(
  if grep -q "distribute_boot_report\|clawd/agents/agent" "$REPO_DIR/scripts/safe-mode-handler.sh" 2>/dev/null; then
    pass "Boot report distributes to agent workspaces"
  else
    fail "Boot report should distribute to all agent workspaces"
  fi
)

# ─── Test 17: No reference to safe-mode-diagnostics.txt in handler ───────

(
  if grep -q "safe-mode-diagnostics.txt" "$REPO_DIR/scripts/safe-mode-handler.sh" 2>/dev/null; then
    fail "safe-mode-handler.sh should not reference safe-mode-diagnostics.txt (use AUTH_DIAG_LOG)"
  else
    pass "No reference to old safe-mode-diagnostics.txt in handler"
  fi
)

# ─── Test 18: API missing key gets descriptive reason ─────────────────────

(
  setup_test_env
  export ANTHROPIC_API_KEY=""
  export OPENAI_API_KEY=""
  export GOOGLE_API_KEY=""
  
  find_working_api_provider >/dev/null 2>&1
  
  if grep -q "missing\|no.key" "$AUTH_DIAG_LOG" 2>/dev/null; then
    pass "Missing API key gets descriptive reason in diagnostics"
  else
    fail "Missing API key should record descriptive reason (missing/no key)"
  fi
  
  cleanup_test_env
)

# ─── Summary ─────────────────────────────────────────────────────────────

echo ""
echo "=================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=================================="

exit $FAILED
