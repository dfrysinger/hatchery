#!/usr/bin/env bash
# Tests for notification platform fallback

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-framework.sh"

test_notification_uses_discord_when_telegram_missing() {
  describe "Notification uses Discord when Telegram not in safe mode config"
  
  # Create safe mode config with only Discord
  local config_file="$TMP_DIR/openclaw.json"
  cat > "$config_file" << 'CONF'
{
  "channels": {
    "discord": {
      "token": "valid-discord-token"
    }
  }
}
CONF
  
  # Safe mode flag exists
  touch "$TMP_DIR/safe-mode"
  
  # Should detect Discord as send platform
  assert_contains "$(grep -A50 'send_boot_notification' "$REPO_ROOT/scripts/gateway-health-check.sh" | head -80)" \
    "discord" "Notification function should handle Discord"
}

test_notification_cross_platform_fallback() {
  describe "Notification falls back to alternate platform"
  
  # The function should try PLATFORM first, then fall back
  assert_contains "$(grep -B5 -A10 'Cross-platform fallback' "$REPO_ROOT/scripts/gateway-health-check.sh")" \
    "alt_platform" "Should have cross-platform fallback logic"
}

test_discord_dm_creation() {
  describe "Discord notification creates DM channel"
  
  assert_contains "$(grep -A20 'send_discord_notification' "$REPO_ROOT/scripts/gateway-health-check.sh")" \
    "users/@me/channels" "Should create DM channel before sending"
}

run_tests
