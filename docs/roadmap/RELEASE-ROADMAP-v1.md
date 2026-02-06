# Hatchery Release Roadmap — v1.1

> **Prepared by:** Judge (Opus)  
> **Date:** 2026-02-05 (Updated: 2026-02-06)  
> **Status:** In Progress — R1 Security Complete

---

## Current State Assessment

### ✅ Completed (2026-02-05 – 2026-02-06)

**Workflow & Infrastructure (PR #28):**
- AI Product Org Workflow v2.0 merged
- Discord: Product Org category + 5 channels created
- GitHub: `docs/prds/` directory, branch protection enabled
- Clawdbot: 11-agent architecture configured
- AGENTS.md files written for EL + Workers
- 136 tests passing on main

**Security Hardening (Council moved to R1):**
- PR #38: VNC port 5900 closed + security regression tests
- PR #34: /log debug endpoint removed + root SSH access fixed

**Stability & Boot Fixes:**
- PR #35: bootstrap.sh self-overwrite syntax error fixed
- PR #36: Bootstrap self-overwrite regression guard added
- PR #29: Slim YAML boot failures fixed

**Cloud-Init Compatibility:**
- PR #31: Unicode replaced with ASCII for cloud-init compat
- PR #32: ASCII enforcement + CI check added

**Cleanup:**
- PR #30: Redundant Shortcut placeholders removed
- PR #33: TELEGRAM_USER_ID_B64 placeholder removed

### ⚠️ Remaining Known Issues

**Must-Fix (blocking release stability):**
1. `build-full-config.sh` line 722 — missing `*` fallback disables both channels on unknown PLATFORM
2. `set-council-group.sh` — Telegram-only, breaks on Discord habitats

**Should-Fix (quality/reliability):**
3. JSON validation missing in config builder (special chars break it)
4. DM channel caching could improve performance
5. `rclone sync` can wipe Dropbox memory if restore fails before first periodic sync
6. Cross-shell `wait` race condition (bootcmd vs runcmd separate shells)

**Security (✅ Addressed):**
- ~~VNC unauthenticated + port 5900 exposed~~ → Closed (PR #38)
- ~~API server POST endpoints have zero auth~~ → Fixed (PR #34)

---

## Proposed Release Roadmap

### R1: Stability & Platform Parity ✅ SECURITY COMPLETE
**Theme:** Fix blocking issues, ensure Discord + Telegram both work reliably

| Task | Status | Description | PR |
|------|:------:|-------------|:--:|
| ~~TASK-8~~ | ✅ | Close VNC port 5900 + add regression tests | #38 |
| ~~TASK-9~~ | ✅ | Fix API /log debug endpoint + root SSH access | #34 |
| TASK-1 | 🔲 | Fix `build-full-config.sh` line 722 — add `*` fallback case | — |
| TASK-2 | 🔲 | Update `set-council-group.sh` for dual-platform support | — |
| TASK-3 | 🔲 | Add JSON validation to config builder (escape special chars) | — |

**Exit Criteria:**
- ✅ No unauthenticated remote access (VNC closed, API secured)
- 🔲 Both platforms work with same codebase
- 🔲 Config builder handles special characters in channel names/IDs
- ✅ All tests passing (136+)

---

### R2: Resilience & Data Safety (Target: Week 2)
**Theme:** Prevent data loss, improve crash recovery

| Task | Status | Description |
|------|:------:|-------------|
| TASK-4 | 🔲 | Fix `rclone sync` → `rclone copy` for memory safety (don't wipe on empty source) |
| TASK-5 | 🔲 | Fix cross-shell `wait` race condition between bootcmd and runcmd |
| TASK-6 | 🔲 | Add DM channel caching to reduce API calls |
| TASK-7 | 🔲 | Implement `sprint-state.json` for EL crash recovery |

**Exit Criteria:**
- Memory cannot be wiped by failed restore
- Boot sequence is deterministic
- Sprint state persists across EL restarts

---

### R3: Tooling & Observability (Target: Week 3)
**Theme:** Build features to support the new workflow (moved up per council)

| Task | Status | Description |
|------|:------:|-------------|
| TASK-15 | 🔲 | Standup generator: read `sprint-state.json`, format daily brief |
| TASK-16 | 🔲 | Gate brief generator: produce ≤500 word summaries for council |
| TASK-10 | 🔲 | Implement secret redaction in logs and reports |
| TASK-11 | 🔲 | Add `npm audit` / dependency scanning to CI |

**Exit Criteria:**
- Judge can auto-generate standups from sprint state
- Secrets never appear in logs or Discord
- CI blocks PRs with known vulnerabilities

---

### R4: Architecture Modernization (Target: Week 4+)
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

### R5: iOS Shortcut & Distribution (Target: Week 5+)
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
| **R1** | 5 | 2 | Stability + Security | 🟡 In Progress |
| **R2** | 4 | 0 | Resilience & Data Safety | ⬜ Not Started |
| **R3** | 4 | 0 | Tooling & Observability | ⬜ Not Started |
| **R4** | 4 | 0 | Architecture Modernization | ⬜ Not Started |
| **R5** | 3 | 0 | iOS Shortcut & Distribution | ⬜ Not Started |

**Total: 20 tasks across 5 releases (2 complete, 18 remaining)**

---

## Changelog

### v1.1 (2026-02-06)
- Security tasks (TASK-8, TASK-9) completed and moved to R1
- Added TASK-18 (git identity) per council feedback
- Reordered releases: Tooling moved to R3, Architecture to R4
- Added status column and PR links for completed tasks
- Updated "Completed" section with all merged PRs

### v1.0 (2026-02-05)
- Initial draft with 17 tasks across 5 releases
- Council review requested

---

*This roadmap is a living document. Updates after each council review.*
