#!/bin/bash
# =============================================================================
source "$(dirname "$0")/test-helpers.sh"
# test-health-check-e2e-fixes.sh -- Regression tests for E2E health check fixes
# =============================================================================
# Tests for bugs found during safe mode E2E testing (2026-02-19)
# Branch: feature/e2e-health-check
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"





HEALTH_CHECK="$REPO_DIR/scripts/gateway-health-check.sh"
BUILD_CONFIG="$REPO_DIR/scripts/build-full-config.sh"
SAFE_MODE_RECOVERY="$REPO_DIR/scripts/safe-mode-recovery.sh"
SETUP_SAFE_MODE="$REPO_DIR/scripts/setup-safe-mode-workspace.sh"

# =============================================================================
# Bug: bind: "lan" in build-full-config.sh (commit a521c08)
# Gateway must use loopback for CLI --deliver to work
# =============================================================================
echo ""
echo "=== Bug: Gateway bind must be loopback ==="

if grep -q '"bind": "loopback"' "$BUILD_CONFIG"; then
  pass "build-full-config.sh uses bind: loopback"
else
  fail "build-full-config.sh should use bind: loopback (not lan)"
fi

# Also check ExecStart doesn't override with --bind lan
if grep 'ExecStart.*--bind' "$BUILD_CONFIG" | grep -q 'loopback'; then
  pass "ExecStart uses --bind loopback"
else
  fail "ExecStart should use --bind loopback"
fi

# =============================================================================
# Bug: Account name "default" causes token lookup failures (commit 3eaf978)
# --reply-account agent1 can't find token named "default"
# =============================================================================
echo ""
echo "=== Bug: Account names must match agent IDs ==="

# Agent1 should use "agent1" as account name, not "default"
if grep -q '"default".*botToken.*A1_TG_TOK' "$BUILD_CONFIG"; then
  fail "Agent1 Telegram should NOT use 'default' account name"
else
  pass "Agent1 Telegram does not use 'default' account name"
fi

# Check the TA= assignment line for agent1 (escaped quotes in shell)
if grep 'TA=' "$BUILD_CONFIG" | head -1 | grep -q 'agent1.*botToken'; then
  pass "Agent1 Telegram uses 'agent1' account name"
else
  fail "Agent1 Telegram should use 'agent1' account name"
fi

# Discord too
if grep -q '"default".*token.*A1_DC_TOK' "$BUILD_CONFIG"; then
  fail "Agent1 Discord should NOT use 'default' account name"
else
  pass "Agent1 Discord does not use 'default' account name"
fi

# Check the DA= assignment line for agent1 (escaped quotes in shell)
if grep 'DA=' "$BUILD_CONFIG" | head -1 | grep -q 'agent1.*token'; then
  pass "Agent1 Discord uses 'agent1' account name"
else
  fail "Agent1 Discord should use 'agent1' account name"
fi

# =============================================================================
# Bug: Duplicate account causes 409 self-conflict (commit 3eaf978)
# Same token under both "default" and "agent1" starts 2 polling instances
# =============================================================================
echo ""
echo "=== Bug: No duplicate token entries ==="

# Count how many times agent1's token variable appears in account definitions
TG_ACCOUNT_COUNT=$(grep -c 'A1_TG_TOK_ESC' "$BUILD_CONFIG" | head -1)
if [ "$TG_ACCOUNT_COUNT" -le 2 ]; then
  # One for the variable assignment, one for the account entry
  pass "Agent1 Telegram token appears at most twice (assign + use)"
else
  fail "Agent1 Telegram token appears $TG_ACCOUNT_COUNT times (duplicate accounts?)"
fi

# =============================================================================
# Bug: Safe mode recovery uses "default" account (commit 94e1587)
# --reply-account safe-mode can't find token named "default"
# =============================================================================
echo ""
echo "=== Bug: Safe mode recovery account naming ==="

# Telegram safe-mode account (escaped quotes in heredoc)
if grep -q 'safe-mode.*botToken' "$SAFE_MODE_RECOVERY"; then
  pass "Safe mode recovery uses 'safe-mode' Telegram account name"
else
  fail "Safe mode recovery should use 'safe-mode' Telegram account name"
fi

# Discord safe-mode account (escaped quotes: \"safe-mode\": { \"token\")
if grep 'safe-mode.*token' "$SAFE_MODE_RECOVERY" | grep -qv 'botToken'; then
  pass "Safe mode recovery uses 'safe-mode' Discord account name"
else
  fail "Safe mode recovery should use 'safe-mode' Discord account name"
fi

# Should NOT have accounts.default for Telegram in recovery
if grep -B2 -A2 'botToken.*\${token}' "$SAFE_MODE_RECOVERY" | grep -q '"default"'; then
  fail "Safe mode recovery should NOT use 'default' for Telegram account"
else
  pass "Safe mode recovery does not use 'default' for Telegram account"
fi

# =============================================================================
# Bug: Chat token validation skipped in normal mode (commit 5020df6)
# OpenClaw delivery fallback masks broken tokens
# =============================================================================
echo ""
echo "=== Bug: Chat tokens must be validated before E2E ==="

# check_channel_connectivity must be called before check_agents_e2e in normal mode
if grep -B5 'check_agents_e2e' "$HEALTH_CHECK" | grep -q 'check_channel_connectivity'; then
  pass "check_channel_connectivity called before check_agents_e2e"
else
  fail "check_channel_connectivity must be called before check_agents_e2e"
fi

# Verify the flow: token validation failure skips E2E
if grep -A3 'check_channel_connectivity' "$HEALTH_CHECK" | grep -q 'return 1\|marking unhealthy'; then
  pass "Token validation failure skips E2E and marks unhealthy"
else
  fail "Token validation failure should skip E2E and mark unhealthy"
fi

# =============================================================================
# Bug: check_channel_connectivity only checks configured platform
# =============================================================================
echo ""
echo "=== Platform-aware token validation ==="

# Verify platform conditional for telegram
if grep -A3 'platform.*telegram.*both' "$HEALTH_CHECK" | head -5 | grep -q 'TELEGRAM_BOT_TOKEN\|tg_token'; then
  pass "Token validation checks Telegram when platform=telegram"
else
  fail "Token validation should check Telegram tokens for platform=telegram"
fi

# Verify platform conditional for discord
if grep -A3 'platform.*discord.*both' "$HEALTH_CHECK" | head -5 | grep -q 'DISCORD_BOT_TOKEN\|dc_token'; then
  pass "Token validation checks Discord when platform=discord"
else
  fail "Token validation should check Discord tokens for platform=discord"
fi

# Verify missing token fails (empty token = agent fails)
# The logic: if token is empty, agent_valid stays false → failure
if grep -q 'if \[ -n "\$tg_token" \]' "$HEALTH_CHECK"; then
  pass "Empty Telegram token is treated as failure (agent_valid stays false)"
else
  fail "Empty token should leave agent_valid as false"
fi

# =============================================================================
# Bug: Safe mode script notification was skipped (commit a2eb133)
# safe-mode case assumed pre-warning was sent but it was deferred
# =============================================================================
echo ""
echo "=== Bug: Safe mode script notification must be sent ==="

# The safe-mode case in send_boot_notification should send a Telegram/Discord notification
# Look for send_telegram_notification or send_discord_notification in the safe-mode case
SAFE_MODE_CASE=$(sed -n '/^    safe-mode)/,/^    ;;/p' "$HEALTH_CHECK")

if echo "$SAFE_MODE_CASE" | grep -q 'send_telegram_notification\|send_discord_notification'; then
  pass "Safe-mode case sends script notification via raw API"
else
  fail "Safe-mode case should send script notification via Telegram/Discord API"
fi

# Also must trigger SafeModeBot intro
if echo "$SAFE_MODE_CASE" | grep -q 'openclaw agent.*deliver.*safe-mode'; then
  pass "Safe-mode case triggers SafeModeBot intro via --deliver"
else
  fail "Safe-mode case should trigger SafeModeBot intro via openclaw agent --deliver"
fi

# =============================================================================
# Bug: Duplicate notifications (marker file check)
# =============================================================================
echo ""
echo "=== Duplicate notification prevention ==="

if grep -q 'notification-sent-\${status}' "$HEALTH_CHECK"; then
  pass "Notification uses status-specific marker file"
else
  fail "Notification should use notification-sent-\${status} marker"
fi

if grep -B2 'Notification already sent' "$HEALTH_CHECK" | grep -q 'notification_file'; then
  pass "Checks marker file before sending notification"
else
  fail "Should check notification marker file to prevent duplicates"
fi

# =============================================================================
# Bug: Health check log not readable by bot user (commit 5e75a8d)
# =============================================================================
echo ""
echo "=== Bug: Health check log must be readable by bot ==="

if grep -q 'chmod 644.*\$LOG' "$HEALTH_CHECK"; then
  pass "Health check log uses chmod 644 (world-readable)"
else
  fail "Health check log should use chmod 644, not 600"
fi

# Must NOT have umask 077 before the log touch
if grep -B3 'touch.*\$LOG.*chmod' "$HEALTH_CHECK" | grep -q 'umask 077'; then
  fail "Should not have umask 077 before log creation"
else
  pass "No umask 077 before log creation"
fi

# =============================================================================
# Bug: Token lookup in safe mode config must check accounts.safe-mode
# =============================================================================
echo ""
echo "=== Safe mode token lookup paths ==="

# Health check should look for accounts["safe-mode"] when reading safe mode config
if grep -q 'accounts\["safe-mode"\]' "$HEALTH_CHECK"; then
  pass "Health check looks for accounts[\"safe-mode\"] in safe mode config"
else
  fail "Health check should look for accounts[\"safe-mode\"] in token lookups"
fi

# send_entering_safe_mode_warning should also check accounts["safe-mode"]
if grep -A20 'send_entering_safe_mode_warning' "$HEALTH_CHECK" | grep -q 'accounts.*safe-mode'; then
  pass "Pre-warning function checks safe-mode accounts"
else
  fail "Pre-warning function should check accounts[\"safe-mode\"]"
fi

# =============================================================================
# Integration: Full flow - broken token → safe mode → notification + intro
# =============================================================================
echo ""
echo "=== Integration: Broken token triggers full safe mode flow ==="

# Verify the decision tree: unhealthy → enter_safe_mode is called
if grep -q 'enter_safe_mode' "$HEALTH_CHECK"; then
  pass "enter_safe_mode function exists and is called"
else
  fail "enter_safe_mode should be called when unhealthy"
fi

# Verify: safe mode stable path exists and uses send_boot_notification
if grep -A10 'SAFE MODE STABLE' "$HEALTH_CHECK" | grep -q 'send_boot_notification\|EXIT_CODE=0'; then
  pass "Safe mode stable sends notification and exits cleanly"
else
  fail "Safe mode stable should send notification and exit 0"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "E2E Health Check Fix Tests Complete"
echo "========================================="
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo ""

exit $FAILED
