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
    # New format: agent_num:token
    if [ "$result" = "2:TOKEN_2_VALID" ]; then
      pass "finds_working_telegram_token: found Agent2's token"
    else
      fail "finds_working_telegram_token: expected '2:TOKEN_2_VALID', got '$result'"
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
    # New format: agent_num:token
    if [ "$result" = "3:DISCORD_TOKEN_VALID" ]; then
      pass "finds_working_discord_token: found Agent3's token"
    else
      fail "finds_working_discord_token: expected '3:DISCORD_TOKEN_VALID', got '$result'"
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

# Test: Cross-platform fallback (TG fails, DC succeeds)
test_cross_platform_fallback() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Mock: All Telegram tokens fail, Discord token works
    mock_validate_telegram_token() { return 1; }
    mock_validate_discord_token() {
      [ "$1" = "DISCORD_TOKEN_VALID" ] && return 0 || return 1
    }
    export -f mock_validate_telegram_token mock_validate_discord_token
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    VALIDATE_DISCORD_TOKEN_FN="mock_validate_discord_token"
    
    result=$(find_working_platform_and_token)
    # New format: platform:agent_num:token
    if [ "$result" = "discord:3:DISCORD_TOKEN_VALID" ]; then
      pass "cross_platform_fallback: found Discord after Telegram failed"
    else
      fail "cross_platform_fallback: expected 'discord:3:DISCORD_TOKEN_VALID', got '$result'"
    fi
  else
    fail "cross_platform_fallback: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_cross_platform_fallback

# Test: Returns platform:token format
test_platform_token_format() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    mock_validate_telegram_token() {
      [ "$1" = "TOKEN_2_VALID" ] && return 0 || return 1
    }
    export -f mock_validate_telegram_token
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    
    result=$(find_working_platform_and_token)
    if [[ "$result" == "telegram:"* ]]; then
      pass "platform_token_format: returns 'platform:token' format"
    else
      fail "platform_token_format: expected 'telegram:...' format, got '$result'"
    fi
  else
    fail "platform_token_format: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_platform_token_format

# Test: User preferred platform is tried first (Discord)
# When PLATFORM=discord, Discord token should be found before Telegram is tried
test_user_preferred_platform_discord() {
  setup_test_env
  export PLATFORM="discord"  # User's default
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Discord token works, Telegram should NOT be tried
    mock_validate_telegram_token() { return 1; }
    mock_validate_discord_token() { 
      [ "$1" = "DISCORD_TOKEN_VALID" ] && return 0 || return 1
    }
    export -f mock_validate_telegram_token mock_validate_discord_token
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    VALIDATE_DISCORD_TOKEN_FN="mock_validate_discord_token"
    
    result=$(find_working_platform_and_token)
    
    # Should find discord token (not fall back to telegram)
    if [[ "$result" == "discord:"* ]]; then
      pass "user_preferred_platform_discord: discord tried first when PLATFORM=discord"
    else
      fail "user_preferred_platform_discord: expected discord:..., got '$result'"
    fi
  else
    fail "user_preferred_platform_discord: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_user_preferred_platform_discord

# Test: Default platform is telegram when not set
test_default_platform_telegram() {
  setup_test_env
  unset PLATFORM  # No default set
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Telegram token works, Discord should NOT be tried
    mock_validate_telegram_token() {
      [ "$1" = "TOKEN_2_VALID" ] && return 0 || return 1
    }
    mock_validate_discord_token() { return 1; }
    export -f mock_validate_telegram_token mock_validate_discord_token
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    VALIDATE_DISCORD_TOKEN_FN="mock_validate_discord_token"
    
    result=$(find_working_platform_and_token)
    
    # Should find telegram token
    if [[ "$result" == "telegram:"* ]]; then
      pass "default_platform_telegram: telegram tried first when PLATFORM unset"
    else
      fail "default_platform_telegram: expected telegram:..., got '$result'"
    fi
  else
    fail "default_platform_telegram: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_default_platform_telegram

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

# Test: Provider order respects user's default (anthropic model → anthropic first)
test_api_provider_order_user_default_anthropic() {
  setup_test_env
  export AGENT1_MODEL="anthropic/claude-opus-4-5"
  export ANTHROPIC_API_KEY="KEY_A"
  export OPENAI_API_KEY="KEY_O"
  export GOOGLE_API_KEY="KEY_G"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    PROVIDERS_TRIED=()
    mock_validate_api_key() {
      PROVIDERS_TRIED+=("$1")
      return 1  # All fail
    }
    export -f mock_validate_api_key
    export PROVIDERS_TRIED
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    find_working_api_provider >/dev/null
    
    # With anthropic model, order should be: anthropic → openai → google
    if [ "${PROVIDERS_TRIED[0]}" = "anthropic" ]; then
      pass "api_provider_order_user_default_anthropic: anthropic tried first"
    else
      fail "api_provider_order_user_default_anthropic: expected anthropic first, got ${PROVIDERS_TRIED[0]}"
    fi
  else
    fail "api_provider_order_user_default_anthropic: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_api_provider_order_user_default_anthropic

# Test: Provider order respects user's default (openai model → openai first)
test_api_provider_order_user_default_openai() {
  setup_test_env
  export AGENT1_MODEL="openai/gpt-4o"
  export ANTHROPIC_API_KEY="KEY_A"
  export OPENAI_API_KEY="KEY_O"
  export GOOGLE_API_KEY="KEY_G"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    PROVIDERS_TRIED=()
    mock_validate_api_key() {
      PROVIDERS_TRIED+=("$1")
      return 1  # All fail
    }
    export -f mock_validate_api_key
    export PROVIDERS_TRIED
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    find_working_api_provider >/dev/null
    
    # With openai model, order should be: openai → google → anthropic
    if [ "${PROVIDERS_TRIED[0]}" = "openai" ]; then
      pass "api_provider_order_user_default_openai: openai tried first"
    else
      fail "api_provider_order_user_default_openai: expected openai first, got ${PROVIDERS_TRIED[0]}"
    fi
  else
    fail "api_provider_order_user_default_openai: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_api_provider_order_user_default_openai

# Test: Provider order respects user's default (google model → google first)
test_api_provider_order_user_default_google() {
  setup_test_env
  export AGENT1_MODEL="google/gemini-2.0-flash"
  export ANTHROPIC_API_KEY="KEY_A"
  export OPENAI_API_KEY="KEY_O"
  export GOOGLE_API_KEY="KEY_G"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    PROVIDERS_TRIED=()
    mock_validate_api_key() {
      PROVIDERS_TRIED+=("$1")
      return 1  # All fail
    }
    export -f mock_validate_api_key
    export PROVIDERS_TRIED
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    find_working_api_provider >/dev/null
    
    # With google model, order should be: google → openai → anthropic
    if [ "${PROVIDERS_TRIED[0]}" = "google" ]; then
      pass "api_provider_order_user_default_google: google tried first"
    else
      fail "api_provider_order_user_default_google: expected google first, got ${PROVIDERS_TRIED[0]}"
    fi
  else
    fail "api_provider_order_user_default_google: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_api_provider_order_user_default_google

# Test: Model selection finds user's configured model for provider
test_model_selection_finds_user_model() {
  setup_test_env
  export AGENT1_MODEL="anthropic/claude-opus-4-5"
  export AGENT2_MODEL="openai/gpt-4o"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    model=$(find_working_model_for_provider "anthropic")
    if [ "$model" = "anthropic/claude-opus-4-5" ]; then
      pass "model_selection_finds_user_model: found user's anthropic model"
    else
      fail "model_selection_finds_user_model: expected 'anthropic/claude-opus-4-5', got '$model'"
    fi
  else
    fail "model_selection_finds_user_model: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_model_selection_finds_user_model

# Test: Model selection falls back to hardcoded when no user model for provider
test_model_selection_fallback_to_hardcoded() {
  setup_test_env
  export AGENT1_MODEL="anthropic/claude-opus-4-5"
  # No openai model configured
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    model=$(find_working_model_for_provider "openai")
    if [ "$model" = "openai/gpt-4o" ]; then
      pass "model_selection_fallback_to_hardcoded: fell back to hardcoded openai model"
    else
      fail "model_selection_fallback_to_hardcoded: expected 'openai/gpt-4o', got '$model'"
    fi
  else
    fail "model_selection_fallback_to_hardcoded: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_model_selection_fallback_to_hardcoded

# Test: Collects all configured models from habitat
test_get_all_configured_models() {
  setup_test_env
  export AGENT_COUNT=3
  export AGENT1_MODEL="anthropic/claude-opus-4-5"
  export AGENT2_MODEL="openai/gpt-4o"
  export AGENT3_MODEL="anthropic/claude-sonnet-4-5"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    models=$(get_all_configured_models)
    # Should have 3 unique models (agent1, agent2, agent3)
    model_count=$(echo "$models" | wc -w)
    if [ "$model_count" -eq 3 ]; then
      pass "get_all_configured_models: found all 3 models"
    else
      fail "get_all_configured_models: expected 3 models, got $model_count: $models"
    fi
  else
    fail "get_all_configured_models: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_get_all_configured_models

# Test: Tries providers in correct order (default - no model set)
test_api_provider_order() {
  setup_test_env
  # No AGENT1_MODEL set - should default to anthropic
  export ANTHROPIC_API_KEY="KEY_A"
  export OPENAI_API_KEY="KEY_O"
  export GOOGLE_API_KEY="KEY_G"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    PROVIDERS_TRIED=()
    mock_validate_api_key() {
      PROVIDERS_TRIED+=("$1")
      return 1  # All fail
    }
    export -f mock_validate_api_key
    export PROVIDERS_TRIED
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    find_working_api_provider >/dev/null
    
    if [ "${PROVIDERS_TRIED[0]}" = "anthropic" ] && \
       [ "${PROVIDERS_TRIED[1]}" = "openai" ] && \
       [ "${PROVIDERS_TRIED[2]}" = "google" ]; then
      pass "api_provider_order: correct order anthropic→openai→google"
    else
      fail "api_provider_order: wrong order: ${PROVIDERS_TRIED[*]}"
    fi
  else
    fail "api_provider_order: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_api_provider_order

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

# Test: OAuth profile detection
test_oauth_profile_detection() {
  setup_test_env
  export TEST_OAUTH=1  # Enable OAuth checking for this test
  
  # Create mock auth-profiles.json with OAuth token
  mkdir -p "$TEST_TMPDIR/.openclaw/agents/agent1/agent"
  cat > "$TEST_TMPDIR/.openclaw/agents/agent1/agent/auth-profiles.json" <<'EOF'
{
  "version": 1,
  "profiles": {
    "openai-codex:default": {
      "type": "oauth",
      "provider": "openai-codex",
      "access": "valid-oauth-token",
      "refresh": "refresh-token",
      "expires": 9999999999999
    }
  }
}
EOF
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # No API keys set - should find OAuth
    unset ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY
    export HOME_DIR="$TEST_TMPDIR"
    
    result=$(check_oauth_profile "openai")
    # New format: "oauth:<actual_provider>" - openai maps to openai-codex
    if [ "$result" = "oauth:openai-codex" ]; then
      pass "oauth_profile_detection: found OpenAI OAuth profile → openai-codex"
    else
      fail "oauth_profile_detection: expected 'oauth:openai-codex', got '$result'"
    fi
  else
    fail "oauth_profile_detection: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_oauth_profile_detection

# Test: OAuth preferred over API key
test_oauth_preferred_over_apikey() {
  setup_test_env
  export TEST_OAUTH=1  # Enable OAuth checking for this test
  
  # Create mock auth-profiles.json with OAuth token
  mkdir -p "$TEST_TMPDIR/.openclaw/agents/agent1/agent"
  cat > "$TEST_TMPDIR/.openclaw/agents/agent1/agent/auth-profiles.json" <<'EOF'
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "oauth",
      "provider": "anthropic",
      "access": "valid-oauth-token",
      "expires": 9999999999999
    }
  }
}
EOF
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Set API key too - OAuth should be preferred
    export ANTHROPIC_API_KEY="also-valid-key"
    export HOME_DIR="$TEST_TMPDIR"
    
    # Mock: API key validation would pass
    mock_validate_api_key() { return 0; }
    export -f mock_validate_api_key
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    auth_type=$(get_auth_type_for_provider "anthropic")
    if [ "$auth_type" = "oauth" ]; then
      pass "oauth_preferred_over_apikey: OAuth selected over API key"
    else
      fail "oauth_preferred_over_apikey: expected 'oauth', got '$auth_type'"
    fi
  else
    fail "oauth_preferred_over_apikey: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_oauth_preferred_over_apikey

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
# RESILIENCE TESTS
# =============================================================================
echo ""
echo "=== Resilience Tests ==="

# Test: Config JSON validation
test_config_json_validation() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Valid JSON
    if validate_config_json '{"test": true}'; then
      pass "config_json_validation: accepts valid JSON"
    else
      fail "config_json_validation: rejected valid JSON"
    fi
    
    # Invalid JSON
    if ! validate_config_json '{invalid json'; then
      pass "config_json_validation: rejects invalid JSON"
    else
      fail "config_json_validation: accepted invalid JSON"
    fi
  else
    fail "config_json_validation: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_config_json_validation

# Test: Network check function exists
test_network_check_exists() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    if type check_network &>/dev/null; then
      pass "network_check_exists: check_network function exists"
    else
      fail "network_check_exists: check_network function not found"
    fi
  else
    fail "network_check_exists: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_network_check_exists

# Test: Full recovery escalation function exists
test_full_recovery_escalation_exists() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    if type run_full_recovery_escalation &>/dev/null; then
      pass "full_recovery_escalation_exists: function exists"
    else
      fail "full_recovery_escalation_exists: function not found"
    fi
  else
    fail "full_recovery_escalation_exists: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_full_recovery_escalation_exists

# Test: Notify user function
test_notify_user_function() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    result=$(notify_user_emergency "Test message" 2>&1)
    if [[ "$result" == *"Test message"* ]]; then
      pass "notify_user_function: correctly outputs message in test mode"
    else
      fail "notify_user_function: expected message output, got '$result'"
    fi
  else
    fail "notify_user_function: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_notify_user_function

# =============================================================================
# SAFE MODE WORKSPACE TESTS
# =============================================================================
echo ""
echo "=== Safe Mode Workspace Tests ==="

# Test: Emergency config uses safe-mode agent ID
test_emergency_config_uses_safe_mode_agent_id() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    config=$(generate_emergency_config "TOKEN" "telegram" "anthropic" "KEY" "OriginalName")
    
    agent_id=$(echo "$config" | jq -r '.agents.list[0].id')
    if [ "$agent_id" = "safe-mode" ]; then
      pass "emergency_config_uses_safe_mode_agent_id: agent id is 'safe-mode'"
    else
      fail "emergency_config_uses_safe_mode_agent_id: expected 'safe-mode', got '$agent_id'"
    fi
  else
    fail "emergency_config_uses_safe_mode_agent_id: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_emergency_config_uses_safe_mode_agent_id

# Test: Emergency config uses SafeModeBot name
test_emergency_config_uses_safemode_name() {
  setup_test_env
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Even if we pass an agent name, it should use SafeModeBot
    config=$(generate_emergency_config "TOKEN" "telegram" "anthropic" "KEY" "SomeOtherAgent")
    
    agent_name=$(echo "$config" | jq -r '.agents.list[0].name')
    if [ "$agent_name" = "SafeModeBot" ]; then
      pass "emergency_config_uses_safemode_name: agent name is 'SafeModeBot'"
    else
      fail "emergency_config_uses_safemode_name: expected 'SafeModeBot', got '$agent_name'"
    fi
  else
    fail "emergency_config_uses_safemode_name: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_emergency_config_uses_safemode_name

# Test: Emergency config uses safe-mode workspace path
test_emergency_config_uses_safe_mode_workspace() {
  setup_test_env
  export HOME_DIR="$TEST_TMPDIR/home"
  mkdir -p "$HOME_DIR"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    config=$(generate_emergency_config "TOKEN" "telegram" "anthropic" "KEY" "Agent")
    
    workspace=$(echo "$config" | jq -r '.agents.list[0].workspace')
    if [[ "$workspace" == */clawd/agents/safe-mode ]]; then
      pass "emergency_config_uses_safe_mode_workspace: workspace ends with '/clawd/agents/safe-mode'"
    else
      fail "emergency_config_uses_safe_mode_workspace: expected '*/clawd/agents/safe-mode', got '$workspace'"
    fi
  else
    fail "emergency_config_uses_safe_mode_workspace: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_emergency_config_uses_safe_mode_workspace

# Test: setup_safe_mode_workspace creates directory structure
test_setup_safe_mode_workspace_creates_structure() {
  setup_test_env
  export HOME_DIR="$TEST_TMPDIR/home"
  export USERNAME="testbot"
  mkdir -p "$HOME_DIR"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    setup_safe_mode_workspace >/dev/null 2>&1
    
    if [ -d "$HOME_DIR/clawd/agents/safe-mode" ]; then
      pass "setup_safe_mode_workspace_creates_structure: safe-mode directory exists"
    else
      fail "setup_safe_mode_workspace_creates_structure: safe-mode directory not created"
    fi
    
    if [ -d "$HOME_DIR/clawd/agents/safe-mode/memory" ]; then
      pass "setup_safe_mode_workspace_creates_structure: memory directory exists"
    else
      fail "setup_safe_mode_workspace_creates_structure: memory directory not created"
    fi
  else
    fail "setup_safe_mode_workspace_creates_structure: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_setup_safe_mode_workspace_creates_structure

# Test: setup_safe_mode_workspace creates IDENTITY.md
test_setup_safe_mode_workspace_creates_identity() {
  setup_test_env
  export HOME_DIR="$TEST_TMPDIR/home"
  export USERNAME="testbot"
  mkdir -p "$HOME_DIR"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    setup_safe_mode_workspace >/dev/null 2>&1
    
    identity_file="$HOME_DIR/clawd/agents/safe-mode/IDENTITY.md"
    if [ -f "$identity_file" ]; then
      pass "setup_safe_mode_workspace_creates_identity: IDENTITY.md exists"
      
      if grep -q "Safe Mode Recovery Bot" "$identity_file"; then
        pass "setup_safe_mode_workspace_creates_identity: contains 'Safe Mode Recovery Bot'"
      else
        fail "setup_safe_mode_workspace_creates_identity: missing 'Safe Mode Recovery Bot' text"
      fi
    else
      fail "setup_safe_mode_workspace_creates_identity: IDENTITY.md not created"
    fi
  else
    fail "setup_safe_mode_workspace_creates_identity: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_setup_safe_mode_workspace_creates_identity

# Test: setup_safe_mode_workspace creates SOUL.md
test_setup_safe_mode_workspace_creates_soul() {
  setup_test_env
  export HOME_DIR="$TEST_TMPDIR/home"
  export USERNAME="testbot"
  mkdir -p "$HOME_DIR"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    setup_safe_mode_workspace >/dev/null 2>&1
    
    soul_file="$HOME_DIR/clawd/agents/safe-mode/SOUL.md"
    if [ -f "$soul_file" ]; then
      pass "setup_safe_mode_workspace_creates_soul: SOUL.md exists"
    else
      fail "setup_safe_mode_workspace_creates_soul: SOUL.md not created"
    fi
  else
    fail "setup_safe_mode_workspace_creates_soul: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_setup_safe_mode_workspace_creates_soul

# Test: Smart recovery does NOT use original agent's identity
test_smart_recovery_uses_safemode_identity() {
  setup_test_env
  export HOME_DIR="$TEST_TMPDIR/home"
  export USERNAME="testbot"
  export DRY_RUN=1
  mkdir -p "$HOME_DIR/.openclaw"
  
  if [ -f "$REPO_DIR/scripts/safe-mode-recovery.sh" ]; then
    source "$REPO_DIR/scripts/safe-mode-recovery.sh"
    
    # Mock: All tokens valid, all providers valid
    mock_validate_telegram_token() { return 0; }
    mock_validate_api_key() { return 0; }
    export -f mock_validate_telegram_token mock_validate_api_key
    VALIDATE_TELEGRAM_TOKEN_FN="mock_validate_telegram_token"
    VALIDATE_API_KEY_FN="mock_validate_api_key"
    
    run_smart_recovery >/dev/null 2>&1
    
    # Check that safe-mode workspace was created
    if [ -d "$HOME_DIR/clawd/agents/safe-mode" ]; then
      pass "smart_recovery_uses_safemode_identity: creates safe-mode workspace"
    else
      fail "smart_recovery_uses_safemode_identity: did not create safe-mode workspace"
    fi
  else
    fail "smart_recovery_uses_safemode_identity: safe-mode-recovery.sh not found"
  fi
  
  cleanup_test_env
}
test_smart_recovery_uses_safemode_identity

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
