# AI Product Organization — Operating Workflow

> **Version:** 2.0
> **Status:** Approved (Council Round 1 + 2, Human confirmation)
> **Last Updated:** 2026-02-05
> **Timezone:** US Mountain Time (MT)

A complete operating manual for running an autonomous AI product organization inside Discord + Clawdbot. This workflow governs how ideas become shipped features through structured council deliberation, daily sprint cadence, and quality gates.

---

## Table of Contents

1. [Organization Design](#1-organization-design)
2. [Decision Authority (RACI)](#2-decision-authority-raci)
3. [Discord Server Structure](#3-discord-server-structure)
4. [Daily Cadence](#4-daily-cadence)
5. [The Workflow Pipeline](#5-the-workflow-pipeline)
6. [Worker Protocol (TDD)](#6-worker-protocol-tdd)
7. [The Judge's Playbook](#7-the-judges-playbook)
8. [Cost Governance](#8-cost-governance)
9. [CI/CD Standards](#9-cicd-standards)
10. [Security Policy](#10-security-policy)
11. [OpenClaw Configuration](#11-openclaw-configuration)
12. [Failure Recovery](#12-failure-recovery)
13. [Artifact Templates](#13-artifact-templates)
14. [Implementation Roadmap](#14-implementation-roadmap)

---

## 1. Organization Design

### 1.1 Permanent Seats (Agents)

| Seat | Model | Access Model | Primary Role |
|------|-------|-------------|--------------|
| **Opus (Judge/CPO)** | Claude Opus 4.5 | Anthropic API (Max) | Orchestrator, final arbiter, CPO tiebreaker |
| **Claude** | Claude Opus 4.5 | Anthropic API (Max) | Panelist — product quality, UX coherence, narrative |
| **ChatGPT** | GPT-5.2 | OpenAI OAuth (subscription) | Panelist — systems thinking, workflow rigor, edge cases |
| **Gemini** | Gemini 3 Pro | Google API (subscription) | Panelist — implementation realism, integration, test strategy |
| **Grok** | Grok | xAI (subscription) | Panelist — adversarial review, failure modes, cost, abuse paths |

### 1.2 Consistent Panelist Personas (No Dynamic Hats)

Each council member keeps a **consistent persona**. The Judge controls focus via the dispatch scope (e.g., "focus on security for this review") rather than swapping "hat prompt packs." This is simpler, cheaper, and equally effective.

- **Claude:** Product quality, UX, narrative coherence, acceptance criteria depth
- **ChatGPT:** Systems thinking, process rigor, edge cases, workflow enforcement
- **Gemini:** Implementation realism, feasibility, test strategy, integration risk
- **Grok:** Adversarial review, failure modes, abuse paths, cost analysis

The Judge's dispatch message tells panelists what perspective to emphasize per round — they don't change identity.

### 1.3 Scrum Team (Execution)

| Role | Model | Count | Purpose |
|------|-------|-------|---------|
| **Engineering Lead (EL)** | Claude Sonnet 4.5 | 1 (dedicated) | Task assignment, code review, integration testing, worker management |
| **Workers** | Claude Sonnet 4.5 | 5 | TDD implementation, unit testing, bug fixes |

**Total: 11 agents** (5 council + 1 EL + 5 workers)

The EL is a **dedicated 6th Sonnet agent**, NOT a council member doing double duty. This keeps the council available for high-leverage decisions and prevents Claude from becoming a bottleneck.

### 1.4 Account Strategy

| Account | Models | Purpose | Rate Handling |
|---------|--------|---------|---------------|
| **Leadership** | Anthropic API (Opus + Sonnet EL) | Judge, Claude panelist, EL | Priority lane |
| **Workers** | Anthropic API (Sonnet × 5) | Development tasks | Queue-managed with semaphore |
| **ChatGPT** | OpenAI OAuth (subscription) | Council gates only | Throttled, not capped |
| **Gemini** | Google API (subscription) | Council gates only | Throttled, not capped |
| **Grok** | xAI (subscription) | Council gates only | Throttled, not capped |

**Key:** Subscription-based models (ChatGPT, Gemini, Grok) are throttled when hitting rate limits, not hard-capped. Budget management is about managing throughput, not preventing overages.

---

## 2. Decision Authority (RACI)

Clear authority prevents endless debate. When in doubt, check this table.

| Decision | Responsible | Accountable | Consulted | Informed |
|----------|------------|-------------|-----------|----------|
| Initiative worth council time | Judge | Human | — | Council |
| PRD acceptance | Council | Judge | **Human (required)** | Workers |
| Architecture acceptance | Council | Judge | Human | EL |
| Security requirements | Council | Judge | Human | EL |
| Sprint plan approval | EL | Judge | **Human (required)** | Workers |
| Task breakdown & sizing | EL | EL | — | Workers |
| Technical approach per task | Worker | EL | — | — |
| Code merge readiness | EL | EL | — | Judge |
| Release readiness | Council | Judge | **Human (required)** | EL, Workers |
| Emergency hotfix | EL | Judge | Council (post-hoc) | Human |
| Tiebreaker (any dispute) | Judge | Judge | — | All |

### Human Gates (Hard Requirements)

The human MUST approve at these points (✅ reaction or text both count):
1. **Morning standup plan** — daily work plan before anything starts
2. **PRD review** — before engineering begins
3. **Sprint plan** — before workers start coding
4. **Release candidate** — before anything ships

### Dispute Resolution Protocol

1. **Disagreement detected** between EL and PM (or between council members)
2. **One structured rebuttal round** — each party writes a ≤200 word case
3. **Judge decides** within 60 seconds, citing rationale
4. **Decision is final** and recorded in `#decisions-log`

No appeals. No re-litigation. Move forward.

---

## 3. Discord Server Structure

### 3.1 Channel Map (5 Channels)

```
📁 Product Org
├── #standup           — Human-facing: daily briefs, approvals, EOD reports
├── #council-forum     — Forum: one thread per feature (tags: PRD / Sprint / RC / Done)
├── #decisions-log     — Append-only: final decisions, gate outcomes
├── #alerts            — Escalations, budget warnings, failures
└── #dev-log           — EL: task assignments, MR links, CI results, worker progress
```

**Design principle:** The human checks `#standup` daily. Everything else is optional depth.

### 3.2 Channel Purposes

| Channel | Who Posts | Who Reads | Purpose |
|---------|----------|-----------|---------|
| `#standup` | Judge | Human, all agents | Morning plan, EOD report, approval requests |
| `#council-forum` | Judge, Council | Human, all agents | Feature lifecycle (PRD → Sprint → RC → Done) |
| `#decisions-log` | Judge only | All | Canonical decision record, gate outcomes |
| `#alerts` | Judge, EL | Human, Judge | Budget warnings, CI failures, blockers |
| `#dev-log` | EL | Judge, Human (optional) | Task assignments, MR status, CI results |

**Workers never post to Discord.** EL summarizes worker progress to `#dev-log`. This reduces noise and keeps the human-facing channels clean.

### 3.3 Forum Channel Usage

`#council-forum` uses Discord forum posts with tags:
- **PRD** — feature in PRD/design phase
- **Sprint** — feature in active development
- **RC** — release candidate under review
- **Done** — shipped and archived

Each feature gets ONE forum thread that tracks its entire lifecycle. PRDs, architecture decisions, sprint plans, and RC reviews all happen in the same thread.

---

## 4. Daily Cadence

**Day = Sprint.** Every day follows a Sunrise → Execute → Sunset rhythm.

### 4.1 Sunrise (9:30 AM MT)

Judge generates and posts the **Daily Brief** to `#standup`:

```
☀️ DAILY BRIEF — [Date]

## Yesterday
- [Completed items]
- [Carry-over items]

## Today's Plan
- [Task 1] → Worker-N
- [Task 2] → Worker-N
- [Blocked items]

## Decisions Needed
- [Any approvals required]

## Budget Status
- Leadership: [X% used]
- Workers: [X% used]
- Council calls remaining: ~[N]

⏳ Awaiting approval to begin. React ✅ or reply to approve.
```

**No work starts until the human approves** (✅ reaction or text reply).

### 4.2 Execution (After Approval)

- EL assigns tasks to workers via `sessions_send`
- Workers execute TDD cycle (see Section 6)
- EL monitors, reviews MRs, handles blockers
- EL posts progress updates to `#dev-log`
- **Midday checkpoint** only if there's a decision needed (EL escalates to Judge → `#standup`)

### 4.3 Sunset (End of Work Day)

Judge compiles and posts **EOD Report** to `#standup`:

```
🌙 EOD REPORT — [Date]

## Completed
- ✅ [Task] — merged, tests passing
- ✅ [Task] — merged, tests passing

## In Progress
- 🔄 [Task] — MR submitted, awaiting review
- 🔄 [Task] — 60% complete, continuing tomorrow

## Blocked
- 🔴 [Task] — [reason], [proposed resolution]

## Tomorrow's Draft Plan
- [Proposed task 1]
- [Proposed task 2]

## Notes
- [Any observations, risks, or decisions for the human]
```

### 4.4 Day Types

| Day Type | What Happens | Council Involved? |
|----------|-------------|-------------------|
| **Planning Day** | New feature → PRD draft → Council review → Human approval → Task breakdown → Human approval | Yes (1 gate) |
| **Execution Day** | Standup → Workers code → EL manages → EOD report | No |
| **Ship Day** | RC ready → Council review → Human demo → Release decision | Yes (1 gate) |

Most days are Execution Days. Council only convenes at gates.

---

## 5. The Workflow Pipeline

### Overview

```
Intake → [GATE 1: PRD + Architecture] → Sprint Planning → [GATE 2: Task Review] →
Sprint Execution → Testing → [GATE 3: Release Review] → Demo
```

Each gate includes a **Packaging Layer**: a Sonnet-generated brief that summarizes context for the council, reducing expensive model token usage by 50-70%.

---

### Phase 0 — Intake (Free)

**Who:** Human
**Where:** `#standup` or `#council-forum`
**What:** Human describes a feature idea or problem

**Judge actions:**
1. Acknowledge receipt
2. Ask 3-5 clarifying questions (scope, constraints, success metrics)
3. Once clarified, write a `OnePager.md` summary
4. Decide: proceed to Gate 1, or defer

---

### Pre-Gate: Packaging Layer

Before every gate, the EL (or a Sonnet worker) produces a **Brief**:
- 10-bullet summary of current state
- Decisions needed (max 3)
- Risks (max 5)
- Links to artifacts / diffs since last gate
- ≤500 words total

This brief is what gets dispatched to the council — not raw artifacts.

---

### GATE 1 — PRD + Architecture Review (Council)

**Cost:** 4 panelist calls + 1 Judge synthesis = **5 calls**
**Time:** 30-45 minutes max
**Where:** Feature thread in `#council-forum`

Council members respond with both product and engineering perspectives in one report.

**Judge dispatches:**
```
COUNCIL:PROCEED
Topic: <one-line description>
Slug: <topic-slug>
Round: 1
Focus: Combined product + engineering review
Context: <Brief contents>
Deadline: 5 minutes
```

**Output:**
- `PRD.md` → committed to GitHub in `docs/prds/`
- `Solution.md` → committed to GitHub in `docs/prds/`

**Human gate:** Human reviews PRD in GitHub. ✅ reaction or text reply to approve.

---

### Phase 1 — Sprint Planning (EL + Judge)

**Cost:** 0-1 council calls (Judge + EL only; council consulted only if complex)
**Where:** Feature thread in `#council-forum`

**EL produces:**
- Release breakdown (R1, R2, ...)
- Per-release task list with acceptance criteria
- Dependency ordering for serialized merging
- `Files Touched` and `Conflicts With` per task

**Human gate:** Sprint plan posted to `#standup`. Human approves before workers start.

---

### GATE 2 — Task Review (Council, Quick)

**Cost:** 4 panelist calls + 1 synthesis = **5 calls**
**Time:** 15-20 minutes
**Where:** Feature thread in `#council-forum`

Quick sanity check: Do these tasks fully cover the PRD requirements?

---

### Phase 2 — Sprint Execution (Workers + EL)

**Cost:** 0 council calls
**Where:** `#dev-log` for status; worker sessions for actual work

This is where the 5 Sonnet workers build. See [Section 6: Worker Protocol](#6-worker-protocol-tdd).

**Merge policy:** Serialized merging. EL merges one MR at a time; next worker rebases before pushing. This prevents merge conflicts with 5 parallel workers.

---

### Phase 3 — Testing (Workers + EL)

**Cost:** 0 council calls
**Where:** `#dev-log`, GitHub CI

1. Workers test their own tasks — run unit tests, verify acceptance criteria
2. EL runs integration tests across the full release
3. Bugs filed as GitHub issues, assigned back to the responsible worker
4. Fix cycle: Worker fixes → EL re-tests → repeat until clean
5. Stuck workers (2 attempts): EL takes over, Judge reviews

**Triggered SEC mini-round:** If any agent flags a 🛑 security concern during testing, Judge convenes a 10-15 minute SEC-focused council round (2 panelists + Judge) before proceeding.

**Release Candidate criteria:**
- All unit tests passing
- Integration tests passing
- No P0 or P1 bugs open
- All acceptance criteria verified
- CI green on all required checks

---

### GATE 3 — Release Candidate Review (Council)

**Cost:** 4 panelist calls + 1 synthesis = **5 calls** (multi-perspective)
**Time:** 30 minutes max
**Where:** `#council-forum` (RC tag on feature thread)

Council reviews RC checklist + brief (NOT raw code diffs).

**Gate decision options:**
- ✅ **Ship it** → proceed to demo
- 🔄 **Conditional** → specific issues sent back to scrum team
- 🛑 **Reject** → fundamental problems

**Human gate:** Judge announces "Ready for demo" in `#standup`. Human tests and approves.

---

### Phase 4 — Retrospective (After Each Release)

- EL writes sprint retro (what worked, what didn't, metrics)
- Judge summarizes and updates `KNOWLEDGE.md` + this workflow doc
- No council call needed — Judge + EL handle async
- Lessons feed into future sprint planning

---

### Budget Summary Per Feature

| Phase | Council Calls | Notes |
|-------|:------------:|-------|
| Intake | 0 | Judge only |
| Gate 1: PRD + Architecture | 5 | Combined round |
| Sprint Planning | 0-1 | EL + Judge; council only if complex |
| Gate 2: Task Review | 5 | Quick sanity check |
| Sprint Execution | 0 | Workers + EL only |
| Testing | 0-5 | 0 normally; +5 if SEC mini-round triggered |
| Gate 3: RC Review | 5 | Multi-perspective round |
| Retrospective | 0 | Judge + EL only |
| **Total** | **15-21** | Sustainable on subscription tiers |

---

## 6. Worker Protocol (TDD)

### 6.1 Task Assignment

Workers receive tasks from the EL via `sessions_send`:

```
TASK:ASSIGNED
Task-ID: <id>
Title: <title>
Description: <what to build>
Acceptance Criteria:
  - AC1: <criterion>
  - AC2: <criterion>
Test Requirements:
  - <what must be tested>
Files Touched: <files this task modifies>
Conflicts With: <other task IDs touching same files, or "none">
Branch: feature/<task-id>-<slug>
Context: <relevant PRD sections, architecture notes>
```

### 6.2 TDD Cycle

```
1. READ task spec + acceptance criteria thoroughly
2. CREATE feature branch: feature/<task-id>-<slug>
3. WRITE failing tests first (RED phase)
   - One test per acceptance criterion minimum
   - Edge case tests for boundary conditions
4. IMPLEMENT minimum code to pass tests (GREEN phase)
5. REFACTOR for clarity, readability, and maintainability
6. RUN tests locally — all must pass before pushing
7. PUSH to remote — CI runs automatically
8. COMMIT with conventional commit message:
   feat(<scope>): <description>
   Refs: TASK-<id>
9. Report to EL via sessions_send:
   [TASK-<id>] <title>
   Branch: feature/<task-id>-<slug>
   Tests: X passing, Y new
   Files: <list>
   Summary: <what and why>
10. WAIT for EL review feedback
11. ADDRESS feedback (up to 2 revision rounds)
12. If STUCK after 2 attempts:
    Report to EL: BLOCKED: TASK-<id> — <what's stuck and why>
    (EL will take over)
```

**"Attempt" definition:** A spec clarification request does NOT count as a failed attempt. Only implementation failures where the worker submitted code that doesn't meet acceptance criteria count.

### 6.3 Status Updates

Workers report to EL via `sessions_send`. EL summarizes to `#dev-log`:

```
🟢 STARTED: TASK-<id> — <title>
🔄 PROGRESS: TASK-<id> — <what's done, what's next>
📝 MR READY: TASK-<id> — submitted for review
🔴 BLOCKED: TASK-<id> — <reason>
🐛 BUG FILED: BUG-<id> — <description>
✅ DONE: TASK-<id> — merged
```

### 6.4 Failure Protocol

When a worker fails a task after 2 attempts:
1. Worker writes a **structured postmortem**: (a) what was attempted, (b) exact error/failure, (c) what they think the root cause is
2. Postmortem sent to EL
3. EL takes over the task
4. Judge (CPO) reviews EL's implementation
5. Postmortem informs future task scoping (lessons learned → `KNOWLEDGE.md`)

---

## 7. The Judge's Playbook

### 7.1 Dispatch Protocol

For each council gate:

```
1. EL (or Sonnet worker) generates Brief (≤500 words)
2. Judge announces phase in #standup
3. Judge creates/updates forum thread in #council-forum
4. Judge sends COUNCIL:PROCEED via sessions_send to each panelist:
   - Focus instruction (what perspective to emphasize)
   - Topic slug + round number
   - Brief + links to full artifacts
   - Deadline (5 minutes standard; 8-10 for Gate 1/3)
5. Monitor for ACKs:
   - No ACK in 60s → re-ping once
   - Still no ACK in 60s → note absence, continue
6. At 4 minutes: reminder to panelists who haven't filed reports
7. At 5 minutes: proceed with available reports
8. Read reports from ~/clawd/shared/reports/
9. Synthesize and post to #decisions-log + feature thread
10. Gate decision: PASSED / CONDITIONAL / FAILED with rationale
11. Post approval request to #standup if human gate required
```

### 7.2 Daily Standup Generation

Judge generates daily standup from `sprint-state.json`:

```
1. Read sprint-state.json for current task status
2. Compile completed, in-progress, and blocked items
3. Draft today's plan based on priority + dependencies
4. Post to #standup at 9:30 AM MT
5. Wait for human approval (✅ or text)
6. Once approved, signal EL to begin work
```

### 7.3 EL Management

During sprint phases:
- Provide EL with approved task list
- Monitor `#dev-log` for blockers
- Intervene only for: architectural disputes, 2-strike escalations, PM vs EL disagreements, scope creep
- Run EL heartbeat check every 10 minutes (if EL unresponsive >5 min, Judge can approve/assign in emergency)
- Do NOT micromanage implementation

### 7.4 Weekly Digest

Every Friday, Judge posts a weekly summary to `#standup`:
- Features in progress, their status
- Budget usage for the week
- Decisions made
- Upcoming gates / milestones
- Blockers or risks

### 7.5 Synthesis Template

```markdown
## Synthesis — [Topic] Round [N]

### Individual Assessment
**Claude:** [strengths, gaps, notable insights]
**ChatGPT:** [strengths, gaps, notable insights]
**Gemini:** [strengths, gaps, notable insights]
**Grok:** [strengths, gaps, notable insights]

### Consensus Points
- [items all/most agree on]

### Divergence Points
- [item] — who says what
  → Judge ruling: [decision + rationale]

### Decisions
1. [decision with rationale]

### Open Questions
- [unresolved items]
```

---

## 8. Cost Governance

### 8.1 Core Principles

1. **Council only meets at gates.** 3 gates per feature, max.
2. **Packaging Layer before every gate.** Sonnet-generated brief reduces council token usage by 50-70%.
3. **Single-round debate.** One rebuttal round for disagreements. Judge decides after that.
4. **Subscriptions are throttled, not capped.** Budget management = throughput management.

### 8.2 Tiered Engagement

| Decision Complexity | Who | Council Calls |
|-------------------|-----|:------------:|
| Full council deliberation | 4 panelists + Judge | 5 |
| Quick review (consensus expected) | 2 panelists + Judge | 3 |
| Triggered SEC mini-round | 2 panelists + Judge | 3 |
| Routine code review | EL only | 0 |
| Bug triage | EL only | 0 |
| Tiebreaker | Judge only | 0 |

### 8.3 Degradation Modes

When subscription rate limits are hit:

| Mode | Trigger | Action |
|------|---------|--------|
| **Full** | Normal | 4 panelists per gate |
| **Reduced** | Any model throttled | 2 panelists + Judge (prioritize least-throttled models) |
| **Minimal** | Multiple models throttled | Judge synthesizes alone from prior reports |
| **Paused** | Leadership account throttled | Pause sprint, notify human |

### 8.4 Budget Tracking

Judge tracks and reports in daily standup:
- Council calls this week
- Throttle events observed
- Estimated remaining capacity

---

## 9. CI/CD Standards

### 9.1 Repository

All code lives in GitHub (`dfrysinger/hatchery` or feature-specific repos). PRDs live in `docs/prds/` in the repo.

### 9.2 GitHub Actions

Required CI jobs on every PR:

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: <install command>
      - name: Lint
        run: <lint command>
      - name: Unit tests
        run: <test command>
      - name: Integration tests
        run: <integration test command>
```

### 9.3 Branch Protection

- **No direct push to `main`** — all changes via PR
- **Required status checks:** CI must pass
- **Required reviews:** EL approval required; Judge approval for release tags
- **Squash merge** as default merge strategy

### 9.4 Local Pre-Flight

**Agents must run tests locally before pushing to CI.** CI is the final gate, not the development loop. Workers that push failing code waste CI minutes and slow everyone down.

### 9.5 MR Workflow

1. Worker creates feature branch and pushes code
2. Worker opens PR via `gh pr create`
3. CI runs automatically
4. EL reviews code (style, correctness, tests, acceptance criteria)
5. If CI passes + EL approves → EL merges (serialized — one at a time)
6. Next worker rebases before pushing their PR

### 9.6 Test Results

CI results automatically appear on the PR. EL posts summary to `#dev-log` for visibility.

---

## 10. Security Policy

### 10.1 Secrets Management

- Secrets live ONLY in environment variables or secret stores
- **Never** in Discord messages, `~/clawd/shared/`, or committed to git
- Workers access secrets via environment injection (`.env` files, not hardcoded)
- Redact tokens/PII from all logs and reports

### 10.2 Filesystem Permissions

| Agent | `~/clawd/shared/` | `prds/` | `DECISIONS.md` | `tasks/` | `reports/` |
|-------|-------------------|---------|----------------|----------|------------|
| Judge | Full write | Full write | Full write | Full write | Full write |
| EL | Read + write tasks | Read | Read | Full write | Write own |
| Council | Read + write reports | Read | Read | Read | Write own |
| Workers | Read only | Read only | Read only | Read assigned | No access |

**Canonical authorship:** Only the Judge edits final PRD/Solution versions and `DECISIONS.md`. Others propose changes; Judge integrates.

### 10.3 Dependency Management

- Adding/updating dependencies requires EL review
- `npm audit` / `pip audit` (or equivalent) must pass in CI
- Lockfile changes reviewed explicitly
- New dependencies require a brief justification in the PR description

### 10.4 Automated Security Scanning

Required CI step:
- Dependency vulnerability scanning (`npm audit`, `pip audit`, etc.)
- Lightweight SAST (`semgrep` or equivalent) for common vulnerability patterns
- Results must be clean or explicitly acknowledged before merge

### 10.5 Triggered SEC Mini-Round

When any agent flags a 🛑 security blocker:
1. Judge convenes a 10-15 minute focused round
2. 2 panelists (Grok + one other) + Judge
3. Review the specific concern with full context
4. Decision: block the release, require fix, or accept risk with documentation
5. Cost: 3 calls (only when triggered, not every feature)

---

## 11. OpenClaw Configuration

### 11.1 Agent Architecture

```
11 agents total:
├── judge (agent: Opus 4.5) — orchestrator, CPO
├── council-claude (agent: Opus 4.5) — panelist
├── council-chatgpt (agent: GPT-5.2, OAuth subscription) — panelist
├── council-gemini (agent: Gemini 3 Pro, subscription) — panelist
├── council-grok (agent: Grok, subscription) — panelist
├── scrum-el (agent: Sonnet 4.5) — engineering lead
├── worker-1 through worker-5 (agent: Sonnet 4.5) — developers
```

### 11.2 Shared Filesystem

```
~/clawd/shared/
├── KNOWLEDGE.md              — Accumulated project knowledge
├── DECISIONS.md              — Decision log (Judge-owned)
├── CONTEXT.md                — Current project context
├── sprint-state.json         — Current sprint status (EL maintains, Judge reads)
├── reports/                  — Council round reports
│   └── Round{N}_{Agent}.md
├── tasks/                    — Task specifications (EL writes, workers read)
│   └── TASK-{id}.md
└── releases/                 — Release documentation
    └── {version}/
        ├── CHANGELOG.md
        ├── RC_CHECKLIST.md
        └── REVIEW.md
```

PRDs and Solutions live in **GitHub** (`docs/prds/`) — not the shared filesystem.

### 11.3 Sprint State File

`sprint-state.json` enables crash recovery and standup generation:

```json
{
  "feature": "feature-slug",
  "phase": "execution",
  "release": "R1",
  "tasks": [
    {
      "id": "TASK-1",
      "title": "...",
      "assignee": "worker-1",
      "status": "done",
      "branch": "feature/TASK-1-slug",
      "pr": 29,
      "completedAt": "2026-02-06T17:30:00Z"
    },
    {
      "id": "TASK-2",
      "title": "...",
      "assignee": "worker-3",
      "status": "in-progress",
      "branch": "feature/TASK-2-slug",
      "attempts": 1
    }
  ],
  "blockers": [],
  "lastUpdated": "2026-02-06T18:00:00Z"
}
```

### 11.4 Communication Flow

```
Human → #standup → Judge
Judge → sessions_send → Council panelists (for gates)
Judge → sessions_send → EL (for sprint management)
EL → sessions_send → Workers (for task assignment)
Workers → sessions_send → EL (status, MR submissions)
EL → #dev-log (summaries)
Judge → #standup, #decisions-log, #council-forum → Human + All
```

### 11.5 Session Discovery

Use **session labels** (not hardcoded session IDs) for agent-to-agent communication. If a session dies and respawns, the label persists. Example: `sessions_send(label="scrum-el", ...)`.

---

## 12. Failure Recovery

### 12.1 Worker Failures

| Scenario | Response |
|----------|----------|
| Worker stuck after 2 attempts | EL takes over; worker writes structured postmortem |
| Worker produces code that breaks CI | Bug filed, assigned back to worker |
| Worker unresponsive (session crash) | EL spawns replacement, reassigns task |
| All workers stuck on same issue | EL escalates to Judge; may need architecture change |

### 12.2 EL Failures

| Scenario | Response |
|----------|----------|
| EL can't resolve integration issue | Escalate to Judge; may convene emergency council |
| EL disagrees with PM on acceptance | One rebuttal round → Judge decides |
| EL session crashes | Judge spawns new EL; new EL reads `sprint-state.json` to bootstrap |
| EL unresponsive >5 min | Judge can approve/assign in emergency mode |

### 12.3 Council Failures

| Scenario | Response |
|----------|----------|
| Panelist doesn't ACK dispatch | Re-ping once; proceed without after 2 minutes |
| Panelist produces off-topic report | Judge ignores it, notes quality issue |
| All panelists disagree | Judge makes independent decision, records rationale |
| Model throttled during gate | Switch to reduced engagement mode |

### 12.4 Infrastructure

| Scenario | Response |
|----------|----------|
| Clawdbot gateway restart | Sessions resume; Judge checks sprint-state.json |
| Git conflict between workers | EL resolves (serialized merging prevents most) |
| CI pipeline broken | EL diagnoses; workers pause until fixed |
| Rate limit hit on subscription | Judge switches to degradation mode; notifies in #alerts |

---

## 13. Artifact Templates

### 13.1 OnePager.md

```markdown
# One-Pager: [Feature Name]

**Author:** [Human / Bot]
**Date:** [YYYY-MM-DD]

## Problem
[What pain point or opportunity?]

## Target Users
[Who benefits?]

## Proposed Solution
[High-level description]

## Success Metrics
[How do we know this worked?]

## Constraints
[Budget, timeline, technical, compliance]

## Non-Goals
[What we're explicitly NOT doing]

## Open Questions
[Unknowns]
```

### 13.2 PRD.md (Lives in GitHub: `docs/prds/`)

```markdown
# PRD: [Feature Name]

**Version:** [N]
**Status:** [Draft / Review / Approved]
**Owner:** Judge (synthesized from council)

## Goal
[One sentence]

## Non-Goals
[Explicit exclusions]

## User Personas & Jobs-to-be-Done
[Who and what they're trying to accomplish]

## Requirements

### Must Have
- [REQ-1] [requirement] — AC: [acceptance criteria]

### Should Have
- [REQ-N] ...

### Could Have
- [REQ-N] ...

## Metrics
[Measurable targets]

## Risks & Assumptions
[What could go wrong]

## Security Considerations
[Data handling, auth, abuse potential]

## Out of Scope
[Boundaries]
```

### 13.3 Task Spec

```markdown
# TASK-[ID]: [Title]

**Release:** R[N]
**Status:** [Todo / In Progress / Review / Done / Blocked]
**Assigned:** [worker-N]
**Complexity:** [S / M / L]
**Depends On:** [TASK-IDs or "none"]
**Conflicts With:** [TASK-IDs or "none"]

## Description
[What to build]

## Acceptance Criteria
- [ ] AC1: [criterion]
- [ ] AC2: [criterion]

## Test Requirements
- [ ] [what must be tested]

## Files Touched
- [file paths this task modifies]

## Branch
`feature/TASK-[ID]-[slug]`

## Definition of Done
- [ ] Tests written and passing (local + CI)
- [ ] Code reviewed by EL
- [ ] Acceptance criteria verified
- [ ] No regressions in test suite
- [ ] Dependency audit clean
```

### 13.4 RC_Checklist.md

```markdown
# Release Candidate: [Version]

**Date:** [YYYY-MM-DD]
**Status:** [Review / Approved / Rejected]

## Test Results
- Unit tests: [X/Y passing]
- Integration tests: [X/Y passing]
- SAST scan: [clean / findings]
- Dependency audit: [clean / findings]

## Changes Included
- TASK-1: [title] — [status]

## Known Issues
- [issue] — [severity] — [mitigation]

## Security Checklist
- [ ] No new unauthenticated endpoints
- [ ] Input validation on all user-facing inputs
- [ ] Secrets management verified
- [ ] No sensitive data in logs
- [ ] Dependency vulnerabilities addressed

## Rollback Plan
[How to revert]

## Demo Script
1. [Step 1]
2. [Step 2]
```

### 13.5 Gate Brief (Packaging Layer)

```markdown
# Brief: [Feature] — Gate [N]

**Date:** [YYYY-MM-DD]
**Prepared by:** [EL / Sonnet worker]

## Summary (≤10 bullets)
- ...

## Decisions Needed (max 3)
1. ...

## Risks (max 5)
1. ...

## Artifacts
- PRD: [link]
- Solution: [link]
- Sprint state: [link]
- CI status: [link]

## Changes Since Last Gate
- [diff summary]
```

---

## 14. Implementation Roadmap

### Week 1: Foundation
- [ ] Create Discord server with 5 channels per Section 3
- [ ] Set up forum channel with status tags
- [ ] Configure Discord roles and permissions
- [ ] Set up Clawdbot 11-agent configuration
- [ ] Deploy this workflow as `WORKFLOW.md` in shared directory
- [ ] Set up GitHub Actions CI pipeline
- [ ] Configure branch protection on `main`

### Week 2: Council Protocol
- [ ] Write Judge's `AGENTS.md` with full orchestration protocol
- [ ] Write panelist `AGENTS.md` with consistent personas + report protocol
- [ ] Test one full council round (Gate 1 style) with a sample topic
- [ ] Verify `sessions_send` reliability between all agents
- [ ] Test daily standup generation from sprint-state.json

### Week 3: Worker Pipeline
- [ ] Write EL's `AGENTS.md` with task management protocol
- [ ] Write worker `AGENTS.md` with TDD protocol
- [ ] Set up shared git access with serialized merge workflow
- [ ] Test: task assignment → TDD → PR → review → merge cycle
- [ ] Test: worker failure → EL takeover flow
- [ ] Validate CI catches failing code before merge

### Week 4: Integration
- [ ] End-to-end test: idea → PRD → tasks → code → test → release
- [ ] Measure actual throttle behavior on subscription models
- [ ] Optimize daily cadence timing
- [ ] First real feature through the pipeline
- [ ] Retrospective and workflow updates

---

## Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Gate** | A council review point where work is approved or rejected |
| **EL** | Engineering Lead — the Sonnet agent managing the worker team |
| **Brief** | Sonnet-generated summary provided to council before each gate |
| **MR/PR** | Merge/Pull Request — a worker's code submission for review |
| **RC** | Release Candidate — code ready for council + human review |
| **Dispatch** | The Judge sending a `COUNCIL:PROCEED` message to panelists |
| **Postmortem** | A worker's structured explanation of why they couldn't complete a task |
| **Sprint State** | `sprint-state.json` — machine-readable sprint progress for crash recovery |
| **Serialized Merge** | One PR merged at a time; next worker rebases before pushing |
| **SEC Mini-Round** | Triggered security review when any agent flags a 🛑 blocker |
| **Packaging Layer** | Pre-gate step where Sonnet summarizes context into a ≤500 word brief |

---

## Appendix B: Decision Log (This Document)

| Decision | Round | Rationale |
|----------|:-----:|-----------|
| 3-gate pipeline with combined perspectives | R1 | Cuts council calls from ~50 to ~15-21 per feature |
| Dedicated Sonnet EL (not council double-duty) | R1 | Prevents Claude bottleneck |
| Serialized merging | R1 | LLMs bad at merge conflicts; simpler than DAGs |
| Packaging Layer before every gate | R1 | Reduces expensive model token usage 50-70% |
| Triggered SEC mini-round | R1 | Defense-in-depth without extra cost in normal case |
| No dynamic hats — consistent personas | R2 | Simpler, cheaper, equally effective |
| Day = Sprint with Sunrise/Sunset cadence | R2 | Daily human visibility without micromanagement |
| 5 channels (not 10+) | R2 | Right-sized for one-person org |
| Workers never post to Discord | R2 | Reduces noise; EL summarizes |
| Sprint state file for crash recovery | R2 | EL can be respawned without losing progress |
| OAuth/subscription model (not API keys) | R2-Human | Throttled not capped; no budget ceiling concern |
| 9:30 AM MT standup | Human | User's preferred time |
| PRDs in GitHub | Human | Version controlled, PR-reviewable |
| 5 workers + 1 EL | Human | Confirmed team size |
| ✅ or text counts as approval | Human | Flexible approval mechanism |

---

*This is a living document. Update after each retrospective.*
