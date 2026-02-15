#!/bin/bash
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
# Returns: agent_num:token (e.g., "2:abc123...")
find_working_telegram_token() {
  local count="${AGENT_COUNT:-0}"
  
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_TELEGRAM_BOT_TOKEN"
    local token="${!token_var:-}"
    
    # Also try generic BOT_TOKEN
    [ -z "$token" ] && token_var="AGENT${i}_BOT_TOKEN" && token="${!token_var:-}"
    
    [ -z "$token" ] && continue
    
    if $VALIDATE_TELEGRAM_TOKEN_FN "$token"; then
      echo "${i}:${token}"
      return 0
    fi
  done
  
  echo ""
  return 1
}

# Find a working Discord token from all agents
# Returns: agent_num:token (e.g., "2:abc123...")
find_working_discord_token() {
  local count="${AGENT_COUNT:-0}"
  
  for i in $(seq 1 "$count"); do
    local token_var="AGENT${i}_DISCORD_BOT_TOKEN"
    local token="${!token_var:-}"
    
    [ -z "$token" ] && continue
    
    if $VALIDATE_DISCORD_TOKEN_FN "$token"; then
      echo "${i}:${token}"
      return 0
    fi
  done
  
  echo ""
  return 1
}

# Find a working platform and token
# Returns: platform:agent_num:token (e.g., "telegram:2:abc123...")
find_working_platform_and_token() {
  local tg_result=$(find_working_telegram_token)
  if [ -n "$tg_result" ]; then
    echo "telegram:$tg_result"
    return 0
  fi
  
  local dc_result=$(find_working_discord_token)
  if [ -n "$dc_result" ]; then
    echo "discord:$dc_result"
    return 0
  fi
  
  echo ""
  return 1
}

# Get the model for a specific agent from habitat config
# Falls back to provider default if not found
get_agent_model() {
  local agent_num="$1"
  local provider="$2"
  
  # Try to get the agent's configured model
  local model_var="AGENT${agent_num}_MODEL"
  local model="${!model_var:-}"
  
  if [ -n "$model" ]; then
    echo "$model"
    return 0
  fi
  
  # Fall back to provider default
  get_default_model_for_provider "$provider"
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
    anthropic) echo "anthropic/claude-sonnet-4-5" ;;
    openai)    echo "openai/gpt-4o" ;;
    google)    echo "google/gemini-2.0-flash" ;;
    *)         echo "anthropic/claude-sonnet-4-5" ;;
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

# Generate emergency config with working credentials
generate_emergency_config() {
  local token="$1"
  local platform="$2"
  local provider="$3"
  local api_key="$4"
  local agent_name="${5:-SafeModeBot}"  # Default to SafeModeBot, not agent's name
  local auth_type="${6:-apikey}"  # oauth or apikey
  local model="${7:-}"  # Use provided model or fall back to default
  
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
    local owner_id="${DISCORD_OWNER_ID:-}"
    local guild_id="${DISCORD_GUILD_ID:-}"
    if [ -n "$owner_id" ]; then
      discord_config="\"discord\": {
        \"enabled\": true,
        \"token\": \"${token}\",
        \"dm\": {
          \"policy\": \"allowlist\",
          \"allowFrom\": [\"${owner_id}\"]
        }
      }"
    else
      discord_config="\"discord\": {
        \"enabled\": true,
        \"token\": \"${token}\",
        \"dm\": { \"policy\": \"pairing\" }
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
# Resilience Functions
# =============================================================================

# Check network connectivity
check_network() {
  if [ "${TEST_MODE:-}" = "1" ]; then
    return 0  # Assume network OK in tests
  fi
  
  # Try multiple endpoints
  for host in "api.telegram.org" "discord.com" "api.anthropic.com" "1.1.1.1"; do
    if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
      return 0
    fi
    if curl -sf --max-time 3 "https://$host" >/dev/null 2>&1; then
      return 0
    fi
  done
  
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

# Backup current config as last-known-good
backup_working_config() {
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local config_path="$home/.openclaw/openclaw.json"
  local backup_path="$home/.openclaw/openclaw.last-good.json"
  
  if [ -f "$config_path" ]; then
    cp "$config_path" "$backup_path" 2>/dev/null || true
  fi
}

# Restore last-known-good config
restore_last_good_config() {
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local config_path="$home/.openclaw/openclaw.json"
  local backup_path="$home/.openclaw/openclaw.last-good.json"
  
  if [ -f "$backup_path" ]; then
    cp "$backup_path" "$config_path" 2>/dev/null
    return $?
  fi
  
  return 1
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
  
  log_recovery() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$log"
  }
  
  log_recovery "========== SMART RECOVERY STARTING =========="
  
  # Step 0: Check network connectivity
  log_recovery "Step 0: Checking network connectivity..."
  if ! check_network; then
    log_recovery "WARNING: Network connectivity issues detected"
    notify_user_emergency "⚠️ Safe Mode: Network connectivity issues. Recovery may fail."
  else
    log_recovery "Network OK"
  fi
  
  # Step 1: Find working platform and token
  log_recovery "Step 1: Searching for working bot token..."
  local platform_token=$(find_working_platform_and_token)
  
  if [ -z "$platform_token" ]; then
    log_recovery "ERROR: No working bot tokens found"
    log_recovery "Attempting openclaw doctor --fix..."
    run_doctor_fix >> "$log" 2>&1
    
    # Retry after doctor
    platform_token=$(find_working_platform_and_token)
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
  local provider=$(find_working_api_provider)
  
  if [ -z "$provider" ]; then
    log_recovery "WARNING: No working API providers found via validation"
    log_recovery "Attempting to use default Anthropic (may fail at runtime)"
    provider="anthropic"  # Fallback - let it fail at runtime rather than here
  fi
  
  local api_key=$(get_api_key_for_provider "$provider")
  local auth_type=$(get_auth_type_for_provider "$provider")
  log_recovery "Using API provider: $provider (auth: $auth_type)"
  
  # Get the model - prefer the working agent's configured model
  local model=$(get_agent_model "$agent_num" "$provider")
  log_recovery "Using model: $model"
  
  # Step 3: Generate emergency config
  log_recovery "Step 3: Generating emergency config..."
  # Use SafeModeBot identity - don't inherit original agent's name/identity
  # The safe-mode workspace has its own IDENTITY.md and SOUL.md
  local config=$(generate_emergency_config "$token" "$platform" "$provider" "$api_key" "SafeModeBot" "$auth_type" "$model")
  
  # Validate config JSON
  if ! validate_config_json "$config"; then
    log_recovery "ERROR: Generated config is invalid JSON!"
    echo "ERROR: Generated invalid config" >&2
    return 1
  fi
  log_recovery "Config JSON validated OK"
  
  # Step 4: Write emergency config
  local home="${HOME_DIR:-/home/${USERNAME:-bot}}"
  local config_dir="${home}/.openclaw"
  local config_path="${config_dir}/openclaw.json"
  
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
  else
    log_recovery "DRY_RUN: Would write config to $config_path"
  fi
  
  log_recovery "========== SMART RECOVERY COMPLETED =========="
  log_recovery "  Platform: $platform"
  log_recovery "  Provider: $provider (auth: $auth_type)"
  log_recovery "  Model: $(get_default_model_for_provider "$provider")"
  
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
  
  # Level 4: Try last-known-good config
  log_recovery "Level 4: Attempting last-known-good config..."
  if restore_last_good_config; then
    log_recovery "Restored last-known-good config"
    return 0
  fi
  
  # Level 5: Give up
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
  
  run_smart_recovery
fi
