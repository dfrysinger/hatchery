# Sprint State Management

## Overview

The sprint state system provides crash recovery for the Execution Layer (EL). If the EL crashes mid-sprint, the `sprint-state.json` file preserves task progress, allowing seamless resumption.

## State File Format

```json
{
  "sprint": "R2",
  "started": "2025-01-15T10:00:00Z",
  "tasks": {
    "TASK-4": {"status": "assigned", "worker": "claude-agent", "pr": null},
    "TASK-5": {"status": "in_progress", "worker": "gemini-agent", "pr": null},
    "TASK-6": {"status": "done", "worker": "chatgpt-agent", "pr": "PR #42"}
  }
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `sprint` | string | Sprint identifier (e.g., "R2", "R3") |
| `started` | ISO 8601 | Sprint start timestamp |
| `tasks` | object | Map of task ID → task state |
| `tasks.*.status` | string | Task status (see below) |
| `tasks.*.worker` | string/null | Assigned worker agent |
| `tasks.*.pr` | string/null | Associated PR reference |

### Task Statuses

| Status | Description |
|--------|-------------|
| `pending` | Task created, not yet assigned |
| `assigned` | Task assigned to a worker |
| `in_progress` | Worker actively working on task |
| `blocked` | Task blocked by dependency or issue |
| `done` | Task completed successfully |
| `failed` | Task failed and needs attention |

## Usage

### CLI Commands

```bash
# Initialize a new sprint
./scripts/sprint-state.sh init R2

# Assign a task to a worker
./scripts/sprint-state.sh update TASK-4 assigned claude-worker

# Mark task as in progress
./scripts/sprint-state.sh update TASK-4 in_progress claude-worker

# Mark task done with PR reference
./scripts/sprint-state.sh update TASK-4 done claude-worker "PR #123"

# Get full sprint state
./scripts/sprint-state.sh get

# Get specific task
./scripts/sprint-state.sh get-task TASK-4

# List all tasks with a specific status
./scripts/sprint-state.sh list-tasks in_progress
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SPRINT_STATE_FILE` | `sprint-state.json` | Path to the state file |

### Integration Example

```bash
# At sprint start
./scripts/sprint-state.sh init R2

# When assigning tasks
for task in TASK-4 TASK-5 TASK-6; do
    ./scripts/sprint-state.sh update "$task" pending
done

# Worker picks up task
./scripts/sprint-state.sh update TASK-4 assigned "claude-agent"

# Worker starts work
./scripts/sprint-state.sh update TASK-4 in_progress "claude-agent"

# Worker completes task
./scripts/sprint-state.sh update TASK-4 done "claude-agent" "PR #123"
```

## Crash Recovery

On EL restart:

1. Check if `sprint-state.json` exists
2. Parse to find incomplete tasks (`in_progress`, `assigned`, `blocked`)
3. Resume or reassign as needed

```bash
# Find tasks that need attention after crash
./scripts/sprint-state.sh list-tasks in_progress
./scripts/sprint-state.sh list-tasks assigned
./scripts/sprint-state.sh list-tasks blocked
```

## Requirements

- `jq` for JSON manipulation
- Bash 4.0+
