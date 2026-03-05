#!/bin/bash
# =============================================================================
# verify-2b.sh — Automated verification for Test 2B (Session Regression)
# =============================================================================
# Usage: ./verify-2b.sh [hostname]
# Default hostname: bot1.frysinger.org
# =============================================================================
set -euo pipefail

HOST="${1:-bot1.frysinger.org}"
SSH="sshpass -p 'h31CPqjldx0P*tvqR0DB8vQHM^GWgS' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 bot@${HOST}"
PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }
section() { echo ""; echo "=== $1 ==="; }

echo "============================================"
echo "  Test 2B: Session Regression Verification"
echo "  Host: ${HOST}"
echo "============================================"

# --- 1. Boot status ---
section "1. Boot Status"
STATUS=$(eval $SSH 'curl -sf localhost:8080/status' 2>/dev/null) || { fail "API server unreachable"; STATUS="{}"; }
STAGE=$(echo "$STATUS" | jq -r '.stage // "unknown"')
SAFE=$(echo "$STATUS" | jq -r '.safe_mode // "unknown"')
READY=$(echo "$STATUS" | jq -r '.ready // "unknown"')
if [ "$STAGE" = "11" ]; then pass "Stage 11 (ready)"; else fail "Stage=$STAGE (expected 11)"; fi
if [ "$SAFE" = "false" ] || [ "$SAFE" = "unknown" ]; then pass "Not in safe mode (safe_mode=$SAFE)"; else fail "safe_mode=$SAFE"; fi

# --- 2. Session services active ---
section "2. Session Services"
ACTIVE_COUNT=$(eval $SSH 'systemctl list-units "openclaw-group-*" --no-pager --no-legend 2>/dev/null | grep -c "running"' 2>/dev/null) || ACTIVE_COUNT=0
if [ "$ACTIVE_COUNT" -ge 2 ]; then
  pass "$ACTIVE_COUNT session services active"
else
  fail "Only $ACTIVE_COUNT session services active (expected ≥2)"
fi

# List actual service names
eval $SSH 'systemctl list-units "openclaw-*" --no-pager --no-legend 2>/dev/null | grep -v safeguard | grep -v sync | grep -v "e2e"' 2>/dev/null | while read -r line; do
  echo "    $line"
done

# --- 3. Docker NOT installed ---
section "3. Docker Absent"
DOCKER=$(eval $SSH 'which docker 2>/dev/null && echo "FOUND" || echo "ABSENT"' 2>/dev/null)
if [ "$DOCKER" = "ABSENT" ]; then pass "Docker not installed"; else fail "Docker found (should not be installed for session-only)"; fi

# --- 4. No container units ---
section "4. No Container Units"
CONTAINER_UNITS=$(eval $SSH 'ls /etc/systemd/system/openclaw-container-*.service 2>/dev/null | wc -l' 2>/dev/null) || CONTAINER_UNITS=0
if [ "$CONTAINER_UNITS" = "0" ]; then pass "No container systemd units"; else fail "$CONTAINER_UNITS container units found"; fi

# --- 5. Manifest valid ---
section "5. Manifest"
MANIFEST=$(eval $SSH 'cat /etc/openclaw-groups.json 2>/dev/null' 2>/dev/null) || MANIFEST="{}"
GROUP_COUNT=$(echo "$MANIFEST" | jq '.groups | length' 2>/dev/null) || GROUP_COUNT=0
if [ "$GROUP_COUNT" -ge 2 ]; then pass "$GROUP_COUNT groups in manifest"; else fail "Only $GROUP_COUNT groups (expected ≥2)"; fi

# Check all groups are session type
ALL_SESSION=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | .value.isolation' 2>/dev/null | sort -u)
if [ "$ALL_SESSION" = "session" ]; then pass "All groups are session type"; else fail "Mixed types: $ALL_SESSION"; fi

# Check unique ports
PORTS=$(echo "$MANIFEST" | jq -r '.groups | to_entries[] | .value.port' 2>/dev/null | sort)
UNIQUE_PORTS=$(echo "$PORTS" | sort -u)
if [ "$PORTS" = "$UNIQUE_PORTS" ]; then pass "All ports unique"; else fail "Duplicate ports detected"; fi

echo "$MANIFEST" | jq -r '.groups | to_entries[] | "    \(.key): \(.value.isolation) port=\(.value.port)"' 2>/dev/null

# --- 6. Safeguard .path units active ---
section "6. Safeguard Watchers"
SAFEGUARD_PATHS=$(eval $SSH 'systemctl list-units "openclaw-safeguard-*.path" --no-pager --no-legend 2>/dev/null' 2>/dev/null)
SAFEGUARD_ACTIVE=$(echo "$SAFEGUARD_PATHS" | grep -c "active" || true)
SAFEGUARD_TOTAL=$(echo "$SAFEGUARD_PATHS" | grep -c "openclaw-safeguard" || true)
if [ "$SAFEGUARD_ACTIVE" -ge 2 ]; then
  pass "$SAFEGUARD_ACTIVE safeguard .path units active"
else
  fail "Only $SAFEGUARD_ACTIVE safeguard .path units active (expected ≥2)"
fi

# --- 7. Handler has EXIT trap ---
section "7. Safe Mode Handler"
TRAP_LINE=$(eval $SSH 'grep -c "trap.*EXIT" /usr/local/bin/safe-mode-handler.sh 2>/dev/null' 2>/dev/null) || TRAP_LINE=0
HANDLER_FN=$(eval $SSH 'grep -c "_handler_exit" /usr/local/bin/safe-mode-handler.sh 2>/dev/null' 2>/dev/null) || HANDLER_FN=0
TRAP_TOTAL=$((TRAP_LINE + HANDLER_FN))
if [ "$TRAP_TOTAL" -ge 2 ]; then pass "EXIT trap found (trap=$TRAP_LINE, handler=$HANDLER_FN)"; else fail "EXIT trap missing (trap=$TRAP_LINE, handler=$HANDLER_FN)"; fi

# Handler stops service on terminal failure
STOP_COUNT=$(eval $SSH 'grep -c "hc_stop_service" /usr/local/bin/safe-mode-handler.sh 2>/dev/null' 2>/dev/null) || STOP_COUNT=0
if [ "$STOP_COUNT" -ge 2 ]; then pass "hc_stop_service on terminal paths ($STOP_COUNT calls)"; else fail "hc_stop_service missing ($STOP_COUNT calls, expected ≥2)"; fi

# --- 8. Health check has safeguard re-arm ---
section "8. Health Check Safeguard Re-arm"
REARM=$(eval $SSH 'grep -c "openclaw-safeguard" /usr/local/bin/gateway-health-check.sh 2>/dev/null' 2>/dev/null) || REARM=0
if [ "$REARM" -ge 1 ]; then pass "Safeguard re-arm in health check ($REARM refs)"; else fail "No safeguard re-arm in health check"; fi

# --- 9. HTTP endpoints responding ---
section "9. HTTP Endpoints"
HTTP_PAIRS=$(eval $SSH 'cat /etc/openclaw-groups.json 2>/dev/null' 2>/dev/null | jq -r '.groups | to_entries[] | "\(.key) \(.value.port)"' 2>/dev/null)
while read -r group port; do
  [ -z "$group" ] && continue
  RESP=$(eval $SSH "curl -sf http://localhost:${port}/ >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null)
  if [ "$RESP" = "OK" ]; then pass "$group (port $port): HTTP OK"; else fail "$group (port $port): HTTP FAIL"; fi
done <<< "$HTTP_PAIRS"

# --- 10. Restart policy ---
section "10. Restart Policy"
RESTART_POLICY=$(eval $SSH 'grep "Restart=" /etc/systemd/system/openclaw-group-*.service 2>/dev/null | head -1' 2>/dev/null) || RESTART_POLICY=""
if echo "$RESTART_POLICY" | grep -q "on-failure"; then pass "Restart=on-failure (not always)"; else fail "Restart policy: $RESTART_POLICY"; fi
BURST=$(eval $SSH 'grep "StartLimitBurst" /etc/systemd/system/openclaw-group-*.service 2>/dev/null | head -1' 2>/dev/null) || BURST=""
if echo "$BURST" | grep -q "StartLimitBurst"; then pass "StartLimitBurst set"; else fail "No StartLimitBurst"; fi

# --- 11. Intros sent (wait for E2E services to finish first) ---
section "11. Agent Intros"
E2E_WAIT=0
for attempt in $(seq 1 12); do
  E2E_RUNNING=$(eval $SSH 'systemctl is-active openclaw-e2e-group-alpha.service openclaw-e2e-group-beta.service 2>/dev/null | grep -c "^activating\|^active"' 2>/dev/null) || E2E_RUNNING=0
  [ "$E2E_RUNNING" -eq 0 ] && break
  echo "    Waiting for E2E services to finish... (${attempt}/12)"
  sleep 10
  E2E_WAIT=$((E2E_WAIT + 10))
done
[ "$E2E_WAIT" -gt 0 ] && echo "    Waited ${E2E_WAIT}s for E2E completion"
INTRO_MARKERS=$(eval $SSH 'ls /var/lib/init-status/intro-sent-* 2>/dev/null | wc -l' 2>/dev/null) || INTRO_MARKERS=0
if [ "$INTRO_MARKERS" -ge 2 ]; then pass "$INTRO_MARKERS intro markers found"; else warn "Only $INTRO_MARKERS intro markers (E2E may still be running)"; fi

# --- 12. No errors ---
section "12. Error Check"
SAFE_MARKERS=$(eval $SSH 'ls /var/lib/init-status/safe-mode-* /var/lib/init-status/gateway-failed-* /var/lib/init-status/critical-notified-* 2>/dev/null | wc -l' 2>/dev/null) || SAFE_MARKERS=0
if [ "$SAFE_MARKERS" = "0" ]; then pass "No failure markers"; else fail "$SAFE_MARKERS failure markers found"; fi

# --- 13. No NODE_OPTIONS ---
section "13. NODE_OPTIONS Clean"
NODE_OPTS=$(eval $SSH 'grep -r "experimental-sqlite" /etc/systemd/system/openclaw-* 2>/dev/null | wc -l' 2>/dev/null) || NODE_OPTS=0
if [ "$NODE_OPTS" = "0" ]; then pass "No NODE_OPTIONS=--experimental-sqlite"; else fail "Found experimental-sqlite in $NODE_OPTS files"; fi

# --- Summary ---
echo ""
echo "============================================"
echo "  RESULTS: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 TEST 2B: PASS"
else
  echo "  💥 TEST 2B: FAIL"
fi
exit "$FAIL"
