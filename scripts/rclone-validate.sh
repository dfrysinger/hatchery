#!/bin/bash
# =============================================================================
# rclone-validate.sh -- Path validation functions for safe rclone operations
# =============================================================================
# Purpose:  Prevent dangerous rclone operations caused by empty variables,
#           root paths, or unexpected local/remote targets.
#
# Usage:    source ./rclone-validate.sh
#           validate_rclone_path "$src" "$dst" || exit 1
#           rclone copy "$src" "$dst"
#
# Functions:
#   validate_rclone_path SRC DST
#     Returns 0 if paths are safe, 1 otherwise.
#
#   safe_rclone_copy SRC DST [extra rclone args...]
#     Validates then runs: rclone copy ...
#
#   safe_rclone_su_copy USER SRC DST [extra rclone args...]
#     Validates then runs rclone copy via: su - USER -c ...
# =============================================================================

rclone_is_remote_path() {
  case "$1" in
    [A-Za-z0-9_-]*:*) return 0 ;;
    *) return 1 ;;
  esac
}

_validate_one_path() {
  # Usage: _validate_one_path <path> <role:source|destination>
  local p="$1"
  local role="$2"
  local p_trim

  if [ -z "${p}" ]; then
    echo "ERROR: refusing rclone copy: ${role} path is empty" >&2
    return 1
  fi

  # Reject whitespace-only
  if [ -z "${p//[[:space:]]/}" ]; then
    echo "ERROR: refusing rclone copy: ${role} path is empty" >&2
    return 1
  fi

  # Trim trailing slashes for root check
  p_trim="${p%/}"
  [ -z "$p_trim" ] && p_trim="/"

  if [ "$p_trim" = "/" ] || [ "$p_trim" = "/*" ]; then
    echo "ERROR: refusing rclone copy: ${role} path is '/'" >&2
    return 1
  fi

  # Reject obvious remote roots / no-path remotes
  if rclone_is_remote_path "$p"; then
    # shellcheck disable=SC2221,SC2222  # Patterns are intentionally overlapping for readability
    case "$p" in
      *:|*:/*|*:/\*)
        # dropbox:, dropbox:/, dropbox:/*
        echo "ERROR: refusing rclone copy: ${role} remote path is unsafe: '$p'" >&2
        return 1
        ;;
    esac

    # Expected remote layout for this repo.
    # Require habitat segment to avoid accidentally targeting the remote root.
    if ! echo "$p" | grep -Eq '^dropbox:openclaw-memory/[^/]+(/.*)?$'; then
      echo "ERROR: refusing rclone copy: ${role} remote path is unexpected: '$p'" >&2
      return 1
    fi
  else
    # Expected local layout for this repo.
    if ! echo "$p" | grep -Eq '^/home/[^/]+/(clawd|\.openclaw)(/.*)?$'; then
      echo "ERROR: refusing rclone copy: ${role} local path is unexpected: '$p'" >&2
      return 1
    fi
  fi

  return 0
}

validate_rclone_path() {
  local src="$1"
  local dst="$2"

  _validate_one_path "$src" source || return 1
  _validate_one_path "$dst" destination || return 1

  return 0
}

safe_rclone_copy() {
  local src="$1"
  local dst="$2"
  shift 2 || true

  validate_rclone_path "$src" "$dst" || return 2
  command rclone copy "$src" "$dst" "$@"
}

safe_rclone_su_copy() {
  local user="$1"
  local src="$2"
  local dst="$3"
  shift 3 || true

  if [ -z "${user}" ]; then
    echo "ERROR: refusing rclone copy: USERNAME is empty" >&2
    return 2
  fi

  validate_rclone_path "$src" "$dst" || return 2

  local cmd
  cmd="rclone copy $(printf %q "$src") $(printf %q "$dst")"
  local arg
  for arg in "$@"; do
    cmd+=" $(printf %q "$arg")"
  done

  su - "$user" -c "$cmd"
}

export -f validate_rclone_path 2>/dev/null || true
export -f safe_rclone_copy 2>/dev/null || true
export -f safe_rclone_su_copy 2>/dev/null || true
