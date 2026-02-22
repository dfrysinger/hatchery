#!/bin/bash
# shellcheck disable=SC2155  # Declare and assign separately - acceptable here as we don't check return values
# =============================================================================
# safe-mode-recovery.sh -- Smart Safe Mode Recovery
# =============================================================================

# Source shared libraries
[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh

for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-env.sh" ] && { source "$_lib_path/lib-env.sh"; break; }
done

for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-auth.sh" ] && { source "$_lib_path/lib-auth.sh"; break; }
done
type validate_api_key &>/dev/null || { echo "FATAL: lib-auth.sh not found" >&2; exit 1; }

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
# Diagnostics:
#   Set AUTH_DIAG_LOG before sourcing this file to record diagnostics.
#   lib-auth.sh handles token/API diagnostics; this file adds network/doctor.
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
#   AUTH_DIAG_LOG         - Diagnostic log file (set by caller, defaults /dev/null)
#
# Rule: Call these functions directly (not in subshells) when you need their
# side effects. Use `local var; var=$(func)` only for pure return values.
# =============================================================================

# validate_telegram_token() — now in lib-auth.sh


# validate_discord_token() — now in lib-auth.sh


# validate_api_key() — now in lib-auth.sh


# =============================================================================
# Token Hunting Functions
# =============================================================================

# Global variables for function results (avoids subshell issues with $())
VALIDATION_REASON=""
FOUND_TOKEN_RESULT=""

# find_working_telegram_token() — now in lib-auth.sh


# find_working_discord_token() — now in lib-auth.sh


# Global variable for function results (avoids subshell issues)
FOUND_TOKEN_RESULT=""

# Find a working platform and token
# Order: User's default platform (PLATFORM env var) first, then fallback platform
# Tries ALL tokens from preferred platform before moving to fallback
# Sets: FOUND_TOKEN_RESULT with platform:agent_num:token (e.g., "telegram:2:abc123...")
# Returns: 0 if found, 1 if not
# find_working_platform_and_token() — delegates to lib-auth.sh
find_working_platform_and_token() {
  find_working_platform_token
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

# get_provider_from_model() — now in lib-auth.sh


# get_user_preferred_provider() — now in lib-auth.sh


# get_provider_order() — now in lib-auth.sh


# Global for API provider result
FOUND_API_PROVIDER=""

# Global for OAuth check result (avoids subshell issues)
OAUTH_CHECK_RESULT=""       # "oauth:<provider>" on success, empty on failure
OAUTH_CHECK_REASON=""       # failure reason for diagnostics
OAUTH_CHECK_PROVIDER=""     # actual provider name (e.g., openai-codex for openai)

# Default log_recovery to no-op if not defined (allows function use outside run_smart_recovery)
type log_recovery &>/dev/null || log_recovery() { :; }

# find_working_api_provider() — now in lib-auth.sh


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

# get_default_model_for_provider() — now in lib-auth.sh


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
  
  # Set up diagnostics — lib-auth.sh records token/API results here
  local diag_file="${AUTH_DIAG_LOG:-/var/log/auth-diagnostics.log}"
  [ "${TEST_MODE:-}" = "1" ] && diag_file="${TEST_TMPDIR:-/tmp}/auth-diagnostics.log"
  export AUTH_DIAG_LOG="$diag_file"
  : > "$AUTH_DIAG_LOG"  # Reset for this run
  chmod 600 "$AUTH_DIAG_LOG" 2>/dev/null || true
  
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
    _diag "network:connectivity:❌:unreachable"
    notify_user_emergency "⚠️ Safe Mode: Network connectivity issues. Recovery may fail."
  else
    log_recovery "Network OK"
    _diag "network:connectivity:✅:ok"
  fi
  
  # Step 1: Find working platform and token
  log_recovery "Step 1: Searching for working bot token..."
  # Call directly (not in subshell) to preserve diagnostic array modifications
  find_working_platform_and_token
  local platform_token="$FOUND_TOKEN_RESULT"
  
  if [ -z "$platform_token" ]; then
    log_recovery "ERROR: No working bot tokens found"
    log_recovery "Attempting openclaw doctor --fix..."
    if run_doctor_fix >> "$log" 2>&1; then
      _diag "doctor:fix:✅:completed"
    else
      _diag "doctor:fix:❌:errors"
    fi
    
    # Retry after doctor
    find_working_platform_and_token
    platform_token="$FOUND_TOKEN_RESULT"
    if [ -z "$platform_token" ]; then
      log_recovery "ERROR: Still no working tokens after doctor --fix"
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
  # Use SafeModeBot identity via generate-config.sh --mode safe-mode
  local GEN_CONFIG_SCRIPT=""
  for _gc_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
    [ -f "$_gc_path/generate-config.sh" ] && { GEN_CONFIG_SCRIPT="$_gc_path/generate-config.sh"; break; }
  done
  if [ -z "$GEN_CONFIG_SCRIPT" ]; then
    log_recovery "FATAL: generate-config.sh not found"
    return 1
  fi

  local gw_token
  gw_token=$(openssl rand -hex 16 2>/dev/null || echo "emergency-$(date +%s)")
  local owner_id="${TELEGRAM_OWNER_ID:-${DISCORD_OWNER_ID:-}}"

  local config
  config=$("$GEN_CONFIG_SCRIPT" --mode safe-mode \
    --token "${api_key:-}" \
    --provider "$provider" \
    --platform "$platform" \
    --bot-token "$token" \
    --owner-id "$owner_id" \
    --model "$model" \
    --gateway-token "$gw_token" \
    --port "${GROUP_PORT:-18789}")
  
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
  # ~/.openclaw/configs/${GROUP}/openclaw.session.json
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local config_dir config_path
  
  if [ -n "${OPENCLAW_CONFIG_PATH:-}" ]; then
    # Use the config path from systemd environment
    config_path="$OPENCLAW_CONFIG_PATH"
    config_dir="$(dirname "$config_path")"
    log_recovery "  Using OPENCLAW_CONFIG_PATH: ${config_path}"
  elif [ -n "${GROUP:-}" ]; then
    config_dir="${home}/.openclaw/configs/${GROUP}"
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
      "key": "${api_key}"
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
      "key": "${api_key}"
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
      "key": "${api_key}"
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
  log_recovery "  Diagnostics: $AUTH_DIAG_LOG"
  
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
