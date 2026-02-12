# Hatchery Release Roadmap — v1.3

> **Prepared by:** Judge (Opus)  
> **Date:** 2026-02-05 (Updated: 2026-02-11)  
> **Status:** R6 In Progress

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

**R4: Code Quality & Documentation (2026-02-08 – 2026-02-09)**  
**Theme:** Address exec code review findings

| Task | Description | PR |
|------|-------------|:--:|
| TASK-28 | Revert API default to 127.0.0.1 (secure-by-default) | #132 |
| TASK-22 | Add drift detection CI for parse-habitat.py | #133 |
| TASK-27 | Document API_BIND_ADDRESS security model | #135 |
| TASK-25 | Fix DEFAULT_STATE_FILE test environment bug | #137 |
| TASK-23 | Document api_uploaded marker file location | #138, #141 |
| TASK-26 | Fix phase2-background.sh YAML drift | #143 |
| TASK-24 | Add v1 schema backward compatibility test | #144 |
| TASK-21 | Add logging/error handling to write_upload_marker() | #145 |

**Exit Criteria:** ✅ All criteria met
- Security: API defaults to localhost-only
- CI: Drift detection prevents config sync issues
- Documentation: API security model clarified
- Tests: v1 backward compatibility verified

**R5: Code Review Fixes (2026-02-09)**  
**Theme:** Address findings from deep code review

| Task | Description | PR |
|------|-------------|:--:|
| TASK-171 | Remove shell=True from api-server.py | #175, #177 |
| TASK-168 | Fix missing executable permissions | #176 |
| TASK-166 | Fix stage 9 duplicate in phase2-background.sh | #177 |
| TASK-169 | Fix SECURITY.md contradictions | #178 |
| TASK-170 | Add endpoint-level authentication tests | #180 |
| TASK-173 | Add stale timestamp validation tests | #182 |
| TASK-181 | Update SECURITY.md endpoint table | #183 |
| TASK-167 | Fix BOOT.md duplicate NO_REPLY instructions | #184 |
| TASK-174 | Improve bad signature test reliability | #186 |
| TASK-163 | Remove stale minified scripts | #187 |

**Exit Criteria:** ✅ All criteria met
- Security: Shell injection vector closed, 40 new auth tests
- Runtime: Script permissions fixed
- Code Quality: 423 lines of stale code removed
- Tests: 562 total (up from 510)

**Hotfix:** PR #188 (runcmd ordering fix)

---

## In Progress

### R6: Habitat Schema v3 / Isolation Support (Started: 2026-02-11)
**Theme:** Per-agent isolation modes for multi-agent deployments

| Task | Status | Description | PR |
|------|:------:|-------------|:--:|
| Spec | ✅ | v3 schema specification | #197 |
| TASK-201 | ✅ | Update parse-habitat.py for v3 fields | #212 |
| TASK-202 | ✅ | Add isolation validation | #212 |
| TASK-205 | ✅ | Backward compatibility tests (21 tests) | #212 |
| TASK-203 | ✅ | Session mode — per-group systemd services (22 tests) | — |
| TASK-204 | ✅ | Docker Compose generation (26 tests) | — |

**Note:** PR #211 (`feature/isolation-v3-parse`) is superseded by #212 — close it.

**Exit Criteria:**
- v2 habitats work unchanged (backward compatible)
- Isolation modes supported: none, session, container, droplet
- Docker Compose generation for container mode
- Comprehensive test coverage (50+ tests)

---

## Upcoming Releases

### R3: Tooling & Observability (Deferred)
**Theme:** Build features to support the workflow

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

### iOS Shortcut & Distribution (Deferred)
**Theme:** Update Shortcuts, improve onboarding

| Task | Status | Description |
|------|:------:|-------------|
| — | ✅ | Token Broker architecture (PR #196) |
| — | ✅ | Base64 body support for /config/upload (PR #193) |
| TASK-17 | 🔲 | iOS Shortcut updates: platform picker, Discord IDs |
| TASK-19 | 🔲 | Documentation: setup guide for new habitats |
| TASK-20 | 🔲 | Release packaging: versioned tarballs with changelogs |

**Exit Criteria:**
- Shortcuts support Discord habitats
- Token Broker implemented for secure token management
- New users can self-onboard
- Releases are reproducible

**Architecture Decision:** PR #192 (unauthenticated `/sign` endpoint) was **rejected** due to signing oracle vulnerability. Adopted Token Broker approach instead (Dropbox-backed state, no server-side signing).

---

### Architecture Modernization (Deferred)
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

## Summary

| Release | Tasks | Done | Theme | Status |
|---------|:-----:|:----:|-------|--------|
| **R1** | 5 | 5 | Stability + Security | ✅ Complete |
| **R2** | 4 | 4 | Resilience & Data Safety | ✅ Complete |
| **R4** | 8 | 8 | Code Quality & Documentation | ✅ Complete |
| **R5** | 10 | 10 | Code Review Fixes | ✅ Complete |
| **R6** | 5 | 0 | Habitat Schema v3 / Isolation | 🟡 In Progress |
| **R3** | 4 | 0 | Tooling & Observability | ⬜ Deferred |
| **iOS** | 3 | 2 | Shortcut & Distribution | 🟡 Partial |
| **Arch** | 4 | 0 | Architecture Modernization | ⬜ Deferred |

**Total: 43 tasks across 8 releases (29 complete, 14 remaining)**

---

## Changelog

### v1.3 (2026-02-11)
- Added R4: Code Quality & Documentation (8 tasks, complete)
- Added R5: Code Review Fixes (10 tasks + 1 hotfix, complete)
- Added R6: Habitat Schema v3 / Isolation Support (in progress)
- Documented PR #192 security decision (Token Broker adopted)
- Marked iOS Shortcut work as partial (Token Broker + base64 support merged)
- Reorganized deferred releases (R3, Architecture, iOS)
- Updated summary table with actual sprint history

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
