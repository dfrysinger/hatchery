#!/bin/bash
# =============================================================================
# verify-2b.sh — Session Regression Verification
# Run on bot1.frysinger.org after Stage 11
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; WARN=0
pass() { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }
warn() { echo "  ⚠️  $1"; ((WARN++)); }

echo "═══════════════════════════════════════════════════"
echo "  Test 2B: Session-Only Regression"
echo "  Host: $(hostname)"
echo "  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════════════"
echo

# --- 1. Stage & Readiness ---
echo "▸ Stage & Readiness"
STAGE=$(curl -sf localhost:8080/status 2>/dev/null | jq -r '.stage // "unreachable"')
if [ "$STAGE" = "11" ]; then
  pass "Stage 11 (READY)"
else
  fail "Stage is $STAGE, expected 11"
fi

if [ -f /var/lib/init-status/setup-complete ]; then
  pass "setup-complete marker exists"
else
  fail "setup-complete marker missing"
fi

# --- 2. No Docker ---
echo
echo "▸ Docker NOT installed (session-only habitat)"
if command -v docker &>/dev/null; then
  fail "Docker is installed — needs_docker() gate failed"
else
  pass "Docker not installed (correct for session-only)"
fi

# --- 3. Manifest ---
echo
echo "▸ Runtime Manifest"
MANIFEST="/etc/openclaw-groups.json"
if [ -f "$MANIFEST" ]; then
  pass "Manifest exists"
  GROUP_COUNT=$(jq '.groups | length' "$MANIFEST")
  if [ "$GROUP_COUNT" = "2" ]; then
    pass "2 groups in manifest (group-alpha, group-beta)"
  else
    fail "Expected 2 groups, found $GROUP_COUNT"
  fi

  # Unique ports
  PORT_COUNT=$(jq '[.groups[].port] | unique | length' "$MANIFEST")
  TOTAL_PORTS=$(jq '[.groups[].port] | length' "$MANIFEST")
  if [ "$PORT_COUNT" = "$TOTAL_PORTS" ]; then
    pass "All ports unique"
  else
    fail "Port collision detected!"
  fi

  # All groups are session type
  NON_SESSION=$(jq '[.groups[] | select(.isolation != "session")] | length' "$MANIFEST")
  if [ "$NON_SESSION" = "0" ]; then
    pass "All groups are session isolation"
  else
    fail "$NON_SESSION group(s) are not session type"
  fi
else
  fail "Manifest missing at $MANIFEST"
fi

# --- 4. Session Services ---
echo
echo "▸ Session Services"
for group in group-alpha group-beta; do
  SVC="openclaw-${group}"
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    pass "$SVC is active"
  else
    fail "$SVC is not active"
  fi
done

# --- 5. Safeguard Units ---
echo
echo "▸ Safeguard & E2E Units"
for group in group-alpha group-beta; do
  if systemctl is-enabled --quiet "openclaw-safeguard-${group}.path" 2>/dev/null; then
    pass "openclaw-safeguard-${group}.path enabled"
  else
    fail "openclaw-safeguard-${group}.path not enabled"
  fi

  if systemctl is-active --quiet "openclaw-safeguard-${group}.path" 2>/dev/null; then
    pass "openclaw-safeguard-${group}.path active (watching)"
  else
    fail "openclaw-safeguard-${group}.path not active (dead — re-arm bug)"
  fi

  if [ -f "/etc/systemd/system/openclaw-e2e-${group}.service" ]; then
    pass "openclaw-e2e-${group}.service exists"
  else
    fail "openclaw-e2e-${group}.service missing"
  fi
done

# --- 6. Configs & Auth ---
echo
echo "▸ Per-Group Configs"
for group in group-alpha group-beta; do
  CONFIG_DIR="/home/bot/.openclaw/configs/${group}"
  if [ -f "${CONFIG_DIR}/openclaw.session.json" ]; then
    pass "${group}: config exists"
  else
    fail "${group}: config missing"
  fi

  if [ -f "${CONFIG_DIR}/group.env" ]; then
    pass "${group}: group.env exists"
  else
    fail "${group}: group.env missing"
  fi

  if [ -f "${CONFIG_DIR}/gateway-token.txt" ]; then
    pass "${group}: gateway token exists"
  else
    fail "${group}: gateway token missing"
  fi
done

# --- 7. No Safe Mode ---
echo
echo "▸ No Safe Mode Markers"
SM_COUNT=$(ls /var/lib/init-status/safe-mode-* 2>/dev/null | wc -l)
if [ "$SM_COUNT" = "0" ]; then
  pass "No safe mode markers"
else
  fail "$SM_COUNT safe mode marker(s) found"
fi

UNHEALTHY=$(ls /var/lib/init-status/unhealthy-* 2>/dev/null | wc -l)
if [ "$UNHEALTHY" = "0" ]; then
  pass "No unhealthy markers"
else
  fail "$UNHEALTHY unhealthy marker(s) found"
fi

# --- 8. Health Check ---
echo
echo "▸ HTTP Health Checks"
for group in group-alpha group-beta; do
  PORT=$(jq -r --arg g "$group" '.groups[$g].port' "$MANIFEST")
  if curl -sf "http://127.0.0.1:${PORT}/" &>/dev/null; then
    pass "${group}: HTTP health check passes (port ${PORT})"
  else
    fail "${group}: HTTP health check fails (port ${PORT})"
  fi
done

# --- 9. Disk ---
echo
echo "▸ Disk Usage"
DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
if [ "$DISK_PCT" -lt 80 ]; then
  pass "Disk usage ${DISK_PCT}% (< 80%)"
else
  warn "Disk usage ${DISK_PCT}% (≥ 80%)"
fi

# --- Summary ---
echo
echo "═══════════════════════════════════════════════════"
echo "  Results: ✅ $PASS passed  ❌ $FAIL failed  ⚠️  $WARN warnings"
echo "═══════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && echo "  🎉 TEST 2B PASSED" || echo "  💥 TEST 2B FAILED"
exit "$FAIL"
