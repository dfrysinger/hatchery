#!/bin/bash
# =============================================================================
# test-safe-mode-regressions.sh -- Regression tests for safe mode bugs
# =============================================================================
# Tests for bugs found during safe mode testing (2026-02-21)
# Branch: fix/single-phase-boot
#
# Bugs covered:
# 1. Invalid model name "anthropic/claude-sonnet-4" (commit c1ae739)
# 2. Model not passed from recovery to config generator (commit 8b4b24c)
# 3. Intro delivered to broken channel instead of active channel (commit 18c5058)
# 4. E2E check didn't validate HEALTH_CHECK_OK magic word (commit f0901e0)
# 5. Emergency.json fallback removed (commit 34bbb46)
# 6. phase2-background.sh missing umask 022 (commit 40e6bef)
# 7. Safe mode bot had no exec access — couldn't run diagnostic/repair commands
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

# =============================================================================
# Bug 1: Invalid model name "anthropic/claude-sonnet-4" (missing -5 suffix)
# Affected: lib-auth.sh, generate-config.sh
# =============================================================================
echo ""
echo "=== Bug 1: No invalid model names ==="

LIB_AUTH="$REPO_DIR/scripts/lib-auth.sh"
GEN_CONFIG="$REPO_DIR/scripts/generate-config.sh"
RECOVERY="$REPO_DIR/scripts/safe-mode-recovery.sh"

# Check lib-auth.sh for stale model names
if grep -q '"anthropic/claude-sonnet-4"' "$LIB_AUTH" 2>/dev/null; then
  fail "lib-auth.sh contains invalid model 'anthropic/claude-sonnet-4' (needs -5 suffix)"
else
  pass "lib-auth.sh has no invalid anthropic/claude-sonnet-4 references"
fi

# Check generate-config.sh
if grep -q '"anthropic/claude-sonnet-4"' "$GEN_CONFIG" 2>/dev/null; then
  fail "generate-config.sh contains invalid model 'anthropic/claude-sonnet-4' (needs -5 suffix)"
else
  pass "generate-config.sh has no invalid anthropic/claude-sonnet-4 references"
fi

# Verify all model defaults end with a version segment (provider/name-version)
while IFS= read -r line; do
  model=$(echo "$line" | grep -oP '"anthropic/[^"]+"|"openai/[^"]+"|"google/[^"]+"' | tr -d '"')
  if [ -n "$model" ] && echo "$model" | grep -qP '^(anthropic|openai|google)/[a-z]+-[a-z]+-[0-9]$'; then
    fail "Model '$model' appears to be missing version suffix (e.g. -5)"
  fi
done < <(grep -n 'echo "anthropic/\|echo "openai/\|echo "google/' "$LIB_AUTH" 2>/dev/null)
pass "All model defaults in lib-auth.sh have version suffixes"

# =============================================================================
# Bug 2: Model not passed from recovery script to generate-config.sh
# Recovery found the right model but didn't pass --model to generator
# =============================================================================
echo ""
echo "=== Bug 2: Recovery passes --model to generate-config.sh ==="

# generate-config.sh must accept --model parameter
if grep -q '\-\-model)' "$GEN_CONFIG" 2>/dev/null; then
  pass "generate-config.sh accepts --model parameter"
else
  fail "generate-config.sh does not accept --model parameter"
fi

# safe-mode-recovery.sh must pass --model when calling generate-config.sh
if grep -A10 'GEN_CONFIG_SCRIPT.*--mode safe-mode' "$RECOVERY" 2>/dev/null | grep -q '\-\-model'; then
  pass "safe-mode-recovery.sh passes --model to generate-config.sh"
else
  fail "safe-mode-recovery.sh does not pass --model to generate-config.sh"
fi

# generate-config.sh safe mode section must use SM_MODEL if set
if grep -q 'SM_MODEL' "$GEN_CONFIG" 2>/dev/null; then
  pass "generate-config.sh uses SM_MODEL variable for safe mode"
else
  fail "generate-config.sh does not use SM_MODEL — model will be hardcoded"
fi

# =============================================================================
# Bug 3: Safe mode intro delivered to broken channel
# When Telegram is broken and recovery switches to Discord, the intro
# delivery must use Discord (from config), not HC_PLATFORM (habitat original)
# =============================================================================
echo ""
echo "=== Bug 3: Intro delivery uses active channel from config ==="

LIB_NOTIFY="$REPO_DIR/scripts/lib-notify.sh"

# lib-notify.sh must detect channel from config, not just use HC_PLATFORM
if grep -q 'channels.discord.enabled' "$LIB_NOTIFY" 2>/dev/null; then
  pass "lib-notify.sh checks which channels are enabled in config"
else
  fail "lib-notify.sh does not check config for enabled channels — will use HC_PLATFORM"
fi

# owner_id must be resolved AFTER channel detection
# (Discord and Telegram have different owner IDs)
NOTIFY_FUNC=$(sed -n '/^notify_send_safe_mode_intro/,/^}/p' "$LIB_NOTIFY" 2>/dev/null)
if echo "$NOTIFY_FUNC" | grep -n "get_owner_id_for_platform" | head -1 | grep -qP '^\d+:'; then
  owner_line=$(echo "$NOTIFY_FUNC" | grep -n "get_owner_id_for_platform" | head -1 | cut -d: -f1)
  channel_line=$(echo "$NOTIFY_FUNC" | grep -n "dc_enabled\|channels.*enabled" | head -1 | cut -d: -f1)
  if [ -n "$channel_line" ] && [ -n "$owner_line" ] && [ "$owner_line" -gt "$channel_line" ]; then
    pass "owner_id resolved after channel detection"
  else
    fail "owner_id resolved before channel detection — wrong owner for cross-platform fallback"
  fi
else
  fail "notify_send_safe_mode_intro doesn't call get_owner_id_for_platform"
fi

# =============================================================================
# Bug 4: E2E check didn't validate HEALTH_CHECK_OK magic word
# Agent returned 401 error, health check counted it as success
# =============================================================================
echo ""
echo "=== Bug 4: E2E validates magic word in response ==="

E2E_CHECK="$REPO_DIR/scripts/gateway-e2e-check.sh"

# The test prompt must ask for a magic word
if grep -q 'HEALTH_CHECK_OK' "$E2E_CHECK" 2>/dev/null; then
  pass "E2E test prompt includes HEALTH_CHECK_OK magic word"
else
  fail "E2E test prompt does not include magic word"
fi

# The success check must verify the magic word is in the response
# It should grep the output for HEALTH_CHECK_OK
SUCCESS_CHECK=$(grep -A2 'rc -eq 0' "$E2E_CHECK" 2>/dev/null | head -3)
if echo "$SUCCESS_CHECK" | grep -q 'HEALTH_CHECK_OK'; then
  pass "E2E success check validates HEALTH_CHECK_OK in response"
else
  fail "E2E success check does not validate magic word — broken LLM passes as healthy"
fi

# Verify the magic word check uses grep on $output (not just the exit code)
if grep 'grep.*HEALTH_CHECK_OK' "$E2E_CHECK" 2>/dev/null | grep -q 'output'; then
  pass "E2E validates magic word in agent output (not just exit code)"
else
  fail "E2E magic word check may not be checking the right variable"
fi

# =============================================================================
# Bug 5: Emergency.json fallback removed (unnecessary complexity)
# =============================================================================
echo ""
echo "=== Cleanup: Emergency config fallback removed ==="

HANDLER="$REPO_DIR/scripts/safe-mode-handler.sh"
PROVISION="$REPO_DIR/scripts/provision.sh"
PHASE1="$REPO_DIR/scripts/phase1-critical.sh"

# safe-mode-handler.sh should not reference emergency.json
if grep -q 'openclaw\.emergency\.json' "$HANDLER" 2>/dev/null; then
  fail "safe-mode-handler.sh still references emergency.json"
else
  pass "safe-mode-handler.sh does not reference emergency.json"
fi

# provision.sh should not generate emergency.json
if grep -q 'openclaw\.emergency\.json' "$PROVISION" 2>/dev/null; then
  fail "provision.sh still generates emergency.json"
else
  pass "provision.sh does not generate emergency.json"
fi

# phase1-critical.sh should not generate emergency.json
if grep -q 'openclaw\.emergency\.json' "$PHASE1" 2>/dev/null; then
  fail "phase1-critical.sh still generates emergency.json"
else
  pass "phase1-critical.sh does not generate emergency.json"
fi

# =============================================================================
# Bug 7: Safe mode bot had no exec access (couldn't run shell commands)
# generate-config.sh safe-mode was missing tools.exec config
# =============================================================================
echo ""
echo "=== Bug 7: Safe mode config includes exec access ==="

# Generate a safe-mode config and check for tools.exec
SM_CONFIG=$(AGENT_COUNT=1 AGENT1_NAME=Test AGENT1_MODEL=anthropic/claude-sonnet-4-5 \
  AGENT1_BOT_TOKEN=fake PLATFORM=telegram TELEGRAM_OWNER_ID=123 \
  "$GEN_CONFIG" --mode safe-mode --token "sk-test" --provider anthropic \
  --platform telegram --bot-token "TESTBOT" --owner-id "123" \
  --gateway-token "test-gw-token" 2>/dev/null)

if echo "$SM_CONFIG" | jq -e '.tools.exec' >/dev/null 2>&1; then
  pass "safe-mode config includes tools.exec"
else
  fail "safe-mode config missing tools.exec — bot cannot run shell commands"
fi

if echo "$SM_CONFIG" | jq -r '.tools.exec.security' 2>/dev/null | grep -q 'full'; then
  pass "safe-mode exec security is 'full'"
else
  fail "safe-mode exec security is not 'full' — bot has restricted access"
fi

if echo "$SM_CONFIG" | jq -r '.tools.exec.ask' 2>/dev/null | grep -q 'off'; then
  pass "safe-mode exec ask is 'off' (no confirmation prompts)"
else
  fail "safe-mode exec ask is not 'off' — bot will be blocked by confirmation prompts"
fi

# =============================================================================
# Bug 6: phase2-background.sh missing umask 022
# npm install -g creates files as 700 on DO images (default umask 077)
# =============================================================================
echo ""
echo "=== Bug 6: All provisioning scripts set umask 022 ==="

PHASE2="$REPO_DIR/scripts/phase2-background.sh"

# phase2-background.sh must set umask 022 before npm installs
if grep -q '^umask 022' "$PHASE2" 2>/dev/null; then
  pass "phase2-background.sh sets umask 022"
else
  fail "phase2-background.sh does not set umask 022 — npm packages will be 700"
fi

# provision.sh must set umask 022
if grep -q '^umask 022' "$PROVISION" 2>/dev/null; then
  pass "provision.sh sets umask 022"
else
  fail "provision.sh does not set umask 022"
fi

# Any temporary umask changes must be in subshells
while IFS=: read -r num line; do
  # Skip comments and the main umask 022 line
  echo "$line" | grep -q '^\s*#' && continue
  echo "$line" | grep -q '^umask 022' && continue
  # Any other umask must be inside (parentheses)
  if ! echo "$line" | grep -q '(.*umask'; then
    fail "Line $num in provision.sh has umask outside subshell: $line"
  fi
done < <(grep -n 'umask' "$PROVISION" 2>/dev/null | grep -v '^\s*#\|^umask 022\|# .*umask')
pass "All temporary umask changes in provision.sh are in subshells"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================="
echo -e "PASSED: ${GREEN}${PASSED}${NC}"
echo -e "FAILED: ${RED}${FAILED}${NC}"
echo "================================="

[ "$FAILED" -gt 0 ] && exit 1
exit 0
