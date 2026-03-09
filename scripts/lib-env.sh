#!/bin/bash
# =============================================================================
# lib-env.sh — Shared environment loading and base64 decode
# =============================================================================
# Single source of truth for the d() base64 decoder, env file loading,
# and API key decoding. Source this instead of copy-pasting d() everywhere.
#
# Usage:
#   source /usr/local/sbin/lib-env.sh
#   env_load                 # Source droplet.env + habitat-parsed.env
#   env_decode_keys          # Decode B64 API keys to standard env vars
#   d "$SOME_B64_VALUE"      # Decode any base64 value
#
# All functions are safe to call multiple times (idempotent).
# =============================================================================

# --- Base64 decode helper ---
# Returns decoded string, or empty string for empty/invalid input.
d() { [ -n "${1:-}" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

# --- Load standard environment files ---
# Sources /etc/droplet.env (secrets) and /etc/habitat-parsed.env (parsed habitat config).
# Returns 0 on success, 1 if droplet.env is missing (non-fatal in test mode).
# Safely parses a KEY=VALUE env file as data only; missing files are non-fatal so
# callers can use this helper behind existence checks without extra branching.
env_load_file_safe() {
  local env_file="$1"
  local line line_no key value

  [ -f "$env_file" ] || return 0
  line_no=0

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue

    if [[ "$line" =~ ^export[[:space:]]+ ]]; then
      line="${line#export }"
    fi

    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "WARNING: unsafe env syntax in ${env_file}:${line_no}" >&2
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    if [[ "$value" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    else
      if [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+\#.*$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      value="${value%"${value##*[![:space:]]}"}"
    fi

    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$env_file"
}

env_load() {
  if [ -f /etc/droplet.env ]; then
    set -a; source /etc/droplet.env; set +a
  elif [ -z "${TEST_MODE:-}" ]; then
    echo "WARNING: /etc/droplet.env not found" >&2
    return 1
  fi

  [ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
  return 0
}

# --- Stage management ---
# Single source of truth for boot stage transitions.
# Monotonic: only advances forward, never goes backward.
# Stage map: 0-8=provisioning, 9=restarting, 10=health-check,
#            11=ready, 12=safe-mode, 13=critical-failure
INIT_STATUS_DIR="/var/lib/init-status"

set_stage() {
  local new="${1:?Usage: set_stage <number>}"
  local current
  current=$(cat "$INIT_STATUS_DIR/stage" 2>/dev/null || echo 0)
  [ "$new" -le "$current" ] && return 0
  echo "$new" > "$INIT_STATUS_DIR/stage" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) STAGE=$new DESC=${2:-}" >> /var/log/init-stages.log 2>/dev/null || true
}

# --- Decode API keys from base64 environment variables ---
# Populates standard *_API_KEY vars from their *_B64 counterparts.
# Will NOT overwrite existing values (respects pre-set env vars).
env_decode_keys() {
  export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(d "${ANTHROPIC_KEY_B64:-}")}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$(d "${OPENAI_KEY_B64:-}")}"
  export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$(d "${GOOGLE_API_KEY_B64:-}")}"
  export BRAVE_API_KEY="${BRAVE_API_KEY:-$(d "${BRAVE_KEY_B64:-}")}"
}
