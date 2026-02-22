#!/bin/bash
# =============================================================================
# generate-config.sh — Single source of truth for OpenClaw config generation
# =============================================================================
# Replaces 5 separate heredoc config generators with one jq-based script.
# All JSON is built via jq — no bash string interpolation for JSON values.
#
# Usage:
#   generate-config.sh --mode full --gateway-token TOKEN
#   generate-config.sh --mode session --group NAME --agents "a1,a2" --port 18790 --gateway-token TOKEN
#   generate-config.sh --mode safe-mode --token BOT_TOKEN --provider anthropic --platform telegram \
#                       --bot-token BOT_TK --owner-id 12345 --model anthropic/claude-sonnet-4-5 --gateway-token TOKEN
#
# Modes:
#   full       — Complete production config (all agents, all channels, browser, skills)
#   session    — Per-group config for session isolation (filtered agents, specific port)
#   safe-mode  — Emergency recovery config (single SafeModeBot agent)
#
# Environment:
#   Reads from /etc/droplet.env and /etc/habitat-parsed.env (via lib-env.sh).
#   AGENT{N}_NAME, AGENT{N}_MODEL, AGENT{N}_BOT_TOKEN, AGENT{N}_DISCORD_BOT_TOKEN
#   PLATFORM, TELEGRAM_OWNER_ID, DISCORD_OWNER_ID, DISCORD_GUILD_ID, etc.
#
# Output: JSON config to stdout. Validate with: generate-config.sh ... | jq .
# =============================================================================
set -euo pipefail

# --- Source lib-env.sh ---
for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-env.sh" ] && { source "$_lib_path/lib-env.sh"; break; }
done
type d &>/dev/null || { echo "FATAL: lib-env.sh not found" >&2; exit 1; }

# --- Parse arguments ---
MODE=""
GROUP=""
GROUP_AGENTS=""
PORT="18789"
GATEWAY_TOKEN=""
SM_API_TOKEN=""
SM_PROVIDER=""
SM_PLATFORM=""
SM_BOT_TOKEN=""
SM_OWNER_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)       MODE="$2"; shift 2 ;;
    --group)      GROUP="$2"; shift 2 ;;
    --agents)     GROUP_AGENTS="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --gateway-token) GATEWAY_TOKEN="$2"; shift 2 ;;
    --token)      SM_API_TOKEN="$2"; shift 2 ;;
    --provider)   SM_PROVIDER="$2"; shift 2 ;;
    --platform)   SM_PLATFORM="$2"; shift 2 ;;
    --bot-token)  SM_BOT_TOKEN="$2"; shift 2 ;;
    --owner-id)   SM_OWNER_ID="$2"; shift 2 ;;
    --model)      SM_MODEL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -z "$MODE" ] && { echo "Usage: generate-config.sh --mode <full|session|safe-mode> [options]" >&2; exit 1; }
[ -z "$GATEWAY_TOKEN" ] && { echo "Error: --gateway-token required" >&2; exit 1; }

# --- Load environment (non-fatal in test mode) ---
if [ -z "${TEST_MODE:-}" ]; then
  env_load || true
else
  # In test mode, env vars are set by the test harness
  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env 2>/dev/null || true
fi
env_decode_keys 2>/dev/null || true

# --- Common variables ---
HOME_DIR="/home/${USERNAME:-bot}"
AGENT_COUNT="${AGENT_COUNT:-1}"

# Determine platform enables
_platform="${PLATFORM:-telegram}"
_tg_enabled=false; _dc_enabled=false
case "$_platform" in
  telegram) _tg_enabled=true ;;
  discord)  _dc_enabled=true ;;
  both)     _tg_enabled=true; _dc_enabled=true ;;
esac

# =============================================================================
# Config Section Builders
# =============================================================================

# Build the gateway section (common to all modes)
build_gateway() {
  jq -n \
    --arg port "$PORT" \
    --arg token "$GATEWAY_TOKEN" \
    '{
      mode: "local",
      port: ($port | tonumber),
      bind: "loopback",
      controlUi: { enabled: true, allowInsecureAuth: true },
      auth: { mode: "token", token: $token }
    }'
}

# Build the agents list for full/session modes
# Args: comma-separated agent IDs to include (empty = all)
build_agents() {
  local filter_agents="${1:-}"
  local agents_json="[]"

  for i in $(seq 1 "$AGENT_COUNT"); do
    local agent_id="agent${i}"

    # Filter by group if specified
    if [ -n "$filter_agents" ]; then
      echo "$filter_agents" | tr ',' '\n' | grep -qx "$agent_id" || continue
    fi

    local name_var="AGENT${i}_NAME"; local name="${!name_var:-Agent${i}}"
    local model_var="AGENT${i}_MODEL"; local model="${!model_var:-anthropic/claude-sonnet-4-5}"
    local is_first=false
    [ "$(echo "$agents_json" | jq 'length')" = "0" ] && is_first=true

    agents_json=$(echo "$agents_json" | jq \
      --arg id "$agent_id" \
      --arg name "$name" \
      --arg model "$model" \
      --arg workspace "${HOME_DIR}/clawd/agents/${agent_id}" \
      --argjson default "$is_first" \
      '. + [{
        id: $id,
        default: $default,
        name: $name,
        model: $model,
        workspace: $workspace,
        groupChat: { mentionPatterns: [($name + ","), ($name + ":")] }
      }]')
  done

  echo "$agents_json"
}

# Build telegram channel config
# Args: comma-separated agent IDs to include (empty = all)
build_telegram_channel() {
  local filter_agents="${1:-}"
  local owner_id="${TELEGRAM_OWNER_ID:-$(d "${TELEGRAM_USER_ID_B64:-}")}"

  # Build accounts object
  local accounts="{}"
  for i in $(seq 1 "$AGENT_COUNT"); do
    local agent_id="agent${i}"
    if [ -n "$filter_agents" ]; then
      echo "$filter_agents" | tr ',' '\n' | grep -qx "$agent_id" || continue
    fi
    local tok_var="AGENT${i}_BOT_TOKEN"; local tok="${!tok_var:-}"
    [ -z "$tok" ] && continue
    accounts=$(echo "$accounts" | jq --arg id "$agent_id" --arg tok "$tok" \
      '. + {($id): {botToken: $tok}}')
  done

  # Build groups if council group configured
  local groups="null"
  local cgi="${COUNCIL_GROUP_ID:-}"
  if [ -n "$cgi" ]; then
    groups=$(jq -n --arg gid "$cgi" '{($gid): {requireMention: true}, "*": {requireMention: true}}')
  fi

  jq -n \
    --argjson enabled "$_tg_enabled" \
    --arg owner_id "$owner_id" \
    --argjson accounts "$accounts" \
    --argjson groups "$groups" \
    '{
      enabled: $enabled,
      dmPolicy: "allowlist",
      allowFrom: [$owner_id],
      accounts: $accounts
    } + (if $groups != null then {groups: $groups} else {} end)'
}

# Build discord channel config
# Args: comma-separated agent IDs to include (empty = all)
build_discord_channel() {
  local filter_agents="${1:-}"
  local owner_id="${DISCORD_OWNER_ID:-$(d "${DISCORD_OWNER_ID_B64:-}")}"
  local guild_id="${DISCORD_GUILD_ID:-$(d "${DISCORD_GUILD_ID_B64:-}")}"

  # Build accounts object
  local accounts="{}"
  for i in $(seq 1 "$AGENT_COUNT"); do
    local agent_id="agent${i}"
    if [ -n "$filter_agents" ]; then
      echo "$filter_agents" | tr ',' '\n' | grep -qx "$agent_id" || continue
    fi
    local tok_var="AGENT${i}_DISCORD_BOT_TOKEN"; local tok="${!tok_var:-}"
    [ -z "$tok" ] && continue
    accounts=$(echo "$accounts" | jq --arg id "$agent_id" --arg tok "$tok" \
      '. + {($id): {token: $tok}}')
  done

  # Build guilds if guild ID set
  local guilds="null"
  if [ -n "$guild_id" ]; then
    guilds=$(jq -n --arg gid "$guild_id" '{($gid): {requireMention: true}}')
  fi

  # Build DM config
  local dm_config
  if [ -n "$owner_id" ]; then
    dm_config=$(jq -n --arg oid "$owner_id" '{enabled: true, policy: "pairing", allowFrom: [$oid]}')
  else
    dm_config=$(jq -n '{enabled: true, policy: "pairing"}')
  fi

  jq -n \
    --argjson enabled "$_dc_enabled" \
    --argjson accounts "$accounts" \
    --argjson dm "$dm_config" \
    --argjson guilds "$guilds" \
    '{
      enabled: $enabled,
      groupPolicy: "allowlist",
      accounts: $accounts,
      dm: $dm
    } + (if $guilds != null then {guilds: $guilds} else {} end)'
}

# Build bindings array (maps non-default agents to their channel accounts)
build_bindings() {
  local filter_agents="${1:-}"
  local bindings="[]"
  local first=true

  for i in $(seq 1 "$AGENT_COUNT"); do
    local agent_id="agent${i}"
    if [ -n "$filter_agents" ]; then
      echo "$filter_agents" | tr ',' '\n' | grep -qx "$agent_id" || continue
    fi

    # First agent in the list is the default — doesn't need a binding
    if [ "$first" = "true" ]; then
      first=false
      continue
    fi

    if [ "$_tg_enabled" = "true" ]; then
      bindings=$(echo "$bindings" | jq --arg aid "$agent_id" \
        '. + [{agentId: $aid, match: {channel: "telegram", accountId: $aid}}]')
    fi
    if [ "$_dc_enabled" = "true" ]; then
      bindings=$(echo "$bindings" | jq --arg aid "$agent_id" \
        '. + [{agentId: $aid, match: {channel: "discord", accountId: $aid}}]')
    fi
  done

  echo "$bindings"
}

# Build env section
build_env() {
  local env_obj
  env_obj=$(jq -n --arg ak "${ANTHROPIC_API_KEY:-}" '{ANTHROPIC_API_KEY: $ak, DISPLAY: ":10"}')

  local gk="${GOOGLE_API_KEY:-}"
  if [ -n "$gk" ]; then
    env_obj=$(echo "$env_obj" | jq --arg k "$gk" '. + {GOOGLE_API_KEY: $k, GEMINI_API_KEY: $k}')
  fi

  local bk="${BRAVE_API_KEY:-}"
  if [ -n "$bk" ]; then
    env_obj=$(echo "$env_obj" | jq --arg k "$bk" '. + {BRAVE_API_KEY: $k}')
  fi

  echo "$env_obj"
}

# Build auth profiles
build_auth_profiles() {
  local profiles='{}'
  profiles=$(echo "$profiles" | jq '. + {"anthropic:default": {provider: "anthropic", mode: "api_key"}}')

  local oa="${OPENAI_ACCESS_B64:-}"
  if [ -n "$oa" ] && [ -n "$(d "$oa")" ]; then
    profiles=$(echo "$profiles" | jq '. + {"openai-codex:default": {provider: "openai-codex", mode: "oauth"}}')
  fi

  local gk="${GOOGLE_API_KEY:-}"
  if [ -n "$gk" ]; then
    profiles=$(echo "$profiles" | jq '. + {"google:default": {provider: "google", mode: "api_key"}}')
  fi

  echo "$profiles"
}

# =============================================================================
# Mode: full — Complete production config
# =============================================================================
generate_full() {
  local agents_list bindings_json env_json tg_channel dc_channel auth_profiles

  agents_list=$(build_agents "")
  bindings_json=$(build_bindings "")
  env_json=$(build_env)
  tg_channel=$(build_telegram_channel "")
  dc_channel=$(build_discord_channel "")
  auth_profiles=$(build_auth_profiles)

  jq -n \
    --argjson env "$env_json" \
    --argjson agents_list "$agents_list" \
    --argjson bindings "$bindings_json" \
    --argjson gateway "$(build_gateway)" \
    --argjson auth_profiles "$auth_profiles" \
    --argjson tg "$tg_channel" \
    --argjson dc "$dc_channel" \
    --argjson tg_enabled "$_tg_enabled" \
    --argjson dc_enabled "$_dc_enabled" \
    --arg workspace "${HOME_DIR}/clawd" \
    '{
      env: $env,
      browser: {
        enabled: true,
        executablePath: "/usr/bin/google-chrome-stable",
        headless: false,
        noSandbox: true
      },
      tools: {
        agentToAgent: { enabled: true },
        exec: { security: "full", ask: "off" }
      },
      agents: {
        defaults: {
          model: { primary: "anthropic/claude-opus-4-5" },
          maxConcurrent: 4,
          workspace: $workspace,
          heartbeat: { every: "30m", session: "heartbeat" },
          models: {
            "openai/gpt-5.2": { params: { reasoning_effort: "high" } }
          }
        },
        list: $agents_list
      },
      bindings: $bindings,
      gateway: $gateway,
      auth: { profiles: $auth_profiles },
      plugins: {
        entries: {
          telegram: { enabled: $tg_enabled },
          discord: { enabled: $dc_enabled }
        }
      },
      channels: {
        telegram: $tg,
        discord: $dc
      },
      skills: { install: { nodeManager: "npm" } },
      hooks: {
        internal: {
          enabled: true,
          entries: { "boot-md": { enabled: true } }
        }
      }
    }'
}

# =============================================================================
# Mode: session — Per-group config for session isolation
# =============================================================================
generate_session() {
  [ -z "$GROUP" ] && { echo "Error: --group required for session mode" >&2; exit 1; }
  [ -z "$GROUP_AGENTS" ] && { echo "Error: --agents required for session mode" >&2; exit 1; }

  local agents_list bindings_json tg_channel dc_channel

  agents_list=$(build_agents "$GROUP_AGENTS")
  bindings_json=$(build_bindings "$GROUP_AGENTS")
  tg_channel=$(build_telegram_channel "$GROUP_AGENTS")
  dc_channel=$(build_discord_channel "$GROUP_AGENTS")

  jq -n \
    --argjson agents_list "$agents_list" \
    --argjson bindings "$bindings_json" \
    --argjson gateway "$(build_gateway)" \
    --argjson tg "$tg_channel" \
    --argjson dc "$dc_channel" \
    --argjson tg_enabled "$_tg_enabled" \
    --argjson dc_enabled "$_dc_enabled" \
    --arg workspace "${HOME_DIR}/clawd" \
    '{
      agents: {
        defaults: {
          model: { primary: "anthropic/claude-opus-4-5" },
          maxConcurrent: 4,
          workspace: $workspace
        },
        list: $agents_list
      },
      bindings: $bindings,
      gateway: $gateway,
      channels: {
        telegram: $tg,
        discord: $dc
      },
      plugins: {
        entries: {
          telegram: { enabled: $tg_enabled },
          discord: { enabled: $dc_enabled }
        }
      }
    }'
}

# =============================================================================
# Mode: safe-mode — Emergency recovery config
# =============================================================================
generate_safe_mode() {
  [ -z "$SM_BOT_TOKEN" ] && { echo "Error: --bot-token required for safe-mode" >&2; exit 1; }
  [ -z "$SM_PLATFORM" ] && SM_PLATFORM="${_platform}"
  [ -z "$SM_PROVIDER" ] && SM_PROVIDER="anthropic"
  [ -z "$SM_OWNER_ID" ] && SM_OWNER_ID="${TELEGRAM_OWNER_ID:-${DISCORD_OWNER_ID:-}}"

  # Build env section based on provider
  local env_json='{}'
  if [ -n "$SM_API_TOKEN" ]; then
    case "$SM_PROVIDER" in
      anthropic) env_json=$(jq -n --arg k "$SM_API_TOKEN" '{ANTHROPIC_API_KEY: $k}') ;;
      openai)    env_json=$(jq -n --arg k "$SM_API_TOKEN" '{OPENAI_API_KEY: $k}') ;;
      google)    env_json=$(jq -n --arg k "$SM_API_TOKEN" '{GOOGLE_API_KEY: $k, GEMINI_API_KEY: $k}') ;;
    esac
  fi

  # Use explicitly passed model, or fall back to provider default
  # NOTE: Keep in sync with get_default_model_for_provider() in lib-auth.sh
  local model="${SM_MODEL:-}"
  if [ -z "$model" ]; then
    case "$SM_PROVIDER" in
      anthropic) model="anthropic/claude-sonnet-4-5" ;;
      openai)    model="openai/gpt-4.1-mini" ;;
      google)    model="google/gemini-2.5-flash" ;;
      *)         model="anthropic/claude-sonnet-4-5" ;;
    esac
  fi

  # Build channel config
  local tg_config dc_config
  if [ "$SM_PLATFORM" = "telegram" ]; then
    tg_config=$(jq -n --arg tok "$SM_BOT_TOKEN" --arg oid "$SM_OWNER_ID" \
      '{enabled: true, accounts: {"safe-mode": {botToken: $tok}}, dmPolicy: "allowlist", allowFrom: [$oid]}')
    dc_config=$(jq -n '{enabled: false}')
  elif [ "$SM_PLATFORM" = "discord" ]; then
    tg_config=$(jq -n '{enabled: false}')
    dc_config=$(jq -n --arg tok "$SM_BOT_TOKEN" --arg oid "$SM_OWNER_ID" \
      '{enabled: true, accounts: {"safe-mode": {token: $tok}}, dmPolicy: "allowlist", allowFrom: [$oid]}')
  else
    tg_config=$(jq -n '{enabled: false}')
    dc_config=$(jq -n '{enabled: false}')
  fi

  jq -n \
    --argjson env "$env_json" \
    --argjson gateway "$(build_gateway)" \
    --argjson tg "$tg_config" \
    --argjson dc "$dc_config" \
    --arg model "$model" \
    --arg workspace "${HOME_DIR}/clawd/agents/safe-mode" \
    --arg defaults_workspace "${HOME_DIR}/clawd" \
    '{
      env: $env,
      tools: {
        exec: { security: "full", ask: "off" }
      },
      agents: {
        defaults: {
          model: { primary: $model },
          workspace: $defaults_workspace
        },
        list: [{
          id: "safe-mode",
          default: true,
          name: "SafeModeBot",
          model: $model,
          workspace: $workspace
        }]
      },
      gateway: $gateway,
      channels: {
        telegram: $tg,
        discord: $dc
      }
    }'
}

# =============================================================================
# Main dispatch
# =============================================================================
case "$MODE" in
  full)      generate_full ;;
  session)   generate_session ;;
  safe-mode) generate_safe_mode ;;
  *)         echo "Unknown mode: $MODE" >&2; exit 1 ;;
esac
