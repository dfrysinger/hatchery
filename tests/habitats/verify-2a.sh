#!/bin/bash
# =============================================================================
# verify-2a.sh — Automated verification for Test 2A (Mixed Mode)
# =============================================================================
# Usage: ./verify-2a.sh [hostname]
# Default hostname: bot2.frysinger.org
# =============================================================================
set -euo pipefail

HOST="${1:-bot2.frysinger.org}"
SSH="sshpass -p 'h31CPqjldx0P*tvqR0DB8vQHM^GWgS' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 bot@${HOST}"
PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }
section() { echo ""; echo "=== $1 ==="; }

echo "============================================"
echo "  Test 2A: Mixed Mode Verification"
echo "  Host: ${HOST}"
echo "============================================"

# --- 1. Boot status ---
section "1. Boot Status"
STATUS=$(eval $SSH 'curl -sf localhost:8080/status' 2>/dev/null) || { fail "API server unreachable"; STATUS="{}"; }
STAGE=$(echo "$STATUS" | jq -r '.stage // "unknown"')
SAFE=$(echo "$STATUS" | jq -r '.safe_mode // "unknown"')
if [ "$STAGE" = "11" ]; then pass "Stage 11 (ready)"; else fail "Stage=$STAGE (expected 11)"; fi
if [ "$SAFE" = "false" ] || [ "$SAFE" = "unknown" ]; then pass "Not in safe mode (safe_mode=$SAFE)"; else fail "safe_mode=$SAFE"; fi

# --- 2. Manifest: mixed isolation ---
section "2. Manifest"
MANIFEST=$(eval $SSH 'cat /etc/openclaw-groups.json 2>/dev/null' 2>/dev/null) || MANIFEST="{}"
TYPES=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | .value.isolation' 2>/dev/null | sort -u)
HAS_SESSION=$(echo "$TYPES" | grep -c "session" || true)
HAS_CONTAINER=$(echo "$TYPES" | grep -c "container" || true)
if [ "$HAS_SESSION" -ge 1 ] && [ "$HAS_CONTAINER" -ge 1 ]; then
  pass "Mixed isolation: session + container"
else
  fail "Not mixed: types=$TYPES"
fi

PORTS=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | .value.port' 2>/dev/null | sort)
UNIQUE_PORTS=$(echo "$PORTS" | sort -u)
if [ "$PORTS" = "$UNIQUE_PORTS" ]; then pass "All ports unique"; else fail "Duplicate ports"; fi

echo "$MANIFEST" | jq -r '.groups | to_entries[] | "    \(.key): \(.value.isolation) port=\(.value.port)"' 2>/dev/null

# --- 3. Session service active ---
section "3. Session Service"
SESSION_GROUP=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | select(.value.isolation == "session") | .key' 2>/dev/null | head -1)
if [ -n "$SESSION_GROUP" ]; then
  SVC_STATUS=$(eval $SSH "systemctl is-active openclaw-${SESSION_GROUP} 2>/dev/null" 2>/dev/null) || SVC_STATUS="unknown"
  if [ "$SVC_STATUS" = "active" ]; then pass "openclaw-${SESSION_GROUP}: active"; else fail "openclaw-${SESSION_GROUP}: $SVC_STATUS"; fi
else
  fail "No session group in manifest"
fi

# --- 4. Container healthy ---
section "4. Container"
CONTAINER_GROUP=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | select(.value.isolation == "container") | .key' 2>/dev/null | head -1)
if [ -n "$CONTAINER_GROUP" ]; then
  HEALTH=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.State.Health.Status}}' 2>/dev/null" 2>/dev/null) || HEALTH="unknown"
  if [ "$HEALTH" = "healthy" ]; then pass "openclaw-${CONTAINER_GROUP}: healthy"; else fail "openclaw-${CONTAINER_GROUP}: $HEALTH"; fi
else
  fail "No container group in manifest"
fi

# --- 5. Container mounts — security check ---
section "5. Container Mounts"
MOUNTS=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} 2>/dev/null | jq -r '.[0].Mounts[] | \"\(.Source)|\(.Destination)|\(.Mode)\"'" 2>/dev/null) || MOUNTS=""

# Check no host scripts leaked
BAD_MOUNTS=$(echo "$MOUNTS" | grep -E "/usr/local/bin|/usr/local/sbin|/etc/droplet|/var/lib/init|/var/log" || true)
if [ -z "$BAD_MOUNTS" ]; then pass "No host scripts/state in container mounts"; else fail "Leaked mounts: $BAD_MOUNTS"; fi

# Check config and token are read-only (pipe-delimited: source|dest|mode)
RO_CONFIG=$(echo "$MOUNTS" | grep "openclaw.json" | grep -c "|ro" || true)
RO_TOKEN=$(echo "$MOUNTS" | grep "gateway-token" | grep -c "|ro" || true)
if [ "$RO_CONFIG" -ge 1 ]; then pass "Config mount is read-only"; else fail "Config mount not read-only"; fi
if [ "$RO_TOKEN" -ge 1 ]; then pass "Token mount is read-only"; else fail "Token mount not read-only"; fi

# --- 6. Security hardening ---
section "6. Container Security"
CAP_DROP=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.CapDrop}}' 2>/dev/null" 2>/dev/null) || CAP_DROP=""
READONLY=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null" 2>/dev/null) || READONLY=""
SEC_OPT=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.SecurityOpt}}' 2>/dev/null" 2>/dev/null) || SEC_OPT=""
PIDS=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.PidsLimit}}' 2>/dev/null" 2>/dev/null) || PIDS=""

if echo "$CAP_DROP" | grep -q "ALL"; then pass "cap_drop: ALL"; else fail "cap_drop: $CAP_DROP"; fi
if [ "$READONLY" = "true" ]; then pass "read_only rootfs"; else fail "read_only=$READONLY"; fi
if echo "$SEC_OPT" | grep -q "no-new-privileges"; then pass "no-new-privileges"; else fail "SecurityOpt=$SEC_OPT"; fi
if [ -n "$PIDS" ] && [ "$PIDS" != "0" ] && [ "$PIDS" != "-1" ]; then pass "pids_limit=$PIDS"; else warn "pids_limit=$PIDS (unbounded)"; fi

# --- 7. Resource limits ---
section "7. Resource Limits"
MEM=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.Memory}}' 2>/dev/null" 2>/dev/null) || MEM=0
CPU=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.NanoCpus}}' 2>/dev/null" 2>/dev/null) || CPU=0
if [ "$MEM" -gt 0 ] 2>/dev/null; then pass "Memory limit: $((MEM / 1048576))MB"; else fail "No memory limit"; fi
if [ "$CPU" -gt 0 ] 2>/dev/null; then pass "CPU limit: $((CPU / 1000000000)) cores"; else warn "No CPU limit"; fi

# --- 8. Restart policy (Docker) ---
section "8. Docker Restart Policy"
RESTART_POLICY=$(eval $SSH "docker inspect openclaw-${CONTAINER_GROUP} --format='{{.HostConfig.RestartPolicy.Name}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}' 2>/dev/null" 2>/dev/null) || RESTART_POLICY=""
if echo "$RESTART_POLICY" | grep -q "on-failure"; then pass "Restart: on-failure"; else fail "Restart: $RESTART_POLICY"; fi
MAX_RETRY=$(echo "$RESTART_POLICY" | cut -d: -f2)
if [ "$MAX_RETRY" -gt 0 ] 2>/dev/null; then pass "Max retries: $MAX_RETRY"; else fail "No retry cap (infinite restarts)"; fi

# --- 9. Restart policy (Systemd) ---
section "9. Systemd Restart Policy"
if [ -n "$SESSION_GROUP" ]; then
  SYS_RESTART=$(eval $SSH "grep 'Restart=' /etc/systemd/system/openclaw-${SESSION_GROUP}.service 2>/dev/null" 2>/dev/null) || SYS_RESTART=""
  SYS_BURST=$(eval $SSH "grep 'StartLimitBurst' /etc/systemd/system/openclaw-${SESSION_GROUP}.service 2>/dev/null" 2>/dev/null) || SYS_BURST=""
  if echo "$SYS_RESTART" | grep -q "on-failure"; then pass "Systemd: Restart=on-failure"; else fail "Systemd: $SYS_RESTART"; fi
  if echo "$SYS_BURST" | grep -q "StartLimitBurst"; then pass "Systemd: $SYS_BURST"; else fail "No StartLimitBurst"; fi
fi

# --- 10. Safeguard watchers ---
section "10. Safeguard Watchers"
SAFEGUARD_PATHS=$(eval $SSH 'systemctl list-units "openclaw-safeguard-*.path" --no-pager --no-legend 2>/dev/null' 2>/dev/null)
SAFEGUARD_ACTIVE=$(echo "$SAFEGUARD_PATHS" | grep -c "active" || true)
if [ "$SAFEGUARD_ACTIVE" -ge 2 ]; then
  pass "$SAFEGUARD_ACTIVE safeguard .path units active"
else
  fail "Only $SAFEGUARD_ACTIVE safeguard .path units active (expected ≥2)"
fi

# --- 11. Safe mode handler ---
section "11. Safe Mode Handler"
STOP_COUNT=$(eval $SSH 'grep -c "hc_stop_service" /usr/local/bin/safe-mode-handler.sh 2>/dev/null' 2>/dev/null) || STOP_COUNT=0
if [ "$STOP_COUNT" -ge 2 ]; then pass "hc_stop_service on terminal paths ($STOP_COUNT)"; else fail "hc_stop_service missing ($STOP_COUNT, need ≥2)"; fi

# --- 12. HTTP endpoints ---
section "12. HTTP Endpoints"
HTTP_PAIRS=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | "\(.key) \(.value.port)"' 2>/dev/null)
while read -r group port; do
  [ -z "$group" ] && continue
  RESP=$(eval $SSH "curl -sf http://localhost:${port}/ >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null)
  if [ "$RESP" = "OK" ]; then pass "$group (port $port): HTTP OK"; else fail "$group (port $port): HTTP FAIL"; fi
done <<< "$HTTP_PAIRS"

# --- 13. Container UID ---
section "13. Container UID"
CUID=$(eval $SSH "docker exec openclaw-${CONTAINER_GROUP} id -u 2>/dev/null" 2>/dev/null) || CUID="unknown"
if [ "$CUID" = "1000" ]; then pass "Container runs as UID 1000 (bot)"; else fail "Container UID=$CUID (expected 1000)"; fi

# --- 14. Intros sent (wait for E2E services to finish first) ---
section "14. Agent Intros"
E2E_WAIT=0
for attempt in $(seq 1 12); do
  E2E_RUNNING=$(eval $SSH 'systemctl list-units "openclaw-e2e-*.service" --no-pager --no-legend 2>/dev/null | grep -c "running\|activating"' 2>/dev/null) || E2E_RUNNING=0
  [ "$E2E_RUNNING" -eq 0 ] && break
  echo "    Waiting for E2E services to finish... (${attempt}/12)"
  sleep 10
  E2E_WAIT=$((E2E_WAIT + 10))
done
[ "$E2E_WAIT" -gt 0 ] && echo "    Waited ${E2E_WAIT}s for E2E completion"
INTRO_MARKERS=$(eval $SSH 'ls /var/lib/init-status/intro-sent-* 2>/dev/null | wc -l' 2>/dev/null) || INTRO_MARKERS=0
if [ "$INTRO_MARKERS" -ge 2 ]; then pass "$INTRO_MARKERS intro markers"; else warn "Only $INTRO_MARKERS intro markers (E2E may still be running)"; fi

# --- 15. No errors ---
section "15. Error Check"
SAFE_MARKERS=$(eval $SSH 'ls /var/lib/init-status/safe-mode-* /var/lib/init-status/gateway-failed-* /var/lib/init-status/critical-notified-* 2>/dev/null | wc -l' 2>/dev/null) || SAFE_MARKERS=0
if [ "$SAFE_MARKERS" = "0" ]; then pass "No failure markers"; else fail "$SAFE_MARKERS failure markers found"; fi

# --- 16. NODE_OPTIONS clean ---
section "16. NODE_OPTIONS Clean"
NODE_OPTS=$(eval $SSH 'grep -r "experimental-sqlite" /etc/systemd/system/openclaw-* 2>/dev/null | wc -l' 2>/dev/null) || NODE_OPTS=0
if [ "$NODE_OPTS" = "0" ]; then pass "No NODE_OPTIONS=--experimental-sqlite"; else fail "Found in $NODE_OPTS files"; fi

# --- 17. kill-droplet.sh uses droplet ID ---
section "17. Self-Destruct"
KILL_BY_ID=$(eval $SSH 'grep -c DROPLET_ID /usr/local/bin/kill-droplet.sh' 2>/dev/null) || KILL_BY_ID=0
if [ "$KILL_BY_ID" -ge 2 ]; then pass "kill-droplet.sh uses droplet ID ($KILL_BY_ID refs)"; else fail "kill-droplet.sh missing droplet ID lookup ($KILL_BY_ID refs)"; fi

# --- Summary ---
echo ""
echo "============================================"
echo "  RESULTS: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 TEST 2A: PASS"
else
  echo "  💥 TEST 2A: FAIL"
fi
exit "$FAIL"
