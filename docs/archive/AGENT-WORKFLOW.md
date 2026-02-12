# Agent Workflow & Reliability Guide

This document describes the multi-agent workflow used for Hatchery development, including lessons learned and reliability patterns.

## Team Structure

```
Human (Owner)
    │
    ▼
Judge (Opus) ─────────────────┐
    │                         │
    ▼                         ▼
EL (ChatGPT) ◄──────► Panelists (Claude, ChatGPT, Gemini)
    │                         │
    ▼                         │
Workers (5x cheaper models)   │
    │                         │
    ▼                         ▼
Implementation            Reviews & Deliberation
```

## Role Responsibilities

### Judge (Opus)
- Facilitates council deliberations
- Assigns tasks to EL (not directly to workers)
- Sets reminders and tracks progress
- Escalates when blocked
- Maintains sprint state file

### Executive Lead (EL) — ChatGPT
- Receives tasks from Judge
- Delegates implementation to worker sub-agents
- Reviews worker output
- Reports completion to Judge
- **Must track all worker spawns in sprint-state file**

### Workers (Sub-agents)
- Execute implementation tasks
- **Must return PR URL or explicit "no changes needed"**
- Silent completion = failure

### Panelists (Council)
- Participate in code reviews and deliberations
- Reserved for reviews, NOT implementation
- Respond only to `COUNCIL:PROCEED` dispatches

## Sprint State Tracking

**File:** `~/clawd/shared/sprint-state.md`

This persistent file survives session gaps and context compaction.

### Contents
- Current sprint status
- Backlog with assignments
- Active workers (label, task, spawn time)
- Pending reminders
- Completed items

### Update Rules
1. Judge updates after sprint state changes
2. EL updates when spawning/completing workers
3. Check on session resume if context was compacted

## Worker Protocol

### On Spawn (EL must do immediately)
```markdown
## Active Workers
| Worker Label | Task | Spawned | Last Update | Status |
|--------------|------|---------|-------------|--------|
| worker-68 | rclone validation | 2026-02-06 08:25 | — | Running |
```

### On Completion (Worker must return)
One of:
- **PR URL**: `https://github.com/org/repo/pull/123`
- **Explicit no-op**: `"No changes needed — <reason>"`
- **Error**: `"Failed: <error description>"`

### Timeout Handling
- 30 min with no update → EL checks status
- 60 min with no update → EL escalates to Judge
- Judge retries or notifies user

## Reminder & Escalation Protocol

### Reminder Rules
1. Every "I'll check back in X" → immediate cron job
2. Use `wakeMode: "now"` to ensure prompt wake
3. When reminder fires → actually do the thing

### Escalation Ladder
| Attempt | Action |
|---------|--------|
| 1st reminder | Check status, ping responsible agent |
| 2nd reminder (no progress) | Retry flow: re-dispatch to EL, spawn new worker |
| 3rd reminder (still stuck) | Notify user AND continue retrying |
| Never | Give up silently |

### Retry Flow
```
1. Read sprint-state.md to identify stuck task
2. Re-dispatch task to EL via sessions_send
3. EL spawns fresh worker
4. Update sprint-state.md with retry attempt
5. Set new reminder for 30 min
```

## Cost Optimization

### Why Workers?
- Workers use cheaper models (5x cost reduction)
- Extends runtime before hitting token/cost limits
- Council members reserved for high-value reviews

### Delegation Rules
- Implementation tasks → EL → Workers
- Reviews/deliberation → Panelists
- Never assign PRs directly to panelists

## Lessons Learned (R4 Retrospective)

### What Went Wrong
1. Worker spawned but never completed — no tracking
2. Reminders fired but queued during inactive session
3. Context compaction lost sprint state
4. No retry mechanism when worker stalled

### Fixes Implemented
1. **Sprint state file** — persistent tracking across sessions
2. **Worker tracking protocol** — EL logs all spawns
3. **Escalation ladder** — retry before escalating to user
4. **Worker completion rule** — must return PR URL or explicit status

---

*Document created after R4 retrospective — 2026-02-06*
