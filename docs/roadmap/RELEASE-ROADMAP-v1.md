# Hatchery Release Roadmap — v1 Draft

> **Prepared by:** Judge (Opus)  
> **Date:** 2026-02-05  
> **Status:** Draft — Awaiting Council Review

---

## Current State Assessment

### ✅ Completed Today (2026-02-05)
- AI Product Org Workflow v2.0 merged (PR #28)
- Discord: Product Org category + 5 channels created
- GitHub: `docs/prds/` directory, branch protection enabled
- Clawdbot: 11-agent architecture configured
- AGENTS.md files written for EL + Workers
- 136 tests passing on main

### ⚠️ Known Issues (from Code Review)

**Must-Fix (blocking release stability):**
1. `build-full-config.sh` line 722 — missing `*` fallback disables both channels on unknown PLATFORM
2. `set-council-group.sh` — Telegram-only, breaks on Discord habitats

**Should-Fix (quality/reliability):**
3. JSON validation missing in config builder (special chars break it)
4. DM channel caching could improve performance
5. `rclone sync` can wipe Dropbox memory if restore fails before first periodic sync
6. Cross-shell `wait` race condition (bootcmd vs runcmd separate shells)

**Security Findings (deferred but tracked):**
7. VNC unauthenticated + port 5900 exposed
8. API server POST endpoints (/sync, /prepare-shutdown) have zero auth

---

## Proposed Release Roadmap

### R1: Stability & Platform Parity (Target: This Week)
**Theme:** Fix blocking issues, ensure Discord + Telegram both work reliably

| Task | Complexity | Description |
|------|:----------:|-------------|
| TASK-1 | S | Fix `build-full-config.sh` line 722 — add `*` fallback case |
| TASK-2 | M | Update `set-council-group.sh` for dual-platform support |
| TASK-3 | S | Add JSON validation to config builder (escape special chars) |

**Exit Criteria:**
- Both platforms work with same codebase
- Config builder handles special characters in channel names/IDs
- All 136 tests still passing

---

### R2: Resilience & Data Safety (Target: Week 2)
**Theme:** Prevent data loss, improve crash recovery

| Task | Complexity | Description |
|------|:----------:|-------------|
| TASK-4 | M | Fix `rclone sync` → `rclone copy` for memory safety (don't wipe on empty source) |
| TASK-5 | M | Fix cross-shell `wait` race condition between bootcmd and runcmd |
| TASK-6 | S | Add DM channel caching to reduce API calls |
| TASK-7 | M | Implement `sprint-state.json` for EL crash recovery |

**Exit Criteria:**
- Memory cannot be wiped by failed restore
- Boot sequence is deterministic
- Sprint state persists across EL restarts

---

### R3: Security Hardening (Target: Week 3)
**Theme:** Close security gaps identified in code review

| Task | Complexity | Description |
|------|:----------:|-------------|
| TASK-8 | L | Add authentication to VNC (password or SSH tunnel only) |
| TASK-9 | M | Add auth to API server POST endpoints (/sync, /prepare-shutdown) |
| TASK-10 | M | Implement secret redaction in logs and reports |
| TASK-11 | S | Add `npm audit` / dependency scanning to CI |

**Exit Criteria:**
- No unauthenticated remote access
- All endpoints require auth
- CI blocks PRs with known vulnerabilities

---

### R4: Architecture Modernization (Target: Week 4)
**Theme:** Reduce complexity, improve maintainability

| Task | Complexity | Description |
|------|:----------:|-------------|
| TASK-12 | L | Rewrite `build-full-config.sh` in Python (cleaner JSON handling) |
| TASK-13 | L | Reduce YAML to thin bootstrapper (~15KB target, from 57KB) |
| TASK-14 | M | Refactor `test_parse_habitat` for better coverage |

**Exit Criteria:**
- Config builder is maintainable and testable
- YAML is human-readable without deep nesting
- Test coverage improved

---

### R5: Product Org Tooling (Target: Week 5+)
**Theme:** Build features to support the new workflow

| Task | Complexity | Description |
|------|:----------:|-------------|
| TASK-15 | M | Standup generator: read `sprint-state.json`, format daily brief |
| TASK-16 | M | Gate brief generator: produce ≤500 word summaries for council |
| TASK-17 | L | iOS Shortcut updates: platform picker, Discord IDs, per-agent tokens |

**Exit Criteria:**
- Judge can auto-generate standups from sprint state
- Packaging layer is automated
- Shortcuts support Discord habitats

---

## Summary

| Release | Tasks | Theme | Risk |
|---------|:-----:|-------|------|
| **R1** | 3 | Stability & Platform Parity | Low — small, well-understood fixes |
| **R2** | 4 | Resilience & Data Safety | Medium — touches boot sequence |
| **R3** | 4 | Security Hardening | Medium — requires careful testing |
| **R4** | 3 | Architecture Modernization | High — major refactor |
| **R5** | 3 | Product Org Tooling | Medium — new functionality |

**Total: 17 tasks across 5 releases**

---

## Open Questions for Council

1. **Prioritization:** Should security (R3) come before resilience (R2)?
2. **R4 Risk:** Is the Python rewrite worth it, or should we patch bash incrementally?
3. **R5 Scope:** What other tooling does the Product Org need day-1?
4. **Grok seat:** Should we add Grok to the council for security reviews, or keep 3 panelists?

---

*This roadmap is a living document. Updates after each council review.*
