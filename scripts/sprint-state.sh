#!/usr/bin/env bash
# sprint-state.sh — Manage sprint state for crash recovery
# Part of the Hatchery project (Issue #51)
#
# Usage:
#   sprint-state.sh init <sprint-name>
#   sprint-state.sh update <task-id> <status> [worker] [pr]
#   sprint-state.sh get
#   sprint-state.sh get-task <task-id>
#   sprint-state.sh list-tasks [status]

set -euo pipefail

STATE_FILE="${SPRINT_STATE_FILE:-sprint-state.json}"

# Initialize a new sprint
init_sprint() {
    local name="$1"
    local started
    started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$STATE_FILE" <<EOF
{
  "sprint": "$name",
  "started": "$started",
  "tasks": {}
}
EOF
    echo "Initialized sprint '$name' at $started"
}

# Update a task's status
update_task() {
    local task_id="$1"
    local status="$2"
    local worker="${3:-null}"
    local pr="${4:-null}"
    
    # Validate status
    case "$status" in
        pending|assigned|in_progress|blocked|done|failed)
            ;;
        *)
            echo "Error: Invalid status '$status'" >&2
            echo "Valid statuses: pending, assigned, in_progress, blocked, done, failed" >&2
            return 1
            ;;
    esac
    
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: State file '$STATE_FILE' not found. Run 'init' first." >&2
        return 1
    fi
    
    # Format worker and pr as JSON strings or null
    local worker_json pr_json
    if [[ "$worker" == "null" ]]; then
        worker_json="null"
    else
        worker_json="\"$worker\""
    fi
    
    if [[ "$pr" == "null" ]]; then
        pr_json="null"
    else
        pr_json="\"$pr\""
    fi
    
    # Update the task using jq
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg id "$task_id" \
       --arg status "$status" \
       --argjson worker "$worker_json" \
       --argjson pr "$pr_json" \
       '.tasks[$id] = {status: $status, worker: $worker, pr: $pr}' \
       "$STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
    
    echo "Updated $task_id: status=$status worker=$worker pr=$pr"
}

# Get full sprint state
get_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: State file '$STATE_FILE' not found." >&2
        return 1
    fi
    cat "$STATE_FILE"
}

# Get a specific task
get_task() {
    local task_id="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: State file '$STATE_FILE' not found." >&2
        return 1
    fi
    jq --arg id "$task_id" '.tasks[$id] // empty' "$STATE_FILE"
}

# List tasks, optionally filtered by status
list_tasks() {
    local status="${1:-}"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Error: State file '$STATE_FILE' not found." >&2
        return 1
    fi
    
    if [[ -n "$status" ]]; then
        jq --arg status "$status" '.tasks | to_entries | map(select(.value.status == $status)) | from_entries' "$STATE_FILE"
    else
        jq '.tasks' "$STATE_FILE"
    fi
}

# Show usage
usage() {
    cat <<EOF
sprint-state.sh — Manage sprint state for crash recovery

Usage:
  sprint-state.sh init <sprint-name>     Initialize a new sprint
  sprint-state.sh update <id> <status> [worker] [pr]
                                         Update task status
  sprint-state.sh get                    Get full sprint state
  sprint-state.sh get-task <id>          Get specific task
  sprint-state.sh list-tasks [status]    List tasks, optionally by status

Environment:
  SPRINT_STATE_FILE    Path to state file (default: sprint-state.json)

Valid statuses: pending, assigned, in_progress, blocked, done, failed

Examples:
  sprint-state.sh init R2
  sprint-state.sh update TASK-4 assigned claude-worker
  sprint-state.sh update TASK-4 done claude-worker "PR #123"
  sprint-state.sh list-tasks in_progress
EOF
}

# Main command dispatch
case "${1:-}" in
    init)
        [[ -z "${2:-}" ]] && { echo "Error: Sprint name required"; usage; exit 1; }
        init_sprint "$2"
        ;;
    update)
        [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Error: Task ID and status required"; usage; exit 1; }
        update_task "$2" "$3" "${4:-null}" "${5:-null}"
        ;;
    get)
        get_state
        ;;
    get-task)
        [[ -z "${2:-}" ]] && { echo "Error: Task ID required"; usage; exit 1; }
        get_task "$2"
        ;;
    list-tasks)
        list_tasks "${2:-}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
