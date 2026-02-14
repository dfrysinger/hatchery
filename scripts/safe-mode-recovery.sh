#!/bin/bash
# =============================================================================
# safe-mode-recovery.sh -- Smart Safe Mode Recovery
# =============================================================================
# Purpose:  When full config fails, intelligently find working credentials
#           and generate an emergency config to get a bot online.
#
# Features:
#   - Token hunting: Try all bot tokens until one works
#   - API fallback: Try Anthropic → OpenAI → Gemini
#   - Emergency config: Generate minimal working config
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
# Token Validation Functions
# =============================================================================

# Validate a Telegram bot token by calling getMe
validate_telegram_token() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  # In test mode, use mock
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 1
  fi
  
  response=$(curl -sf --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null)
  [ $? -eq 0 ] && echo "$response" | jq -e '.ok == true' >/dev/null 2>&1
}

# Validate a Discord bot token by calling /users/@me
validate_discord_token() {
  local token="$1"
  [ -z "$token" ] && return 1
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 1
  fi
  
  response=$(curl -sf --max-time 10 \
    -H "Authorization: Bot ${token}" \
    "https://discord.com/api/v10/users/@me" 2>/dev/null)
  [ $? -eq 0 ] && echo "$response" | jq -e '.id' >/dev/null 2>&1
}

# Validate an API key by making a minimal request
validate_api_key() {
  local provider="$1"
  local key="$2"
  [ -z "$key" ] && return 1
  
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 1
  fi
  
  case "$provider" in
    anthropic)
      # Anthropic: Try a minimal messages request (will fail with 400 but auth succeeds)
      response=$(curl -sf --max-time 10 \
        -H "x-api-key: ${key}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        "https://api.anthropic.com/v1/messages" 2>&1)
      # 200 = success, 400 = bad request but auth OK, 401/403 = auth failed
      [ $? -eq 0 ] || echo "$response" | grep -q '"type"'
      ;;
    openai)
      # OpenAI: Check models endpoint
      response=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${key}" \
        "https://api.openai.com/v1/models" 2>/dev/null)
      [ $? -eq 0 ] && echo "$response" | jq -e '.data' >/dev/null 2>&1
      ;;
    google)
      # Google: Check models endpoint
      response=$(curl -sf --max-time 10 \
        "https://generativelanguage.googleapis.com/v1/models?key=${key}" 2>/dev/null)
      [ $? -eq 0 ] && echo "$response" | jq -e '.models' >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# =============================================================================
# Token Hunting Functions
# =============================================================================

# Find a working Telegram token from all agents
find_working_telegram_token() {
  local count="${AGENT_COUNT:-0}"
  
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    local token="${!token_var:-}"
    
    # Also try generic BOT_TOKEN
    [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
    
    [ -z "$token" ] && continue
    
    if $VALIDATE_TELEGRAM_TOKEN_FN "$token"; then
      echo "$token"
      return 0
    fi
  done
  
  echo ""
  return 1
}

# Find a working Discord token from all agents
find_working_discord_token() {
  local count="${AGENT_COUNT:-0}"
  
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
    local token="${!token_var:-}"
    
    [ -z "$token" ] && continue
    
    if $VALIDATE_DISCORD_TOKEN_FN "$token"; then
      echo "$token"
      return 0
    fi
  done
  
  echo ""
  return 1
}

# Find a working platform and token
find_working_platform_and_token() {
  local tg_token=$(find_working_telegram_token)
  if [ -n "$tg_token" ]; then
    echo "telegram:$tg_token"
    return 0
  fi
  
  local dc_token=$(find_working_discord_token)
  if [ -n "$dc_token" ]; then
    echo "discord:$dc_token"
    return 0
  fi
  
  echo ""
  return 1
}

# =============================================================================
# API Key Fallback Functions
# =============================================================================

# Check if OAuth profile exists and is valid in auth-profiles.json
check_oauth_profile() {
  local provider="$1"
  local auth_file="${AUTH_PROFILES_PATH:-}"
  
  # Skip OAuth check in test mode unless explicitly testing OAuth
  if [ "${TEST_MODE:-}" = "1" ] && [ "${TEST_OAUTH:-}" != "1" ]; then
    return 1
  fi
  
  # Find auth-profiles.json
  if [ -z "$auth_file" ]; then
    local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
    for path in \
      "$home/.openclaw/agents/agent1/agent/auth-profiles.json" \
      "$home/.openclaw/agent/auth-profiles.json"; do
      [ -f "$path" ] && auth_file="$path" && break
    done
  fi
  
  [ -z "$auth_file" ] || [ ! -f "$auth_file" ] && return 1
  
  # Map provider name to auth-profiles key
  local profile_key=""
  case "$provider" in
    anthropic) profile_key="anthropic:default" ;;
    openai)    profile_key="openai-codex:default" ;;
    google)    profile_key="google:default" ;;
    *)         return 1 ;;
  esac
  
  # Check if profile exists and has access token
  local access_token
  access_token=$(jq -r ".profiles[\"$profile_key\"].access // empty" "$auth_file" 2>/dev/null)
  
  if [ -n "$access_token" ] && [ "$access_token" != "null" ]; then
    # Check if expired (if expires field exists)
    local expires
    expires=$(jq -r ".profiles[\"$profile_key\"].expires // empty" "$auth_file" 2>/dev/null)
    if [ -n "$expires" ] && [ "$expires" != "null" ]; then
      local now=$(date +%s)
      local exp_ts=$((expires / 1000))  # Convert ms to seconds if needed
      [ "$exp_ts" -lt 1000000000000 ] || exp_ts=$((expires / 1000))
      if [ "$now" -lt "$exp_ts" ]; then
        echo "oauth"
        return 0
      fi
    else
      # No expiry, assume valid
      echo "oauth"
      return 0
    fi
  fi
  
  return 1
}

# Find a working API provider (Anthropic → OpenAI → Gemini)
# Checks both OAuth (auth-profiles.json) and API keys
find_working_api_provider() {
  local providers=("anthropic" "openai" "google")
  
  for provider in "${providers[@]}"; do
    # First check OAuth profile
    if check_oauth_profile "$provider" >/dev/null 2>&1; then
      echo "$provider"
      return 0
    fi
    
    # Then check API key
    local key=""
    case "$provider" in
      anthropic) key="${ANTHROPIC_API_KEY:-}" ;;
      openai)    key="${OPENAI_API_KEY:-}" ;;
      google)    key="${GOOGLE_API_KEY:-}" ;;
    esac
    
    if [ -n "$key" ] && $VALIDATE_API_KEY_FN "$provider" "$key"; then
      echo "$provider"
      return 0
    fi
  done
  
  echo ""
  return 1
}

# Get auth type for a provider (oauth or apikey)
get_auth_type_for_provider() {
  local provider="$1"
  if check_oauth_profile "$provider" >/dev/null 2>&1; then
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
    anthropic) echo "anthropic/claude-sonnet-4" ;;
    openai)    echo "openai/gpt-4o" ;;
    google)    echo "google/gemini-2.0-flash" ;;
    *)         echo "anthropic/claude-sonnet-4" ;;
  esac
}

# =============================================================================
# Emergency Config Generation
# =============================================================================

# Generate emergency config with working credentials
generate_emergency_config() {
  local token="$1"
  local platform="$2"
  local provider="$3"
  local api_key="$4"
  local agent_name="${5:-RecoveryBot}"
  local auth_type="${6:-apikey}"  # oauth or apikey
  
  local model=$(get_default_model_for_provider "$provider")
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local gateway_token=$(openssl rand -hex 16 2>/dev/null || echo "emergency-token-$(date +%s)")
  
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
    telegram_config="\"telegram\": {
      \"enabled\": true,
      \"botToken\": \"${token}\",
      \"ownerId\": \"${TELEGRAM_OWNER_ID:-}\",
      \"allowlist\": { \"mode\": \"owner\" }
    }"
  elif [ "$platform" = "discord" ]; then
    discord_config="\"discord\": {
      \"enabled\": true,
      \"botToken\": \"${token}\",
      \"ownerId\": \"${DISCORD_OWNER_ID:-}\",
      \"guildId\": \"${DISCORD_GUILD_ID:-}\",
      \"allowlist\": { \"mode\": \"owner\" }
    }"
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
        "id": "agent1",
        "default": true,
        "name": "${agent_name}",
        "workspace": "${home}/clawd/agents/agent1"
      }
    ]
  },
  "gateway": {
    "mode": "local",
    "port": 18789,
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
# Main Recovery Function
# =============================================================================

# Run smart recovery - find working credentials and generate emergency config
run_smart_recovery() {
  local log="${RECOVERY_LOG:-/var/log/safe-mode-recovery.log}"
  
  # Use temp log in test mode
  if [ "${TEST_MODE:-}" = "1" ]; then
    log="${TEST_TMPDIR:-/tmp}/safe-mode-recovery.log"
  fi
  
  log_recovery() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$log"
  }
  
  log_recovery "Starting smart recovery..."
  
  # Step 1: Find working platform and token
  log_recovery "Step 1: Searching for working bot token..."
  local platform_token=$(find_working_platform_and_token)
  
  if [ -z "$platform_token" ]; then
    log_recovery "ERROR: No working bot tokens found"
    echo "ERROR: No working bot tokens found" >&2
    return 1
  fi
  
  local platform="${platform_token%%:*}"
  local token="${platform_token#*:}"
  log_recovery "Found working token for platform: $platform"
  
  # Step 2: Find working API provider
  log_recovery "Step 2: Searching for working API provider..."
  local provider=$(find_working_api_provider)
  
  if [ -z "$provider" ]; then
    log_recovery "ERROR: No working API providers found"
    echo "ERROR: No working API providers found" >&2
    return 1
  fi
  
  local api_key=$(get_api_key_for_provider "$provider")
  local auth_type=$(get_auth_type_for_provider "$provider")
  log_recovery "Found working API provider: $provider (auth: $auth_type)"
  
  # Step 3: Generate emergency config
  log_recovery "Step 3: Generating emergency config..."
  local agent_name="${AGENT1_NAME:-RecoveryBot}"
  local config=$(generate_emergency_config "$token" "$platform" "$provider" "$api_key" "$agent_name" "$auth_type")
  
  # Step 4: Write emergency config
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local config_path="${home}/.openclaw/openclaw.json"
  
  if [ "${DRY_RUN:-}" != "1" ]; then
    echo "$config" > "$config_path"
    chmod 600 "$config_path"
    [ -n "${USERNAME:-}" ] && chown "${USERNAME}:${USERNAME}" "$config_path" 2>/dev/null
    log_recovery "Emergency config written to $config_path"
  else
    log_recovery "DRY_RUN: Would write config to $config_path"
  fi
  
  log_recovery "Smart recovery completed successfully"
  log_recovery "  Platform: $platform"
  log_recovery "  Provider: $provider"
  log_recovery "  Model: $(get_default_model_for_provider "$provider")"
  
  # Output result for callers
  echo "platform=$platform"
  echo "provider=$provider"
  echo "token_found=true"
  
  return 0
}

# =============================================================================
# Script Entry Point (when run directly)
# =============================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Source environment if available
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  [ -f /etc/droplet.env ] && source /etc/droplet.env
  
  run_smart_recovery
fi
