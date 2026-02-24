# Docker Isolation Plan — v2

> Reconstructed from screenshots after data loss (2026-02-24).
> Original v1 by ClaudeBot (2026-02-21 9:44 PM MST).
> Reviewed by ChatGPTBot (2026-02-21 9:51 PM MST) — 3 blockers, 4 design concerns, 11 total comments.
> v2 by ClaudeBot (2026-02-21 10:03 PM MST) — all 11 review comments addressed.
> Phase order revised per ChatGPT's suggestion.

---

## Must-Fix Before Phase 1 (ChatGPT Quick Checklist)

- [ ] **Rollback steps documented** for each phase (especially Phase 1 and Phase 4) with exact commands.
- [ ] **Deterministic compose project naming** (`COMPOSE_PROJECT_NAME`) defined per group.
- [ ] **Canonical file layout** defined for generated compose/config artifacts (no ambiguous paths).
- [ ] **Container security baseline enabled** by default (`cap_drop: ["ALL"]`, `no-new-privileges`, read-only rootfs where feasible).
- [ ] **Port allocator contract documented** (algorithm + idempotency + persistence source of truth).
- [ ] **Health-check/restart timeouts and retries** specified explicitly (no implicit defaults).
- [ ] **Acceptance gates for Phase 1** added (`docker compose config`, unit start/stop behavior, non-blocking startup).

---

## Architecture Decision: Host-Orchestrated

Health checks and safe mode run on the **host**, not inside containers. Containers are just a runtime boundary. This lets us reuse all the scripts we just merged with minimal adaptation:

- `systemctl restart` → `docker compose restart`
- `journalctl` → `docker logs`
- Health check scripts stay on the host
- Safe mode recovery stays on the host

This is **Option A** (host-orchestrated), not Option B (self-contained containers).

## Current State

- `generate-docker-compose.sh` exists with 26 passing tests
- **No Dockerfile exists** — the compose generator references `hatchery/agent:latest` which was never built
- The existing scaffolding was built for Option B (self-contained) and needs fixing for Option A

---

## Phases (Revised Order)

Phase order revised per ChatGPT review: fix compose generator *first* (it has 3 fundamental issues), then Dockerfile, then Docker install, then global port assignment, then first live test.

### Phase 1: Fix Compose Generation (foundation)

Fix the 3 blockers in `generate-docker-compose.sh`:

1. **Remove Option B volume mounts** — The scaffolding mounts health check scripts, `/var/lib/init-status`, and `/var/log` into containers, which defeats the isolation purpose. Containers should only get:
   - Config (ro)
   - Workspace (rw)
   - Auth-profiles (ro)
   - Gateway-token (ro)
2. **Fix systemd unit** — Current template has blocking `docker compose up` which prevents `ExecStartPost` from ever running. Fix to `Type=oneshot` + `RemainAfterExit=yes` + `up -d`
3. **Remove script mounts** — Health check runs on host, not inside container

### Phase 2: Dockerfile + Docker Install

Create `hatchery/agent:latest` base image:

- Base: Ubuntu 22.04 or Node.js 22 LTS
- Install: OpenClaw, curl, jq, bash, ca-certificates
- `OPENCLAW_VERSION` build arg for version pinning
- `--build-arg BOT_UID=$(id -u bot)` for UID matching
- Browser deferred to Phase 6 `full` variant
- Add Docker install to provisioning pipeline

### Phase 3: Abstract Health Check for Container Mode

- `hc_restart_service()` — abstracts `systemctl restart` vs `docker compose restart`
- `docker exec` for E2E health check (magic word test)
- Health check logic stays on host, reaches into containers

### Phase 4: Global Port Assignment + First Live Test

- Fix port collision: session and container groups both start at 18789
- Global port assignment in `build-full-config.sh` across all group types
- Both generators (session + container) read pre-assigned ports
- **Live droplet test** — validate phases 1-4 work end-to-end

### Phase 5: Mixed Mode

- Session groups via systemd + container groups via Docker on the same droplet
- Mixed isolation filtering (only container groups get compose services)
- Shared filesystem paths work across both modes

### Phase 6: Network Isolation (host/internal/none)

- `host` → `network_mode: host` (default)
- `internal` → custom bridge network, no external access
- `none` → **NOT** Docker's `network_mode: none` (kills loopback, useless). Instead: isolated bridge with no egress. Viable for code sandbox + shared FS IPC

### Phase 7: Resource Limits + Security Hardening

- `resources.memory` → `mem_limit`
- `resources.cpu` → `cpus`
- `restart: on-failure` on all compose services
- Security context restrictions

---

## Config Hot-Reload

Host rewrites config file → `docker compose restart` → container picks up new config on startup. Same pattern as session mode.

---

## Review Fixes Applied (v1 → v2)

### 🔴 Critical Fixes

| # | Issue | Fix |
|---|-------|-----|
| 1 | Blocking `docker compose up` | `Type=oneshot` + `RemainAfterExit=yes` + `up -d` |
| 2 | State/log mounts defeat isolation | Removed. Containers only get config (ro), workspace (rw), auth-profiles (ro), gateway-token (ro) |
| 3 | Script mounts are Option B artifacts | Removed. Health check runs on host, not inside container |

### 🟡 Important Fixes

| # | Issue | Fix |
|---|-------|-----|
| 4 | `network: "none"` isn't viable | Redefined as isolated bridge with no egress (not Docker's `network_mode: none`) |
| 5 | Dockerfile too thin | Added curl, jq, bash, ca-certificates. `OPENCLAW_VERSION` build arg. Browser deferred to Phase 6 `full` variant |
| 6 | Port collision in mixed mode | Global port assignment in `build-full-config.sh` across all group types |
| 7 | Config hot-reload not mentioned | Added section: host rewrites config → `docker compose restart` → new config on startup |

### 🟢 Minor Fixes

| # | Issue | Fix |
|---|-------|-----|
| 8 | `docker-compose` vs `docker compose` | V2 CLI (`docker compose`) everywhere |
| 9 | Bot UID mismatch | Explicit `--build-arg BOT_UID=$(id -u bot)` |
| 10 | No restart policy | `restart: on-failure` on all compose services |
| 11 | Shared FS unclear | Confirmed fine, noted in Open Questions |

---

## Live Droplet Tests

3 tests planned at critical milestones:

| Test | After Phase | Validates |
|------|-------------|-----------|
| Test 1 | Phase 4 | Basic container lifecycle, port assignment, E2E health check |
| Test 2 | Phase 5 | Mixed mode (session + container on same droplet) |
| Test 3 | Phase 7 | Network isolation, resource limits, full production readiness |

---

## Estimate

3-5 focused sessions to complete — much less than the safe mode work since the health check foundation is already solid.

---

## Open Questions

- Shared filesystem: confirmed working, but need to validate cross-mode access patterns
- Browser support in containers: deferred to Phase 6 `full` variant (needs Xvfb + Chrome)
- Log aggregation: containers log to stdout, host collects via `docker logs` — sufficient?

---

## Review Comments (ChatGPT)

Overall: strong, practical plan. Host-orchestrated is the right call for incremental delivery.

### High-priority additions before implementation

1. **Define rollback behavior per phase**
   - For each phase, add: “if validation fails, revert by …”
   - Especially for Phase 1/4 (compose generation + port assignment), include exact rollback commands.

2. **Pin compose project naming + paths**
   - Specify deterministic `COMPOSE_PROJECT_NAME` per isolation group.
   - Define canonical location for per-group compose files and generated configs.
   - Prevent accidental cross-group `docker compose down` collisions.

3. **Security baseline for all containers**
   - Add default hardening:
     - `read_only: true` (except required writable mounts)
     - `cap_drop: ["ALL"]`
     - `security_opt: ["no-new-privileges:true"]`
     - explicit writable tmpfs for `/tmp` if needed
   - This should be baseline in Phase 2/7, not optional.

4. **Port allocation contract**
   - Document the allocator algorithm and persistence source of truth.
   - Ensure idempotent regeneration (same input => same assigned ports unless intentionally reallocated).

5. **Health-check timing and failure semantics**
   - Define concrete timeouts/retry counts for `docker compose restart`, `docker exec` checks, and escalation to safe mode.
   - Avoid implicit defaults.

### Medium-priority design clarifications

6. **Secret handling in container mode**
   - `gateway-token` mount is fine, but add strict file perms check at startup.
   - Prefer per-group tokens over a shared token if not already guaranteed.

7. **Network mode `none` implementation detail**
   - Good call avoiding Docker `network_mode: none`.
   - Add exact mechanism for “isolated bridge + no egress” (iptables/nftables policy + DNS behavior) and test assertions.

8. **Container/image lifecycle policy**
   - Define prune policy, image update cadence, and how stale images are handled safely.

9. **Log retention and debugging**
   - Add retention + rotation guidance for `docker logs` collection path.
   - Include a minimal “incident triage” command set.

### Suggested acceptance criteria (add to phases)

- **Phase 1:** generated compose validates (`docker compose config`), unit file starts/stops cleanly, no blocking start.
- **Phase 3:** health check abstraction proves identical pass/fail semantics vs session mode.
- **Phase 4:** no port collisions across mixed groups after repeated regenerate/restart cycles.
- **Phase 5:** mixed-mode restart of one group does not impact other groups.
- **Phase 6:** `internal/none` modes block egress as designed while preserving required IPC.
- **Phase 7:** resource limits are enforced and observable under stress test.

