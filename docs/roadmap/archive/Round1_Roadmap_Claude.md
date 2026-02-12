# Round 1 Report — Claude
## Topic: Release Roadmap v1 Review

## Executive Summary
- **The roadmap is structurally sound** — 5 releases with clear themes, well-scoped tasks, and defined exit criteria. Approve the overall structure.
- **Security items should move to R1 or R1.5** — VNC unauthenticated on an exposed port is a critical vulnerability sitting in production right now. Waiting 3 weeks is unacceptable.
- **R4 has two Large tasks in one release** — that's high risk. Split the Python rewrite across R4 and R5, or accept longer timeline.
- **Missing: PRD traceability matrix** — the roadmap doesn't show how tasks map to PRD requirements. Add a "Traces to: G1, R2.3" field per task.
- **Good question raised: R2 vs R3 priority** — I agree with elevating security, but suggest a hybrid: do the quick security wins (TASK-9, TASK-11) in R2 alongside resilience, defer VNC (TASK-8) only if it's truly complex.

---

## Analysis (by priority)

### Critical

**1. Security Vulnerabilities Are Sitting in Production (SEC)**

The roadmap acknowledges:
- VNC unauthenticated + port 5900 exposed
- API server POST endpoints with zero auth

These are currently live. The roadmap schedules fixes for **Week 3**. That's 2-3 weeks of running an unauthenticated VNC server on an internet-facing port.

**Risk:** Anyone who discovers the droplet's IP can connect to VNC and control the desktop. They can see the agent's screen, read Discord messages, access credentials displayed in browser windows, etc. This is a P0 security incident waiting to happen.

**Recommendation:**
- **TASK-8 (VNC auth) → Move to R1** as a blocking release criteria, OR
- **Immediately firewall port 5900** as a stopgap until the real fix lands (add as TASK-0)
- **TASK-9 (API auth) → Move to R2** at minimum

The resilience work in R2 is important but won't matter if the system gets compromised.

---

### High

**2. R4 Has Two Large Tasks — High Risk (EL)**

R4 contains:
- TASK-12 (L): Rewrite `build-full-config.sh` in Python
- TASK-13 (L): Reduce YAML to ~15KB

Both are major refactors. Doing both in the same release means:
- Higher chance of regression (two big changes at once)
- Harder to isolate bugs if something breaks
- If either slips, the whole release slips

**Recommendation:**
- Split: Python rewrite in R4, YAML reduction in R5
- OR: Accept that R4 is a "big bet" release with extended timeline (2 weeks instead of 1)
- Ensure R4 has a clear rollback plan to the bash version

**3. No PRD Traceability (PM)**

The PRD v5.0 defines goals (G1-G6) and specific requirements (R2.1, R4.7.1, etc.). The roadmap doesn't show which tasks address which requirements.

Without traceability:
- Can't verify the roadmap covers all PRD requirements
- Can't identify if anything is missing
- Hard to explain to stakeholders why a task matters

**Recommendation:** Add a "Traces to:" field in each task description:
```
| TASK-4 | M | Fix rclone sync → rclone copy | Traces to: G1, R4.5 |
```

Also add a coverage check at the end: "PRD Requirements Not Yet Scheduled: [list]"

**4. No Dependency Graph (EL)**

Some tasks have implicit dependencies:
- TASK-7 (sprint-state.json) should probably come before R5's standup generator (TASK-15)
- TASK-12 (Python rewrite) may block TASK-13 (YAML reduction) or vice versa

The flat task list doesn't show these relationships.

**Recommendation:** Add a "Depends On:" field per task, or include a simple dependency diagram per release.

---

### Medium

**5. Complexity Estimates Need Calibration (EL)**

S/M/L is useful for rough planning but:
- What's "S" in hours/days? What's "L"?
- Is the team (5 Sonnet workers + 1 EL) calibrated on these estimates?
- No mention of buffer time for unexpected issues

**Recommendation:**
- Define S=1 day, M=2-3 days, L=5+ days (or similar)
- Add 20% buffer to each release timeline
- After R1, do a quick retro on estimate accuracy

**6. "Should-Fix" vs "Must-Fix" Boundary Is Unclear (PM)**

R1 includes TASK-3 (JSON validation) which is listed as "Should-Fix" in the Known Issues section, but it's bundled with Must-Fix items.

Is JSON validation blocking? If not, could it slip to R2 if R1 is time-constrained?

**Recommendation:** Explicitly mark each task as Must/Should/Could for the release. Makes prioritization decisions easier when time is tight.

**7. Open Question 4 (Grok) Is Off-Topic (PM)**

"Should we add Grok to the council?" is a valid organizational question but doesn't belong in a release roadmap review. It's about team composition, not feature prioritization.

**Recommendation:** Remove from this document; address separately in a council configuration discussion.

---

### Low / Observations

**8. R5 Scope May Be Too Thin**

R5 has only 3 tasks, and one (TASK-17, iOS Shortcuts) is user-facing while the others (TASK-15, TASK-16) are internal tooling. Consider whether R5 should be expanded to include:
- CI/CD enhancements (the workflow doc called for GitHub Actions integration)
- Monitoring/alerting improvements
- Any deferred PRD requirements

**9. Exit Criteria Are Good But Could Be More Specific**

R1's exit criteria: "Both platforms work with same codebase"

Better: "Habitat creation succeeds on both Discord and Telegram platforms within 3 minutes, verified by automated test."

**10. Weekly Timeline May Be Aggressive**

5 releases in 5 weeks assumes everything goes smoothly. Given R4 is marked "High risk" and R3 involves security work, consider:
- R1-R2: Week 1-2 (lower risk)
- R3: Week 3 (security — needs careful testing)
- R4: Week 4-5 (major refactor — needs buffer)
- R5: Week 6 (tooling)

---

## Considerations

### Trade-offs
- **Speed vs Security (current roadmap):** Prioritizes stability (R1-R2) over security (R3). I'd reverse this — security issues are actively exploitable, stability issues are annoying but not catastrophic.
- **Big-bang refactor (R4) vs incremental:** The Python rewrite is cleaner but riskier. Incremental bash fixes would be safer but perpetuate tech debt. I lean toward the rewrite but in isolation.

### Alternatives
- **R1.5 "Security Stopgap":** Firewall VNC + add basic API auth immediately (S complexity each), then do proper security hardening in R3.
- **Merge R2+R3:** Do resilience and security together in a 2-week release. Reduces context-switching.

### Risks
- **R4 regression:** A full rewrite of the config builder could break things that currently work. Need comprehensive test suite before starting.
- **Scope creep in R5:** "Product Org Tooling" is vague. Could expand indefinitely. Define clear boundaries.

---

## Open Questions

1. **What's the current firewall state on port 5900?** If it's open to 0.0.0.0, this is a live vulnerability.
2. **Is there a test suite for the current bash config builder?** If not, TASK-12 needs a "write tests for existing behavior" subtask first.
3. **Who owns R5 requirements?** The Product Org Tooling tasks seem designed for the Judge's workflow — does the human have additional requirements?
4. **Are we tracking PRD requirement coverage somewhere?** If not, we risk shipping R5 and realizing we missed G4 or G6.

---

## Responses to Judge's Open Questions

**1. Should security (R3) come before resilience (R2)?**
Yes, partially. Critical security (VNC auth, API auth) should be R1.5 or early R2. The full security hardening (audit, scanning) can stay R3.

**2. Is the Python rewrite worth it?**
Yes, but with caveats:
- Only if current tests exist or are written first
- Should be isolated in its own release
- Needs a rollback plan

**3. What other tooling does the Product Org need day-1?**
From the workflow doc, I'd add:
- Automated test result posting to #test-results (webhook)
- Sprint state persistence (already TASK-7 — good)
- Weekly usage digest generator

**4. Grok seat?**
Out of scope for this review. But if asked: yes, add Grok for adversarial/security perspective. The $20/mo cost is worth it for security gates.

---

## DISSENT: Security priority

The roadmap places security in R3 (Week 3). I dissent on this ordering.

**My position:** VNC unauthenticated on an exposed port is a critical vulnerability that should block R1 or be addressed as a P0 stopgap immediately.

**Evidence:** Port 5900 exposed + no VNC auth = anyone with the IP can control the desktop. This includes reading credentials, Discord messages, and potentially the agent's memory files.

**Recommendation:** Either move TASK-8 to R1, or add TASK-0: "Firewall port 5900 to localhost-only" as a 15-minute stopgap in R1.

---

## QUESTION for Judge: 

Do we have confirmation that port 5900 is firewalled or exposed? If exposed, I recommend we pause this review and fix it now before continuing with roadmap planning.
