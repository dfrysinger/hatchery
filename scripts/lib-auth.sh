#!/bin/bash
# =============================================================================
# lib-auth.sh -- Shared authentication and token utilities
# =============================================================================
# Purpose:  Centralizes auth header generation, API key validation, and
#           platform token discovery. Sourced by gateway-health-check.sh,
#           safe-mode-recovery.sh, and related scripts.
#
# Usage:    source "$(dirname "$0")/lib-auth.sh"
#
# Functions:
#   get_anthropic_auth_header <key>  — Returns auth header for Anthropic keys
#   validate_api_key <provider> <key> — Validates provider API keys
#   find_working_token <platform>     — Finds working token from agents in GROUP
# =============================================================================

# Global for validation results (avoids subshell issues)
VALIDATION_REASON=""

# Global for token search results
FOUND_TOKEN_RESULT=""

# -----------------------------------------------------------------------------
# get_anthropic_auth_header -- Return the correct auth header for Anthropic keys
# Arguments: $1 = API key
# Outputs:   prints the header string (e.g., "x-api-key: sk-..." or "Authorization: Bearer sk-...")
# Returns:   0 always
# -----------------------------------------------------------------------------
get_anthropic_auth_header() {
  local key="$1"
  if [[ "$key" == sk-ant-oat* ]]; then
    echo "Authorization: Bearer ${key}"
  else
    echo "x-api-key: ${key}"
  fi
}

# -----------------------------------------------------------------------------
# is_anthropic_oauth_token -- Check if key is an OAuth Access Token
# Arguments: $1 = API key
# Returns:   0 if OAuth, 1 if not
# -----------------------------------------------------------------------------
is_anthropic_oauth_token() {
  [[ "$1" == sk-ant-oat* ]]
}

# -----------------------------------------------------------------------------
# validate_api_key -- Validate a provider API key via HTTP
# Arguments: $1 = provider (anthropic|openai|google)
#            $2 = API key
# Sets:      VALIDATION_REASON (global) with result description
# Returns:   0 if valid, 1 if invalid/error
# -----------------------------------------------------------------------------
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
      if is_anthropic_oauth_token "$key"; then
        # OAuth tokens cannot be validated via API, trust them if present
        VALIDATION_REASON="OAuth token (trusted)"
        return 0
      fi
      local auth_header
      auth_header="$(get_anthropic_auth_header "$key")"
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

# -----------------------------------------------------------------------------
# generate_auth_profiles_json -- Generate auth-profiles.json for a provider
# Arguments: $1 = provider (anthropic|openai|google)
#            $2 = API key
# Outputs:   prints JSON string
# -----------------------------------------------------------------------------
generate_auth_profiles_json() {
  local provider="$1"
  local key="$2"

  if [ -z "$provider" ] || [ -z "$key" ]; then
    echo '{}'
    return
  fi

  printf '{"version":1,"profiles":{"%s:default":{"type":"api_key","provider":"%s","token":"%s"}}}' \
    "$provider" "$provider" "$key"
}

# -----------------------------------------------------------------------------
# find_working_token -- Find a working platform token from agents in GROUP
# Arguments: $1 = platform (telegram|discord)
# Requires:  AGENT_COUNT, AGENT{N}_TELEGRAM_BOT_TOKEN / AGENT{N}_DISCORD_BOT_TOKEN,
#            GROUP (optional, for session isolation filtering),
#            VALIDATE_TELEGRAM_TOKEN_FN / VALIDATE_DISCORD_TOKEN_FN (validation function names),
#            diag_add() function (optional, for diagnostics)
# Sets:      FOUND_TOKEN_RESULT with "agent_num:token" (e.g., "2:abc123...")
# Returns:   0 if found, 1 if not
# -----------------------------------------------------------------------------
find_working_token() {
  local platform="$1"
  local count="${AGENT_COUNT:-0}"
  local current_group="${GROUP:-}"
  FOUND_TOKEN_RESULT=""

  local token_var_suffix validate_fn
  case "$platform" in
    telegram)
      token_var_suffix="TELEGRAM_BOT_TOKEN"
      validate_fn="${VALIDATE_TELEGRAM_TOKEN_FN:-validate_telegram_token}"
      ;;
    discord)
      token_var_suffix="DISCORD_BOT_TOKEN"
      validate_fn="${VALIDATE_DISCORD_TOKEN_FN:-validate_discord_token}"
      ;;
    *)
      return 1
      ;;
  esac

  for i in $(seq 1 "$count"); do
    # If GROUP is set (session isolation), only consider agents in this group
    if [ -n "$current_group" ]; then
      local agent_group_var="AGENT${i}_ISOLATION_GROUP"
      local agent_group="${!agent_group_var:-}"
      if [ "$agent_group" != "$current_group" ]; then
        continue
      fi
    fi

    local token_var="AGENT${i}_${token_var_suffix}"
    local token="${!token_var:-}"

    # For telegram, also try generic BOT_TOKEN
    if [ -z "$token" ] && [ "$platform" = "telegram" ]; then
      token_var="AGENT${i}_BOT_TOKEN"
      token="${!token_var:-}"
    fi

    if [ -z "$token" ]; then
      continue
    fi

    VALIDATION_REASON=""
    if $validate_fn "$token"; then
      # Call diag_add if available
      if type diag_add &>/dev/null; then
        diag_add "$platform" "agent${i}" "✅" "valid"
      fi
      [ -z "$FOUND_TOKEN_RESULT" ] && FOUND_TOKEN_RESULT="${i}:${token}"
    else
      if type diag_add &>/dev/null; then
        diag_add "$platform" "agent${i}" "❌" "${VALIDATION_REASON:-unknown}"
      fi
    fi
  done

  [ -n "$FOUND_TOKEN_RESULT" ] && return 0
  return 1
}

# -----------------------------------------------------------------------------
# resolve_config_path -- Determine the correct OpenClaw config file path
# Uses OPENCLAW_CONFIG_PATH if set, otherwise constructs from ISOLATION/GROUP/USERNAME
# Arguments: none (reads environment variables)
# Outputs:   prints the resolved config path
# Returns:   0 always
# -----------------------------------------------------------------------------
resolve_config_path() {
  local home="/home/${USERNAME:-bot}"

  if [ -n "${OPENCLAW_CONFIG_PATH:-}" ]; then
    echo "$OPENCLAW_CONFIG_PATH"
  elif [ "${ISOLATION:-}" = "session" ] || [ -n "${GROUP:-}" ]; then
    echo "${home}/.openclaw-sessions/${GROUP:-default}/openclaw.session.json"
  else
    echo "${home}/.openclaw/openclaw.json"
  fi
}
