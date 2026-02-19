#!/bin/bash
# lib-permissions.sh — Centralized permission utilities for Hatchery
#
# Source this file in any script that creates bot-owned directories/files.
# Usage: source /usr/local/sbin/lib-permissions.sh
#
# Functions:
#   ensure_bot_dir <path> [mode]           - Create/fix directory with bot ownership
#   ensure_bot_file <path> [mode]          - Create/fix file with bot ownership  
#   fix_bot_permissions [home]             - Fix all standard bot directories
#   fix_workspace_permissions [home]       - Fix workspace (clawd/) permissions
#   fix_state_permissions [home]           - Fix state (.openclaw*) permissions
#   fix_agent_workspace <agent_dir>        - Fix single agent workspace
#   fix_session_state <state_dir>          - Fix session isolation state dir
#

# Resolve bot username (default: bot)
BOT_USER="${USERNAME:-${SVC_USER:-bot}}"
BOT_HOME="${HOME_DIR:-/home/${BOT_USER}}"

# Log helper (only if log function exists)
_perm_log() {
  if type log &>/dev/null; then
    log "  [permissions] $*"
  fi
}

# Create a directory with correct bot ownership
# Usage: ensure_bot_dir /path/to/dir [mode]
ensure_bot_dir() {
  local dir="$1"
  local mode="${2:-755}"
  
  if [ ! -d "$dir" ]; then
    # Use install to create with correct ownership atomically
    install -d -o "$BOT_USER" -g "$BOT_USER" -m "$mode" "$dir" 2>/dev/null || {
      # Fallback if install fails (e.g., parent not writable)
      mkdir -p "$dir" 2>/dev/null
      chown "$BOT_USER:$BOT_USER" "$dir" 2>/dev/null || true
      chmod "$mode" "$dir" 2>/dev/null || true
    }
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

# Fix a single agent workspace directory
# Usage: fix_agent_workspace /home/bot/clawd/agents/agent1
fix_agent_workspace() {
  local agent_dir="$1"
  [ -d "$agent_dir" ] || return 0
  
  # Ensure the agent dir and subdirs exist with correct ownership
  ensure_bot_dir "$agent_dir" 755
  ensure_bot_dir "$agent_dir/memory" 755
  ensure_bot_dir "$agent_dir/sessions" 755
  ensure_bot_dir "$agent_dir/.openclaw" 700
  
  # Fix ownership recursively
  chown -R "$BOT_USER:$BOT_USER" "$agent_dir" 2>/dev/null || true
}

# Fix workspace (clawd/) permissions
# Usage: fix_workspace_permissions [home]
fix_workspace_permissions() {
  local home="${1:-$BOT_HOME}"
  
  # Main workspace structure
  ensure_bot_dir "$home/clawd" 755
  ensure_bot_dir "$home/clawd/agents" 755
  ensure_bot_dir "$home/clawd/shared" 755
  ensure_bot_dir "$home/clawd/memory" 755
  
  # Fix each agent workspace
  for agent_dir in "$home/clawd/agents"/*/; do
    [ -d "$agent_dir" ] || continue
    fix_agent_workspace "$agent_dir"
  done
  
  # Shared files
  ensure_bot_file "$home/clawd/TOOLS.md" 644
  ensure_bot_file "$home/clawd/HEARTBEAT.md" 644
  
  # Shared directory contents
  if [ -d "$home/clawd/shared" ]; then
    chown -R "$BOT_USER:$BOT_USER" "$home/clawd/shared" 2>/dev/null || true
  fi
}

# Fix state (.openclaw*) permissions  
# Usage: fix_state_permissions [home]
fix_state_permissions() {
  local home="${1:-$BOT_HOME}"
  
  # Main OpenClaw state
  ensure_bot_dir "$home/.openclaw" 700
  ensure_bot_dir "$home/.openclaw/credentials" 700
  ensure_bot_dir "$home/.openclaw/agents" 700
  ensure_bot_dir "$home/.openclaw/agents/main" 700
  ensure_bot_dir "$home/.openclaw/agents/main/agent" 700
  
  # Sensitive config files (600 = owner read/write only)
  ensure_bot_file "$home/.openclaw/openclaw.json" 600
  ensure_bot_file "$home/.openclaw/openclaw.full.json" 600
  ensure_bot_file "$home/.openclaw/openclaw.emergency.json" 600
  ensure_bot_file "$home/.openclaw/agents/main/agent/auth-profiles.json" 600
  
  # Safe-mode agent state
  if [ -d "$home/.openclaw/agents/safe-mode" ]; then
    chown -R "$BOT_USER:$BOT_USER" "$home/.openclaw/agents/safe-mode" 2>/dev/null || true
  fi
  
  # Session isolation state directories
  if [ -d "$home/.openclaw-sessions" ]; then
    chown -R "$BOT_USER:$BOT_USER" "$home/.openclaw-sessions" 2>/dev/null || true
    chmod 700 "$home/.openclaw-sessions" 2>/dev/null || true
  fi
}

# Fix session isolation state directory
# Usage: fix_session_state /home/bot/.openclaw-sessions/documents
fix_session_state() {
  local state_dir="$1"
  [ -d "$state_dir" ] || return 0
  
  # Fix the state directory itself
  ensure_bot_dir "$state_dir" 700
  
  # Fix agent subdirectories
  if [ -d "$state_dir/agents" ]; then
    for agent_dir in "$state_dir/agents"/*/; do
      [ -d "$agent_dir" ] || continue
      ensure_bot_dir "$agent_dir" 700
      ensure_bot_dir "$agent_dir/agent" 700
      ensure_bot_file "$agent_dir/agent/auth-profiles.json" 600
    done
  fi
  
  # Recursive fix for anything we missed
  chown -R "$BOT_USER:$BOT_USER" "$state_dir" 2>/dev/null || true
}

# Fix systemd config directory for session isolation
# Usage: fix_session_config_dir /etc/systemd/system/documents
fix_session_config_dir() {
  local config_dir="$1"
  [ -d "$config_dir" ] || return 0
  
  # Config dirs need to be readable by systemd but config files secured
  chmod 755 "$config_dir" 2>/dev/null || true
  
  # Config file contains tokens - restrict access
  if [ -f "$config_dir/openclaw.session.json" ]; then
    chown "$BOT_USER:$BOT_USER" "$config_dir/openclaw.session.json" 2>/dev/null || true
    chmod 600 "$config_dir/openclaw.session.json" 2>/dev/null || true
  fi
}

# Fix permissions on all standard bot directories
# Call this BEFORE starting any services that run as bot
# Usage: fix_bot_permissions [home]
fix_bot_permissions() {
  local home="${1:-$BOT_HOME}"
  
  _perm_log "Fixing permissions for $home (user: $BOT_USER)"
  
  # Home directory itself
  ensure_bot_dir "$home" 750
  
  # Fix workspace (clawd/) - must happen BEFORE services start
  fix_workspace_permissions "$home"
  
  # Fix state (.openclaw*) 
  fix_state_permissions "$home"
  
  _perm_log "Permissions fixed"
}

# Export functions for use in other scripts
export BOT_USER BOT_HOME
export -f ensure_bot_dir ensure_bot_file 
export -f fix_agent_workspace fix_workspace_permissions fix_state_permissions
export -f fix_session_state fix_session_config_dir fix_bot_permissions
