#!/bin/bash
# =============================================================================
# verify-2a.sh — Mixed Mode Verification (session + container on same droplet)
# Run on bot2.frysinger.org after Stage 11
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; WARN=0
pass() { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }
warn() { echo "  ⚠️  $1"; ((WARN++)); }

echo "═══════════════════════════════════════════════════"
echo "  Test 2A: Mixed Mode (Session + Container)"
echo "  Host: $(hostname)"
echo "  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════════════"
echo

MANIFEST="/etc/openclaw-groups.json"

# --- 1. Stage & Readiness ---
echo "▸ Stage & Readiness"
STAGE=$(curl -sf localhost:8080/status 2>/dev/null | jq -r '.stage // "unreachable"')
if [ "$STAGE" = "11" ]; then
  pass "Stage 11 (READY)"
else
  fail "Stage is $STAGE, expected 11"
fi

# --- 2. Docker Installed ---
echo
echo "▸ Docker Installation"
if command -v docker &>/dev/null; then
  pass "Docker installed"
  DOCKER_VER=$(docker --version)
  echo "       $DOCKER_VER"
else
  fail "Docker not installed — install-docker.sh didn't run"
fi

if docker info &>/dev/null; then
  pass "Docker daemon running"
else
  fail "Docker daemon not responding"
fi

# Log rotation
if [ -f /etc/docker/daemon.json ]; then
  MAX_SIZE=$(jq -r '.["log-opts"]["max-size"] // "missing"' /etc/docker/daemon.json)
  if [ "$MAX_SIZE" = "50m" ]; then
    pass "Docker log rotation configured (50m)"
  else
    warn "Docker log rotation: max-size=$MAX_SIZE (expected 50m)"
  fi
else
  fail "Docker daemon.json missing"
fi

# --- 3. Manifest ---
echo
echo "▸ Runtime Manifest"
if [ -f "$MANIFEST" ]; then
  pass "Manifest exists"
  echo "       $(jq -c '.groups | to_entries[] | {name: .key, iso: .value.isolation, port: .value.port}' "$MANIFEST")"

  # Check mixed types
  SESSION_COUNT=$(jq '[.groups[] | select(.isolation == "session")] | length' "$MANIFEST")
  CONTAINER_COUNT=$(jq '[.groups[] | select(.isolation == "container")] | length' "$MANIFEST")
  if [ "$SESSION_COUNT" -ge 1 ] && [ "$CONTAINER_COUNT" -ge 1 ]; then
    pass "Mixed mode: ${SESSION_COUNT} session + ${CONTAINER_COUNT} container group(s)"
  else
    fail "Expected mixed mode, got ${SESSION_COUNT} session + ${CONTAINER_COUNT} container"
  fi

  # Unique ports
  PORT_COUNT=$(jq '[.groups[].port] | unique | length' "$MANIFEST")
  TOTAL_PORTS=$(jq '[.groups[].port] | length' "$MANIFEST")
  if [ "$PORT_COUNT" = "$TOTAL_PORTS" ]; then
    pass "All ports unique (no collisions)"
  else
    fail "Port collision detected!"
  fi
else
  fail "Manifest missing"
fi

# --- 4. Session Group ---
echo
echo "▸ Session Group (session-group)"
SVC="openclaw-session-group"
if systemctl is-active --quiet "$SVC" 2>/dev/null; then
  pass "$SVC is active"
else
  fail "$SVC is not active"
fi

S_PORT=$(jq -r '.groups["session-group"].port' "$MANIFEST" 2>/dev/null)
if curl -sf "http://127.0.0.1:${S_PORT}/" &>/dev/null; then
  pass "HTTP health check passes (port ${S_PORT})"
else
  fail "HTTP health check fails (port ${S_PORT})"
fi

# --- 5. Container Group ---
echo
echo "▸ Container Group (container-group)"
CSVC="openclaw-container-container-group"
if systemctl is-active --quiet "$CSVC" 2>/dev/null; then
  pass "$CSVC systemd wrapper is active"
else
  fail "$CSVC systemd wrapper is not active"
fi

# Container health
CONTAINER_NAME="openclaw-container-group"
HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not-found")
if [ "$HEALTH" = "healthy" ]; then
  pass "Container '$CONTAINER_NAME' is healthy"
else
  fail "Container health: $HEALTH (expected healthy)"
fi

C_PORT=$(jq -r '.groups["container-group"].port' "$MANIFEST" 2>/dev/null)
if curl -sf "http://127.0.0.1:${C_PORT}/" &>/dev/null; then
  pass "HTTP health check passes (port ${C_PORT})"
else
  fail "HTTP health check fails (port ${C_PORT})"
fi

# --- 6. Container Mounts (Option A validation) ---
echo
echo "▸ Container Mounts (Option A — no host scripts)"
MOUNTS=$(docker inspect "$CONTAINER_NAME" --format='{{range .Mounts}}{{.Source}}{{println}}{{end}}' 2>/dev/null)
if echo "$MOUNTS" | grep -q '/usr/local/'; then
  fail "Host scripts mounted in container (Option B leak!)"
  echo "       Offending mounts:"
  echo "$MOUNTS" | grep '/usr/local/' | sed 's/^/         /'
else
  pass "No host scripts mounted (Option A correct)"
fi

if echo "$MOUNTS" | grep -q '/var/lib/init-status'; then
  fail "Marker dir mounted in container"
else
  pass "No marker dir mounted"
fi

if echo "$MOUNTS" | grep -q '/etc/droplet.env\|/etc/habitat-parsed.env'; then
  fail "Host secrets mounted in container"
else
  pass "No host secrets mounted"
fi

# Read-only mounts
RO_MOUNTS=$(docker inspect "$CONTAINER_NAME" --format='{{range .Mounts}}{{.Source}} {{.Mode}}{{println}}{{end}}' 2>/dev/null)
if echo "$RO_MOUNTS" | grep 'openclaw.session.json' | grep -q 'ro'; then
  pass "Config mounted read-only"
else
  warn "Config mount mode unclear (check manually)"
fi

# --- 7. Security Hardening ---
echo
echo "▸ Security Hardening"
CAP_DROP=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.CapDrop}}' 2>/dev/null)
if echo "$CAP_DROP" | grep -qi 'ALL'; then
  pass "cap_drop: ALL"
else
  fail "cap_drop not set to ALL: $CAP_DROP"
fi

SEC_OPT=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.SecurityOpt}}' 2>/dev/null)
if echo "$SEC_OPT" | grep -q 'no-new-privileges'; then
  pass "no-new-privileges enabled"
else
  fail "no-new-privileges not set"
fi

READ_ONLY=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null)
if [ "$READ_ONLY" = "true" ]; then
  pass "Read-only root filesystem"
else
  fail "Root filesystem not read-only"
fi

PIDS=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.PidsLimit}}' 2>/dev/null)
if [ "$PIDS" = "256" ]; then
  pass "pids_limit: 256"
else
  warn "pids_limit: $PIDS (expected 256)"
fi

# --- 8. Resource Limits ---
echo
echo "▸ Resource Limits"
MEM_LIMIT=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.Memory}}' 2>/dev/null)
# 1g = 1073741824 bytes
if [ "$MEM_LIMIT" = "1073741824" ]; then
  pass "Memory limit: 1g"
elif [ "$MEM_LIMIT" -gt 0 ] 2>/dev/null; then
  warn "Memory limit: $((MEM_LIMIT / 1024 / 1024))MB (expected 1024MB)"
else
  fail "No memory limit set"
fi

CPU_QUOTA=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.NanoCpus}}' 2>/dev/null)
# 1.0 cpu = 1000000000 nanocpus
if [ "$CPU_QUOTA" = "1000000000" ]; then
  pass "CPU limit: 1.0"
elif [ "$CPU_QUOTA" -gt 0 ] 2>/dev/null; then
  warn "CPU limit: $(echo "scale=2; $CPU_QUOTA / 1000000000" | bc) (expected 1.0)"
else
  fail "No CPU limit set"
fi

# --- 9. Container UID ---
echo
echo "▸ Container User"
CONTAINER_UID=$(docker exec "$CONTAINER_NAME" id -u 2>/dev/null)
HOST_UID=$(id -u bot 2>/dev/null || echo "unknown")
if [ "$CONTAINER_UID" = "$HOST_UID" ]; then
  pass "Container UID ($CONTAINER_UID) matches host bot UID"
else
  warn "Container UID=$CONTAINER_UID, host bot UID=$HOST_UID"
fi

# --- 10. Safeguard Units (ALL groups) ---
echo
echo "▸ Safeguard & E2E Units"
for group in session-group container-group; do
  if systemctl is-enabled --quiet "openclaw-safeguard-${group}.path" 2>/dev/null; then
    pass "openclaw-safeguard-${group}.path enabled"
  else
    fail "openclaw-safeguard-${group}.path not enabled"
  fi

  if [ -f "/etc/systemd/system/openclaw-e2e-${group}.service" ]; then
    pass "openclaw-e2e-${group}.service exists"
  else
    fail "openclaw-e2e-${group}.service missing"
  fi
done

# --- 11. Cross-Mode Isolation ---
echo
echo "▸ Cross-Mode Isolation"
echo "  (Restart container group, verify session group unaffected)"
# Just verify both are independently reachable — manual restart test is in the checklist
if curl -sf "http://127.0.0.1:${S_PORT}/" &>/dev/null && curl -sf "http://127.0.0.1:${C_PORT}/" &>/dev/null; then
  pass "Both groups independently reachable on different ports"
else
  fail "One or both groups unreachable"
fi

# --- 12. No Safe Mode ---
echo
echo "▸ No Safe Mode Markers"
SM_COUNT=$(ls /var/lib/init-status/safe-mode-* 2>/dev/null | wc -l)
if [ "$SM_COUNT" = "0" ]; then
  pass "No safe mode markers"
else
  fail "$SM_COUNT safe mode marker(s) found"
fi

# --- 13. Graceful Shutdown Timing ---
echo
echo "▸ Graceful Shutdown (container)"
echo "  Timing docker compose down..."
COMPOSE_PATH=$(jq -r '.groups["container-group"].composePath' "$MANIFEST")
START_TIME=$(date +%s%N)
docker compose -f "$COMPOSE_PATH" -p "openclaw-container-group" down 2>/dev/null
END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
if [ "$DURATION_MS" -lt 10000 ]; then
  pass "Graceful shutdown in ${DURATION_MS}ms (< 10s)"
else
  warn "Shutdown took ${DURATION_MS}ms (≥ 10s — may hit SIGKILL)"
fi

echo "  Restarting container group..."
docker compose -f "$COMPOSE_PATH" -p "openclaw-container-group" up -d --wait 2>/dev/null
sleep 5
HEALTH_AFTER=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not-found")
if [ "$HEALTH_AFTER" = "healthy" ]; then
  pass "Container recovered after restart"
else
  warn "Container health after restart: $HEALTH_AFTER (may need more time for start_period)"
fi

# --- Summary ---
echo
echo "═══════════════════════════════════════════════════"
echo "  Results: ✅ $PASS passed  ❌ $FAIL failed  ⚠️  $WARN warnings"
echo "═══════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && echo "  🎉 TEST 2A PASSED" || echo "  💥 TEST 2A FAILED"
exit "$FAIL"
