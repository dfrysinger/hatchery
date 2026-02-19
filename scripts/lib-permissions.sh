#!/bin/bash
# lib-permissions.sh — Centralized permission utilities for Hatchery
#
# Source this file in any script that creates bot-owned directories.
# Usage: source /usr/local/sbin/lib-permissions.sh
#
# Functions:
#   ensure_bot_dir <path>     - Create directory owned by bot user
#   ensure_bot_file <path>    - Ensure file is owned by bot user
#   fix_bot_permissions       - Fix all standard bot directories
#

# Resolve bot username (default: bot)
BOT_USER="${USERNAME:-${SVC_USER:-bot}}"
BOT_HOME="${HOME_DIR:-/home/${BOT_USER}}"

# Create a directory with correct bot ownership
# Usage: ensure_bot_dir /path/to/dir [mode]
ensure_bot_dir() {
  local dir="$1"
  local mode="${2:-755}"
  
  if [ ! -d "$dir" ]; then
    # Use install to create with correct ownership atomically
    install -d -o "$BOT_USER" -g "$BOT_USER" -m "$mode" "$dir"
  else
    # Directory exists, fix ownership if needed
    chown "$BOT_USER:$BOT_USER" "$dir" 2>/dev/null || true
    chmod "$mode" "$dir" 2>/dev/null || true
  fi
}

# Ensure a file has correct bot ownership
# Usage: ensure_bot_file /path/to/file [mode]
ensure_bot_file() {
  local file="$1"
  local mode="${2:-644}"
  
  if [ -f "$file" ]; then
    chown "$BOT_USER:$BOT_USER" "$file" 2>/dev/null || true
    chmod "$mode" "$file" 2>/dev/null || true
  fi
}

# Fix permissions on all standard bot directories
# Call this before starting any services that run as bot
fix_bot_permissions() {
  local home="${1:-$BOT_HOME}"
  
  # Core directories
  ensure_bot_dir "$home" 750
  ensure_bot_dir "$home/.openclaw" 700
  ensure_bot_dir "$home/clawd" 755
  ensure_bot_dir "$home/clawd/agents" 755
  
  # Agent workspaces
  for agent_dir in "$home/clawd/agents"/*/; do
    [ -d "$agent_dir" ] || continue
    chown -R "$BOT_USER:$BOT_USER" "$agent_dir" 2>/dev/null || true
  done
  
  # Session state directories
  if [ -d "$home/.openclaw-sessions" ]; then
    chown -R "$BOT_USER:$BOT_USER" "$home/.openclaw-sessions" 2>/dev/null || true
  fi
  
  # OpenClaw state
  if [ -d "$home/.openclaw" ]; then
    chown -R "$BOT_USER:$BOT_USER" "$home/.openclaw" 2>/dev/null || true
  fi
  
  # Sensitive files
  ensure_bot_file "$home/.openclaw/openclaw.json" 600
  ensure_bot_file "$home/.openclaw/openclaw.full.json" 600
  ensure_bot_file "$home/.openclaw/openclaw.emergency.json" 600
}

# Export functions for use in other scripts
export -f ensure_bot_dir ensure_bot_file fix_bot_permissions
