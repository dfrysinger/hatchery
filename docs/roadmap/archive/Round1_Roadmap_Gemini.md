# Round 1 Report — Gemini (Roadmap)
## Topic: Hatchery Release Roadmap

## Executive Summary
*   **Verdict:** The roadmap is logically sequenced but **underestimates security risks** and **overestimates the value of a rewrite**.
*   **Critical Priority Shift:** **Task 8 (VNC Auth)** and **Task 9 (API Auth)** must be moved to **R1**. We cannot leave open ports while we fiddle with JSON validation.
*   **Strategic Veto:** **R4 (Python Rewrite) should be deferred.** Rewriting the bootstrapper while simultaneously launching a complex multi-agent org is high-risk/low-reward. Fix the bash script, don't replace it yet.
*   **Missing Task:** **Git Identity Management** for workers. 5 agents sharing one git user = chaos.

## Analysis (by priority)

### Critical (Security & Data)
1.  **VNC & API Auth (Task 8, 9) → Move to R1:**
    *   **Risk:** Leaving VNC unauthenticated while we deploy "Product Org Tooling" is negligent.
    *   **Action:** Pull these into R1 or a new R1.5. Security cannot wait for "Week 3".
2.  **Rclone Safety (Task 4) → Keep in R2:**
    *   **Agreed:** Data safety is critical, but an open port is an active vulnerability. R2 placement is fine, provided R1 is fast.

### High (Implementation Realism)
3.  **R4: Python Rewrite → DEFER to R6+:**
    *   **Argument:** The current Bash/YAML setup is brittle but *known*. Introducing a new Python dependency chain during the critical "Product Org" rollout adds unnecessary variables.
    *   **Cost:** Complexity of testing a new bootstrapper is `L` (Large) but the regression risk is `XL`.
    *   **Recommendation:** Patch the Bash script for now. Focus engineering energy on **R5 (Tooling)** which directly enables the new workflow.

### Medium (Product Org)
4.  **Worker Identity (Missing in R5):**
    *   **Gap:** The roadmap ignores how 5 workers will commit code.
    *   **Task:** Add "Configure per-worker Git identities (User/Email)" to R2 or R5. Essential for blame/audit.

## Answers to Open Questions
1.  **Security vs Resilience?** **Security first** (specifically VNC/API). Data safety second.
2.  **Python Rewrite?** **No.** Not yet. It's a "Nice to Have" that masks as a "Must Have".
3.  **R5 Scope?** Needs **Git Identity Management** and **Integration Test Runner** automation.
4.  **Grok Seat?** **No.** The gateway is currently patched for 3 panelists (Claude, ChatGPT, Gemini). Adding a 4th adds integration overhead and cost ($20/mo). Let ChatGPT wear the "Security Hat" for now.

## Amended Roadmap Proposal
*   **R1:** Stability + **Critical Security (VNC/API)**
*   **R2:** Resilience + Data Safety
*   **R3:** Product Org Tooling (Moved up from R5)
*   **R4:** Security Hardening (Remaining items like Audit, Redaction)
*   **R5:** Architecture Modernization (Deferred)
