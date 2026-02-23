#!/bin/bash
# =============================================================================
# openclaw-state.sh -- Centralized state machine for safe mode lifecycle
# =============================================================================
# Purpose:  Single source of truth for system health state. All components
#           (E2E check, recovery handler, config switcher) go through this
#           controller for state transitions. Eliminates race conditions
#           from multiple marker files.
#
# Usage:
#   openclaw-state get [--field <field>]       Read current state
#   openclaw-state transition --to <STATE> [--reason "..."] [--by "..."]
#   openclaw-state report-health --status pass|fail [--failed-agents "a,b"]
#   openclaw-state lock --holder <name> [--ttl <seconds>]
#   openclaw-state unlock [--holder <name>]
#   openclaw-state init                        Initialize state file
#   openclaw-state history [--limit N]         Show recent transitions
#
# State file: /var/lib/openclaw/state.json
# Lock file:  /var/lib/openclaw/state.lock (flock-based)
# Event log:  /var/log/openclaw-state-events.jsonl
#
# Dependencies: jq, flock, bash 4+
# =============================================================================
set -euo pipefail

# --- Configuration (can be overridden via env) ---
STATE_DIR="${OPENCLAW_STATE_DIR:-/var/lib/openclaw}"
GROUP_SUFFIX="${GROUP:+-$GROUP}"
STATE_FILE="${STATE_DIR}/state${GROUP_SUFFIX}.json"
LOCK_FILE="${STATE_DIR}/state${GROUP_SUFFIX}.lock"
EVENT_LOG="${OPENCLAW_STATE_LOG:-${STATE_DIR}/events${GROUP_SUFFIX}.jsonl}"

# Thresholds (concrete defaults per review feedback)
DEGRADE_AFTER=${OPENCLAW_DEGRADE_AFTER:-1}          # failures before DEGRADED
RECOVER_AFTER=${OPENCLAW_RECOVER_AFTER:-2}           # failures before RECOVERING
RECOVERY_COOLDOWN_SEC=${OPENCLAW_RECOVERY_COOLDOWN:-300}  # 5 min between recovery attempts
MAX_RECOVERY_ATTEMPTS=${OPENCLAW_MAX_RECOVERY:-3}    # max attempts before SAFE_MODE
HEALTHY_STREAK_REQUIRED=${OPENCLAW_HEALTHY_STREAK:-2} # consecutive passes to exit safe mode
TRANSITION_TIMEOUT_SEC=${OPENCLAW_TRANSITION_TIMEOUT:-120} # max time in TRANSITIONING

# Valid states
VALID_STATES="BOOTING HEALTHY DEGRADED RECOVERING TRANSITIONING SAFE_MODE"

# Valid transitions: FROM:TO
VALID_TRANSITIONS=(
  "BOOTING:HEALTHY"
  "BOOTING:DEGRADED"
  "BOOTING:SAFE_MODE"
  "HEALTHY:DEGRADED"
  "DEGRADED:HEALTHY"
  "DEGRADED:RECOVERING"
  "RECOVERING:TRANSITIONING"
  "RECOVERING:SAFE_MODE"
  "TRANSITIONING:HEALTHY"
  "TRANSITIONING:SAFE_MODE"
  "SAFE_MODE:TRANSITIONING"
)

# --- Utility Functions ---

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

log_event() {
  local event_type="$1"; shift
  local payload="$*"
  local entry
  entry=$(jq -n --arg type "$event_type" --arg ts "$(now_iso)" --arg payload "$payload" \
    '{timestamp: $ts, type: $type, payload: $payload}')
  echo "$entry" >> "$EVENT_LOG" 2>/dev/null || true
}

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_dirs() {
  mkdir -p "$STATE_DIR"
  touch "$LOCK_FILE" "$EVENT_LOG" 2>/dev/null || true
}

# --- Atomic State File Operations ---
# Uses flock for OS-level locking + atomic write via temp+rename

# Read state file under shared lock
read_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "{}"
    return
  fi
  flock -s "$LOCK_FILE" cat "$STATE_FILE"
}

# Write state file atomically under exclusive lock
# Usage: echo "$new_json" | write_state
write_state() {
  local tmp="${STATE_FILE}.tmp.$$"
  flock -x "$LOCK_FILE" bash -c "
    cat > '$tmp'
    sync '$tmp' 2>/dev/null || true
    mv '$tmp' '$STATE_FILE'
  "
}

# Read a specific field from state
get_field() {
  local field="$1"
  read_state | jq -r ".$field // empty"
}

# Modify state atomically: read, apply jq filter, write back
# Usage: modify_state '.field = "value"'
modify_state() {
  local jq_filter="$1"
  flock -x "$LOCK_FILE" bash -c "
    if [ -f '$STATE_FILE' ]; then
      current=\$(cat '$STATE_FILE')
    else
      current='{}'
    fi
    echo \"\$current\" | jq '$jq_filter' > '${STATE_FILE}.tmp.$$'
    sync '${STATE_FILE}.tmp.$$' 2>/dev/null || true
    mv '${STATE_FILE}.tmp.$$' '$STATE_FILE'
  "
}

# --- Validation ---

is_valid_state() {
  local state="$1"
  echo "$VALID_STATES" | tr ' ' '\n' | grep -qx "$state"
}

is_valid_transition() {
  local from="$1" to="$2"
  local pair="${from}:${to}"
  for valid in "${VALID_TRANSITIONS[@]}"; do
    [ "$valid" = "$pair" ] && return 0
  done
  return 1
}

# --- Lock Management ---

acquire_lock() {
  local holder="$1"
  local ttl="${2:-60}"
  local now
  now=$(now_epoch)
  local expires_at=$((now + ttl))

  local current_holder
  current_holder=$(get_field "lock.holder")

  # Check if lock is held and not expired
  if [ -n "$current_holder" ] && [ "$current_holder" != "null" ]; then
    local lock_expires
    lock_expires=$(get_field "lock.expires_epoch")
    if [ -n "$lock_expires" ] && [ "$lock_expires" != "null" ] && [ "$now" -lt "$lock_expires" ]; then
      die "Lock held by '$current_holder' until epoch $lock_expires"
    fi
    # Lock expired, we can take it
  fi

  modify_state "
    .lock.holder = \"$holder\" |
    .lock.acquired_at = \"$(now_iso)\" |
    .lock.expires_epoch = $expires_at
  "
  log_event "lock_acquired" "holder=$holder ttl=${ttl}s"
  echo "Lock acquired by '$holder' for ${ttl}s"
}

release_lock() {
  local holder="${1:-}"
  local current_holder
  current_holder=$(get_field "lock.holder")

  if [ -n "$holder" ] && [ "$current_holder" != "$holder" ]; then
    die "Lock held by '$current_holder', not '$holder'"
  fi

  modify_state '.lock = { "holder": null, "acquired_at": null, "expires_epoch": null }'
  log_event "lock_released" "holder=${current_holder:-none}"
  echo "Lock released"
}

is_locked() {
  local holder
  holder=$(get_field "lock.holder")
  if [ -z "$holder" ] || [ "$holder" = "null" ]; then
    return 1
  fi
  local expires
  expires=$(get_field "lock.expires_epoch")
  local now
  now=$(now_epoch)
  if [ -n "$expires" ] && [ "$expires" != "null" ] && [ "$now" -ge "$expires" ]; then
    # Lock expired — auto-release
    modify_state '.lock = { "holder": null, "acquired_at": null, "expires_epoch": null }'
    return 1
  fi
  return 0
}

# --- State Transitions ---

do_transition() {
  local to_state="$1"
  local reason="${2:-}"
  local by="${3:-cli}"

  is_valid_state "$to_state" || die "Invalid state: $to_state"

  local current_state
  current_state=$(get_field "state")
  [ -z "$current_state" ] && current_state="BOOTING"

  # Same state is a no-op
  [ "$current_state" = "$to_state" ] && { echo "Already in $to_state"; return 0; }

  # Validate transition
  is_valid_transition "$current_state" "$to_state" || \
    die "Invalid transition: $current_state -> $to_state"

  # Check lock — only the lock holder can transition during lock
  if is_locked; then
    local lock_holder
    lock_holder=$(get_field "lock.holder")
    if [ "$by" != "$lock_holder" ]; then
      die "State locked by '$lock_holder'. Cannot transition."
    fi
  fi

  local now
  now=$(now_iso)
  local generation
  generation=$(read_state | jq '.generation // 0')
  generation=$((generation + 1))

  # Build the transition update
  local update_filter="
    .state = \"$to_state\" |
    .previous_state = \"$current_state\" |
    .updated_at = \"$now\" |
    .updated_by = \"$by\" |
    .reason = \"$reason\" |
    .generation = $generation
  "

  # State-specific updates
  case "$to_state" in
    HEALTHY)
      update_filter="$update_filter |
        .health.consecutive_failures = 0 |
        .health.failed_agents = [] |
        .health.last_success = \"$now\" |
        .recovery.attempts = 0 |
        .recovery.cooldown_until = null
      "
      ;;
    DEGRADED)
      # Keep failure count, it gets incremented by report-health
      ;;
    RECOVERING)
      local attempts
      attempts=$(read_state | jq '.recovery.attempts // 0')
      attempts=$((attempts + 1))
      local cooldown_until
      cooldown_until=$(date -u -d "+${RECOVERY_COOLDOWN_SEC} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -v+${RECOVERY_COOLDOWN_SEC}S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      update_filter="$update_filter |
        .recovery.attempts = $attempts |
        .recovery.last_attempt = \"$now\" |
        .recovery.cooldown_until = \"$cooldown_until\"
      "
      ;;
    TRANSITIONING)
      local timeout_at
      timeout_at=$(date -u -d "+${TRANSITION_TIMEOUT_SEC} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -v+${TRANSITION_TIMEOUT_SEC}S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      update_filter="$update_filter |
        .transition.in_progress = true |
        .transition.from_state = \"$current_state\" |
        .transition.to_state = \"$to_state\" |
        .transition.started_at = \"$now\" |
        .transition.timeout_at = \"$timeout_at\"
      "
      ;;
    SAFE_MODE)
      update_filter="$update_filter |
        .transition.in_progress = false
      "
      ;;
  esac

  modify_state "$update_filter"
  log_event "transition" "from=$current_state to=$to_state by=$by reason=$reason gen=$generation"

  # Write legacy marker files for Phase 1 compatibility
  write_legacy_markers "$to_state"

  echo "Transition: $current_state -> $to_state (gen=$generation)"
}

# --- Health Reporting ---

report_health() {
  local status="$1"
  local failed_agents="${2:-}"
  local now
  now=$(now_iso)
  local current_state
  current_state=$(get_field "state")

  # Update health check timestamp
  modify_state ".health.last_check = \"$now\""

  if [ "$status" = "pass" ]; then
    # Increment healthy streak
    local streak
    streak=$(read_state | jq '.health.healthy_streak // 0')
    streak=$((streak + 1))
    modify_state "
      .health.healthy_streak = $streak |
      .health.last_success = \"$now\" |
      .health.consecutive_failures = 0 |
      .health.failed_agents = []
    "
    log_event "health_pass" "streak=$streak state=$current_state"

    # State-dependent actions on health pass
    case "$current_state" in
      DEGRADED)
        do_transition "HEALTHY" "E2E passed" "e2e-check"
        ;;
      TRANSITIONING)
        do_transition "HEALTHY" "E2E passed after transition" "e2e-check"
        ;;
      SAFE_MODE)
        # Anti-flap: require streak before exiting safe mode
        if [ "$streak" -ge "$HEALTHY_STREAK_REQUIRED" ]; then
          echo "Healthy streak ($streak) >= threshold ($HEALTHY_STREAK_REQUIRED)"
          # Don't auto-exit safe mode — requires explicit transition via try-full-config
        else
          echo "Healthy streak ($streak) < threshold ($HEALTHY_STREAK_REQUIRED), staying in SAFE_MODE"
        fi
        ;;
    esac

  elif [ "$status" = "fail" ]; then
    local failures
    failures=$(read_state | jq '.health.consecutive_failures // 0')
    failures=$((failures + 1))

    # Parse failed agents into JSON array
    local agents_json="[]"
    if [ -n "$failed_agents" ]; then
      agents_json=$(echo "$failed_agents" | tr ',' '\n' | jq -R . | jq -s .)
    fi

    modify_state "
      .health.consecutive_failures = $failures |
      .health.failed_agents = $agents_json |
      .health.healthy_streak = 0
    "
    log_event "health_fail" "failures=$failures agents=$failed_agents state=$current_state"

    # State-dependent actions on health failure
    case "$current_state" in
      HEALTHY|BOOTING)
        if [ "$failures" -ge "$DEGRADE_AFTER" ]; then
          do_transition "DEGRADED" "E2E failed ($failures failures): $failed_agents" "e2e-check"
        fi
        ;;
      DEGRADED)
        if [ "$failures" -ge "$RECOVER_AFTER" ]; then
          # Check cooldown
          local cooldown
          cooldown=$(get_field "recovery.cooldown_until")
          local now_epoch_val
          now_epoch_val=$(now_epoch)
          local can_recover=true
          if [ -n "$cooldown" ] && [ "$cooldown" != "null" ]; then
            local cooldown_epoch
            cooldown_epoch=$(date -d "$cooldown" +%s 2>/dev/null || echo 0)
            if [ "$now_epoch_val" -lt "$cooldown_epoch" ]; then
              can_recover=false
              echo "Recovery on cooldown until $cooldown"
            fi
          fi

          # Check max attempts
          local attempts
          attempts=$(read_state | jq '.recovery.attempts // 0')
          if [ "$attempts" -ge "$MAX_RECOVERY_ATTEMPTS" ]; then
            do_transition "SAFE_MODE" "Max recovery attempts ($attempts) reached" "e2e-check"
          elif [ "$can_recover" = "true" ]; then
            do_transition "RECOVERING" "Consecutive failures ($failures) >= threshold ($RECOVER_AFTER)" "e2e-check"
          fi
        fi
        ;;
      TRANSITIONING)
        # Transition failed
        do_transition "SAFE_MODE" "E2E failed during transition: $failed_agents" "e2e-check"
        ;;
    esac
  fi
}

# --- Legacy Marker Compatibility (Phase 1) ---

write_legacy_markers() {
  local state="$1"
  local group_suffix="${GROUP:+-$GROUP}"
  local marker_dir="${OPENCLAW_MARKER_DIR:-/var/lib/init-status}"

  # Skip if marker dir doesn't exist or isn't writable
  [ -d "$marker_dir" ] && [ -w "$marker_dir" ] || return 0

  case "$state" in
    HEALTHY)
      rm -f "${marker_dir}/safe-mode${group_suffix}" \
            "${marker_dir}/unhealthy${group_suffix}" \
            "${marker_dir}/recovery-attempts${group_suffix}" \
            "${marker_dir}/recently-recovered${group_suffix}" 2>/dev/null || true
      touch "${marker_dir}/setup-complete" 2>/dev/null || true
      ;;
    DEGRADED)
      touch "${marker_dir}/unhealthy${group_suffix}" 2>/dev/null || true
      ;;
    RECOVERING)
      touch "${marker_dir}/unhealthy${group_suffix}" 2>/dev/null || true
      echo "$(now_epoch)" > "${marker_dir}/recently-recovered${group_suffix}" 2>/dev/null || true
      ;;
    SAFE_MODE)
      touch "${marker_dir}/safe-mode${group_suffix}" 2>/dev/null || true
      touch "${marker_dir}/setup-complete" 2>/dev/null || true
      rm -f "${marker_dir}/unhealthy${group_suffix}" 2>/dev/null || true
      ;;
    TRANSITIONING)
      # Keep markers as-is during transition
      ;;
  esac
}

# --- Init ---

init_state() {
  ensure_dirs

  if [ -f "$STATE_FILE" ]; then
    echo "State file already exists at $STATE_FILE"
    read_state | jq .
    return 0
  fi

  # Bootstrap from existing marker files
  local initial_state="BOOTING"
  local marker_dir="${OPENCLAW_MARKER_DIR:-/var/lib/init-status}"
  local group_suffix="${GROUP:+-$GROUP}"

  if [ -f "${marker_dir}/safe-mode${group_suffix}" ]; then
    initial_state="SAFE_MODE"
  elif [ -f "${marker_dir}/unhealthy${group_suffix}" ]; then
    initial_state="DEGRADED"
  elif [ -f "${marker_dir}/setup-complete" ]; then
    initial_state="HEALTHY"
  fi

  local now
  now=$(now_iso)
  local state_json
  state_json=$(jq -n \
    --arg state "$initial_state" \
    --arg now "$now" \
    '{
      version: 1,
      generation: 1,
      state: $state,
      previous_state: null,
      config: "full",
      updated_at: $now,
      updated_by: "init",
      reason: "State machine initialized",
      health: {
        last_check: null,
        last_success: null,
        consecutive_failures: 0,
        healthy_streak: 0,
        failed_agents: []
      },
      recovery: {
        attempts: 0,
        last_attempt: null,
        cooldown_until: null
      },
      transition: {
        in_progress: false,
        from_state: null,
        to_state: null,
        started_at: null,
        timeout_at: null
      },
      lock: {
        holder: null,
        acquired_at: null,
        expires_epoch: null
      }
    }')

  echo "$state_json" | write_state
  log_event "init" "initial_state=$initial_state bootstrapped_from=markers group=${GROUP:-global}"

  echo "Initialized state machine: $initial_state (group=${GROUP:-global})"
  read_state | jq .
}

# --- Display ---

show_state() {
  local field="${1:-}"
  if [ -n "$field" ]; then
    get_field "$field"
  else
    read_state | jq .
  fi
}

show_history() {
  local limit="${1:-20}"
  if [ -f "$EVENT_LOG" ]; then
    tail -n "$limit" "$EVENT_LOG" | jq -r '[.timestamp, .type, .payload] | join(" | ")'
  else
    echo "No event log found"
  fi
}

# --- Check Transition Timeout ---

check_timeout() {
  local state
  state=$(get_field "state")
  if [ "$state" = "TRANSITIONING" ]; then
    local timeout_at
    timeout_at=$(get_field "transition.timeout_at")
    if [ -n "$timeout_at" ] && [ "$timeout_at" != "null" ]; then
      local timeout_epoch
      timeout_epoch=$(date -d "$timeout_at" +%s 2>/dev/null || echo 0)
      local now
      now=$(now_epoch)
      if [ "$now" -ge "$timeout_epoch" ]; then
        echo "Transition timed out at $timeout_at"
        do_transition "SAFE_MODE" "Transition timed out" "timeout-check"
      fi
    fi
  fi
}

# --- CLI Entrypoint ---

usage() {
  cat <<EOF
Usage: openclaw-state <command> [options]

Commands:
  init                          Initialize state file (bootstrap from markers)
  get [--field <path>]          Read current state (or specific field)
  transition --to <STATE>       Transition to new state
    [--reason "..."]            Reason for transition
    [--by "..."]                Who initiated (default: cli)
  report-health                 Report E2E health check result
    --status pass|fail
    [--failed-agents "a,b"]
  lock --holder <name>          Acquire state lock
    [--ttl <seconds>]           Lock TTL (default: 60)
  unlock [--holder <name>]      Release state lock
  history [--limit N]           Show recent state events
  check-timeout                 Check/enforce transition timeout

States: $VALID_STATES
EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    init)
      init_state
      ;;

    get)
      local field=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --field) field="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done
      show_state "$field"
      ;;

    transition)
      local to="" reason="" by="cli"
      while [ $# -gt 0 ]; do
        case "$1" in
          --to) to="$2"; shift 2 ;;
          --reason) reason="$2"; shift 2 ;;
          --by) by="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done
      [ -z "$to" ] && die "Missing --to <STATE>"
      do_transition "$to" "$reason" "$by"
      ;;

    report-health)
      local status="" failed_agents=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --status) status="$2"; shift 2 ;;
          --failed-agents) failed_agents="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done
      [ -z "$status" ] && die "Missing --status pass|fail"
      report_health "$status" "$failed_agents"
      ;;

    lock)
      local holder="" ttl=60
      while [ $# -gt 0 ]; do
        case "$1" in
          --holder) holder="$2"; shift 2 ;;
          --ttl) ttl="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done
      [ -z "$holder" ] && die "Missing --holder <name>"
      acquire_lock "$holder" "$ttl"
      ;;

    unlock)
      local holder=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --holder) holder="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done
      release_lock "$holder"
      ;;

    history)
      local limit=20
      while [ $# -gt 0 ]; do
        case "$1" in
          --limit) limit="$2"; shift 2 ;;
          *) die "Unknown option: $1" ;;
        esac
      done
      show_history "$limit"
      ;;

    check-timeout)
      check_timeout
      ;;

    -h|--help|help)
      usage
      ;;

    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
