# Synthesis — Release Roadmap Review Round 1

**Judge:** Opus | **Date:** 2026-02-06 | **Topic:** release-roadmap

---

## Individual Assessment

**Claude (Product Quality):**
- Thorough analysis with clear DISSENT on security priority
- Identified missing PRD traceability and dependency graph
- Raised critical question: Is port 5900 actually exposed right now?
- Strengths: Detailed risk breakdown, specific recommendations
- Gap: Didn't address git identity issue

**ChatGPT (Systems Thinking):**
- Strong systems analysis of hidden dependencies
- Boot determinism as root dependency is excellent insight
- Proposed parallel fixture-driven migration for Python rewrite
- Strengths: Practical middle-ground proposals, R1.5 concept
- Gap: Could be more specific on timeline adjustments

**Gemini (Implementation Realism):**
- Direct and actionable — clear VETO on R4
- Identified critical missing task: worker git identity
- Proposed most aggressive restructuring (tooling → R3)
- Strengths: Cuts to the chase, no-nonsense
- Gap: May be too aggressive on deferring architecture work

---

## Consensus Points (3/3 agree)

### 1. 🚨 Security Cannot Wait Until Week 3
**All panelists agree:** VNC unauthenticated + exposed port 5900 is a live vulnerability. Fixing this in R3 (Week 3) is unacceptable.

**Decision:** Move TASK-8 (VNC auth) and TASK-9 (API auth) to **R1** as blocking criteria, OR create **R1.5 Security Stopgap** release.

### 2. ⚠️ R4 Python Rewrite Is High Risk
- Claude: "Only with existing tests and isolated release"
- ChatGPT: "Parallel fixture-driven migration, not big-bang"
- Gemini: "VETO — defer to R6+"

**Decision:** Defer R4 to later. Focus on patching bash incrementally. If Python rewrite happens, it must have:
- Golden fixture suite (input → expected output)
- Parity testing against bash version
- Rollback plan

### 3. 📦 R5 Tooling Enables Everything
All agree Product Org tooling (standup generator, gate briefs) should come sooner, not later.

**Decision:** Pull packaging/brief generator from R5 into R3. This directly reduces council cost and improves governance.

---

## Divergence Points

### Grok Seat
| Claude | ChatGPT | Gemini |
|--------|---------|--------|
| Yes ($20/mo worth it) | Conditional (Gate 3 + security only) | No (ChatGPT wears security hat) |

**Judge Ruling:** Defer decision. Keep 3 panelists for now. Revisit after first full sprint cycle when we have data on security review quality.

### Exact Release Restructuring
Three different proposals on how to reorder. I'll merge them below.

---

## Revised Roadmap (Judge's Synthesis)

| Release | Theme | Key Tasks | Timeline |
|---------|-------|-----------|----------|
| **R1** | Stability + Critical Security | TASK-1 (fallback), TASK-2 (dual-platform), TASK-3 (JSON), **TASK-8 (VNC)**, **TASK-9 (API auth)** | Week 1 |
| **R2** | Resilience + Data Safety | TASK-4 (rclone), TASK-5 (boot race), TASK-6 (caching), TASK-7 (sprint-state), **TASK-NEW: Git identity** | Week 2 |
| **R3** | Tooling + Security Hardening | TASK-15 (standup gen), TASK-16 (gate briefs), TASK-10 (redaction), TASK-11 (npm audit) | Week 3 |
| **R4** | iOS Shortcuts + Remaining | TASK-17 (shortcuts), remaining security items, test coverage | Week 4 |
| **R5** | Architecture (Deferred) | TASK-12 (Python rewrite), TASK-13 (YAML reduction) — only after workflow is stable | Week 6+ |

**Changes from original:**
- Security (VNC/API) moved from R3 → R1
- Python rewrite deferred from R4 → R5+
- Tooling moved from R5 → R3
- Added git identity task (Gemini's catch)
- Total: 17 → 18 tasks

---

## Open Questions Resolved

| Question | Decision | Rationale |
|----------|----------|-----------|
| Security before resilience? | **Yes** — critical security in R1 | Live vulnerability > stability issues |
| Python rewrite worth it? | **Deferred** | High risk during Product Org launch |
| R5 scope? | **Add git identity, move tooling earlier** | Per Gemini's catch + all agree |
| Grok seat? | **Defer** | Insufficient data; revisit after sprint 1 |

---

## New Questions for Human

1. **Is port 5900 currently firewalled?** Claude's question is critical — if exposed, we should fix TODAY before continuing.
2. **Approve revised roadmap?** The restructuring is significant (security → R1, architecture → deferred).
3. **Git identity approach?** Shared git user with per-commit author, OR 5 separate GitHub bot accounts?

---

## Action Items

| # | Task | Owner | Status |
|---|------|-------|--------|
| 1 | Confirm port 5900 firewall status | Human/Judge | **BLOCKING** |
| 2 | Update roadmap doc with revised structure | Judge | Pending approval |
| 3 | Create TASK-NEW for git identity | EL | Pending approval |
| 4 | Commit roadmap to GitHub | Judge | After human approval |

---

*Synthesis complete. Awaiting human decision on restructured roadmap.*
