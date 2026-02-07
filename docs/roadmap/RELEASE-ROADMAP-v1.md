# Hatchery Release Roadmap — v1.2

> **Prepared by:** Judge (Opus)  
> **Date:** 2026-02-05 (Updated: 2026-02-07)  
> **Status:** R3 In Progress

---

## Current State Assessment

### ✅ Completed Releases

**R1: Stability & Platform Parity (2026-02-05 – 2026-02-06)**
| Task | Description | PR |
|------|-------------|:--:|
| TASK-1 | Fix `build-full-config.sh` line 722 — add `*` fallback case | #45 |
| TASK-2 | Update `set-council-group.sh` for dual-platform support | #43 |
| TASK-3 | Add JSON validation to config builder (escape special chars) | #46 |
| TASK-8 | Close VNC port 5900 + add security regression tests | #38 |
| TASK-9 | Fix API /log debug endpoint + root SSH access | #34 |

**R2: Resilience & Data Safety (2026-02-06)**
| Task | Description | PR |
|------|-------------|:--:|
| TASK-4 | Fix `rclone sync` → `rclone copy` for memory safety | #53 |
| TASK-5 | Fix cross-shell `wait` race condition (Xvfb PID file) | #54 |
| TASK-6 | Add DM channel caching to reduce API calls | #52 |
| TASK-7 | Implement `sprint-state.json` for EL crash recovery | #55 |

**Bonus Work (2026-02-06 – 2026-02-07):**
- PR #72: Atomic writes for JSON state files
- PR #73: Xvfb process name validation
- PR #74: desktop.service permission fix
- PR #75: Desktop background config timing fix
- PR #76: File locking for sprint-state.json
- PR #77: rclone path validation guardrails
- PR #78: globalTools support for TOOLS.md
- PR #79: RDP/VNC delay until phase2 completes
- PR #81: Migrate from clawdbot to openclaw
- PR #82: Memory restore before bot starts
- PR #83: x11vnc dependency chain fix

---

## In Progress

### R3: Tooling & Observability (Started: 2026-02-07)
**Theme:** Build features to support the new workflow

| Task | Status | Description |
|------|:------:|-------------|
| TASK-10 | 🔲 | Implement secret redaction in logs and reports |
| TASK-11 | 🔲 | Add `npm audit` / dependency scanning to CI |
| TASK-15 | 🔲 | Standup generator: read `sprint-state.json`, format daily brief |
| TASK-16 | 🔲 | Gate brief generator: produce ≤500 word summaries for council |

**Exit Criteria:**
- Judge can auto-generate standups from sprint state
- Secrets never appear in logs or Discord
- CI blocks PRs with known vulnerabilities

---

## Upcoming Releases

### R4: Architecture Modernization
**Theme:** Reduce complexity, improve maintainability

| Task | Status | Description |
|------|:------:|-------------|
| TASK-12 | 🔲 | Rewrite `build-full-config.sh` in Python (cleaner JSON handling) |
| TASK-13 | 🔲 | Reduce YAML to thin bootstrapper (~15KB target, from 57KB) |
| TASK-14 | 🔲 | Refactor `test_parse_habitat` for better coverage |
| TASK-18 | 🔲 | Add git identity configuration to boot sequence |

**Exit Criteria:**
- Config builder is maintainable and testable
- YAML is human-readable without deep nesting
- Test coverage improved

---

### R5: iOS Shortcut & Distribution
**Theme:** Update Shortcuts, improve onboarding

| Task | Status | Description |
|------|:------:|-------------|
| TASK-17 | 🔲 | iOS Shortcut updates: platform picker, Discord IDs, per-agent tokens |
| TASK-19 | 🔲 | Documentation: setup guide for new habitats |
| TASK-20 | 🔲 | Release packaging: versioned tarballs with changelogs |

**Exit Criteria:**
- Shortcuts support Discord habitats
- New users can self-onboard
- Releases are reproducible

---

## Summary

| Release | Tasks | Done | Theme | Status |
|---------|:-----:|:----:|-------|--------|
| **R1** | 5 | 5 | Stability + Security | ✅ Complete |
| **R2** | 4 | 4 | Resilience & Data Safety | ✅ Complete |
| **R3** | 4 | 0 | Tooling & Observability | 🟡 In Progress |
| **R4** | 4 | 0 | Architecture Modernization | ⬜ Not Started |
| **R5** | 3 | 0 | iOS Shortcut & Distribution | ⬜ Not Started |

**Total: 20 tasks across 5 releases (9 complete, 11 remaining)**

---

## Changelog

### v1.2 (2026-02-07)
- R1 marked complete (5/5 tasks)
- R2 marked complete (4/4 tasks)
- R3 started
- Added "Bonus Work" section for additional PRs
- Updated summary table

### v1.1 (2026-02-06)
- Security tasks (TASK-8, TASK-9) completed and moved to R1
- Added TASK-18 (git identity) per council feedback
- Reordered releases: Tooling moved to R3, Architecture to R4
- Added status column and PR links for completed tasks

### v1.0 (2026-02-05)
- Initial draft with 17 tasks across 5 releases
- Council review requested

---

*This roadmap is a living document. Updates after each council review.*
