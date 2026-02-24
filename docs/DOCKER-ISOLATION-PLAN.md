# Docker Container Isolation — Implementation Plan v3

> Original v1 by ClaudeBot (2026-02-21). Reviewed by ChatGPTBot (11 comments).
> v2 by ClaudeBot (2026-02-21) — all review comments addressed.
> v3 by ClaudeBot (2026-02-24) — comprehensive rewrite with full implementation details.

---

## Table of Contents

1. [Architecture Decision](#architecture-decision)
2. [Current State Assessment](#current-state-assessment)
3. [Pre-Implementation Checklist](#pre-implementation-checklist)
4. [Phase 1: Fix Compose Generator](#phase-1-fix-compose-generator)
5. [Phase 2: Dockerfile + Docker Install](#phase-2-dockerfile--docker-install)
6. [Phase 3: Health Check Abstraction](#phase-3-health-check-abstraction)
7. [Phase 4: Port Allocator + First Live Test](#phase-4-port-allocator--first-live-test)
8. [Phase 5: Mixed Mode](#phase-5-mixed-mode)
9. [Phase 6: Network Isolation](#phase-6-network-isolation)
10. [Phase 7: Resource Limits + Security Hardening](#phase-7-resource-limits--security-hardening)
11. [Config Hot-Reload](#config-hot-reload)
12. [Rollback Procedures](#rollback-procedures)
13. [Container Lifecycle Management](#container-lifecycle-management)
14. [Debugging and Incident Triage](#debugging-and-incident-triage)
15. [Open Questions](#open-questions)
16. [Estimate](#estimate)

---

## Architecture Decision

**Host-orchestrated** — containers are runtime boundaries, not autonomous units.

| Concern | Runs on | Why |
|---------|---------|-----|
| Health checks | Host | Reuse `gateway-health-check.sh`, `gateway-e2e-check.sh` unchanged |
| Safe mode detection | Host | `.path` unit watches marker files on host filesystem |
| Safe mode recovery | Host | `safe-mode-handler.sh`, `safe-mode-recovery.sh` stay on host |
| Config generation | Host | `build-full-config.sh` → `generate-docker-compose.sh` |
| State machine | Host | `openclaw-state.sh` operates on host-local state files |
| OpenClaw gateway | Container | Only the runtime process is isolated |
| Agent workspace | Container (rw) | Bind-mounted from host for persistence |

**Why not self-contained (Option B)?** Self-contained containers would need health check scripts, `lib-*.sh`, marker files, and recovery tooling inside each container. This duplicates the entire host infrastructure, creates version drift, and defeats the purpose of isolation (containers would have full access to `/var/lib/init-status`, `/var/log`, etc.). Option A keeps containers thin and the host in control.

**Key adaptation surface:**
- `systemctl restart openclaw-{group}` → `docker compose -p openclaw-{group} restart`
- `systemctl stop openclaw-{group}` → `docker compose -p openclaw-{group} down`
- `journalctl -u openclaw-{group}` → `docker compose -p openclaw-{group} logs`
- `pgrep -f openclaw.gateway` → `docker inspect --format='{{.State.Running}}' openclaw-{group}`

---

## Current State Assessment

### What Exists

| Artifact | Status | Issues |
|----------|--------|--------|
| `generate-docker-compose.sh` | ⚠️ Scaffolded | Built for Option B — mounts scripts, state, logs into containers |
| `test_docker_compose.py` | ✅ 26 tests pass | Tests validate current (wrong) Option B behavior |
| `docs/specs/agent-isolation/` | ✅ Specs exist | `architecture.md` (corrupted), `data-model.md`, `api-contracts.md` |
| `examples/habitat-isolation-container.json` | ✅ Example | Good reference for container habitat config |
| `parse-habitat.py` | ✅ Outputs container vars | `AGENT{N}_ISOLATION`, `AGENT{N}_NETWORK`, `AGENT{N}_RESOURCES_*` |
| `safe-mode-handler.sh` | ⚠️ Partial | Has `docker restart` and `docker inspect` stubs (lines 298-309) |
| `Dockerfile` | ❌ Missing | `hatchery/agent:latest` referenced but never built |
| Docker install in provisioning | ❌ Missing | `provision.sh` doesn't install Docker |
| Container systemd units | ❌ Missing | No `openclaw-container-{group}.service` template |
| Port allocator | ❌ Missing | Session services hardcode `BASE_PORT=18790`, compose hardcodes `18789 + offset` |

### What the Compose Generator Currently Does Wrong

1. **Mounts host scripts into container** — `gateway-health-check.sh`, `safe-mode-recovery.sh`, `setup-safe-mode-workspace.sh`, `lib-permissions.sh` (Option B artifacts)
2. **Mounts host state into container** — `/var/lib/init-status`, `/var/log` (defeats isolation)
3. **Mounts secrets directly** — `/etc/droplet.env`, `/etc/habitat-parsed.env` (over-exposes)
4. **Blocking entrypoint** — Inline bash that runs gateway + health check in same process (should be gateway only; health check on host)
5. **Port assignment** — Local variable, not coordinated with session services
6. **No project naming** — Missing `COMPOSE_PROJECT_NAME`, risks collisions on `docker compose down`

---

## Pre-Implementation Checklist

Complete these before writing any Phase 1 code:

- [ ] **Rollback commands documented** for each phase (see [Rollback Procedures](#rollback-procedures))
- [ ] **`COMPOSE_PROJECT_NAME` convention defined**: `openclaw-{group}` (matches container naming)
- [ ] **File layout defined** for generated artifacts:
  ```
  /home/bot/
  ├── .openclaw/compose/{group}/docker-compose.yaml          # Per-group compose file
  ├── .openclaw/
  │   └── configs/{group}/
  │       ├── openclaw.session.json         # OpenClaw config (same as session mode)
  │       └── auth-profiles.json            # Auth credentials
  └── clawd/
      └── agents/{agent}/                   # Agent workspace (bind-mounted rw)
  ```
- [ ] **Security baseline defined**: `cap_drop: ALL`, `security_opt: no-new-privileges:true`, `read_only: true` with tmpfs for `/tmp`
- [ ] **Port allocator contract**: see [Phase 4](#phase-4-port-allocator--first-live-test)
- [ ] **Health-check timeouts defined**: see [Phase 3](#phase-3-health-check-abstraction)
- [ ] **Phase 1 acceptance gates**: `docker compose config` validates, systemd unit start/stop clean, non-blocking startup

---

## Phase 1: Fix Compose Generator

**Goal:** `generate-docker-compose.sh` produces correct Option A compose files.

### 1.1 Remove Option B Volume Mounts

Delete all script and state mounts. Containers get exactly:

```yaml
volumes:
  # OpenClaw config (generated by host, read by container)
  - ${HOME}/.openclaw/configs/${GROUP}/openclaw.session.json:${HOME}/.openclaw/openclaw.json:ro
  # Auth credentials (per-agent — one mount per agent in the group)
  # Session isolation copies auth-profiles to ${STATE_DIR}/agents/${AGENT}/agent/
  # Container mounts mirror the same layout:
  - ${HOME}/.openclaw/configs/${GROUP}/agents/${AGENT}/agent/auth-profiles.json:${STATE_DIR}/agents/${AGENT}/agent/auth-profiles.json:ro
  # Gateway token (per-group — see Phase 7 for per-group token generation)
  - ${HOME}/.openclaw/configs/${GROUP}/gateway-token.txt:${HOME}/.openclaw/gateway-token.txt:ro
  # Agent workspaces (rw — agents write memory, transcripts, etc.)
  - ${HOME}/clawd/agents/${AGENT}:${HOME}/clawd/agents/${AGENT}:rw
  # Shared workspace (rw — cross-agent collaboration)
  - ${HOME}/clawd/shared:${HOME}/clawd/shared:rw
  # Session state (transcripts, persisted across restarts)
  - ${HOME}/.openclaw-sessions/${GROUP}:${HOME}/.openclaw-sessions/${GROUP}:rw
  # Additional shared paths from habitat config
  # (one entry per ISOLATION_SHARED_PATHS item)
```

Mounts explicitly **removed** (Option B artifacts):
- ~~`/usr/local/bin/gateway-health-check.sh`~~
- ~~`/usr/local/bin/safe-mode-recovery.sh`~~
- ~~`/usr/local/bin/setup-safe-mode-workspace.sh`~~
- ~~`/usr/local/sbin/lib-permissions.sh`~~
- ~~`/etc/droplet.env`~~
- ~~`/etc/habitat-parsed.env`~~
- ~~`/var/lib/init-status`~~
- ~~`/var/log`~~

### 1.2 Fix Entrypoint

Container runs OpenClaw gateway only. No health check, no bash wrapper.
Override CMD (not entrypoint) so compose can pass the per-group port:

```yaml
command: ["--bind", "loopback", "--port", "${GROUP_PORT}"]
```

The Dockerfile `ENTRYPOINT` is `["openclaw", "gateway"]` — compose only overrides `CMD`.

### 1.3 Fix Environment Variables

Container needs API keys passed explicitly (not via `/etc/droplet.env` mount):

```yaml
environment:
  - NODE_ENV=production
  - NODE_OPTIONS=--experimental-sqlite
  - OPENCLAW_CONFIG_PATH=${HOME}/.openclaw/openclaw.json
  - OPENCLAW_STATE_DIR=${HOME}/.openclaw-sessions/${GROUP}
  - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
  - GOOGLE_API_KEY=${GOOGLE_API_KEY}
  - GEMINI_API_KEY=${GOOGLE_API_KEY}
  - BRAVE_API_KEY=${BRAVE_API_KEY}
```

### 1.4 Add Container Metadata

```yaml
container_name: openclaw-${GROUP}
restart: on-failure
user: "${BOT_UID}:${BOT_GID}"
```

### 1.5 Per-Group Compose Files

Generate one compose file per group (not one monolith), in a dedicated directory to avoid filename ambiguity with hyphenated group names:

```
/home/bot/.openclaw/compose/council/docker-compose.yaml
/home/bot/.openclaw/compose/workers/docker-compose.yaml
/home/bot/.openclaw/compose/code-sandbox/docker-compose.yaml
```

This prevents `docker compose down` on one group from affecting another. Each uses `COMPOSE_PROJECT_NAME=openclaw-{group}`. The compose command becomes:

```bash
docker compose -f ~/.openclaw/compose/${group}/docker-compose.yaml -p openclaw-${group} up -d
```

### 1.6 Create Container Systemd Unit Template

Replace the blocking compose-up pattern with a proper systemd unit:

```ini
[Unit]
Description=OpenClaw Container - %i
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/home/${SVC_USER}

# Use per-group compose file with deterministic project name
ExecStart=/usr/bin/docker compose -f .openclaw/compose/%i/docker-compose.yaml -p openclaw-%i up -d --wait
ExecStop=/usr/bin/docker compose -f .openclaw/compose/%i/docker-compose.yaml -p openclaw-%i down
ExecStartPost=+/bin/bash -c 'GROUP=%i GROUP_PORT=${PORT} ISOLATION=container RUN_MODE=execstartpost /usr/local/bin/gateway-health-check.sh'

Restart=on-failure
RestartSec=10
RestartPreventExitStatus=2
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
```

Key differences from session mode unit:
- `Type=oneshot` + `RemainAfterExit=yes` (compose up returns immediately with `-d`)
- `Requires=docker.service` (dependency on Docker daemon)
- `User=root` (Docker socket requires root; container runs as bot via `user:` in compose)
- `ExecStop` runs `docker compose down` (clean container lifecycle)
- `--wait` flag makes `up -d` block until containers are healthy

### Tests to Update

- Rewrite `test_docker_compose.py` to validate Option A behavior:
  - No script mounts
  - No state/log mounts
  - No secret file mounts
  - Config, auth-profiles, gateway-token mounts are ro
  - Workspace mounts are rw
  - Entrypoint is `openclaw gateway` (not bash wrapper)
  - `container_name` follows `openclaw-{group}` convention
  - Environment variables include API keys
  - Per-group compose files generated

### Acceptance Criteria

- [ ] `docker compose -f .openclaw/compose/{group}/docker-compose.yaml config` validates without errors
- [ ] Systemd unit starts cleanly: `systemctl start openclaw-container-{group}`
- [ ] Container starts, gateway binds to port, responds to HTTP health check
- [ ] `systemctl stop` cleanly removes the container
- [ ] No host scripts, state dirs, or log dirs mounted inside container
- [ ] `bash -n generate-docker-compose.sh` passes

### Rollback

```bash
# Revert compose generator
git checkout HEAD~1 -- scripts/generate-docker-compose.sh
# Remove generated compose files
rm -rf /home/bot/.openclaw/compose/
# Remove container systemd units
rm -f /etc/systemd/system/openclaw-container-*.service
systemctl daemon-reload
```

---

## Phase 2: Dockerfile + Docker Install

**Goal:** Build `hatchery/agent:latest` image and add Docker to the provisioning pipeline.

### 2.1 Dockerfile

```dockerfile
# hatchery/agent:latest — Minimal OpenClaw runtime
# Build: docker build --build-arg BOT_UID=$(id -u bot) --build-arg OPENCLAW_VERSION=latest -t hatchery/agent:latest .

ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm-slim

ARG BOT_UID=1000
ARG BOT_GID=${BOT_UID}
ARG OPENCLAW_VERSION=latest

# System dependencies for OpenClaw + healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create bot user matching host UID (for bind mount permissions)
RUN groupadd -g ${BOT_GID} bot 2>/dev/null || true \
    && useradd -u ${BOT_UID} -g ${BOT_GID} -m -s /bin/bash bot

# Install OpenClaw
RUN npm install -g openclaw@${OPENCLAW_VERSION}

# Runtime defaults
USER bot
WORKDIR /home/bot
ENV NODE_ENV=production
ENV NODE_OPTIONS=--experimental-sqlite

# Health check for compose --wait
# Note: GROUP_PORT is a runtime env var (from compose environment:), not a build arg.
# Shell form HEALTHCHECK required for variable expansion.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
    CMD curl -sf http://127.0.0.1:${GROUP_PORT:-18790}/ || exit 1

# Default port overridden by compose command: ["--bind", "loopback", "--port", "${GROUP_PORT}"]
ENTRYPOINT ["openclaw", "gateway"]
CMD ["--bind", "loopback", "--port", "18790"]
```

**Notes:**
- `bookworm-slim` not alpine — OpenClaw has native Node modules that need glibc
- `BOT_UID` build arg ensures container user matches host `bot` user (bind mount perms)
- `OPENCLAW_VERSION` build arg for pinning across deployments
- Browser variant deferred to Phase 7 (`hatchery/agent:full` with Xvfb + Chrome)
- No `DISPLAY` env — headless by default

### 2.2 Docker Install in Provisioning

Add to `provision.sh` (Stage 5: Install tools), gated on `ISOLATION_DEFAULT`:

```bash
# --- Docker (only for container isolation) ---
if [ "$ISOLATION_DEFAULT" = "container" ] || group_needs_container; then
    echo "Installing Docker for container isolation..."
    # Use official apt repo with version pinning (not curl|sh per AGENTS.md rules)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # Add bot user to docker group (allows docker commands without sudo)
    usermod -aG docker "$USERNAME"
    # Enable Docker service
    systemctl enable docker
    systemctl start docker
    
    # Build the base image
    docker build \
        --build-arg BOT_UID="$(id -u "$USERNAME")" \
        --build-arg OPENCLAW_VERSION="$(openclaw --version 2>/dev/null || echo latest)" \
        -t hatchery/agent:latest \
        -f /opt/hatchery/Dockerfile \
        /opt/hatchery/
fi
```

### 2.3 Image Build Verification

```bash
# Verify image
docker run --rm hatchery/agent:latest --version
# Expected: openclaw X.Y.Z
```

### Acceptance Criteria

- [ ] `docker build` succeeds with pinned OpenClaw version
- [ ] Container starts and `openclaw gateway --version` works
- [ ] Image size under 500MB (slim base, no browser)
- [ ] Container runs as `bot` user (UID matches host)
- [ ] Healthcheck passes when gateway is running

### Rollback

```bash
# Remove image
docker rmi hatchery/agent:latest
# Docker itself stays installed (no harm)
```

---

## Phase 3: Health Check Abstraction

**Goal:** Health check scripts work identically for session and container modes.

### 3.1 Service Restart Abstraction

Add to `lib-health-check.sh`:

```bash
# Restart the OpenClaw service for a given group.
# Handles both session mode (systemd) and container mode (docker compose).
hc_restart_service() {
    local group="${1:?Usage: hc_restart_service <group>}"
    local isolation="${ISOLATION:-session}"

    case "$isolation" in
        container)
            docker compose -f "/home/${USERNAME}/.openclaw/compose/${group}/docker-compose.yaml" \
                -p "openclaw-${group}" restart
            ;;
        session|*)
            systemctl restart "openclaw-${group}"
            ;;
    esac
}

# Check if the OpenClaw service for a group is running.
hc_is_service_active() {
    local group="${1:?Usage: hc_is_service_active <group>}"
    local isolation="${ISOLATION:-session}"

    case "$isolation" in
        container)
            docker inspect --format='{{.State.Running}}' "openclaw-${group}" 2>/dev/null | grep -q 'true'
            ;;
        session|*)
            systemctl is-active --quiet "openclaw-${group}"
            ;;
    esac
}

# Get recent logs for a group's service.
hc_service_logs() {
    local group="${1:?Usage: hc_service_logs <group>}"
    local lines="${2:-50}"
    local isolation="${ISOLATION:-session}"

    case "$isolation" in
        container)
            docker compose -f "/home/${USERNAME}/.openclaw/compose/${group}/docker-compose.yaml" \
                -p "openclaw-${group}" logs --tail="$lines" 2>/dev/null
            ;;
        session|*)
            journalctl -u "openclaw-${group}" --no-pager -n "$lines" 2>/dev/null
            ;;
    esac
}

# Stop the service for a group (used during safe mode takeover).
hc_stop_service() {
    local group="${1:?Usage: hc_stop_service <group>}"
    local isolation="${ISOLATION:-session}"

    case "$isolation" in
        container)
            docker compose -f "/home/${USERNAME}/.openclaw/compose/${group}/docker-compose.yaml" \
                -p "openclaw-${group}" down
            ;;
        session|*)
            systemctl stop "openclaw-${group}"
            ;;
    esac
}
```

### 3.2 E2E Health Check for Containers

`gateway-e2e-check.sh` needs to reach the gateway inside the container. Since containers use `network_mode: host` by default, the gateway is reachable at `localhost:${GROUP_PORT}` — no change needed. For `internal`/`none` network modes, E2E check uses `docker exec`:

```bash
# In gateway-e2e-check.sh
if [ "$ISOLATION" = "container" ] && [ "$NETWORK_MODE" != "host" ]; then
    # Can't reach container port from host — exec into container
    response=$(docker exec "openclaw-${GROUP}" \
        curl -sf "http://127.0.0.1:${GROUP_PORT}/api/health" 2>/dev/null)
else
    # Host network or session mode — reach directly
    response=$(curl -sf "http://127.0.0.1:${GROUP_PORT}/api/health" 2>/dev/null)
fi
```

### 3.3 Safe Mode Handler Adaptation

`safe-mode-handler.sh` already has container stubs (lines 298-309). Expand to use the new abstractions:

```bash
# Replace direct docker/systemctl calls with:
hc_stop_service "$GROUP"
# ... recovery logic ...
hc_restart_service "$GROUP"
hc_is_service_active "$GROUP" || handle_failure
```

### 3.4 Health Check Timeouts

| Check | Timeout | Retries | Escalation |
|-------|---------|---------|------------|
| HTTP health (compose `HEALTHCHECK`) | 5s | 3 | Container marked unhealthy |
| HTTP health (`gateway-health-check.sh`) | 10s | 3 | Marks gateway unhealthy |
| E2E magic word (`gateway-e2e-check.sh`) | 60s | 1 | Triggers safe mode |
| `docker compose restart` | 30s | — | Systemd RestartSec kicks in |
| `docker compose up --wait` | 180s | — | TimeoutStartSec, then safe mode |

### Acceptance Criteria

- [ ] `hc_restart_service` works for both `ISOLATION=session` and `ISOLATION=container`
- [ ] `hc_is_service_active` returns correct status for both modes
- [ ] `hc_service_logs` returns recent logs for both modes
- [ ] E2E health check passes for container with `network_mode: host`
- [ ] E2E health check passes for container with `internal` network (via `docker exec`)
- [ ] Safe mode handler uses abstraction — no direct `systemctl`/`docker` calls in handler
- [ ] Identical pass/fail semantics: same failure modes trigger same recovery paths regardless of isolation mode

### Rollback

```bash
# Revert lib-health-check.sh
git checkout HEAD~1 -- scripts/lib-health-check.sh
# Health check and safe mode fall back to session-mode-only behavior
```

---

## Phase 4: Port Allocator + First Live Test

**Goal:** Deterministic, collision-free port assignment across all group types.

### 4.1 Port Allocation Contract

**Algorithm:**
1. Collect all isolation groups (session + container) from `ISOLATION_GROUPS`
2. Sort alphabetically for deterministic ordering
3. Assign ports starting at `BASE_PORT=18790` (18789 reserved for non-isolated default)
4. Same input → same ports (idempotent)
5. Port map written to `/etc/openclaw-ports.env` as source of truth

```bash
# /etc/openclaw-ports.env (generated by build-full-config.sh)
# Source of truth for port assignments across all isolation modes.
# Regenerated on every config build. Same input = same output.
OPENCLAW_PORT_council=18790
OPENCLAW_PORT_workers=18791
OPENCLAW_PORT_sandbox=18792
```

**Consumers:**
- `generate-session-services.sh` reads `OPENCLAW_PORT_{group}` instead of computing `BASE_PORT + offset`
- `generate-docker-compose.sh` reads `OPENCLAW_PORT_{group}` instead of computing `18789 + offset`
- Both generators are now stateless — port allocation is centralized

### 4.2 Port Allocator Implementation

Add to `build-full-config.sh`:

```bash
# --- Global port assignment ---
# Sort groups alphabetically for deterministic assignment.
# BASE_PORT=18790 (18789 reserved for non-isolated single-instance mode).
allocate_ports() {
    local base_port=18790
    local port_file="/etc/openclaw-ports.env"
    local groups_sorted
    
    # Sort groups alphabetically
    IFS=',' read -ra groups_array <<< "$ISOLATION_GROUPS"
    groups_sorted=($(printf '%s\n' "${groups_array[@]}" | sort))
    
    # Write port map
    echo "# Generated by build-full-config.sh — do not edit" > "$port_file"
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$port_file"
    
    local offset=0
    for group in "${groups_sorted[@]}"; do
        local port=$((base_port + offset))
        echo "OPENCLAW_PORT_${group}=${port}" >> "$port_file"
        offset=$((offset + 1))
    done
    
    chmod 644 "$port_file"
}
```

### 4.3 First Live Droplet Test

**Test habitat:** Use existing `habitat-isolation-container.json` example with real tokens.

**Test sequence:**
1. Provision fresh droplet with Docker + container isolation habitat
2. Verify: `docker compose config` validates for each group
3. Verify: `systemctl start openclaw-container-{group}` succeeds
4. Verify: Container is running and healthy
5. Verify: HTTP health check passes from host
6. Verify: E2E magic word test passes
7. Verify: `systemctl stop` cleanly removes container
8. Verify: Port assignments are correct and don't collide
9. Verify: No host scripts/state mounted inside container (`docker inspect` mounts check)

### Acceptance Criteria

- [ ] Port allocator produces identical output for identical input
- [ ] No port collisions between session and container groups
- [ ] Port file at `/etc/openclaw-ports.env` is source of truth
- [ ] Both generators read from port file, not compute locally
- [ ] Live test passes all 9 verification steps
- [ ] Repeated `build-full-config.sh` runs don't change ports (idempotent)

### Rollback

```bash
# Revert port allocator
git checkout HEAD~1 -- scripts/build-full-config.sh
# Revert generator changes
git checkout HEAD~1 -- scripts/generate-session-services.sh scripts/generate-docker-compose.sh
# Remove port file
rm -f /etc/openclaw-ports.env
```

---

## Phase 5: Mixed Mode

**Goal:** Session groups (systemd) and container groups (Docker) coexist on the same droplet.

### 5.1 Mixed Mode Filtering

`build-full-config.sh` determines which generator to call per group:

```bash
for group in "${ALL_GROUPS[@]}"; do
    group_isolation=$(get_group_isolation "$group")
    case "$group_isolation" in
        container)
            # Will be handled by generate-docker-compose.sh
            container_groups+=("$group")
            ;;
        session|*)
            # Will be handled by generate-session-services.sh
            session_groups+=("$group")
            ;;
    esac
done

# Generate session services for session groups
if [ ${#session_groups[@]} -gt 0 ]; then
    ISOLATION_GROUPS=$(IFS=','; echo "${session_groups[*]}") \
        generate-session-services.sh
fi

# Generate compose files for container groups
if [ ${#container_groups[@]} -gt 0 ]; then
    ISOLATION_GROUPS=$(IFS=','; echo "${container_groups[*]}") \
        generate-docker-compose.sh
fi
```

### 5.2 Service Naming Convention

| Mode | Service Name | Compose Project |
|------|-------------|-----------------|
| Session | `openclaw-{group}.service` | — |
| Container | `openclaw-container-{group}.service` | `openclaw-{group}` |
| Safe mode (session) | `openclaw-safeguard-{group}.service` | — |
| Safe mode (container) | `openclaw-safeguard-{group}.service` | — |

Safe mode always runs on the host (not in container) — it uses the session-mode systemd pattern regardless of the group's normal isolation mode.

### 5.3 Cross-Mode Restart Safety

Restarting one group must not affect another, regardless of mode:

- Session groups: `systemctl restart openclaw-{group}` (already isolated)
- Container groups: `docker compose -p openclaw-{group} restart` (project name isolation)
- Never use `docker compose down` without `-p` (would match any compose file in cwd)

### Acceptance Criteria

- [ ] Mixed habitat with session + container groups provisions correctly
- [ ] Session group restart doesn't affect container group and vice versa
- [ ] Safe mode for a container group runs on host (not in container)
- [ ] Port assignments don't collide across modes
- [ ] `systemctl list-units "openclaw-*"` shows both session and container units

### Rollback

```bash
# Revert to session-only mode
git checkout HEAD~1 -- scripts/build-full-config.sh
# Stop and remove container services
for f in /etc/systemd/system/openclaw-container-*.service; do
    systemctl stop "$(basename "$f" .service)" 2>/dev/null || true
    rm -f "$f"
done
systemctl daemon-reload
# Remove compose files
rm -rf /home/bot/.openclaw/compose/
```

---

## Phase 6: Network Isolation

**Goal:** Three network modes with correct semantics.

### 6.1 Network Mode Definitions

| Mode | Docker Implementation | Egress | LLM API Access | Loopback | Use Case |
|------|----------------------|--------|----------------|----------|----------|
| `host` | `network_mode: host` | Full | Yes | Yes | Default — same as session mode |
| `internal` | Custom bridge, no default route | None | No (unless proxy) | Yes | Code sandbox with shared FS IPC |
| `none` | Custom bridge, iptables egress block | Blocked | No | Yes | Maximum isolation, shared FS only |

**Critical:** `none` is NOT Docker's `network_mode: none` which removes the loopback interface entirely, making the gateway unable to bind. Instead, it's an isolated bridge with iptables rules blocking all egress.

### 6.2 Network Implementation

```yaml
# .openclaw/compose/{group}/docker-compose.yaml

# For host mode:
services:
  council:
    network_mode: host
    # No port mapping needed — gateway binds directly on host

# For internal mode:
services:
  sandbox:
    networks:
      - isolated-sandbox
    ports:
      - "${GROUP_PORT}:${GROUP_PORT}"  # Expose gateway port to host for health checks

networks:
  isolated-sandbox:
    driver: bridge
    internal: true  # No external access

# For none mode:
services:
  lockdown:
    networks:
      - blocked-lockdown
    ports:
      - "${GROUP_PORT}:${GROUP_PORT}"
    dns: []  # No DNS resolution

networks:
  blocked-lockdown:
    driver: bridge
    internal: true
    driver_opts:
      com.docker.network.bridge.enable_ip_masquerade: "false"
```

For `internal` and `none` modes, the gateway port must be explicitly mapped so the host health check can reach it.

### 6.3 DNS Behavior

| Mode | DNS | Reason |
|------|-----|--------|
| `host` | Host DNS | Full network access |
| `internal` | None | Bridge `internal: true` blocks external DNS |
| `none` | None | Explicitly blocked |

### Acceptance Criteria

- [ ] `host` mode: container can reach external APIs
- [ ] `internal` mode: container cannot reach external IPs, loopback works, health check works from host
- [ ] `none` mode: container cannot reach anything external, loopback works, health check works from host
- [ ] All three modes pass E2E health check (gateway responds to magic word)
- [ ] `internal`/`none` agents fail gracefully on LLM calls (return error, don't crash)

### Rollback

```bash
# Revert to host-only networking
# Edit compose files to remove network definitions
# Or regenerate from config
```

---

## Phase 7: Resource Limits + Security Hardening

**Goal:** Enforce resource boundaries and minimize container attack surface.

### 7.1 Resource Limits

From habitat config (`resources.memory`, `resources.cpu`):

```yaml
services:
  sandbox:
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "0.5"
        reservations:
          memory: 256M
          cpus: "0.25"
```

### 7.2 Security Baseline (All Containers)

Applied by default to every container service:

```yaml
services:
  any-group:
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=256M
      - /run:size=64M
    # Workspace mount is rw (agents need to write memory/transcripts)
    # Config/auth mounts are ro
```

**`read_only: true` exceptions:**
- Agent workspace bind mounts are `rw` (agents write `MEMORY.md`, transcripts, etc.)
- Shared workspace is `rw`
- Session state dir is `rw` (transcripts)
- `/tmp` and `/run` as tmpfs

### 7.3 Per-Group Secret Isolation

Each container group gets its own gateway token and auth-profiles:

```bash
# In build-full-config.sh
for group in "${CONTAINER_GROUPS[@]}"; do
    # Generate per-group gateway token (not shared across groups)
    openssl rand -hex 32 > "${CONFIG_DIR}/${group}/gateway-token.txt"
    chmod 600 "${CONFIG_DIR}/${group}/gateway-token.txt"
done
```

File permissions check at container startup (in compose healthcheck or entrypoint wrapper):
```bash
# Verify secret file permissions before starting
[ "$(stat -c %a /home/bot/.openclaw/gateway-token.txt)" = "600" ] || exit 1
```

### 7.4 Browser Variant (Future)

For agents needing browser tools (`hatchery/agent:full`):

```dockerfile
FROM hatchery/agent:latest
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb chromium fonts-liberation \
    && rm -rf /var/lib/apt/lists/*
ENV DISPLAY=:99
# Xvfb started by entrypoint wrapper
```

Deferred — not part of the initial rollout.

### Acceptance Criteria

- [ ] `docker inspect` shows `CapDrop: [ALL]`, `SecurityOpt: [no-new-privileges]`, `ReadonlyRootfs: true`
- [ ] Container cannot write to root filesystem (except bind mounts and tmpfs)
- [ ] Memory limits enforced: container OOM-killed at limit
- [ ] CPU limits enforced: container throttled at limit
- [ ] Each container group has its own gateway token
- [ ] Gateway token file permissions are 600 inside container
- [ ] Resource-constrained container still passes health check under normal load

### Rollback

```bash
# Remove security options from compose files (regenerate without hardening)
# Resource limits can be removed by clearing resources in habitat config
```

---

## Config Hot-Reload

When the host config changes (e.g., agent model update, new auth profile):

```
Host: build-full-config.sh regenerates configs
  → Writes new openclaw.session.json to ~/.openclaw/configs/{group}/
  → For session mode: SIGUSR1 to gateway process (in-place reload)
  → For container mode: docker compose -p openclaw-{group} restart
    → Container stops, restarts with new config (bind-mounted, so already updated)
```

This is the same pattern as session mode — the host is the config authority. Containers are stateless with respect to config.

---

## Rollback Procedures

### Per-Phase Quick Reference

| Phase | Rollback Command | Impact |
|-------|-----------------|--------|
| Phase 1 | `git checkout HEAD~1 -- scripts/generate-docker-compose.sh` | Reverts to Option B scaffolding |
| Phase 2 | `docker rmi hatchery/agent:latest` | Removes image, Docker stays |
| Phase 3 | `git checkout HEAD~1 -- scripts/lib-health-check.sh` | Falls back to session-only health |
| Phase 4 | `rm /etc/openclaw-ports.env` + revert generators | Back to local port computation |
| Phase 5 | Remove `openclaw-container-*.service`, revert `build-full-config.sh` | Session-only mode |
| Phase 6 | Regenerate compose files with `host` network only | All containers on host network |
| Phase 7 | Regenerate compose files without security opts | Containers run without hardening |

### Full Rollback (Container → Session)

```bash
# 1. Stop all container services
for svc in /etc/systemd/system/openclaw-container-*.service; do
    systemctl stop "$(basename "$svc" .service)" 2>/dev/null || true
    systemctl disable "$(basename "$svc" .service)" 2>/dev/null || true
    rm -f "$svc"
done
systemctl daemon-reload

# 2. Remove compose files
rm -rf /home/bot/.openclaw/compose/

# 3. Remove port file
rm -f /etc/openclaw-ports.env

# 4. Convert container groups to session groups in habitat config
# Edit habitat JSON: change isolation: "container" → isolation: "session"

# 5. Regenerate session services
build-full-config.sh

# 6. Start session services
for group in $(echo "$ISOLATION_GROUPS" | tr ',' '\n'); do
    systemctl start "openclaw-${group}"
done
```

---

## Container Lifecycle Management

### Image Updates

```bash
# Rebuild with new OpenClaw version
docker build \
    --build-arg BOT_UID=$(id -u bot) \
    --build-arg OPENCLAW_VERSION=$(openclaw --version) \
    -t hatchery/agent:latest \
    -f /opt/hatchery/Dockerfile \
    /opt/hatchery/

# Rolling restart per group
for group in "${CONTAINER_GROUPS[@]}"; do
    docker compose -f ".openclaw/compose/${group}/docker-compose.yaml" -p "openclaw-${group}" up -d --force-recreate
    sleep 10  # Allow health check to pass before next group
done
```

### Prune Policy

Add to the sync timer or a dedicated cron:

```bash
# Weekly: remove dangling images and stopped containers
docker image prune -f --filter "until=168h"
docker container prune -f --filter "until=168h"
```

### Image Staleness Detection

```bash
# Check image age
image_created=$(docker inspect --format='{{.Created}}' hatchery/agent:latest 2>/dev/null)
# Compare with current OpenClaw version
# Alert if image is >7 days old and OpenClaw has been updated
```

---

## Debugging and Incident Triage

### Quick Diagnostic Commands

```bash
# Container status
docker ps --filter "name=openclaw-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Container logs (last 50 lines)
docker compose -p openclaw-council logs --tail=50

# Container resource usage
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" $(docker ps -q --filter "name=openclaw-")

# Container mounts (verify no Option B artifacts)
docker inspect openclaw-council --format='{{range .Mounts}}{{.Source}} → {{.Destination}} ({{.Mode}}){{println}}{{end}}'

# Container network
docker inspect openclaw-council --format='{{range .NetworkSettings.Networks}}{{.NetworkID}} {{.IPAddress}}{{end}}'

# Health check status
docker inspect openclaw-council --format='{{.State.Health.Status}}'

# Exec into container for debugging
docker exec -it openclaw-council bash

# Port assignments
cat /etc/openclaw-ports.env

# State machine status for a group
openclaw-state.sh status --group council
```

### Log Retention

Docker logs follow the daemon's default log driver. Configure in `/etc/docker/daemon.json`:

```json
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    }
}
```

This gives 150MB of logs per container (3 × 50MB rotation), consistent with the systemd journal retention for session mode.

---

## Open Questions

1. **Shared filesystem race conditions:** Multiple containers writing to `~/clawd/shared/` simultaneously. Session mode has the same risk. Mitigation: OpenClaw's file locking should handle this, but worth a stress test in Phase 5.

2. **Browser in containers:** Deferred to Phase 7 `full` variant. Needs Xvfb + Chrome + significant image size increase. Consider: is it worth the complexity, or should browser agents always run in session mode?

3. **Dropbox sync for container transcripts:** Session state lives at `~/.openclaw-sessions/{group}/` on the host (bind-mounted into container). The sync script fix (commit `c724c76`) already handles this path, so container transcripts will be synced. Verify on first live test.

4. **Safe mode in container context:** When a container group enters safe mode, the safe-mode bot runs on the host (session mode), not in a container. This means safe mode always works even if Docker is broken. Confirm this is the right design.

5. **Multi-host (future):** Docker Swarm or Kubernetes for `droplet` isolation level. Out of scope for v1 but the host-orchestrated architecture is a good foundation — the host just becomes a control plane node.

6. **OpenClaw `exec` tool inside containers:** Agents with `exec` capability run shell commands. In session mode this is on the host. In container mode, commands run inside the container — which is the whole point of isolation, but the container needs the tools the agent expects (git, python, etc.). The base image is minimal. Options: (a) fat image with common tools, (b) per-group image variants, (c) sidecar tool containers. Decide in Phase 2.

7. **Container restart vs recreate:** `docker compose restart` keeps the same container (preserves tmpfs state). `docker compose up --force-recreate` creates a fresh container. For config hot-reload, `restart` is sufficient. For image updates, `up --force-recreate` is required. Document which to use when.

8. **Graceful shutdown:** OpenClaw gateway handles SIGTERM for graceful shutdown. Docker sends SIGTERM then SIGKILL after `stop_grace_period` (default 10s). Verify OpenClaw shuts down within 10s, or increase `stop_grace_period` in compose.

---

## Architecture Review: Single Source of Truth

### Current SSOT Violations (must fix)

The codebase has **6 duplicated concerns** across isolation types that the plan must consolidate:

#### 1. Agent-per-group filtering (duplicated 3×)

The pattern "iterate `AGENT{N}_ISOLATION_GROUP`, match against group name, check `AGENT{N}_ISOLATION`" is implemented independently in:
- `generate-session-services.sh` (lines 85-96)
- `generate-docker-compose.sh` (lines 68-82)
- `generate-docker-compose.sh` again in `get_group_network()`, `get_group_memory()`, `get_group_cpu()`, `get_group_agent_names()` (lines 110-170)

**Fix:** Create `lib-isolation.sh` with shared functions:
```bash
# Get agent IDs belonging to a group
get_group_agents() { local group="$1"; ... }
# Get first network mode for a group
get_group_network() { local group="$1"; ... }
# Get resource limits for a group
get_group_resources() { local group="$1"; ... }
# Filter groups by isolation type
get_groups_by_type() { local type="$1"; ... }  # "session" or "container"
```

Both generators source `lib-isolation.sh` instead of reimplementing filtering.

#### 2. OpenClaw config generation (should be shared, currently session-only)

`generate-session-services.sh` calls `generate-config.sh --mode session` to produce `openclaw.session.json`. `generate-docker-compose.sh` **doesn't generate a config at all** — it just mounts a `./config/${group}` directory and hopes something else fills it.

**Fix:** `build-full-config.sh` generates `openclaw.session.json` for **all** groups regardless of isolation type, before dispatching to mode-specific generators. The container generator simply references the already-generated config. This makes `generate-config.sh --mode session` the single source of truth for per-group configs, used by both modes.

```bash
# In build-full-config.sh — unified config generation
for group in "${ALL_GROUPS[@]}"; do
    generate-config.sh --mode session \
        --group "$group" \
        --agents "$(get_group_agents "$group")" \
        --port "$(get_group_port "$group")" \
        --gateway-token "$(generate_group_token "$group")" \
        > "${CONFIG_BASE}/${group}/openclaw.session.json"
done

# THEN dispatch to mode-specific generators (which only create service definitions)
generate-session-services.sh   # → systemd units only
generate-docker-compose.sh     # → compose files only
```

#### 3. Auth-profiles handling (duplicated 3×)

Auth-profiles are created/managed in three places:
- `build-full-config.sh` creates `agents/main/agent/auth-profiles.json` then symlinks to `agents/agent{N}/agent/`
- `generate-session-services.sh` copies auth-profiles into `${state_dir}/agents/agent{N}/agent/`
- The plan has container mode bind-mounting auth-profiles from `configs/{group}/`

**Fix:** `build-full-config.sh` writes auth-profiles to the canonical location for each group:
```bash
# Single auth-profiles write function
setup_group_auth_profiles() {
    local group="$1"
    local config_dir="${CONFIG_BASE}/${group}"
    # Auth-profiles are per-agent within each group's config dir
    for agent_id in $(get_group_agents "$group"); do
        local auth_dir="${config_dir}/agents/${agent_id}/agent"
        ensure_bot_dir "$auth_dir" 700
        # Symlink to master auth-profiles (single source)
        ln -sf "${HOME_DIR}/.openclaw/agents/main/agent/auth-profiles.json" \
            "${auth_dir}/auth-profiles.json"
    done
}
```

Both session services and container compose reference the same `configs/{group}/` directory. Session mode uses `OPENCLAW_STATE_DIR` pointed at it. Container mode bind-mounts it.

#### 4. Port assignment (duplicated 2×, different base ports)

- `generate-session-services.sh`: `BASE_PORT=18790`, offset by group index within session groups
- `generate-docker-compose.sh`: `18789 + offset` within container groups
- Different base ports, different ordering = guaranteed collision in mixed mode

**Fix:** Already in the plan (Phase 4) — centralized port allocator in `build-full-config.sh` writing `/etc/openclaw-ports.env`. Both generators read from this file. **Neither generator computes ports.** Move this to Phase 0/pre-implementation since it's needed by both generators.

#### 5. Safeguard and E2E unit generation (session-only, needs both)

`generate-session-services.sh` generates 3 units per group:
- `openclaw-{group}.service` (main service)
- `openclaw-safeguard-{group}.path` + `.service` (safe mode watcher)
- `openclaw-e2e-{group}.service` (E2E health check)

Container mode needs the same safeguard and E2E units (they run on the host). Only the main service unit differs between modes.

**Fix:** Extract safeguard/E2E unit generation into shared functions in `lib-isolation.sh`:
```bash
# Generates safeguard .path + .service for any group (mode-agnostic)
generate_safeguard_units() {
    local group="$1" port="$2" isolation="$3" output_dir="$4"
    # .path unit is identical for both modes (watches marker file on host)
    # .service unit passes ISOLATION=$isolation so hc_ functions dispatch correctly
    ...
}

# Generates E2E check service for any group (mode-agnostic)
generate_e2e_unit() {
    local group="$1" port="$2" isolation="$3" output_dir="$4"
    ...
}
```

Both generators call these shared functions. The main service unit is the only mode-specific artifact.

#### 6. Directory structure setup (duplicated 3×)

Directory creation is scattered across:
- `build-full-config.sh` — creates `~/.openclaw/agents/`, `~/clawd/agents/`, `~/clawd/shared/`
- `generate-session-services.sh` — creates `${state_dir}`, `${config_dir}`, per-agent subdirs
- Container mode (planned) — creates compose directories

**Fix:** Centralize in `build-full-config.sh`:
```bash
# Single function creates all directories for a group
setup_group_directories() {
    local group="$1"
    ensure_bot_dir "${CONFIG_BASE}/${group}" 700
    ensure_bot_dir "${STATE_BASE}/${group}" 700
    ensure_bot_dir "${COMPOSE_BASE}/${group}" 755  # Only for container groups
    for agent_id in $(get_group_agents "$group"); do
        ensure_bot_dir "${STATE_BASE}/${group}/agents/${agent_id}/agent" 700
    done
}
```

### Proposed Architecture: Clean Separation

```
build-full-config.sh (orchestrator)
  ├── lib-isolation.sh (shared group/agent/port queries)
  ├── generate-config.sh --mode session (per-group OpenClaw config — used by ALL modes)
  ├── setup_group_directories() (all dirs for all groups)
  ├── setup_group_auth_profiles() (auth for all groups)
  ├── allocate_ports() → /etc/openclaw-ports.env
  │
  ├── generate-session-services.sh (THIN — only generates systemd unit file)
  │   └── calls generate_safeguard_units() from lib-isolation.sh
  │   └── calls generate_e2e_unit() from lib-isolation.sh
  │
  └── generate-docker-compose.sh (THIN — only generates compose file + container systemd unit)
      └── calls generate_safeguard_units() from lib-isolation.sh
      └── calls generate_e2e_unit() from lib-isolation.sh
```

**Impact on plan phases:**
- Phase 1 should create `lib-isolation.sh` first, then refactor both generators to use it
- Port allocator moves from Phase 4 to Phase 1 (dependency)
- Config generation happens in `build-full-config.sh`, not in individual generators
- This makes Phase 3 (health check abstraction) cleaner because `ISOLATION` is always in the environment

### Revised Phase Order

| Phase | Content | Rationale |
|-------|---------|-----------|
| **Phase 1** | `lib-isolation.sh` + port allocator + refactor generators to be thin | Foundation — everything else depends on shared code |
| **Phase 2** | Fix compose generator (Option A mounts, entrypoint, env vars) | Can now reuse `lib-isolation.sh` |
| **Phase 3** | Dockerfile + Docker install | Depends on Phase 2 |
| **Phase 4** | Health check abstraction | Depends on `ISOLATION` being in all units |
| **Phase 5** | First live test | Validates Phases 1-4 |
| **Phase 5.5** | Mixed mode | Already mostly works if Phase 1 is done right |
| **Phase 6** | Network isolation | Independent of other phases after Phase 5 |
| **Phase 7** | Security hardening + resource limits | Polish |

This front-loads the hardest work (shared code, SSOT) and makes subsequent phases straightforward.

---

## Self-Review: Issues Found and Fixed in v3

### Fixed in This Version

1. **Dockerfile HEALTHCHECK uses runtime env var** — `GROUP_PORT` is passed via compose `environment:`, not as a build arg. Shell-form `CMD` is required for variable expansion. Added clarifying comment.

2. **Entrypoint vs CMD confusion** — Original plan had compose overriding `entrypoint`. Corrected: Dockerfile sets `ENTRYPOINT ["openclaw", "gateway"]`, compose overrides only `command` (CMD) with `["--bind", "loopback", "--port", "${GROUP_PORT}"]`.

3. **Auth-profiles mount path wrong** — Plan mounted to `agents/main/agent/auth-profiles.json` but session isolation uses `${STATE_DIR}/agents/${AGENT}/agent/auth-profiles.json`. Container mounts must mirror the session isolation layout, with one auth-profiles per agent in the group.

4. **Missing `exec` tool consideration** — Agents running shell commands inside containers need tools the base image doesn't have (git, python, etc.). Added to Open Questions.

5. **Restart vs recreate semantics** — Config hot-reload section didn't distinguish between `restart` (keep container, reload config via bind mount) and `up --force-recreate` (needed for image updates). Clarified.

6. **Graceful shutdown timing** — Docker's default 10s SIGTERM→SIGKILL may be too aggressive. Added to Open Questions.

### Known Gaps Not Yet Addressed

7. **`ISOLATION` env var for health check functions** — The `hc_restart_service()` abstraction reads `$ISOLATION` but this variable comes from `/etc/habitat-parsed.env`. The systemd ExecStartPost already passes `ISOLATION=container` via `Environment=`. However, the safeguard `.path` unit and E2E check service also need this. Ensure all systemd units that invoke health check functions have `ISOLATION` in their environment.

8. **Per-group compose file naming with hyphens** — ✅ Resolved: using subdirectory convention `~/.openclaw/compose/{group}/docker-compose.yaml` to avoid ambiguity with hyphenated group names.

9. **`get.docker.com` in provisioning** — The plan uses `curl -fsSL https://get.docker.com | sh` which violates the AGENTS.md rule: "Use `curl | bash` without verifying the source and pinning a version." Should pin Docker version or use the apt repository method with version pinning.

10. **Test migration plan** — The existing 26 tests in `test_docker_compose.py` validate Option B behavior. These need to be rewritten, not just updated. The plan says "rewrite" but doesn't specify how to handle the transition period where tests break during Phase 1 implementation. Approach: write new tests first (RED), then fix the generator (GREEN), then delete old tests.

---

## Estimate

| Phase | Effort | Depends On |
|-------|--------|------------|
| Phase 1: Fix Compose Generator | 1 session | — |
| Phase 2: Dockerfile + Docker Install | 1 session | Phase 1 |
| Phase 3: Health Check Abstraction | 1 session | Phase 1 |
| Phase 4: Port Allocator + Live Test | 1 session | Phases 1-3 |
| Phase 5: Mixed Mode | 0.5 session | Phase 4 |
| Phase 6: Network Isolation | 0.5 session | Phase 4 |
| Phase 7: Security Hardening | 0.5 session | Phase 4 |
| **Total** | **5-6 sessions** | |

Live droplet tests at Phases 4, 5, and 7.

---

## Appendix: File Layout Reference

```
/home/bot/
├── .openclaw/
│   ├── compose/{group}/docker-compose.yaml  # Per-group compose file (generated)
├── .openclaw/
│   ├── openclaw.json                         # Default (non-isolated) config
│   ├── gateway-token.txt                     # Default gateway token
│   ├── configs/
│   │   └── {group}/
│   │       ├── openclaw.session.json         # Per-group OpenClaw config
│   │       ├── auth-profiles.json            # Per-group auth credentials
│   │       └── gateway-token.txt             # Per-group gateway token
│   └── agents/
│       └── {agent}/sessions/                 # Default state dir transcripts
├── .openclaw-sessions/
│   └── {group}/                              # Session-isolation state dir
│       └── agents/{agent}/sessions/          # Per-group transcripts
├── clawd/
│   ├── agents/{agent}/                       # Agent workspaces
│   │   ├── AGENTS.md, SOUL.md, etc.
│   │   └── memory/
│   └── shared/                               # Cross-agent shared workspace
├── Dockerfile                                # Agent base image (or in /opt/hatchery/)
/etc/
├── openclaw-ports.env                        # Port allocation source of truth
├── systemd/system/
│   ├── openclaw-{group}.service              # Session mode units
│   ├── openclaw-container-{group}.service    # Container mode units
│   ├── openclaw-safeguard-{group}.path       # Safe mode watcher
│   └── openclaw-safeguard-{group}.service    # Safe mode handler
/var/lib/openclaw/
├── state-{group}.json                        # State machine per group
└── events-{group}.jsonl                      # Event log per group
```
