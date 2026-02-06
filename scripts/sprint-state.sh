#!/usr/bin/env bash
# =============================================================================
# sprint-state.sh -- Manage sprint-state.json for EL crash recovery
# =============================================================================
# Requires: bash, jq, python3
#
# Commands:
#   init <SPRINT>
#   update <TASK_ID> <STATUS> [WORKER] [PR]
#   get
#   get-task <TASK_ID>
#   list-tasks <STATUS>
#
# Env:
#   SPRINT_STATE_FILE (default: sprint-state.json)
# =============================================================================
set -euo pipefail

STATE_FILE="${SPRINT_STATE_FILE:-sprint-state.json}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[sprint-state] ERROR: missing dependency: $1" >&2
    exit 1
  }
}
need jq
need python3

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Atomic write with fsync + replace
atomic_write() {
  local path="$1"
  local content="$2"

  python3 - "$path" <<'PY'
import os, sys, tempfile
path = sys.argv[1]
content = sys.stdin.read()

# Temp file in same directory for atomic replace
base_dir = os.path.dirname(os.path.abspath(path)) or "."
os.makedirs(base_dir, exist_ok=True)
fd, tmppath = tempfile.mkstemp(prefix=".tmp-", dir=base_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmppath, path)
    # fsync directory entry for durability
    try:
        dfd = os.open(base_dir, os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except Exception:
        pass
finally:
    try:
        os.unlink(tmppath)
    except FileNotFoundError:
        pass
PY
}

read_state_or_init_empty() {
  if [ -f "$STATE_FILE" ]; then
    if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      local bad="${STATE_FILE}.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
      mv -f "$STATE_FILE" "$bad" 2>/dev/null || true
      echo "[sprint-state] WARN: corrupt state file quarantined to $bad" >&2
      echo '{"sprint":null,"started":null,"tasks":{}}'
      return 0
    fi
    cat "$STATE_FILE"
  else
    echo '{"sprint":null,"started":null,"tasks":{}}'
  fi
}

write_state_json() {
  local json="$1"
  # Validate before writing
  echo "$json" | jq -e . >/dev/null
  atomic_write "$STATE_FILE" "$json"
}

usage() {
  cat >&2 <<EOF
Usage:
  $0 init <SPRINT>
  $0 update <TASK_ID> <STATUS> [WORKER] [PR]
  $0 get
  $0 get-task <TASK_ID>
  $0 list-tasks <STATUS>
EOF
  exit 1
}

cmd="${1:-}"
case "$cmd" in
  init)
    sprint="${2:-}"; [ -z "$sprint" ] && usage
    json=$(read_state_or_init_empty | jq --arg sprint "$sprint" --arg started "$(now_iso)" '
      .sprint=$sprint | .started=$started | (.tasks //= {})
    ')
    write_state_json "$json"
    ;;

  update)
    task="${2:-}"; status="${3:-}"; worker="${4:-}"; pr="${5:-}"
    [ -z "$task" ] || [ -z "$status" ] && usage
    case "$status" in
      pending|assigned|in_progress|blocked|done|failed) ;;
      *)
        echo "[sprint-state] ERROR: invalid status '$status'" >&2
        exit 1
        ;;
    esac

    json=$(read_state_or_init_empty | jq --arg task "$task" --arg status "$status" \
      --arg worker "$worker" --arg pr "$pr" '
      .tasks //= {} |
      .tasks[$task] = {
        status: $status,
        worker: (if $worker=="" then null else $worker end),
        pr: (if $pr=="" then null else $pr end)
      }
    ')
    write_state_json "$json"
    ;;

  get)
    read_state_or_init_empty | jq .
    ;;

  get-task)
    task="${2:-}"; [ -z "$task" ] && usage
    read_state_or_init_empty | jq --arg task "$task" '.tasks[$task] // empty'
    ;;

  list-tasks)
    status="${2:-}"; [ -z "$status" ] && usage
    read_state_or_init_empty | jq -r --arg status "$status" '
      (.tasks // {}) | to_entries[] | select(.value.status==$status) | .key
    '
    ;;

  *)
    usage
    ;;
esac
