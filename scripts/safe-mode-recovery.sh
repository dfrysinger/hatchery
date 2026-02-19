#!/bin/bash
# shellcheck disable=SC2155  # Declare and assign separately - acceptable here as we don't check return values
# =============================================================================
# safe-mode-recovery.sh -- Smart Safe Mode Recovery
# =============================================================================
# Purpose:  When full config fails, intelligently find working credentials
#           and generate an emergency config to get a bot online.
#
# Features:
#   - Token hunting: Try all bot tokens (TG + Discord) until one works
#   - API fallback: Try Anthropic → OpenAI → Gemini (OAuth + API keys)
#   - Emergency config: Generate minimal working config
#   - Network check: Verify connectivity before API validation
#   - Config validation: Verify JSON syntax before applying
#   - Doctor fix: Run openclaw doctor --fix as last resort
#   - State cleanup: Clear corrupted state if needed
#
# Usage:    source safe-mode-recovery.sh
#           run_smart_recovery
#
# Requires: /etc/habitat-parsed.env to be sourced first
# =============================================================================

# Allow mock functions for testing
VALIDATE_TELEGRAM_TOKEN_FN="${VALIDATE_TELEGRAM_TOKEN_FN:-validate_telegram_token}"
VALIDATE_DISCORD_TOKEN_FN="${VALIDATE_DISCORD_TOKEN_FN:-validate_discord_token}"
VALIDATE_API_KEY_FN="${VALIDATE_API_KEY_FN:-validate_api_key}"

# =============================================================================
# Globals & Cross-Function State
# =============================================================================
# IMPORTANT: Many functions set global variables instead of returning values.
# This is intentional - Bash loses variable assignments made in subshells, so
# patterns like `result=$(some_func)` would discard side effects.
#
# Key globals set by functions:
#   VALIDATION_REASON     - Why the last validation failed (set by validate_*)
#   FOUND_TOKEN_RESULT    - Result of token hunting (platform:agent:token)
#   FOUND_API_PROVIDER    - Result of API provider search
#   OAUTH_CHECK_RESULT    - Result of OAuth profile check (oauth:provider)
#   DIAG_*                - Diagnostic accumulator arrays
#
# Rule: Call these functions directly (not in subshells) when you need their
# side effects. Use `local var; var=$(func)` only for pure return values.
# =============================================================================

# Diagnostics tracking - accumulates validation results for boot report
declare -a DIAG_TELEGRAM_RESULTS=()
declare -a DIAG_DISCORD_RESULTS=()
declare -a DIAG_API_RESULTS=()
DIAG_DOCTOR_RAN=""
DIAG_DOCTOR_RESULT=""
DIAG_NETWORK_OK=""

# Add a diagnostic result
# Usage: diag_add "telegram" "agent1" "✅" "valid"
#        diag_add "api" "anthropic" "❌" "401 unauthorized"
diag_add() {
  local category="$1"
  local name="$2"
  local icon="$3"
  local reason="$4"
  local entry="${name}:${icon}:${reason}"
  
  case "$category" in
    telegram) DIAG_TELEGRAM_RESULTS+=("$entry") ;;
    discord)  DIAG_DISCORD_RESULTS+=("$entry") ;;
    api)      DIAG_API_RESULTS+=("$entry") ;;
  esac
}

# Write diagnostics summary to file for boot report
write_diagnostics_summary() {
  local output_file="${1:-/var/log/safe-mode-diagnostics.txt}"
  
  {
    echo "🔍 Recovery diagnostics:"
    
    # Telegram tokens - one per line
    echo "  Telegram:"
    if [ ${#DIAG_TELEGRAM_RESULTS[@]} -gt 0 ]; then
      for entry in "${DIAG_TELEGRAM_RESULTS[@]}"; do
        local name="${entry%%:*}"
        local rest="${entry#*:}"
        local icon="${rest%%:*}"
        local reason="${rest#*:}"
        if [ -n "$reason" ] && [ "$reason" != "valid" ]; then
          echo "    ${icon} ${name} (${reason})"
        else
          echo "    ${icon} ${name}"
        fi
      done
    else
      echo "    (none configured)"
    fi
    
    # Discord tokens - one per line
    echo "  Discord:"
    if [ ${#DIAG_DISCORD_RESULTS[@]} -gt 0 ]; then
      for entry in "${DIAG_DISCORD_RESULTS[@]}"; do
        local name="${entry%%:*}"
        local rest="${entry#*:}"
        local icon="${rest%%:*}"
        local reason="${rest#*:}"
        if [ -n "$reason" ] && [ "$reason" != "valid" ]; then
          echo "    ${icon} ${name} (${reason})"
        else
          echo "    ${icon} ${name}"
        fi
      done
    else
      echo "    (none configured)"
    fi
    
    # API providers - one per line
    echo "  API:"
    if [ ${#DIAG_API_RESULTS[@]} -gt 0 ]; then
      for entry in "${DIAG_API_RESULTS[@]}"; do
        local name="${entry%%:*}"
        local rest="${entry#*:}"
        local icon="${rest%%:*}"
        local reason="${rest#*:}"
        if [ -n "$reason" ] && [ "$reason" != "valid" ]; then
          echo "    ${icon} ${name} (${reason})"
        else
          echo "    ${icon} ${name}"
        fi
      done
    else
      echo "    (none found)"
    fi
    
    # Doctor status
    if [ -n "$DIAG_DOCTOR_RAN" ]; then
      echo "  Doctor: ran (${DIAG_DOCTOR_RESULT:-no issues})"
    fi
    
    # Network status
    if [ -n "$DIAG_NETWORK_OK" ]; then
      if [ "$DIAG_NETWORK_OK" = "yes" ]; then
        echo "  Network: ✅ OK"
      else
        echo "  Network: ❌ Issues detected"
      fi
    fi
    
  } > "$output_file"
  
  # Also return for inline use
  cat "$output_file"
}

# =============================================================================
# Token Validation Functions
# =============================================================================

# Validate a Telegram bot token by calling getMe
# Returns: 0=valid, 1=invalid
# Sets: VALIDATION_REASON with status/error details
validate_telegram_token() {
  local token="$1"
  
  if [ -z "$token" ]; then
    VALIDATION_REASON="empty"
    return 1
  fi
  
  # In test mode, use mock
  if [ "${TEST_MODE:-}" = "1" ]; then
    VALIDATION_REASON="test-mode"
    return 1
  fi
  
  local http_code response
  response=$(curl -s --max-time 10 -w "\n%{http_code}" "https://api.telegram.org/bot${token}/getMe" 2>/dev/null)
  http_code=$(echo "$response" | tail -1)
  response=$(echo "$response" | head -n -1)
  
  case "$http_code" in
    200)
      if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        VALIDATION_REASON="valid"
        return 0
      else
        VALIDATION_REASON="invalid response"
        return 1
      fi
      ;;
    401) VALIDATION_REASON="401 unauthorized"; return 1 ;;
    403) VALIDATION_REASON="403 forbidden"; return 1 ;;
    404) VALIDATION_REASON="404 not found"; return 1 ;;
    409) VALIDATION_REASON="409 conflict"; return 1 ;;
    000) VALIDATION_REASON="timeout"; return 1 ;;
    *)   VALIDATION_REASON="http ${http_code}"; return 1 ;;
  esac
}

# Validate a Discord bot token by calling /users/@me
validate_discord_token() {
  local token="$1"
  
  if [ -z "$token" ]; then
    VALIDATION_REASON="empty"
    return 1
  fi
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    VALIDATION_REASON="test-mode"
    return 1
  fi
  
  local http_code response
  response=$(curl -s --max-time 10 -w "\n%{http_code}" \
    -H "Authorization: Bot ${token}" \
    "https://discord.com/api/v10/users/@me" 2>/dev/null)
  http_code=$(echo "$response" | tail -1)
  response=$(echo "$response" | head -n -1)
  
  case "$http_code" in
    200)
      if echo "$response" | jq -e '.id' >/dev/null 2>&1; then
        VALIDATION_REASON="valid"
        return 0
      else
        VALIDATION_REASON="invalid response"
        return 1
      fi
      ;;
    401) VALIDATION_REASON="401 unauthorized"; return 1 ;;
    403) VALIDATION_REASON="403 forbidden"; return 1 ;;
    000) VALIDATION_REASON="timeout"; return 1 ;;
    *)   VALIDATION_REASON="http ${http_code}"; return 1 ;;
  esac
}

# Validate an API key by making a minimal request
validate_api_key() {
  local provider="$1"
  local key="$2"
  
  if [ -z "$key" ]; then
    VALIDATION_REASON="no key"
    return 1
  fi
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    VALIDATION_REASON="test-mode"
    return 1
  fi
  
  local http_code response
  
  case "$provider" in
    anthropic)
      # Detect OAuth Access Token (sk-ant-oat*) vs API key (sk-ant-api*)
      local auth_header
      if [[ "$key" == sk-ant-oat* ]]; then
        # OAuth tokens cannot be validated via API, trust them if present
        VALIDATION_REASON="OAuth token (trusted)"
        return 0
        auth_header="Authorization: Bearer ${key}"
        # OAuth tokens cannot be validated via API, trust them if present
        VALIDATION_REASON="OAuth token (trusted)"
        return 0
      else
        auth_header="x-api-key: ${key}"
      fi
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "$auth_header" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        "https://api.anthropic.com/v1/messages" 2>/dev/null)
      ;;
    openai)
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "Authorization: Bearer ${key}" \
        "https://api.openai.com/v1/models" 2>/dev/null)
      ;;
    google)
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        "https://generativelanguage.googleapis.com/v1/models?key=${key}" 2>/dev/null)
      ;;
    *)
      VALIDATION_REASON="unknown provider"
      return 1
      ;;
  esac
  
  http_code=$(echo "$response" | tail -1)
  
  case "$http_code" in
    200) VALIDATION_REASON="valid"; return 0 ;;
    400) 
      # Anthropic returns 400 for bad request but auth OK
      if [ "$provider" = "anthropic" ]; then
        VALIDATION_REASON="valid"
        return 0
      fi
      VALIDATION_REASON="400 bad request"
      return 1
      ;;
    401) VALIDATION_REASON="401 unauthorized"; return 1 ;;
    403) VALIDATION_REASON="403 forbidden"; return 1 ;;
    429) VALIDATION_REASON="429 rate limited"; return 1 ;;
    000) VALIDATION_REASON="timeout"; return 1 ;;
    *)   VALIDATION_REASON="http ${http_code}"; return 1 ;;
  esac
}

# =============================================================================
# Token Hunting Functions
# =============================================================================

# Global variables for function results (avoids subshell issues with $())
VALIDATION_REASON=""
FOUND_TOKEN_RESULT=""

# Find a working Telegram token from all agents
# Sets: FOUND_TOKEN_RESULT with agent_num:token (e.g., "2:abc123...")
# Side effect: populates DIAG_TELEGRAM_RESULTS
find_working_telegram_token() {
  local count="${AGENT_COUNT:-0}"
  FOUND_TOKEN_RESULT=""
  
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    local token="${!token_var:-}"
    
    # Also try generic BOT_TOKEN
    [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
    
    if [ -z "$token" ]; then
      # Don't log "not configured" for every agent - only if none have tokens
      continue
    fi
    
    # Run validation - captures reason via VALIDATION_REASON global
    VALIDATION_REASON=""
    if $VALIDATE_TELEGRAM_TOKEN_FN "$token"; then
      diag_add "telegram" "agent${i}" "✅" "valid"
      [ -z "$FOUND_TOKEN_RESULT" ] && FOUND_TOKEN_RESULT="${i}:${token}"
    else
      diag_add "telegram" "agent${i}" "❌" "${VALIDATION_REASON:-unknown}"
    fi
  done
  
  [ -n "$FOUND_TOKEN_RESULT" ] && return 0
  return 1
}

# Find a working Discord token from all agents
# Sets: FOUND_TOKEN_RESULT with agent_num:token (e.g., "2:abc123...")
# Side effect: populates DIAG_DISCORD_RESULTS
find_working_discord_token() {
  local count="${AGENT_COUNT:-0}"
  FOUND_TOKEN_RESULT=""
  
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
    local token="${!token_var:-}"
    
    if [ -z "$token" ]; then
      continue
    fi
    
    VALIDATION_REASON=""
    if $VALIDATE_DISCORD_TOKEN_FN "$token"; then
      diag_add "discord" "agent${i}" "✅" "valid"
      [ -z "$FOUND_TOKEN_RESULT" ] && FOUND_TOKEN_RESULT="${i}:${token}"
    else
      diag_add "discord" "agent${i}" "❌" "${VALIDATION_REASON:-unknown}"
    fi
  done
  
  [ -n "$FOUND_TOKEN_RESULT" ] && return 0
  return 1
}

# Global variable for function results (avoids subshell issues)
FOUND_TOKEN_RESULT=""

# Find a working platform and token
# Order: User's default platform (PLATFORM env var) first, then fallback platform
# Tries ALL tokens from preferred platform before moving to fallback
# Sets: FOUND_TOKEN_RESULT with platform:agent_num:token (e.g., "telegram:2:abc123...")
# Returns: 0 if found, 1 if not
find_working_platform_and_token() {
  local user_platform="${PLATFORM:-telegram}"
  local platforms=()
  FOUND_TOKEN_RESULT=""
  
  # Build ordered list: user's default first, then the other
  if [ "$user_platform" = "discord" ]; then
    platforms=("discord" "telegram")
  else
    platforms=("telegram" "discord")
  fi
  
  for platform in "${platforms[@]}"; do
    # Call directly (not in subshell) to preserve diagnostic array modifications
    case "$platform" in
      telegram) find_working_telegram_token ;;
      discord)  find_working_discord_token ;;
    esac
    
    if [ -n "$FOUND_TOKEN_RESULT" ]; then
      FOUND_TOKEN_RESULT="${platform}:${FOUND_TOKEN_RESULT}"
      return 0
    fi
  done
  
  return 1
}

# Get the model for a specific agent from habitat config
# Falls back to provider default if not found
# Collect all unique models from habitat config
# Returns models in order: agent1's model first, then others
get_all_configured_models() {
  local count="${AGENT_COUNT:-0}"
  local models=()
  local seen=()
  
  for i in $(seq 1 "$count"); do
    local model_var="AGENT${i}_MODEL"
    local model="${!model_var:-}"
    
    if [ -n "$model" ]; then
      # Skip duplicates (shellcheck: quotes intentional for exact word match)
      # shellcheck disable=SC2076
      if [[ ! " ${seen[*]} " =~ " $model " ]]; then
        models+=("$model")
        seen+=("$model")
      fi
    fi
  done
  
  echo "${models[@]}"
}

# Find a working model for a provider
# Order: User's configured models → hardcoded fallback
# Returns the first model that matches the provider
find_working_model_for_provider() {
  local provider="$1"
  local configured_models
  read -ra configured_models <<< "$(get_all_configured_models)"
  
  # Try configured models first (that match this provider)
  for model in "${configured_models[@]}"; do
    local model_provider=$(get_provider_from_model "$model")
    if [ "$model_provider" = "$provider" ]; then
      echo "$model"
      return 0
    fi
  done
  
  # Fall back to hardcoded default for this provider
  get_default_model_for_provider "$provider"
}

# =============================================================================
# API Key Fallback Functions
# =============================================================================

# Test if an OAuth token actually works by making an API call
# This catches cases where the access token is expired AND refresh token is also expired
# Returns: 0 if token works, 1 if it fails
# Echoes: error message on failure
test_oauth_token() {
  local provider="$1"
  local access_token="$2"
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    echo "test-mode"
    return 1
  fi
  
  local http_code response
  
  case "$provider" in
    openai-codex|openai)
      # Test with models endpoint (lightweight, just needs auth)
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "Authorization: Bearer ${access_token}" \
        "https://api.openai.com/v1/models" 2>/dev/null)
      ;;
    anthropic)
      # Anthropic OAuth - test with a minimal request
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "Authorization: Bearer ${access_token}" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" 2>/dev/null)
      ;;
    google)
      # Google OAuth
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "Authorization: Bearer ${access_token}" \
        "https://generativelanguage.googleapis.com/v1/models" 2>/dev/null)
      ;;
    *)
      echo "unknown provider"
      return 1
      ;;
  esac
  
  http_code=$(echo "$response" | tail -1)
  
  case "$http_code" in
    200) return 0 ;;  # Token works
    401) echo "401 unauthorized - token/refresh expired"; return 1 ;;
    403) echo "403 forbidden"; return 1 ;;
    000) echo "timeout"; return 1 ;;
    *)   echo "http ${http_code}"; return 1 ;;
  esac
}

# Check if OAuth profile exists and is valid in auth-profiles.json
# Sets globals (avoids subshell issues with array modifications):
#   OAUTH_CHECK_RESULT:   "oauth:<actual_provider>" on success, empty on failure  
#   OAUTH_CHECK_REASON:   failure reason for diagnostics
#   OAUTH_CHECK_PROVIDER: actual provider name (e.g., openai-codex for openai)
# Returns: 0=success, 1=failure
check_oauth_profile() {
  local provider="$1"
  local auth_file="${AUTH_PROFILES_PATH:-}"
  
  # Reset globals
  OAUTH_CHECK_RESULT=""
  OAUTH_CHECK_REASON=""
  OAUTH_CHECK_PROVIDER=""
  
  # Skip OAuth check in test mode unless explicitly testing OAuth
  if [ "${TEST_MODE:-}" = "1" ] && [ "${TEST_OAUTH:-}" != "1" ]; then
    OAUTH_CHECK_REASON="test-mode"
    return 1
  fi
  
  # Find auth-profiles.json
  if [ -z "$auth_file" ]; then
    local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
    for path in \
      "$home/.openclaw/agents/main/agent/auth-profiles.json" \
      "$home/.openclaw/agents/agent1/agent/auth-profiles.json" \
      "$home/.openclaw/agent/auth-profiles.json"; do
      if [ -f "$path" ]; then
        auth_file="$path"
        log_recovery "  Found auth-profiles.json at: $path"
        break
      fi
    done
  fi
  
  if [ -z "$auth_file" ] || [ ! -f "$auth_file" ]; then
    log_recovery "  No auth-profiles.json found"
    OAUTH_CHECK_REASON="no auth-profiles.json"
    return 1
  fi
  
  # Map provider name to auth-profiles key AND actual provider name for config
  local profile_key=""
  local actual_provider="$provider"
  case "$provider" in
    anthropic) 
      profile_key="anthropic:default"
      actual_provider="anthropic"
      ;;
    openai|openai-codex)
      # OpenAI OAuth uses "openai-codex" provider name in OpenClaw
      profile_key="openai-codex:default"
      actual_provider="openai-codex"
      ;;
    google)
      profile_key="google:default"
      actual_provider="google"
      ;;
    *)
      OAUTH_CHECK_REASON="unknown provider"
      return 1
      ;;
  esac
  
  OAUTH_CHECK_PROVIDER="$actual_provider"
  
  # Check if profile exists and has access token
  local access_token
  access_token=$(jq -r ".profiles[\"$profile_key\"].access // empty" "$auth_file" 2>/dev/null)
  
  if [ -n "$access_token" ] && [ "$access_token" != "null" ]; then
    log_recovery "    OAuth access token exists for $provider (actual: $actual_provider)"
    
    # Check if expired (if expires field exists)
    local expires
    expires=$(jq -r ".profiles[\"$profile_key\"].expires // empty" "$auth_file" 2>/dev/null)
    local is_expired=0
    if [ -n "$expires" ] && [ "$expires" != "null" ] && [ "$expires" != "0" ]; then
      local now=$(date +%s)
      local exp_ts=$((expires / 1000))  # Convert ms to seconds if needed
      [ "$exp_ts" -lt 1000000000000 ] || exp_ts=$((expires / 1000))
      
      if [ "$now" -lt "$exp_ts" ]; then
        log_recovery "    OAuth token valid (expires in $((exp_ts - now))s)"
        # Token not expired - should work
        OAUTH_CHECK_RESULT="oauth:$actual_provider"
        return 0
      else
        log_recovery "    OAuth token EXPIRED (expired $((now - exp_ts))s ago)"
        is_expired=1
      fi
    fi
    
    # Token expired or no expiry info - TEST if it actually works
    # Make a real API call to see if token is valid or can be refreshed
    if [ "$is_expired" -eq 1 ]; then
      log_recovery "    Testing OAuth token with API call..."
      local test_result
      test_result=$(test_oauth_token "$actual_provider" "$access_token")
      if [ $? -eq 0 ]; then
        log_recovery "    OAuth token WORKS (refresh succeeded or token still valid)"
        OAUTH_CHECK_RESULT="oauth:$actual_provider"
        return 0
      else
        log_recovery "    OAuth token FAILED: $test_result"
        log_recovery "    Skipping $actual_provider OAuth - refresh token may be expired"
        OAUTH_CHECK_REASON="OAuth expired"
        return 1
      fi
    else
      # No expiry info, assume valid
      log_recovery "    OAuth token has no expiry, assuming valid"
      OAUTH_CHECK_RESULT="oauth:$actual_provider"
      return 0
    fi
  else
    log_recovery "    No OAuth access token for $provider"
    OAUTH_CHECK_REASON="no token"
  fi
  
  return 1
}

# Extract provider name from model string (e.g., "anthropic/claude-opus-4-5" → "anthropic")
get_provider_from_model() {
  local model="$1"
  echo "${model%%/*}"
}

# Get user's preferred provider from their configured models
# Returns the provider from AGENT1_MODEL, or first agent with a model
get_user_preferred_provider() {
  local count="${AGENT_COUNT:-0}"
  
  # Try AGENT1_MODEL first (primary agent)
  local model="${AGENT1_MODEL:-}"
  if [ -n "$model" ]; then
    get_provider_from_model "$model"
    return 0
  fi
  
  # Fall back to first agent with a model configured
  for i in $(seq 1 "$count"); do
    local model_var="AGENT${i}_MODEL"
    model="${!model_var:-}"
    if [ -n "$model" ]; then
      get_provider_from_model "$model"
      return 0
    fi
  done
  
  # Default to anthropic if nothing configured
  echo "anthropic"
}

# Build ordered list of providers to try
# Order: user's default → anthropic → openai → google (skipping user's default in fallback)
get_provider_order() {
  local user_pref=$(get_user_preferred_provider)
  local ordered=()
  
  # Add user's preference first
  ordered+=("$user_pref")
  
  # Add remaining providers in fixed order: anthropic → openai → google
  # (skipping whichever was the user's default)
  for p in "anthropic" "openai" "google"; do
    # Skip if already added (user's default)
    # shellcheck disable=SC2076  # Quotes intentional for exact word match
    [[ " ${ordered[*]} " =~ " $p " ]] && continue
    ordered+=("$p")
  done
  
  echo "${ordered[@]}"
}

# Global for API provider result
FOUND_API_PROVIDER=""

# Global for OAuth check result (avoids subshell issues)
OAUTH_CHECK_RESULT=""       # "oauth:<provider>" on success, empty on failure
OAUTH_CHECK_REASON=""       # failure reason for diagnostics
OAUTH_CHECK_PROVIDER=""     # actual provider name (e.g., openai-codex for openai)

# Default log_recovery to no-op if not defined (allows function use outside run_smart_recovery)
type log_recovery &>/dev/null || log_recovery() { :; }

# Find a working API provider
# Order: User's default provider → Anthropic → OpenAI → Google (skipping user's default)
# Checks both OAuth (auth-profiles.json) and API keys
# Sets: FOUND_API_PROVIDER with provider name (may be "openai-codex" for OAuth)
# Side effect: populates DIAG_API_RESULTS
find_working_api_provider() {
  local providers
  read -ra providers <<< "$(get_provider_order)"
  log_recovery "  Provider order: ${providers[*]}"
  log_recovery "  Available keys: ANTHROPIC=${ANTHROPIC_API_KEY:+yes} OPENAI=${OPENAI_API_KEY:+yes} GOOGLE=${GOOGLE_API_KEY:+yes}"
  FOUND_API_PROVIDER=""
  
  for provider in "${providers[@]}"; do
    log_recovery "  Checking provider: $provider"
    local oauth_tried=0
    local oauth_failed_reason=""
    local oauth_provider=""
    
    # First check OAuth profile (NOT in subshell - uses globals)
    check_oauth_profile "$provider"
    local oauth_status=$?
    
    if [ $oauth_status -eq 0 ] && [ -n "$OAUTH_CHECK_RESULT" ]; then
      # Parse "oauth:<actual_provider>" format
      local actual_provider="${OAUTH_CHECK_RESULT#oauth:}"
      log_recovery "    OAuth profile found for $provider → using $actual_provider"
      diag_add "api" "$actual_provider" "✅" "OAuth"
      [ -z "$FOUND_API_PROVIDER" ] && FOUND_API_PROVIDER="$actual_provider"
      # Continue checking others for diagnostics, but we have our answer
      continue
    else
      # OAuth failed - record details for diagnostic
      if [ -n "$OAUTH_CHECK_PROVIDER" ]; then
        oauth_tried=1
        oauth_provider="$OAUTH_CHECK_PROVIDER"
        oauth_failed_reason="${OAUTH_CHECK_REASON:-failed}"
      fi
      log_recovery "    No OAuth for $provider (reason: ${OAUTH_CHECK_REASON:-none})"
    fi
    
    # Then check API key
    local key=""
    case "$provider" in
      anthropic) key="${ANTHROPIC_API_KEY:-}" ;;
      openai)    key="${OPENAI_API_KEY:-}" ;;
      google)    key="${GOOGLE_API_KEY:-}" ;;
    esac
    
    if [ -n "$key" ]; then
      log_recovery "    API key found for $provider, validating..."
      VALIDATION_REASON=""
      if $VALIDATE_API_KEY_FN "$provider" "$key"; then
        log_recovery "    API key valid for $provider"
        diag_add "api" "$provider" "✅" "API key"
        [ -z "$FOUND_API_PROVIDER" ] && FOUND_API_PROVIDER="$provider"
      else
        log_recovery "    API key invalid for $provider: ${VALIDATION_REASON:-unknown}"
        diag_add "api" "$provider" "❌" "${VALIDATION_REASON:-unknown}"
      fi
    else
      log_recovery "    No API key for $provider"
      # Report OAuth failure if it was tried, otherwise "not configured"
      if [ "$oauth_tried" -eq 1 ]; then
        # OAuth was configured but failed
        diag_add "api" "$oauth_provider" "❌" "$oauth_failed_reason"
      else
        # Neither OAuth nor API key configured
        diag_add "api" "$provider" "⚪" "not configured"
      fi
    fi
  done
  
  log_recovery "  === find_working_api_provider COMPLETE ==="
  log_recovery "  FOUND_API_PROVIDER='$FOUND_API_PROVIDER'"
  log_recovery "  DIAG_API_RESULTS: ${DIAG_API_RESULTS[*]:-empty}"
  
  [ -n "$FOUND_API_PROVIDER" ] && return 0
  
  log_recovery "  !!! No working provider found - returning failure !!!"
  return 1
}

# Get auth type for a provider (oauth or apikey)
get_auth_type_for_provider() {
  local provider="$1"
  check_oauth_profile "$provider" 2>/dev/null
  if [ $? -eq 0 ] && [[ "$OAUTH_CHECK_RESULT" == oauth:* ]]; then
    echo "oauth"
  else
    echo "apikey"
  fi
}

# Get the API key for a provider
get_api_key_for_provider() {
  local provider="$1"
  case "$provider" in
    anthropic) echo "${ANTHROPIC_API_KEY:-}" ;;
    openai)    echo "${OPENAI_API_KEY:-}" ;;
    google)    echo "${GOOGLE_API_KEY:-}" ;;
    *)         echo "" ;;
  esac
}

# Get the default model for a provider
get_default_model_for_provider() {
  local provider="$1"
  case "$provider" in
    anthropic)     echo "anthropic/claude-sonnet-4-5" ;;
    openai)        echo "openai/gpt-4o" ;;
    openai-codex)  echo "openai-codex/gpt-5.2" ;;  # OAuth provider uses different model names
    google)        echo "google/gemini-2.0-flash" ;;
    *)             echo "anthropic/claude-sonnet-4-5" ;;
  esac
}

# =============================================================================
# Emergency Config Generation
# =============================================================================

# Ensure safe-mode workspace exists
setup_safe_mode_workspace() {
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local user="${USERNAME:-bot}"
  local safe_mode_dir="$home/clawd/agents/safe-mode"
  local setup_script="/usr/local/bin/setup-safe-mode-workspace.sh"
  
  # If setup script exists, use it
  if [ -x "$setup_script" ]; then
    "$setup_script" "$home" "$user"
    return $?
  fi
  
  # Otherwise create minimal workspace inline
  mkdir -p "$safe_mode_dir/memory"
  
  # Create minimal IDENTITY.md
  cat > "$safe_mode_dir/IDENTITY.md" << 'EOF'
# Safe Mode Recovery Bot

You are the **Safe Mode Recovery Bot** - an emergency diagnostic and repair agent.

The normal bot(s) failed to start. Check BOOT_REPORT.md in your workspace to see what failed.

## Your Mission
1. Read BOOT_REPORT.md to understand what's broken
2. Diagnose the problem using system tools
3. Attempt repair if possible
4. Escalate to user with clear explanation if you can't fix it

You are NOT one of the originally configured agents - you're borrowing a working token to communicate.
EOF

  # Create minimal SOUL.md
  cat > "$safe_mode_dir/SOUL.md" << 'EOF'
You are calm, competent, and focused on getting things working again.

Be clear about what's wrong. Explain what you're checking. If stuck, say so and ask for help.

Start with status, not pleasantries: "Safe mode active. Checking boot report..."
EOF

  chown -R "$user:$user" "$safe_mode_dir" 2>/dev/null || true
  echo "$safe_mode_dir"
}

# Generate emergency OpenClaw config with working credentials
# Uses bind=lan (not local) because:
#   - iOS Shortcut API needs to reach the gateway from the LAN
#   - Safe mode still needs config apply/health check endpoints accessible
#   - bind=local would only allow localhost connections, breaking remote management
generate_emergency_config() {
  local token="$1"       # Bot token (Telegram or Discord)
  local platform="$2"    # "telegram" or "discord"
  local provider="$3"    # API provider: "anthropic", "openai", "google"
  local api_key="$4"     # API key (empty if using OAuth)
  local auth_type="${5:-apikey}"  # "oauth" or "apikey"
  local model="${6:-}"   # Model override (uses provider default if empty)
  
  [ -z "$model" ] && model=$(get_default_model_for_provider "$provider")
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local gateway_token=$(openssl rand -hex 16 2>/dev/null || echo "emergency-token-$(date +%s)")
  
  # Ensure safe-mode workspace exists
  setup_safe_mode_workspace >/dev/null 2>&1
  
  # Build env section based on provider and auth type
  local env_json=""
  if [ "$auth_type" = "oauth" ]; then
    # OAuth - no API key needed in env, uses auth-profiles.json
    env_json=""
  else
    # API key auth
    case "$provider" in
      anthropic)
        env_json="\"ANTHROPIC_API_KEY\": \"${api_key}\""
        ;;
      openai)
        env_json="\"OPENAI_API_KEY\": \"${api_key}\""
        ;;
      google)
        env_json="\"GOOGLE_API_KEY\": \"${api_key}\""
        ;;
    esac
  fi
  
  # Build channel config
  local telegram_config="\"telegram\": { \"enabled\": false }"
  local discord_config="\"discord\": { \"enabled\": false }"
  
  if [ "$platform" = "telegram" ]; then
    # Use correct OpenClaw schema: dmPolicy + allowFrom (not ownerId/allowlist)
    local owner_id="${TELEGRAM_OWNER_ID:-}"
    if [ -n "$owner_id" ]; then
      telegram_config="\"telegram\": {
        \"enabled\": true,
        \"botToken\": \"${token}\",
        \"dmPolicy\": \"allowlist\",
        \"allowFrom\": [\"${owner_id}\"]
      }"
    else
      # No owner ID - use pairing mode (safest default)
      telegram_config="\"telegram\": {
        \"enabled\": true,
        \"botToken\": \"${token}\",
        \"dmPolicy\": \"pairing\"
      }"
    fi
  elif [ "$platform" = "discord" ]; then
    # Use correct OpenClaw schema for Discord
    # Token under accounts.default, DM config uses flat keys (dmPolicy, allowFrom)
    local owner_id="${DISCORD_OWNER_ID:-}"
    if [ -n "$owner_id" ]; then
      discord_config="\"discord\": {
        \"enabled\": true,
        \"accounts\": {
          \"default\": { \"token\": \"${token}\" }
        },
        \"dmPolicy\": \"allowlist\",
        \"allowFrom\": [\"${owner_id}\"]
      }"
    else
      discord_config="\"discord\": {
        \"enabled\": true,
        \"accounts\": {
          \"default\": { \"token\": \"${token}\" }
        },
        \"dmPolicy\": \"pairing\"
      }"
    fi
  fi
  
  cat <<EOF
{
  "env": {
    ${env_json}
  },
  "agents": {
    "defaults": {
      "model": { "primary": "${model}" },
      "workspace": "${home}/clawd"
    },
    "list": [
      {
        "id": "safe-mode",
        "default": true,
        "name": "SafeModeBot",
        "workspace": "${home}/clawd/agents/safe-mode"
      }
    ]
  },
  "gateway": {
    "mode": "local",
    "port": ${GROUP_PORT:-18789},
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${gateway_token}"
    }
  },
  "channels": {
    ${telegram_config},
    ${discord_config}
  }
}
EOF
}

# =============================================================================
# Resilience Functions
# =============================================================================

# Check network connectivity
check_network() {
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 0  # Assume network OK in tests
  fi
  
  # Try multiple endpoints - use real API endpoints that we'll need anyway
  # Avoid 1.1.1.1 - some networks block it or it may cause false negatives
  for url in "https://api.telegram.org" "https://discord.com" "https://api.anthropic.com" "https://www.google.com"; do
    if curl -sf --max-time 5 --head "$url" >/dev/null 2>&1; then
      return 0
    fi
  done
  
  # Fallback: try DNS resolution
  if host api.telegram.org >/dev/null 2>&1 || nslookup api.telegram.org >/dev/null 2>&1; then
    return 0
  fi
  
  return 1
}

# Validate JSON config syntax
validate_config_json() {
  local config="$1"
  echo "$config" | jq . >/dev/null 2>&1
}

# Run openclaw doctor --fix
run_doctor_fix() {
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local user="${USERNAME:-bot}"
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    echo "DRY_RUN: would run openclaw doctor --fix"
    return 0
  fi
  
  # Run as the bot user
  if command -v openclaw >/dev/null 2>&1; then
    su - "$user" -c "cd $home && openclaw doctor --fix" 2>&1 || true
    return $?
  fi
  
  return 1
}

# Clear corrupted state (nuclear option)
clear_corrupted_state() {
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local user="${USERNAME:-bot}"
  
  if [ "${TEST_MODE:-}" = "1" ] || [ "${DRY_RUN:-}" = "1" ]; then
    echo "DRY_RUN: would clear state"
    return 0
  fi
  
  # Backup and clear session state
  local state_dir="$home/.openclaw"
  local backup_dir="$home/.openclaw-backup-$(date +%Y%m%d-%H%M%S)"
  
  if [ -d "$state_dir/sessions" ]; then
    mv "$state_dir/sessions" "$backup_dir-sessions" 2>/dev/null || true
  fi
  
  # Clear agent state but keep configs
  for agent_dir in "$state_dir/agents"/*/agent; do
    if [ -d "$agent_dir" ]; then
      # Keep auth-profiles.json, remove corrupted state
      find "$agent_dir" -name "*.db" -delete 2>/dev/null || true
      find "$agent_dir" -name "*.db-*" -delete 2>/dev/null || true
    fi
  done
  
  return 0
}

# Try to notify user via any available channel
notify_user_emergency() {
  local message="$1"
  local tg_notify="${TG_NOTIFY:-/usr/local/bin/tg-notify.sh}"
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    echo "NOTIFY: $message"
    return 0
  fi
  
  # Try Telegram notification script
  if [ -x "$tg_notify" ]; then
    "$tg_notify" "$message" 2>/dev/null && return 0
  fi
  
  # Try curl to Telegram directly if we have owner ID and any bot token
  local owner_id="${TELEGRAM_OWNER_ID:-}"
  if [ -n "$owner_id" ]; then
    for i in $(seq 1 "${AGENT_COUNT:-1}"); do
      local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
      local token="${!token_var:-}"
      [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
      
      if [ -n "$token" ]; then
        curl -sf --max-time 10 \
          "https://api.telegram.org/bot${token}/sendMessage" \
          -d "chat_id=${owner_id}" \
          -d "text=${message}" \
          -d "parse_mode=HTML" >/dev/null 2>&1 && return 0
      fi
    done
  fi
  
  # Try Discord webhook if configured
  local discord_webhook="${DISCORD_WEBHOOK_URL:-}"
  if [ -n "$discord_webhook" ]; then
    curl -sf --max-time 10 \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"$message\"}" \
      "$discord_webhook" >/dev/null 2>&1 && return 0
  fi
  
  return 1
}

# =============================================================================
# Main Recovery Function
# =============================================================================

# Run smart recovery - find working credentials and generate emergency config
run_smart_recovery() {
  local log="${RECOVERY_LOG:-/var/log/safe-mode-recovery.log}"
  
  # Use temp log in test mode
  if [ "${TEST_MODE:-}" = "1" ]; then
    log="${TEST_TMPDIR:-/tmp}/safe-mode-recovery.log"
  fi
  
  # Security: restrict log file permissions (diagnostic context, no secrets)
  touch "$log" && chmod 600 "$log" 2>/dev/null || true
  
  log_recovery() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$log"
  }
  
  # Reset diagnostics arrays for this run
  DIAG_TELEGRAM_RESULTS=()
  DIAG_DISCORD_RESULTS=()
  DIAG_API_RESULTS=()
  DIAG_DOCTOR_RAN=""
  DIAG_DOCTOR_RESULT=""
  DIAG_NETWORK_OK=""
  
  log_recovery "========== SMART RECOVERY STARTING =========="
  log_recovery "PID: $$ | HOME_DIR=${HOME_DIR:-unset} | USERNAME=${USERNAME:-unset}"
  log_recovery "Environment check:"
  log_recovery "  GROUP: ${GROUP:-unset} (session isolation mode: ${GROUP:+yes}${GROUP:-no})"
  log_recovery "  ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:+SET (${#ANTHROPIC_API_KEY} chars)}"
  log_recovery "  OPENAI_API_KEY: ${OPENAI_API_KEY:+SET (${#OPENAI_API_KEY} chars)}"
  log_recovery "  GOOGLE_API_KEY: ${GOOGLE_API_KEY:+SET (${#GOOGLE_API_KEY} chars)}"
  log_recovery "  AGENT_COUNT: ${AGENT_COUNT:-unset}"
  log_recovery "  PLATFORM: ${PLATFORM:-unset}"
  
  # Step 0: Check network connectivity
  log_recovery "Step 0: Checking network connectivity..."
  if ! check_network; then
    log_recovery "WARNING: Network connectivity issues detected"
    DIAG_NETWORK_OK="no"
    notify_user_emergency "⚠️ Safe Mode: Network connectivity issues. Recovery may fail."
  else
    log_recovery "Network OK"
    DIAG_NETWORK_OK="yes"
  fi
  
  # Step 1: Find working platform and token
  log_recovery "Step 1: Searching for working bot token..."
  # Call directly (not in subshell) to preserve diagnostic array modifications
  find_working_platform_and_token
  local platform_token="$FOUND_TOKEN_RESULT"
  
  if [ -z "$platform_token" ]; then
    log_recovery "ERROR: No working bot tokens found"
    log_recovery "Attempting openclaw doctor --fix..."
    DIAG_DOCTOR_RAN="yes"
    if run_doctor_fix >> "$log" 2>&1; then
      DIAG_DOCTOR_RESULT="completed"
    else
      DIAG_DOCTOR_RESULT="errors"
    fi
    
    # Retry after doctor
    find_working_platform_and_token
    platform_token="$FOUND_TOKEN_RESULT"
    if [ -z "$platform_token" ]; then
      log_recovery "ERROR: Still no working tokens after doctor --fix"
      # Write diagnostics before failing
      write_diagnostics_summary "/var/log/safe-mode-diagnostics.txt" >/dev/null 2>&1
      notify_user_emergency "🚨 CRITICAL: Safe Mode failed - no working bot tokens found!"
      echo "ERROR: No working bot tokens found" >&2
      return 1
    fi
  fi
  
  # Parse platform:agent_num:token format
  local platform="${platform_token%%:*}"
  local rest="${platform_token#*:}"
  local agent_num="${rest%%:*}"
  local token="${rest#*:}"
  log_recovery "Found working token for platform: $platform (agent${agent_num})"
  
  # Step 2: Find working API provider
  log_recovery "Step 2: Searching for working API provider..."
  find_working_api_provider
  local provider="$FOUND_API_PROVIDER"
  log_recovery "  find_working_api_provider returned: FOUND_API_PROVIDER='$FOUND_API_PROVIDER'"
  
  if [ -z "$provider" ]; then
    log_recovery "!!! WARNING: No working API providers found via validation !!!"
    log_recovery "!!! Falling back to anthropic (THIS MAY FAIL) !!!"
    log_recovery "Diagnostic arrays at this point:"
    log_recovery "  DIAG_API_RESULTS: ${DIAG_API_RESULTS[*]:-empty}"
    provider="anthropic"  # Fallback - let it fail at runtime rather than here
  else
    log_recovery "  Using provider: $provider"
  fi
  
  local api_key=$(get_api_key_for_provider "$provider")
  local auth_type=$(get_auth_type_for_provider "$provider")
  log_recovery "Using API provider: $provider (auth: $auth_type)"
  
  # Get the model - try user's configured models first, then hardcoded fallback
  local model=$(find_working_model_for_provider "$provider")
  log_recovery "Using model: $model"
  log_recovery "  (User's configured models: $(get_all_configured_models))"
  
  # Step 3: Generate emergency config
  log_recovery "Step 3: Generating emergency config..."
  log_recovery "  Parameters: token=${token:0:10}... platform=$platform provider=$provider auth_type=$auth_type model=$model"
  log_recovery "  api_key: ${api_key:+SET (${#api_key} chars)}"
  # Use SafeModeBot identity - don't inherit original agent's name/identity
  # The safe-mode workspace has its own IDENTITY.md and SOUL.md
  local config=$(generate_emergency_config "$token" "$platform" "$provider" "$api_key" "$auth_type" "$model")
  
  # Validate config JSON
  if ! validate_config_json "$config"; then
    log_recovery "!!! ERROR: Generated config is invalid JSON !!!"
    log_recovery "Config content (first 500 chars): ${config:0:500}"
    echo "ERROR: Generated invalid config" >&2
    return 1
  fi
  log_recovery "Config JSON validated OK"
  
  # Log what we're about to write
  local config_model=$(echo "$config" | jq -r '.agents.defaults.model.primary // .agents.defaults.model // "unknown"' 2>/dev/null)
  local config_keys=$(echo "$config" | jq -r '.env | keys | join(",")' 2>/dev/null)
  log_recovery "  Generated config: model=$config_model, env_keys=$config_keys"
  
  # Step 4: Write emergency config
  # Use OPENCLAW_CONFIG_PATH if set (from systemd environment) - this is the ACTUAL
  # config path the gateway uses. For session isolation, systemd sets this to
  # /etc/systemd/system/${GROUP}/openclaw.session.json
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local config_dir config_path
  
  if [ -n "${OPENCLAW_CONFIG_PATH:-}" ]; then
    # Use the config path from systemd environment
    config_path="$OPENCLAW_CONFIG_PATH"
    config_dir="$(dirname "$config_path")"
    log_recovery "  Using OPENCLAW_CONFIG_PATH: ${config_path}"
  elif [ -n "${GROUP:-}" ]; then
    config_dir="${home}/.openclaw-sessions/${GROUP}"
    config_path="${config_dir}/openclaw.session.json"
    log_recovery "  Session isolation mode (fallback): writing to ${config_path}"
  else
    config_dir="${home}/.openclaw"
    config_path="${config_dir}/openclaw.json"
  fi
  
  if [ "${DRY_RUN:-}" != "1" ]; then
    # Ensure directory exists
    mkdir -p "$config_dir" 2>/dev/null || true
    
    # Backup current config if it exists
    [ -f "$config_path" ] && cp "$config_path" "${config_path}.pre-recovery" 2>/dev/null
    
    # Write new config
    echo "$config" > "$config_path"
    chmod 600 "$config_path"
    [ -n "${USERNAME:-}" ] && chown "${USERNAME}:${USERNAME}" "$config_path" 2>/dev/null
    log_recovery "Emergency config written to $config_path"
    
    # Create auth-profiles.json for safe-mode agent
    # OpenClaw looks for API keys in per-agent auth-profiles.json, not just env vars
    local state_dir="${OPENCLAW_STATE_DIR:-${home}/.openclaw}"
    [ -n "${GROUP:-}" ] && state_dir="${home}/.openclaw-sessions/${GROUP}"
    local auth_dir="${state_dir}/agents/safe-mode/agent"
    mkdir -p "$auth_dir" 2>/dev/null || true
    
    # Generate auth-profiles.json based on provider
    local auth_profiles
    case "$provider" in
      google)
        auth_profiles=$(cat <<AUTHEOF
{
  "version": 1,
  "profiles": {
    "google:default": {
      "type": "api_key",
      "provider": "google",
      "token": "${api_key}"
    }
  }
}
AUTHEOF
)
        ;;
      anthropic)
        auth_profiles=$(cat <<AUTHEOF
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "api_key",
      "provider": "anthropic",
      "token": "${api_key}"
    }
  }
}
AUTHEOF
)
        ;;
      openai)
        auth_profiles=$(cat <<AUTHEOF
{
  "version": 1,
  "profiles": {
    "openai:default": {
      "type": "api_key",
      "provider": "openai",
      "token": "${api_key}"
    }
  }
}
AUTHEOF
)
        ;;
    esac
    
    if [ -n "$auth_profiles" ]; then
      echo "$auth_profiles" > "${auth_dir}/auth-profiles.json"
      chmod 600 "${auth_dir}/auth-profiles.json"
      [ -n "${USERNAME:-}" ] && chown -R "${USERNAME}:${USERNAME}" "${state_dir}/agents" 2>/dev/null
      log_recovery "Created auth-profiles.json at ${auth_dir}/auth-profiles.json"
    fi
  else
    log_recovery "DRY_RUN: Would write config to $config_path"
  fi
  
  log_recovery "========== SMART RECOVERY COMPLETED =========="
  log_recovery "  Platform: $platform"
  log_recovery "  Provider: $provider (auth: $auth_type)"
  log_recovery "  Model: $(get_default_model_for_provider "$provider")"
  
  # Write diagnostics summary for boot report
  local diag_file="/var/log/safe-mode-diagnostics.txt"
  [ "${TEST_MODE:-}" = "1" ] && diag_file="${TEST_TMPDIR:-/tmp}/safe-mode-diagnostics.txt"
  write_diagnostics_summary "$diag_file" >/dev/null 2>&1
  log_recovery "Diagnostics written to $diag_file"
  
  # Note: Don't send celebratory notification here - the boot report flow
  # will send a proper safe mode notification with failure details.
  # We only notify on critical failures, not on successful recovery.
  
  # Output result for callers
  echo "platform=$platform"
  echo "provider=$provider"
  echo "auth_type=$auth_type"
  echo "token_found=true"
  
  return 0
}

# Full recovery with escalation - tries everything
run_full_recovery_escalation() {
  local log="${RECOVERY_LOG:-/var/log/safe-mode-recovery.log}"
  
  log_recovery() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$log"
  }
  
  log_recovery "========== FULL RECOVERY ESCALATION =========="
  
  # Level 1: Smart recovery
  log_recovery "Level 1: Attempting smart recovery..."
  if run_smart_recovery; then
    return 0
  fi
  
  # Level 2: Run doctor --fix and retry
  log_recovery "Level 2: Running openclaw doctor --fix..."
  run_doctor_fix >> "$log" 2>&1
  if run_smart_recovery; then
    return 0
  fi
  
  # Level 3: Clear state and retry
  log_recovery "Level 3: Clearing corrupted state..."
  clear_corrupted_state >> "$log" 2>&1
  if run_smart_recovery; then
    return 0
  fi
  
  # Level 4: Give up
  log_recovery "CRITICAL: All recovery attempts failed!"
  notify_user_emergency "🚨 CRITICAL: All recovery attempts failed! Manual intervention required."
  
  return 1
}

# =============================================================================
# Script Entry Point (when run directly)
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Source environment if available
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  [ -f /etc/droplet.env ] && source /etc/droplet.env
  
  # Defensive base64 decoding for standalone execution
  # (droplet.env stores API keys as base64-encoded values)
  d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(d "${ANTHROPIC_KEY_B64:-}")}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$(d "${OPENAI_KEY_B64:-}")}"
  export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$(d "${GOOGLE_API_KEY_B64:-}")}"
  export BRAVE_API_KEY="${BRAVE_API_KEY:-$(d "${BRAVE_KEY_B64:-}")}"
  
  run_smart_recovery
fi
