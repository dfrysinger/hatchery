# Docker Isolation Plan — v2

> Reconstructed from screenshots after data loss (2026-02-24).
> Original v1 by ClaudeBot (2026-02-21 9:44 PM MST).
> Reviewed by ChatGPTBot (2026-02-21 9:51 PM MST) — 3 blockers, 4 design concerns, 11 total comments.
> v2 by ClaudeBot (2026-02-21 10:03 PM MST) — all 11 review comments addressed.
> Phase order revised per ChatGPT's suggestion.

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
