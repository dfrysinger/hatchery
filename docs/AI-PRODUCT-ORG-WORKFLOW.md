# AI Product Organization — Operating Workflow

> **Version:** 1.0-draft
> **Status:** Council Review Pending
> **Last Updated:** 2026-02-05

A complete operating manual for running an autonomous AI product organization inside Discord + Clawdbot. This workflow governs how ideas become shipped features through structured council deliberation, sprint execution, and quality gates.

---

## Table of Contents

1. [Organization Design](#1-organization-design)
2. [Decision Authority (RACI)](#2-decision-authority-raci)
3. [Discord Server Structure](#3-discord-server-structure)
4. [The Workflow Pipeline](#4-the-workflow-pipeline)
5. [Worker Protocol (TDD)](#5-worker-protocol-tdd)
6. [The Judge's Playbook](#6-the-judges-playbook)
7. [Cost Governance](#7-cost-governance)
8. [Clawdbot Configuration](#8-clawdbot-configuration)
9. [Failure Recovery](#9-failure-recovery)
10. [Artifact Templates](#10-artifact-templates)
11. [Implementation Roadmap](#11-implementation-roadmap)

---

## 1. Organization Design

### 1.1 Permanent Seats (Agents)

| Seat | Model | Account Tier | Primary Role |
|------|-------|-------------|--------------|
| **Opus (Judge/CPO)** | Claude Opus 4.5 | Max | Orchestrator, final arbiter, CPO tiebreaker |
| **Claude** | Claude Opus 4.5 | Max | Panelist — product quality, UX coherence, narrative |
| **ChatGPT** | GPT-5.2 | $20/mo | Panelist — systems thinking, workflow rigor, edge cases |
| **Gemini** | Gemini 3 Pro | $20/mo | Panelist — implementation realism, integration, test strategy |
| **Grok** | Grok | $20/mo | Panelist — adversarial review, failure modes, cost, abuse paths |

### 1.2 Dynamic Hats (Role Overlays)

Hats are NOT separate agents — they're prompt instructions applied when the Judge dispatches work. Each council member adopts the assigned hat's perspective while retaining their natural strengths.

| Hat | Emoji | Focus |
|-----|-------|-------|
| **Product Manager (PM)** | 🎩 | User value, requirements, acceptance criteria, UX, market fit |
| **Engineering Lead (EL)** | 🔧 | Architecture, feasibility, scalability, code quality, implementation |
| **Security Researcher (SEC)** | 🔒 | Threat modeling, attack surfaces, auth, data handling, abuse cases |
| **QA Lead** | 🧪 | Test strategy, edge cases, integration testing, quality gates |

**How hats activate:** The Judge's dispatch message includes `HAT: <role>`. Council members respond through that lens. The hat is in the dispatch, not the channel — this avoids context loss from channel-hopping and saves tokens.

### 1.3 Scrum Team (Execution)

| Role | Model | Count | Purpose |
|------|-------|-------|---------|
| **Engineering Lead** | Claude Sonnet 4.5 | 1 (dedicated) | Task assignment, code review, integration testing, worker management |
| **Workers** | Claude Sonnet 4.5 | 5 | TDD implementation, unit testing, bug fixes |

**Key design choice:** The EL is a **6th Sonnet agent**, NOT a council member doing double duty. This keeps the council available for high-leverage decisions and prevents Claude from becoming a bottleneck.

---

## 2. Decision Authority (RACI)

Clear authority prevents endless debate. When in doubt, check this table.

| Decision | Responsible | Accountable | Consulted | Informed |
|----------|------------|-------------|-----------|----------|
| Initiative worth council time | Judge | Human | — | Council |
| PRD acceptance | Council (PM hat) | Judge | Human | Workers |
| Architecture acceptance | Council (EL hat) | Judge | Human | EL |
| Security requirements | Council (SEC hat) | Judge | Human | EL |
| Task breakdown & sizing | EL | Judge | Council (quick review) | Workers |
| Technical approach per task | EL | EL | — | Workers |
| Implementation details | Worker | EL | — | — |
| Code merge readiness | EL | EL | PM (acceptance criteria only) | Judge |
| Release readiness | Council (all hats) | Judge | Human | EL, Workers |
| Tiebreaker (any dispute) | Judge | Judge | — | All |

### Dispute Resolution Protocol

1. **Disagreement detected** between EL and PM (or between council members)
2. **One structured rebuttal round** — each party writes a ≤200 word case
3. **Judge decides** within 60 seconds, citing rationale
4. **Decision is final** and recorded in `#decisions-log`

No appeals. No re-litigation. Move forward.

---

## 3. Discord Server Structure

### 3.1 Channel Map

```
🏛️ COUNCIL
├── #council-lobby        — Judge announcements, phase transitions, human requests
├── #deliberation         — Forum: council discusses dispatched topics (1 post per topic)
├── #decisions-log        — Read-only: Judge posts final decisions + rationale
├── #council-votes        — Quick polls when preference sensing is useful

📋 PRODUCT
├── 📋 prds               — Forum: each PRD is a post (tags: Draft / Review / Approved / Rejected)
├── 📋 roadmap            — Forum: release milestones and feature groupings

🔧 SCRUM
├── #standup              — EL posts assignments, workers report status (daily summaries)
├── #code-review          — MR submissions, review discussions, approval/rejection
├── 📋 sprint-tasks       — Forum: each task is a post (tags: Todo / In Progress / Review / Done / Blocked)
├── 📋 bugs               — Forum: bug reports (tags: P0 / P1 / P2 / In Progress / Resolved)

🧪 QUALITY
├── #test-results         — Automated test output, integration test reports
├── #release-candidates   — RC announcements + council review threads

📊 RELEASES
├── #release-notes        — Published release notes for the human
├── 📋 releases           — Forum: each release with changelog and review trail

🔧 OPS
├── #alerts               — CI failures, gateway issues, cron reminders
├── #audit-log            — "Who did what" summaries (bot-posted)
```

### 3.2 Permission Model

| Role | Council Channels | Product | Scrum | Quality | Releases | Ops |
|------|-----------------|---------|-------|---------|----------|-----|
| Human | Full access | Full | Full | Full | Full | Full |
| Judge | Full access | Full | Read + post | Full | Full | Full |
| Council Members | Post in #deliberation | Read | Read only | Read | Read | Read |
| EL | Read #decisions-log | Read | Full access | Full | Post | Read |
| Workers | None | Read PRDs | Post in scrum channels | Post test results | None | None |

### 3.3 Discord Features Used

| Feature | Purpose |
|---------|---------|
| **Forum channels** | Structured tracking with status tags (PRDs, tasks, bugs, releases) |
| **Forum tags** | Status workflow (Draft → Review → Approved → Done) |
| **Threads** | Per-item discussions, keeps main channels clean |
| **Pinned messages** | Latest approved artifacts in each channel |
| **Polls** | Quick council preference sensing (Judge still decides) |
| **Reactions** | ✅ approve, 🚩 flag concern, 🛑 block, 👀 reviewing |
| **Roles** | Visual identification + permission control |

---

## 4. The Workflow Pipeline

### Overview

The pipeline has **3 council gates** (expensive, high-leverage) and **multiple execution phases** (cheap, worker-driven).

```
Intake → [GATE 1: PRD + Architecture] → Sprint Planning → [GATE 2: Task Review] →
Sprint Execution → Testing → [GATE 3: Release Review] → Demo
```

---

### Phase 0 — Intake (Free)

**Who:** Human (or lightweight bot triage)
**Where:** `#council-lobby`
**What:** Human describes a feature idea or problem

**Output:** Raw feature request. Judge decides if it's worth council time.

**Judge actions:**
1. Acknowledge receipt
2. Ask 3-5 clarifying questions (scope, constraints, success metrics)
3. Once clarified, write a `OnePager.md` summary
4. Decide: proceed to Gate 1, or defer

---

### GATE 1 — PRD + Architecture Review (Council)

**Cost:** 4 panelist calls + 1 Judge synthesis = **5 calls**
**Time:** 30-45 minutes max
**Where:** `#deliberation` forum post

This gate combines PM hat (PRD) and EL hat (architecture) into a single council round to save budget. Council members respond with BOTH perspectives in one report.

**Judge dispatches:**
```
COUNCIL:PROCEED
Topic: <one-line description>
Slug: <topic-slug>
Round: 1
HAT: PM + EL (combined)
Scope: Write a combined assessment covering:
  1. PRD perspective: requirements, user value, acceptance criteria, risks
  2. Engineering perspective: architecture, feasibility, dependencies, test strategy
Context: <OnePager.md contents>
Deadline: 5 minutes
```

**Each panelist produces:** `~/clawd/shared/reports/Round1_<AgentName>.md`

**Judge synthesizes into:**
- `PRD.md` → posted to 📋 prds forum
- `Solution.md` → posted to 📋 prds forum (same thread)
- `SecurityNotes.md` (from Grok's adversarial review)

**Gate decision:** Judge posts to `#decisions-log`:
```
GATE 1 PASSED/FAILED
Topic: <slug>
Rationale: <why>
Action: Proceed to Sprint Planning / Revise and resubmit
```

**Human touchpoint:** Human reviews PRD + Solution in the forum post. Approves or requests changes.

---

### Phase 1 — Sprint Planning (EL + Judge)

**Cost:** 0-1 council calls (Judge + EL only; council consulted only if complex)
**Where:** `📋 sprint-tasks` forum

**EL produces:**
- Release breakdown (R1, R2, ...)
- Per-release task list with:
  - Task ID, title, description
  - Acceptance criteria (tied to PRD requirements)
  - Test requirements
  - Files likely touched
  - Dependencies on other tasks
  - Definition of done
  - Estimated complexity (S/M/L)

**Output:** One forum post per task in `📋 sprint-tasks`, tagged `Todo`.

---

### GATE 2 — Task Review (Council, Quick)

**Cost:** 4 panelist calls + 1 synthesis = **5 calls**
**Time:** 15-20 minutes (this is a sanity check, not a deep dive)

**Judge dispatches** the full task list to council with:
```
COUNCIL:PROCEED
HAT: PM
Topic: <slug> — Task Coverage Review
Question: Do these tasks fully cover the PRD requirements?
  Missing scenarios? Over-engineering? Under-scoping?
```

**Output:** Approved task backlog, or specific gaps to address.

---

### Phase 2 — Sprint Execution (Workers + EL)

**Cost:** 0 council calls
**Where:** `#standup`, `#code-review`, `📋 sprint-tasks`

This is where the 5 Sonnet workers do the actual building. See [Section 5: Worker Protocol](#5-worker-protocol-tdd) for details.

**EL responsibilities during sprint:**
1. Assign tasks to workers via `sessions_send`
2. Monitor `#standup` for status updates
3. Review MRs in `#code-review`
4. Provide code-level feedback
5. Check acceptance criteria alignment (PM perspective)
6. Escalate to Judge only for disputes or architectural questions
7. Take over tasks where workers are stuck after 2 attempts

**Parallel execution:** Up to 5 tasks in flight simultaneously. EL manages branch conflicts and dependency ordering.

---

### Phase 3 — Testing (Workers + EL)

**Cost:** 0 council calls
**Where:** `#test-results`, `📋 bugs`

1. **Workers test their own tasks** — run unit tests, verify acceptance criteria
2. **Workers report** results to `#test-results`
3. **EL runs integration tests** across the full release
4. **Bugs filed** to `📋 bugs` forum, assigned back to the worker who wrote the code
5. **Fix cycle:** Worker fixes → EL re-tests → repeat until clean
6. **Stuck workers** (2 attempts): EL fixes, Judge reviews

**Release Candidate criteria:**
- All unit tests passing
- Integration tests passing
- No P0 or P1 bugs open
- All acceptance criteria verified

---

### GATE 3 — Release Candidate Review (Council)

**Cost:** 4 panelist calls + 1 synthesis = **5 calls** (batched multi-hat)
**Time:** 30 minutes max
**Where:** `#release-candidates`

**Judge dispatches ONE round** with all hats combined:
```
COUNCIL:PROCEED
HAT: EL + PM + SEC (all perspectives)
Topic: <slug> — Release Candidate Review
Deliverables:
  1. Engineering review: code quality, architecture compliance, tech debt
  2. Product review: all PRD requirements met? UX acceptable?
  3. Security review: threat mitigations in place? New attack surfaces?
Context: <RC_Checklist.md with test results, known issues, changes>
```

**Gate decision options:**
- ✅ **Ship it** → proceed to demo
- 🔄 **Conditional** → specific issues sent back to scrum team (one more cycle)
- 🛑 **Reject** → fundamental problems, needs re-architecture (rare)

**Human touchpoint:** Judge announces "Ready for demo" in `#release-notes`.

---

### Phase 4 — Release Demo

**Where:** `#release-notes`
**What:** Human tests the release candidate live

**Output:** Ship approval, or bug list for one more fix cycle.

---

### Budget Summary Per Feature

| Phase | Council Calls | Notes |
|-------|:------------:|-------|
| Intake | 0 | Judge only |
| Gate 1: PRD + Architecture | 5 | Combined round |
| Sprint Planning | 0-1 | EL + Judge; council only if complex |
| Gate 2: Task Review | 5 | Quick sanity check |
| Sprint Execution | 0 | Workers + EL only |
| Testing | 0 | Workers + EL only |
| Gate 3: RC Review | 5 | Batched multi-hat round |
| **Total** | **15-16** | ~4 calls per $20/mo model per feature |

This is **3-4x cheaper** than sequential hat rounds, with no loss of quality — council members are smart enough to wear multiple hats simultaneously when asked.

---

## 5. Worker Protocol (TDD)

### 5.1 Task Assignment

Workers receive tasks from the EL via `sessions_send`:

```
TASK:ASSIGNED
Task-ID: <id>
Title: <title>
Description: <what to build>
Acceptance Criteria:
  - AC1: <criterion>
  - AC2: <criterion>
  - ...
Test Requirements:
  - <what must be tested>
Files: <likely files to touch>
Branch: feature/<task-id>-<slug>
Context: <relevant PRD sections, architecture notes>
```

### 5.2 TDD Cycle

```
1. READ task spec + acceptance criteria thoroughly
2. CREATE feature branch: feature/<task-id>-<slug>
3. WRITE failing tests first (RED phase)
   - One test per acceptance criterion minimum
   - Edge case tests for boundary conditions
4. IMPLEMENT minimum code to pass tests (GREEN phase)
5. REFACTOR for clarity, readability, and maintainability
6. RUN full test suite — fix any regressions
7. COMMIT with conventional commit message:
   feat(<scope>): <description>
   Refs: TASK-<id>
8. POST MR to #code-review:
   [TASK-<id>] <title>
   Branch: feature/<task-id>-<slug>
   Tests: X passing, Y new
   Files: <list>
   Summary: <what and why>
9. WAIT for review feedback
10. ADDRESS feedback (up to 2 revision rounds)
11. If STUCK after 2 attempts:
    POST to #standup: 🔴 BLOCKED: TASK-<id> — <what's stuck and why>
    (EL will take over)
```

### 5.3 Status Updates

Workers post to `#standup` using these prefixes:

```
🟢 STARTED: TASK-<id> — <title>
🔄 PROGRESS: TASK-<id> — <what's done, what's next>
📝 MR READY: TASK-<id> — submitted to #code-review
🔴 BLOCKED: TASK-<id> — <reason>
🐛 BUG FILED: BUG-<id> — <description>
✅ DONE: TASK-<id> — merged
```

### 5.4 Failure Protocol

When a worker fails a task after 2 attempts:
1. Worker writes a **short postmortem** (≤100 words): what was tried, what failed, what they think the issue is
2. Postmortem posted to `#standup`
3. EL takes over the task
4. Judge (CPO) reviews EL's implementation
5. Postmortem informs future task scoping (lessons learned → `KNOWLEDGE.md`)

---

## 6. The Judge's Playbook

### 6.1 Dispatch Protocol

For each council gate:

```
1. Announce phase in #council-lobby
2. Create forum post in #deliberation (or #release-candidates for Gate 3)
3. Send COUNCIL:PROCEED via sessions_send to each panelist:
   - HAT instruction(s)
   - PHASE name
   - TOPIC slug + round number
   - Full context (PRD, code summary, previous decisions)
   - DEADLINE (5 minutes standard)
4. Monitor for ACKs:
   - No ACK in 60s → re-ping once
   - Still no ACK in 60s → note absence, continue with available panelists
5. At 4 minutes: reminder to panelists who haven't filed reports
6. At 5 minutes: proceed with available reports
7. Read reports from ~/clawd/shared/reports/Round{N}_{AgentName}.md
8. Synthesize into structured output
9. Post synthesis to #decisions-log (and relevant forum post)
10. Address any DISSENT: or QUESTION: tags from panelists
11. Gate decision: PASSED / CONDITIONAL / FAILED with rationale
12. Check if human feedback needed → wait or proceed
```

### 6.2 EL Management Protocol

During sprint phases, the Judge manages the Sonnet EL:

```
1. Provide EL with approved task list from ~/clawd/shared/tasks/
2. EL breaks down and assigns tasks to workers
3. Judge monitors #standup for blockers
4. Judge intervenes only for:
   - Architectural disputes
   - Worker 2-strike escalations
   - PM vs EL disagreements
   - Scope creep detection
5. Judge does NOT micromanage implementation
```

### 6.3 Synthesis Template

```markdown
## Synthesis — [Topic] Round [N]

### Individual Assessment
**Claude:** [strengths, gaps, notable insights]
**ChatGPT:** [strengths, gaps, notable insights]
**Gemini:** [strengths, gaps, notable insights]
**Grok:** [strengths, gaps, notable insights]

### Consensus Points
- [items all/most panelists agree on]

### Divergence Points
- [item] — Claude/ChatGPT say X, Gemini/Grok say Y
  → Judge ruling: [decision + rationale]

### My Analysis
[Judge's independent assessment — not just averaging the panelists]

### Decisions
1. [decision with rationale]
2. [decision with rationale]

### Open Questions
- [unresolved items for human or next round]

### DISSENT Responses
- [response to any DISSENT: tags]

### QUESTION Responses
- [answers to any QUESTION for Judge: tags]
```

---

## 7. Cost Governance

### 7.1 Core Principles

1. **Council only meets at gates.** Three gates per feature, max. Everything else is async EL + workers.
2. **Artifact-first rule.** No council discussion without a structured document to react to.
3. **Single-round debate.** One rebuttal round for disagreements. Judge decides after that.
4. **Combined hats save money.** Asking for PM + EL + SEC in one dispatch is 4 calls. Doing them sequentially is 12.
5. **Sonnet does the drafting.** Use cheap models to write first drafts of PRDs/solutions, then council critiques (expensive refinement, cheap generation).

### 7.2 Tiered Engagement

| Decision Complexity | Who | Cost |
|-------------------|-----|------|
| Full council deliberation | 4 panelists + Judge | 5 calls |
| Quick review (consensus expected) | 2 panelists + Judge | 3 calls |
| Routine code review | EL only | 0 external calls |
| Bug triage | EL + 1 panelist | 1 call |
| Tiebreaker | Judge only | 0 external calls |
| Worker task execution | Workers | Sonnet-tier only |

### 7.3 Monthly Capacity Estimates

Assuming ~100 quality interactions per $20/month model:

| Activity | Calls per Model | Features/Month |
|----------|:--------------:|:--------------:|
| Full feature (3 gates) | ~4 per gate × 3 = 12 | ~8 features |
| Quick feature (1-2 gates) | ~4-8 | ~12-25 features |
| Bug fix / patch (no council) | 0 | Unlimited |

**Budget alarm:** Judge tracks API usage. If any model is at 70% monthly usage, switch to reduced engagement (2 panelists instead of 4, skip Gate 2).

---

## 8. Clawdbot Configuration

### 8.1 Agent Architecture

```
11 agents total:
├── judge (agent: Opus 4.5) — orchestrator
├── council-claude (agent: Opus 4.5) — panelist
├── council-chatgpt (agent: GPT-5.2) — panelist
├── council-gemini (agent: Gemini 3 Pro) — panelist
├── council-grok (agent: Grok) — panelist
├── scrum-el (agent: Sonnet 4.5) — engineering lead
├── worker-1 through worker-5 (agent: Sonnet 4.5) — developers
```

### 8.2 Shared Filesystem

```
~/clawd/shared/
├── ROLES.md                  — Hat definitions and behavioral instructions
├── WORKFLOW.md               — This document (phase state machine)
├── KNOWLEDGE.md              — Accumulated project knowledge
├── DECISIONS.md              — Decision log
├── CONTEXT.md                — Current project context
├── reports/                  — Council round reports
│   └── Round{N}_{Agent}.md
├── prds/                     — PRD documents
│   └── {feature-slug}.md
├── tasks/                    — Task specifications
│   └── TASK-{id}.md
├── bugs/                     — Bug reports
│   └── BUG-{id}.md
└── releases/                 — Release documentation
    └── {version}/
        ├── CHANGELOG.md
        ├── RC_CHECKLIST.md
        └── REVIEW.md
```

### 8.3 Communication Flow

```
Human → #council-lobby → Judge
Judge → sessions_send → Council panelists (for gates)
Judge → sessions_send → EL (for sprint management)
EL → sessions_send → Workers (for task assignment)
Workers → #standup, #code-review → EL (status, MRs)
EL → Judge (escalations only)
Judge → #decisions-log → All (decisions)
Judge → #release-notes → Human (demo readiness)
```

### 8.4 Channel Bindings

Each Discord channel is bound to the appropriate agent(s):

- **Council channels** (`#council-lobby`, `#deliberation`, `#decisions-log`) → Judge
- **Scrum channels** (`#standup`, `#code-review`, `📋 sprint-tasks`, `📋 bugs`) → EL
- **Quality channels** (`#test-results`, `#release-candidates`) → EL + Judge
- **Release channels** (`#release-notes`) → Judge
- **Forum channels** (PRDs, roadmap, releases) → Judge (posting), all (reading)

Workers communicate via `sessions_send`, not Discord channels directly, to reduce noise.

---

## 9. Failure Recovery

### 9.1 Worker Failures

| Scenario | Response |
|----------|----------|
| Worker stuck after 2 attempts | EL takes over; worker writes postmortem |
| Worker produces code that breaks integration tests | Bug filed, assigned back to worker |
| Worker unresponsive (session crash) | EL spawns replacement worker, reassigns task |
| All workers stuck on same issue | EL escalates to Judge; may need architecture change |

### 9.2 EL Failures

| Scenario | Response |
|----------|----------|
| EL can't resolve integration issue | Escalate to Judge; Judge may convene emergency council |
| EL disagrees with PM on acceptance | One rebuttal round → Judge decides |
| EL session crashes | Judge spawns new EL agent, provides full context |

### 9.3 Council Failures

| Scenario | Response |
|----------|----------|
| Panelist doesn't ACK dispatch | Re-ping once; proceed without after 2 minutes |
| Panelist produces garbage report | Judge ignores it, notes quality issue |
| All panelists disagree | Judge makes independent decision, records rationale |
| Judge session crashes | Human restarts; Judge reads DECISIONS.md for continuity |

### 9.4 Infrastructure

| Scenario | Response |
|----------|----------|
| Clawdbot gateway restart | Sessions resume; Judge checks for interrupted phases |
| Git conflict between workers | EL resolves; may reassign conflicting tasks sequentially |
| Rate limit hit on $20/mo model | Judge switches to reduced engagement mode |

---

## 10. Artifact Templates

### 10.1 OnePager.md

```markdown
# One-Pager: [Feature Name]

**Author:** [Human / Bot]
**Date:** [YYYY-MM-DD]

## Problem
[What pain point or opportunity are we addressing?]

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
[Unknowns that need resolution]
```

### 10.2 PRD.md

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
- [REQ-2] ...

### Should Have
- [REQ-N] ...

### Could Have
- [REQ-N] ...

## UX Notes
[Interaction model, key flows]

## Metrics
[Success criteria with measurable targets]

## Risks & Assumptions
[What could go wrong; what we're assuming is true]

## Security Considerations
[Data handling, auth, abuse potential — from Grok's review]

## Out of Scope
[Explicit boundaries]
```

### 10.3 Solution.md

```markdown
# Solution: [Feature Name]

**Version:** [N]
**PRD:** [link]

## Architecture Overview
[High-level design with component diagram if useful]

## Data Flow
[How data moves through the system]

## APIs / Interfaces
[New or modified interfaces]

## Dependencies
[External services, libraries, other features]

## Test Strategy
- Unit: [approach]
- Integration: [approach]
- E2E: [approach]

## Rollout Plan
[How to deploy safely]

## Observability
[Logging, monitoring, alerting]

## Known Tradeoffs
[Decisions made and why]

## Cost Considerations
[Resource usage, API costs, scaling]
```

### 10.4 Task Spec

```markdown
# TASK-[ID]: [Title]

**Release:** R[N]
**Status:** [Todo / In Progress / Review / Done / Blocked]
**Assigned:** [worker-N]
**Complexity:** [S / M / L]
**Depends On:** [TASK-IDs or "none"]

## Description
[What to build]

## Acceptance Criteria
- [ ] AC1: [criterion]
- [ ] AC2: [criterion]

## Test Requirements
- [ ] [what must be tested]

## Files Likely Touched
- [file paths]

## Branch
`feature/TASK-[ID]-[slug]`

## Definition of Done
- [ ] Tests written and passing
- [ ] Code reviewed by EL
- [ ] Acceptance criteria verified
- [ ] No regressions in test suite
```

### 10.5 RC_Checklist.md

```markdown
# Release Candidate: [Version]

**Date:** [YYYY-MM-DD]
**Release:** R[N]
**Status:** [Review / Approved / Rejected]

## Test Results
- Unit tests: [X/Y passing]
- Integration tests: [X/Y passing]
- Known failures: [list or "none"]

## Changes Included
- TASK-1: [title] — [status]
- TASK-2: [title] — [status]

## Known Issues
- [issue description] — [severity] — [mitigation]

## Security Checklist
- [ ] No new unauthenticated endpoints
- [ ] Input validation on all user-facing inputs
- [ ] Secrets management verified
- [ ] No sensitive data in logs

## Rollback Plan
[How to revert if something breaks]

## Demo Script
1. [Step 1]
2. [Step 2]
```

---

## 11. Implementation Roadmap

### Week 1: Foundation
- [ ] Create Discord server categories and channels per Section 3
- [ ] Set up forum channels with status tags
- [ ] Configure Discord roles and permissions
- [ ] Set up Clawdbot multi-agent configuration (11 agents)
- [ ] Write `ROLES.md` with hat definitions
- [ ] Deploy this workflow document as `WORKFLOW.md` in shared directory

### Week 2: Council Protocol
- [ ] Write Judge's `AGENTS.md` with full orchestration protocol
- [ ] Write panelist `AGENTS.md` files with hat-switching + report protocol
- [ ] Test one full council round (Gate 1 style) with a sample topic
- [ ] Refine dispatch format, timing, and report templates
- [ ] Verify `sessions_send` reliability between all council agents

### Week 3: Worker Pipeline
- [ ] Write EL's `AGENTS.md` with task management protocol
- [ ] Write worker `AGENTS.md` with TDD protocol
- [ ] Set up shared git repository access for all agents
- [ ] Test: task assignment → TDD → MR → review → merge cycle
- [ ] Test: worker failure → EL takeover flow
- [ ] Refine status update format

### Week 4: Integration
- [ ] End-to-end test: idea → PRD → tasks → code → test → release
- [ ] Measure actual council call costs against budget estimates
- [ ] Optimize timing (are 5-minute deadlines right?)
- [ ] Document lessons learned
- [ ] First real feature through the pipeline

---

## Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Gate** | A council review point where work is approved, conditionally approved, or rejected |
| **Hat** | A role overlay that defines the perspective a council member adopts |
| **EL** | Engineering Lead — the Sonnet agent managing the worker team |
| **MR** | Merge Request — a worker's code submission for review |
| **RC** | Release Candidate — code that has passed all tests and is ready for council review |
| **Dispatch** | The Judge sending a `COUNCIL:PROCEED` message to panelists |
| **Postmortem** | A worker's brief explanation of why they couldn't complete a task |

---

*This is a living document. Update after each retrospective.*
