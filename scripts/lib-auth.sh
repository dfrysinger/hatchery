#!/bin/bash
# =============================================================================
# lib-auth.sh — Shared authentication and token validation library
# =============================================================================
# Single source of truth for token validation, auth header construction,
# provider discovery, and token hunting. Extracted from safe-mode-recovery.sh
# to eliminate duplication across health check and recovery scripts.
#
# Dependencies: lib-env.sh (for d()), curl, jq
# Optional: log() function (falls back to stderr if not defined)
#
# Usage:
#   source /usr/local/sbin/lib-auth.sh
#   validate_telegram_token "$token"
#   get_auth_header "anthropic" "sk-ant-oat01-..."
#   find_working_telegram_token
# =============================================================================

# Ensure log() exists (caller should define, but provide fallback)
type log &>/dev/null || log() { echo "[lib-auth] $*" >&2; }

# Global result variables (avoid subshell issues with $())
VALIDATION_REASON=""
FOUND_TOKEN_RESULT=""
# shellcheck disable=SC2034  # Read by callers after find_working_api_provider returns
FOUND_API_PROVIDER=""

# =============================================================================
# Diagnostic Recording (opt-in)
# =============================================================================
# Set AUTH_DIAG_LOG to a file path to record validation results.
# Default: /dev/null (no overhead when diagnostics aren't needed).
# Format: category:name:icon:reason  (one line per validation attempt)
#
# Usage:
#   export AUTH_DIAG_LOG="/var/log/auth-diagnostics.log"
#   find_working_telegram_token   # results logged automatically
#   cat "$AUTH_DIAG_LOG"          # telegram:agent1:✅:valid
# =============================================================================
AUTH_DIAG_LOG="${AUTH_DIAG_LOG:-/dev/null}"

_diag() { echo "$*" >> "$AUTH_DIAG_LOG"; }

# =============================================================================
# Auth Header Construction
# =============================================================================

# Returns the correct HTTP auth header for a provider + token.
# Usage: header=$(get_auth_header "anthropic" "$token")
#        curl -H "$header" ...
get_auth_header() {
  local provider="$1"
  local token="$2"

  case "$provider" in
    anthropic)
      if [[ "$token" == sk-ant-oat* ]]; then
        echo "Authorization: Bearer ${token}"
      else
        echo "x-api-key: ${token}"
      fi
      ;;
    openai|openai-codex)
      echo "Authorization: Bearer ${token}"
      ;;
    google)
      # Google uses query param, but some endpoints accept header
      echo "x-goog-api-key: ${token}"
      ;;
    *)
      echo "Authorization: Bearer ${token}"
      ;;
  esac
}

# =============================================================================
# Token Validation
# =============================================================================

# Validate a Telegram bot token via getMe API
validate_telegram_token() {
  local token="$1"
  [ -z "$token" ] && return 1

  if [ "${TEST_MODE:-}" = "1" ]; then
    # In test mode, tokens starting with "VALID" pass, others fail
    [[ "$token" == VALID* ]] && return 0 || return 1
  fi

  local response
  if response=$(curl -sf --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>&1) \
     && echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    return 0
  fi

  log "  Telegram token validation failed"
  return 1
}

# Validate a Discord bot token via users/@me API
validate_discord_token() {
  local token="$1"
  [ -z "$token" ] && return 1

  if [ "${TEST_MODE:-}" = "1" ]; then
    [[ "$token" == VALID* ]] && return 0 || return 1
  fi

  local response
  if response=$(curl -sf --max-time 10 \
       -H "Authorization: Bot ${token}" \
       "https://discord.com/api/v10/users/@me" 2>&1) \
     && echo "$response" | jq -e '.id' >/dev/null 2>&1; then
    return 0
  fi

  log "  Discord token validation failed"
  return 1
}

# Validate an API key for a given provider
# Sets VALIDATION_REASON with the result.
# OAuth tokens (sk-ant-oat*) are trusted without an API call.
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

  # OAuth tokens cannot be validated via API — trust them
  if [[ "$key" == sk-ant-oat* ]]; then
    VALIDATION_REASON="OAuth token (trusted)"
    return 0
  fi

  local http_code response
  local auth_hdr
  auth_hdr=$(get_auth_header "$provider" "$key")

  case "$provider" in
    anthropic)
      # Use /v1/models endpoint — lightweight auth check, no model name needed
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "$auth_hdr" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" 2>/dev/null)
      ;;
    openai)
      response=$(curl -s --max-time 10 -w "\n%{http_code}" \
        -H "$auth_hdr" \
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
    400) VALIDATION_REASON="400 bad request"; return 1 ;;
    401) VALIDATION_REASON="401 unauthorized"; return 1 ;;
    403) VALIDATION_REASON="403 forbidden"; return 1 ;;
    429) VALIDATION_REASON="429 rate limited"; return 1 ;;
    000) VALIDATION_REASON="timeout"; return 1 ;;
    *)   VALIDATION_REASON="http ${http_code}"; return 1 ;;
  esac
}

# =============================================================================
# Provider Utilities
# =============================================================================

# Extract provider name from model string
# "anthropic/claude-opus-4-5" → "anthropic"
get_provider_from_model() {
  local model="$1"
  echo "${model%%/*}"
}

# Build ordered list of providers to try
# Order: user's preferred → anthropic → openai → google
get_provider_order() {
  local user_pref
  user_pref=$(get_provider_from_model "${AGENT1_MODEL:-anthropic/claude-sonnet-4-5}")

  local ordered=("$user_pref")
  for p in "anthropic" "openai" "google"; do
    # shellcheck disable=SC2076
    [[ " ${ordered[*]} " =~ " $p " ]] && continue
    ordered+=("$p")
  done

  echo "${ordered[@]}"
}

# Get default model for a provider
get_default_model_for_provider() {
  local provider="$1"
  case "$provider" in
    anthropic)    echo "anthropic/claude-sonnet-4-5" ;;
    openai)       echo "openai/gpt-4.1-mini" ;;
    google)       echo "google/gemini-2.5-flash" ;;
    openai-codex) echo "openai/gpt-4.1-mini" ;;
    *)            echo "anthropic/claude-sonnet-4-5" ;;
  esac
}

# =============================================================================
# Token Discovery
# =============================================================================

# Find a working Telegram token from agents in current GROUP (or all agents).
# Sets: FOUND_TOKEN_RESULT with "agent_num:token"
find_working_telegram_token() {
  local count="${AGENT_COUNT:-0}"
  local current_group="${GROUP:-}"
  FOUND_TOKEN_RESULT=""

  for i in $(seq 1 "$count"); do
    # Filter by group if set
    if [ -n "$current_group" ]; then
      local group_var="AGENT${i}_ISOLATION_GROUP"
      local agent_group="${!group_var:-}"
      [ "$agent_group" != "$current_group" ] && continue
    fi

    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    local token="${!token_var:-}"
    # Fallback to AGENT{N}_BOT_TOKEN
    [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"

    if [ -z "$token" ]; then
      _diag "telegram:agent${i}:⬚:no token"
      continue
    fi

    if validate_telegram_token "$token"; then
      _diag "telegram:agent${i}:✅:valid"
      FOUND_TOKEN_RESULT="${i}:${token}"
      return 0
    else
      _diag "telegram:agent${i}:❌:invalid"
    fi
  done

  return 1
}

# Find a working Discord token from agents in current GROUP (or all agents).
# Sets: FOUND_TOKEN_RESULT with "agent_num:token"
find_working_discord_token() {
  local count="${AGENT_COUNT:-0}"
  local current_group="${GROUP:-}"
  FOUND_TOKEN_RESULT=""

  for i in $(seq 1 "$count"); do
    if [ -n "$current_group" ]; then
      local group_var="AGENT${i}_ISOLATION_GROUP"
      local agent_group="${!group_var:-}"
      [ "$agent_group" != "$current_group" ] && continue
    fi

    local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
    local token="${!token_var:-}"

    if [ -z "$token" ]; then
      _diag "discord:agent${i}:⬚:no token"
      continue
    fi

    if validate_discord_token "$token"; then
      _diag "discord:agent${i}:✅:valid"
      FOUND_TOKEN_RESULT="${i}:${token}"
      return 0
    else
      _diag "discord:agent${i}:❌:invalid"
    fi
  done

  return 1
}

# Find a working token on the preferred platform, then cross-platform fallback.
# Sets: FOUND_TOKEN_RESULT with "platform:agent_num:token"
find_working_platform_token() {
  local preferred="${PLATFORM:-${HC_PLATFORM:-telegram}}"
  FOUND_TOKEN_RESULT=""

  # Try preferred platform first
  if [ "$preferred" = "telegram" ] || [ "$preferred" = "both" ]; then
    if find_working_telegram_token; then
      FOUND_TOKEN_RESULT="telegram:${FOUND_TOKEN_RESULT}"
      return 0
    fi
  fi
  if [ "$preferred" = "discord" ] || [ "$preferred" = "both" ]; then
    if find_working_discord_token; then
      FOUND_TOKEN_RESULT="discord:${FOUND_TOKEN_RESULT}"
      return 0
    fi
  fi

  # Cross-platform fallback
  if [ "$preferred" = "telegram" ]; then
    if find_working_discord_token; then
      FOUND_TOKEN_RESULT="discord:${FOUND_TOKEN_RESULT}"
      log "  Cross-platform fallback to Discord"
      return 0
    fi
  elif [ "$preferred" = "discord" ]; then
    if find_working_telegram_token; then
      FOUND_TOKEN_RESULT="telegram:${FOUND_TOKEN_RESULT}"
      log "  Cross-platform fallback to Telegram"
      return 0
    fi
  fi

  return 1
}

# Find a working API provider.
# Checks API keys in provider order: user's default → anthropic → openai → google.
# Sets: FOUND_API_PROVIDER with provider name
find_working_api_provider() {
  local providers
  read -ra providers <<< "$(get_provider_order)"
  FOUND_API_PROVIDER=""

  for provider in "${providers[@]}"; do
    local key=""
    case "$provider" in
      anthropic) key="${ANTHROPIC_API_KEY:-}" ;;
      openai)    key="${OPENAI_API_KEY:-}" ;;
      google)    key="${GOOGLE_API_KEY:-}" ;;
    esac

    if [ -z "$key" ]; then
      _diag "api:${provider}:⬚:no key"
      continue
    fi

    if validate_api_key "$provider" "$key"; then
      _diag "api:${provider}:✅:${VALIDATION_REASON:-valid}"
      # shellcheck disable=SC2034  # Read by callers
      FOUND_API_PROVIDER="$provider"
      return 0
    else
      _diag "api:${provider}:❌:${VALIDATION_REASON:-failed}"
    fi
  done

  return 1
}
