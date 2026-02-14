#!/bin/bash
# =============================================================================
# test-safe-mode.sh -- TDD tests for Smart Safe Mode
# =============================================================================
# Tests token hunting, API fallback, and emergency config generation
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"

PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}✓${NC} $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

skip() {
  echo -e "${YELLOW}○${NC} $1 (skipped)"
}

# Mock functions for testing (override in tests)
MOCK_VALID_TOKENS=()
MOCK_VALID_PROVIDERS=()

# =============================================================================
# Test Setup
# =============================================================================
setup_test_env() {
  export TEST_TMPDIR=$(mktemp -d)
  export TEST_MODE=1
  
  # Create mock habitat-parsed.env
  cat > "$TEST_TMPDIR/habitat-parsed.env" <<'EOF'
HABITAT_NAME="TestHabitat"
PLATFORM="telegram"
AGENT_COUNT=3
AGENT1_NAME="Agent1"
AGENT1_BOT_TOKEN="TOKEN_1_INVALID"
AGENT1_TELEGRAM_BOT_TOKEN="TOKEN_1_INVALID"
AGENT1_DISCORD_BOT_TOKEN=""
AGENT2_NAME="Agent2"
AGENT2_BOT_TOKEN="TOKEN_2_VALID"
AGENT2_TELEGRAM_BOT_TOKEN="TOKEN_2_VALID"
AGENT2_DISCORD_BOT_TOKEN=""
AGENT3_NAME="Agent3"
AGENT3_BOT_TOKEN="TOKEN_3_INVALID"
AGENT3_TELEGRAM_BOT_TOKEN="TOKEN_3_INVALID"
AGENT3_DISCORD_BOT_TOKEN="DISCORD_TOKEN_VALID"
TELEGRAM_OWNER_ID="123456789"
DISCORD_OWNER_ID="987654321"
EOF
  
  # Set up API keys
  export ANTHROPIC_API_KEY="INVALID_ANTHROPIC_KEY"
  export OPENAI_API_KEY="VALID_OPENAI_KEY"
  export GOOGLE_API_KEY="VALID_GOOGLE_KEY"
  
  source "$TEST_TMPDIR/habitat-parsed.env"
}

cleanup_test_env() {
  rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# TOKEN HUNTING TESTS
# =============================================================================
echo ""
echo "=== Token Hunting Tests ==="

# Test: Find working Telegram token from list
test_finds_working_telegram_token() {
  setup_test_env
  
  # Source the recovery script (will be created)
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Mock: TOKEN_2_VALID is the only valid one
    mock_validate_telegram_token() {
      [ "$1" = "TOKEN_2_VALID" ] && return 0 || return 1
    }
    export -f mock_validate_telegram_token
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    
    result=$(find_working_telegram_token)
    if [ "$result" = "TOKEN_2_VALID" ]; then
      pass "finds_working_telegram_token: found TOKEN_2_VALID"
    else
      fail "finds_working_telegram_token: expected TOKEN_2_VALID, got '$result'"
    fi
  else
    fail "finds_working_telegram_token: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_finds_working_telegram_token

# Test: Find working Discord token from list
test_finds_working_discord_token() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_discord_token() {
      [ "$1" = "DISCORD_TOKEN_VALID" ] && return 0 || return 1
    }
    export -f mock_validate_discord_token
    VALIDATE_DISCORD_TOKEN_FN="mock_validate_discord_token"
    
    result=$(find_working_discord_token)
    if [ "$result" = "DISCORD_TOKEN_VALID" ]; then
      pass "finds_working_discord_token: found DISCORD_TOKEN_VALID"
    else
      fail "finds_working_discord_token: expected DISCORD_TOKEN_VALID, got '$result'"
    fi
  else
    fail "finds_working_discord_token: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_finds_working_discord_token

# Test: Returns empty when no valid tokens
test_returns_empty_when_no_valid_tokens() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_telegram_token() { return 1; }
    export -f mock_validate_telegram_token
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    
    result=$(find_working_telegram_token)
    if [ -z "$result" ]; then
      pass "returns_empty_when_no_valid_tokens: correctly returned empty"
    else
      fail "returns_empty_when_no_valid_tokens: expected empty, got '$result'"
    fi
  else
    fail "returns_empty_when_no_valid_tokens: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_returns_empty_when_no_valid_tokens

# Test: Tries tokens in order (agent1 to agentN)
test_tries_tokens_in_order() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    TOKENS_TRIED=()
    mock_validate_telegram_token() {
      TOKENS_TRIED+=("$1")
      return 1  # All fail
    }
    export -f mock_validate_telegram_token
    export TOKENS_TRIED
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    
    find_working_telegram_token >/dev/null
    
    if [ "${TOKENS_TRIED[0]}" = "TOKEN_1_INVALID" ] && \
       [ "${TOKENS_TRIED[1]}" = "TOKEN_2_VALID" ] && \
       [ "${TOKENS_TRIED[2]}" = "TOKEN_3_INVALID" ]; then
      pass "tries_tokens_in_order: correct order agent1→agent2→agent3"
    else
      fail "tries_tokens_in_order: wrong order: ${TOKENS_TRIED[*]}"
    fi
  else
    fail "tries_tokens_in_order: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_tries_tokens_in_order

# =============================================================================
# API KEY FALLBACK TESTS
# =============================================================================
echo ""
echo "=== API Key Fallback Tests ==="

# Test: Uses Anthropic if valid
test_uses_anthropic_if_valid() {
  setup_test_env
  export ANTHROPIC_API_KEY="VALID_ANTHROPIC_KEY"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_api_key() {
      [ "$1" = "anthropic" ] && [ "$2" = "VALID_ANTHROPIC_KEY" ] && return 0
      return 1
    }
    export -f mock_validate_api_key
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    result=$(find_working_api_provider)
    if [ "$result" = "anthropic" ]; then
      pass "uses_anthropic_if_valid: selected anthropic"
    else
      fail "uses_anthropic_if_valid: expected anthropic, got '$result'"
    fi
  else
    fail "uses_anthropic_if_valid: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_uses_anthropic_if_valid

# Test: Falls back to OpenAI if Anthropic fails
test_falls_back_to_openai() {
  setup_test_env
  export ANTHROPIC_API_KEY="INVALID"
  export OPENAI_API_KEY="VALID_OPENAI"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_api_key() {
      [ "$1" = "openai" ] && [ "$2" = "VALID_OPENAI" ] && return 0
      return 1
    }
    export -f mock_validate_api_key
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    result=$(find_working_api_provider)
    if [ "$result" = "openai" ]; then
      pass "falls_back_to_openai: selected openai"
    else
      fail "falls_back_to_openai: expected openai, got '$result'"
    fi
  else
    fail "falls_back_to_openai: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_falls_back_to_openai

# Test: Falls back to Gemini if OpenAI fails
test_falls_back_to_gemini() {
  setup_test_env
  export ANTHROPIC_API_KEY="INVALID"
  export OPENAI_API_KEY="INVALID"
  export GOOGLE_API_KEY="VALID_GOOGLE"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_api_key() {
      [ "$1" = "google" ] && [ "$2" = "VALID_GOOGLE" ] && return 0
      return 1
    }
    export -f mock_validate_api_key
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    result=$(find_working_api_provider)
    if [ "$result" = "google" ]; then
      pass "falls_back_to_gemini: selected google"
    else
      fail "falls_back_to_gemini: expected google, got '$result'"
    fi
  else
    fail "falls_back_to_gemini: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_falls_back_to_gemini

# Test: Returns error when all providers fail
test_all_providers_fail() {
  setup_test_env
  export ANTHROPIC_API_KEY="INVALID"
  export OPENAI_API_KEY="INVALID"
  export GOOGLE_API_KEY="INVALID"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_api_key() { return 1; }
    export -f mock_validate_api_key
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    result=$(find_working_api_provider)
    if [ -z "$result" ]; then
      pass "all_providers_fail: correctly returned empty"
    else
      fail "all_providers_fail: expected empty, got '$result'"
    fi
  else
    fail "all_providers_fail: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_all_providers_fail

# =============================================================================
# EMERGENCY CONFIG GENERATION TESTS
# =============================================================================
echo ""
echo "=== Emergency Config Generation Tests ==="

# Test: Generates config with working token and provider
test_generates_emergency_config() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    config=$(generate_emergency_config "TOKEN_2_VALID" "telegram" "openai" "VALID_OPENAI" "Agent2")
    
    if echo "$config" | jq -e '.channels.telegram.enabled == true' >/dev/null 2>&1; then
      pass "generates_emergency_config: telegram enabled"
    else
      fail "generates_emergency_config: telegram should be enabled"
    fi
    
    if echo "$config" | jq -e '.env.OPENAI_API_KEY == "VALID_OPENAI"' >/dev/null 2>&1; then
      pass "generates_emergency_config: OpenAI key set"
    else
      fail "generates_emergency_config: OpenAI key not set correctly"
    fi
  else
    fail "generates_emergency_config: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_generates_emergency_config

# Test: Uses minimal template structure
test_uses_minimal_structure() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    config=$(generate_emergency_config "TOKEN" "telegram" "anthropic" "KEY" "Bot")
    
    # Check required structure
    if echo "$config" | jq -e '.agents.list | length == 1' >/dev/null 2>&1; then
      pass "uses_minimal_structure: single agent"
    else
      fail "uses_minimal_structure: should have exactly 1 agent"
    fi
    
    if echo "$config" | jq -e '.gateway.port' >/dev/null 2>&1; then
      pass "uses_minimal_structure: has gateway.port"
    else
      fail "uses_minimal_structure: missing gateway.port"
    fi
  else
    fail "uses_minimal_structure: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_uses_minimal_structure

# Test: Sets correct port 18789
test_sets_correct_port() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    config=$(generate_emergency_config "TOKEN" "telegram" "anthropic" "KEY" "Bot")
    
    port=$(echo "$config" | jq -r '.gateway.port')
    if [ "$port" = "18789" ]; then
      pass "sets_correct_port: port is 18789"
    else
      fail "sets_correct_port: expected 18789, got '$port'"
    fi
  else
    fail "sets_correct_port: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_sets_correct_port

# =============================================================================
# INTEGRATION TESTS
# =============================================================================
echo ""
echo "=== Integration Tests ==="

# Test: Full recovery with bad primary token
test_full_recovery_bad_token() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Mock: Only TOKEN_2_VALID works, Anthropic works
    mock_validate_telegram_token() {
      [ "$1" = "TOKEN_2_VALID" ] && return 0 || return 1
    }
    mock_validate_api_key() {
      [ "$1" = "anthropic" ] && return 0 || return 1
    }
    export -f mock_validate_telegram_token mock_validate_api_key
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    result=$(run_smart_recovery)
    
    if [ "$?" = "0" ]; then
      pass "full_recovery_bad_token: recovery succeeded"
    else
      fail "full_recovery_bad_token: recovery failed"
    fi
  else
    fail "full_recovery_bad_token: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_full_recovery_bad_token

# Test: Full recovery with bad API key
test_full_recovery_bad_api_key() {
  setup_test_env
  export ANTHROPIC_API_KEY="INVALID"
  export OPENAI_API_KEY="VALID_OPENAI"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Mock: All tokens work, only OpenAI works
    mock_validate_telegram_token() { return 0; }
    mock_validate_api_key() {
      [ "$1" = "openai" ] && return 0 || return 1
    }
    export -f mock_validate_telegram_token mock_validate_api_key
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    result=$(run_smart_recovery)
    
    if [ "$?" = "0" ]; then
      pass "full_recovery_bad_api_key: recovery succeeded with OpenAI fallback"
    else
      fail "full_recovery_bad_api_key: recovery failed"
    fi
  else
    fail "full_recovery_bad_api_key: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_full_recovery_bad_api_key

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
