# Pre-Merge Test Runbook: Docker Isolation

Branch: `feature/docker-isolation`
Date: 2026-03-04 (updated: safeguard re-arm + failure notification)

## Overview

Three droplet provisions, run in order. If 2B fails, stop — session regression is a blocker.

| Test | Habitat | Domain | Isolation | Duration | Purpose |
|------|---------|--------|-----------|----------|---------|
| **2B** | `test-2b-session-regression.json` | `bot1.frysinger.org` | session-only | 60 min | Regression: session mode unbroken |
| **2A** | `test-2a-container-mixed.json` | `bot2.frysinger.org` | mixed (session+container) | 90 min | Primary: both modes coexist |
| **2C** | `test-2c-container-safemode.json` | `bot3.frysinger.org` | container | 90 min | Adversarial: safe mode in containers |

---

## Test 2B: Session Regression (FIRST — blocker)

**Habitat:** `test-2b-session-regression.json` → `bot1.frysinger.org`
**Goal:** Prove session isolation works identically to pre-docker-isolation branch.

### Verification Script
```bash
SSH="ssh bot@bot1.frysinger.org"

# 1. Boot status
$SSH "curl -s localhost:8080/status | jq '{stage, ready, mode}'"
# Expect: stage=11, ready=true

# 2. Both session services active
$SSH "systemctl is-active openclaw-group-a openclaw-group-b"
# Expect: active / active

# 3. Docker NOT installed
$SSH "which docker 2>/dev/null && echo 'FAIL: Docker should not be installed' || echo 'PASS: No Docker'"

# 4. No container systemd units
$SSH "ls /etc/systemd/system/openclaw-container-* 2>/dev/null && echo 'FAIL' || echo 'PASS: No container units'"

# 5. Manifest valid
$SSH "jq '.groups | to_entries[] | \"\(.key): \(.value.isolation) port=\(.value.port)\"' /etc/openclaw-groups.json"
# Expect: group-a: session port=18790, group-b: session port=18791

# 6. Safeguard .path units active (re-arm fix: 2026-03-04)
$SSH "systemctl is-active openclaw-safeguard-group-a.path openclaw-safeguard-group-b.path"
# Expect: active / active (NOT inactive/dead)

# 7. Handler has EXIT trap for re-arming
$SSH "grep -c '_handler_exit' /usr/local/bin/safe-mode-handler.sh"
# Expect: >= 2 (function def + trap registration)

# 8. Health check has belt-and-suspenders re-arm
$SSH "grep -c 'openclaw-safeguard' /usr/local/bin/gateway-health-check.sh"
# Expect: >= 1

# 9. Bots respond
# → Send a message to each bot on Telegram, verify response
```

### Pass Criteria
- [ ] Stage 11 READY
- [ ] Both services active
- [ ] No Docker installed
- [ ] No container units
- [ ] Manifest correct (session type, unique ports)
- [ ] Safeguard .path active for both groups (not dead)
- [ ] Handler has EXIT trap with re-arm
- [ ] Health check has safeguard re-arm on success
- [ ] Both bots respond on Telegram

---

## Test 2A: Container Mixed Mode (PRIMARY)

**Habitat:** `test-2a-container-mixed.json` → `bot2.frysinger.org`
**Goal:** Session group + container group coexist on same droplet.

### Verification Script
```bash
SSH="ssh bot@bot2.frysinger.org"

# 1. Boot status
$SSH "curl -s localhost:8080/status | jq '{stage, ready}'"
# Expect: stage=11, ready=true

# 2. Manifest: mixed isolation types
$SSH "jq '.groups | to_entries[] | \"\(.key): \(.value.isolation) port=\(.value.port)\"' /etc/openclaw-groups.json"
# Expect: container-grp: container, session-grp: session — different ports

# 3. Session service active
$SSH "systemctl is-active openclaw-session-grp"
# Expect: active

# 4. Container healthy
$SSH "docker inspect openclaw-container-grp --format='{{.State.Health.Status}}'"
# Expect: healthy

# 5. Container mounts — NO host scripts
$SSH "docker inspect openclaw-container-grp --format='{{range .Mounts}}{{.Source}} → {{.Destination}} ({{.Mode}}){{println}}{{end}}'"
# Expect: only openclaw config (ro), token (ro), state (rw), workspaces (rw), shared (rw)
# Must NOT see: /usr/local/bin, /usr/local/sbin, /etc/droplet.env, /var/lib, /var/log

# 6. Config and token are read-only
$SSH "docker inspect openclaw-container-grp --format='{{range .Mounts}}{{if eq .Mode \"ro\"}}RO: {{.Destination}}{{println}}{{end}}{{end}}'"
# Expect: openclaw.json and gateway-token.txt are RO

# 7. Security hardening
$SSH "docker inspect openclaw-container-grp --format='CapDrop={{.HostConfig.CapDrop}} ReadOnly={{.HostConfig.ReadonlyRootfs}} SecurityOpt={{.HostConfig.SecurityOpt}}'"
# Expect: CapDrop=[ALL] ReadOnly=true SecurityOpt=[no-new-privileges]

# 8. Resource limits
$SSH "docker stats --no-stream --format '{{.Name}} MEM={{.MemUsage}} CPU={{.CPUPerc}}' openclaw-container-grp"
# Also: docker inspect openclaw-container-grp --format='MemLimit={{.HostConfig.Memory}} CPUs={{.HostConfig.NanoCpus}}'

# 9. Safeguard .path active for BOTH (re-arm fix: 2026-03-04)
$SSH "systemctl is-active openclaw-safeguard-session-grp.path openclaw-safeguard-container-grp.path"
# Expect: active / active (NOT inactive/dead)

# 10. UID inside container matches host
$SSH "docker exec openclaw-container-grp id"
# Expect: uid=1000(bot)

# 11. Sync timer
$SSH "systemctl is-active clawdbot-sync.timer"
# Expect: active

# 12. Bots respond on Telegram
# → Send message to both bots
```

### Pass Criteria
- [ ] Stage 11 READY
- [ ] Manifest has both isolation types with unique ports
- [ ] Session service active
- [ ] Container healthy (not just running — Health.Status=healthy)
- [ ] No host scripts/state/logs in container mounts
- [ ] Config + token mounts are read-only
- [ ] Security: cap_drop ALL, read_only rootfs, no-new-privileges
- [ ] Resource limits applied
- [ ] Safeguard .path active for BOTH groups (session and container)
- [ ] Container runs as bot UID (matching host)
- [ ] Sync timer active
- [ ] Both bots respond on Telegram

---

## Test 2C: Container Safe Mode (ADVERSARIAL)

**Habitat:** `test-2c-container-safemode.json` → `bot3.frysinger.org`
**Goal:** Verify safe mode triggers and recovers correctly for container groups.

### Phase 1: Deploy healthy
```bash
SSH="ssh bot@bot3.frysinger.org"

# Wait for Stage 11
$SSH "curl -s localhost:8080/status | jq '{stage, ready}'"
# Expect: stage=11, both containers healthy

# Verify both bots respond
```

### Phase 2: Break one group's API keys
```bash
# Edit broken-grp's environment
$SSH "sudo sed -i 's/^ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=BROKEN/' /home/bot/.openclaw/configs/broken-grp/group.env"
$SSH "sudo sed -i 's/^GOOGLE_API_KEY=.*/GOOGLE_API_KEY=BROKEN/' /home/bot/.openclaw/configs/broken-grp/group.env"
$SSH "sudo sed -i 's/^GEMINI_API_KEY=.*/GEMINI_API_KEY=BROKEN/' /home/bot/.openclaw/configs/broken-grp/group.env"

# Restart broken-grp container (picks up new env)
$SSH "sudo docker compose -f /home/bot/.openclaw/compose/broken-grp/docker-compose.yaml -p openclaw-broken-grp down"
$SSH "sudo docker compose -f /home/bot/.openclaw/compose/broken-grp/docker-compose.yaml -p openclaw-broken-grp up -d"

# Wait for E2E check to run and fail (up to 3 minutes)
$SSH "sleep 180 && ls -la /var/lib/init-status/safe-mode-* /var/lib/init-status/unhealthy-* 2>/dev/null"
```

### Phase 3: Verify safe mode + notification
```bash
# 1. Safe mode marker for broken-grp
$SSH "ls /var/lib/init-status/*broken-grp*"
# Expect: safe-mode-broken-grp or unhealthy-broken-grp

# 2. healthy-grp still running
$SSH "docker inspect openclaw-healthy-grp --format='{{.State.Health.Status}}'"
# Expect: healthy

# 3. SafeModeBot notification
# → Check Telegram for safe mode boot report

# 4. Safeguard .path re-armed after handler ran (re-arm fix: 2026-03-04)
$SSH "systemctl is-active openclaw-safeguard-broken-grp.path openclaw-safeguard-healthy-grp.path"
# Expect: active / active (the broken-grp .path must be re-armed, not dead)

# 5. If recovery FAILED: critical notification received
# → Check Telegram/Discord for "🔴 CRITICAL" DM with journal errors + SSH command
# → Verify lockout marker exists:
$SSH "ls /var/lib/init-status/critical-notified-broken-grp 2>/dev/null && echo 'lockout set' || echo 'no lockout'"

# 6. No lockout for healthy-grp (should not have failed)
$SSH "ls /var/lib/init-status/critical-notified-healthy-grp 2>/dev/null && echo 'FAIL: unexpected lockout' || echo 'PASS'"
```

### Phase 4: Test Docker restart recovery
```bash
# Kill gateway inside healthy container — Docker should auto-restart
$SSH "docker exec openclaw-healthy-grp kill 1"
$SSH "sleep 15 && docker inspect openclaw-healthy-grp --format='{{.State.Health.Status}}'"
# Expect: healthy (or starting — check again after 60s)
```

### Phase 5: Test graceful shutdown
```bash
# Time compose down — should be <10s
$SSH "time sudo docker compose -f /home/bot/.openclaw/compose/healthy-grp/docker-compose.yaml -p openclaw-healthy-grp down"
# Expect: real < 10s
```

### Pass Criteria
- [ ] Both containers start healthy
- [ ] Breaking API keys + restart triggers safe mode for broken-grp only
- [ ] healthy-grp remains unaffected
- [ ] SafeModeBot notification received (or critical failure DM with errors)
- [ ] Safeguard .path re-armed for BOTH groups after handler ran (not dead)
- [ ] Critical notification includes actual journal errors (if recovery failed)
- [ ] Lockout marker only for broken-grp (not healthy-grp)
- [ ] Docker auto-restarts after kill (transient failure recovery)
- [ ] Graceful shutdown completes in <10s

---

## After All Three Pass

```bash
# 1. Merge
cd /tmp/hatchery
git checkout feature/state-machine-v2
git merge feature/docker-isolation
git checkout main
git merge feature/state-machine-v2
git push origin main

# 2. Update iOS Shortcut
# Change hatcheryVersion URL from feature/docker-isolation → main

# 3. Tag
git tag v5.0.0  # Major: new isolation backend
git push origin v5.0.0
```
