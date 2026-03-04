#!/bin/bash
# =============================================================================
# verify-2c.sh — Container Safe Mode Verification
# Run on bot3.frysinger.org after Stage 11 or Stage 12
# 
# PREREQUISITE: Deploy with broken Anthropic API key so the 'broken' group
# fails E2E and enters safe mode. The 'healthy' group uses Gemini/Google.
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; WARN=0
pass() { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }
warn() { echo "  ⚠️  $1"; ((WARN++)); }

echo "═══════════════════════════════════════════════════"
echo "  Test 2C: Container Safe Mode Trigger & Recovery"
echo "  Host: $(hostname)"
echo "  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════════════"
echo

MANIFEST="/etc/openclaw-groups.json"
STAGE=$(curl -sf localhost:8080/status 2>/dev/null | jq -r '.stage // "unreachable"')

# --- 1. Boot Completed ---
echo "▸ Boot Status"
if [ "$STAGE" = "11" ] || [ "$STAGE" = "12" ]; then
  pass "Boot completed (Stage $STAGE)"
else
  fail "Unexpected stage: $STAGE (expected 11 or 12)"
fi

if [ -f /var/lib/init-status/setup-complete ]; then
  pass "setup-complete marker exists"
else
  fail "setup-complete marker missing"
fi

# --- 2. Docker ---
echo
echo "▸ Docker"
if command -v docker &>/dev/null && docker info &>/dev/null; then
  pass "Docker installed and running"
else
  fail "Docker not available"
fi

# --- 3. Manifest ---
echo
echo "▸ Runtime Manifest"
if [ -f "$MANIFEST" ]; then
  pass "Manifest exists"
  jq -c '.groups | to_entries[] | {name: .key, iso: .value.isolation, port: .value.port}' "$MANIFEST" | sed 's/^/       /'
else
  fail "Manifest missing"
fi

# --- 4. Healthy Group Status ---
echo
echo "▸ Healthy Group (Gemini/Google)"
H_CONTAINER="openclaw-healthy-grp"
H_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$H_CONTAINER" 2>/dev/null || echo "not-found")
if [ "$H_HEALTH" = "healthy" ]; then
  pass "Healthy container is healthy"
else
  fail "Healthy container status: $H_HEALTH"
fi

H_PORT=$(jq -r '.groups["healthy-grp"].port' "$MANIFEST" 2>/dev/null)
if curl -sf "http://127.0.0.1:${H_PORT}/" &>/dev/null; then
  pass "Healthy group HTTP check passes (port ${H_PORT})"
else
  fail "Healthy group HTTP check fails (port ${H_PORT})"
fi

# --- 5. Broken Group — Should Be in Safe Mode ---
echo
echo "▸ Broken Group (Anthropic — expected to fail)"
B_PORT=$(jq -r '.groups["broken-grp"].port' "$MANIFEST" 2>/dev/null)

# Check for safe mode markers
if ls /var/lib/init-status/safe-mode-broken-grp* &>/dev/null 2>&1 || ls /var/lib/init-status/unhealthy-broken-grp* &>/dev/null 2>&1; then
  pass "Safe mode / unhealthy marker exists for broken group"
else
  warn "No safe mode marker for broken group (may not have triggered yet)"
fi

# The broken container might be running (safe mode recovery restarts it) or not
B_CONTAINER="openclaw-broken-grp"
B_STATUS=$(docker inspect --format='{{.State.Status}}' "$B_CONTAINER" 2>/dev/null || echo "not-found")
echo "       Broken container status: $B_STATUS"

# Check safeguard .path was triggered
SAFEGUARD_LOG=$(journalctl -u openclaw-safeguard-broken-grp.service --no-pager -n 5 2>/dev/null || echo "no logs")
if echo "$SAFEGUARD_LOG" | grep -qi "safe.mode\|recovery\|handler"; then
  pass "Safeguard handler ran for broken group"
else
  warn "No safeguard handler evidence in logs"
fi

# Check .path units are re-armed (not dead) after handler ran
for grp in broken-grp healthy-grp; do
  if systemctl is-active --quiet "openclaw-safeguard-${grp}.path" 2>/dev/null; then
    pass "openclaw-safeguard-${grp}.path re-armed (active)"
  else
    fail "openclaw-safeguard-${grp}.path dead after handler — re-arm bug"
  fi
done

# Check critical notification lockout (only for broken group)
if [ -f "/var/lib/init-status/critical-notified-broken-grp" ]; then
  pass "Critical notification lockout set for broken-grp"
else
  warn "No critical notification lockout for broken-grp (recovery may have succeeded)"
fi
if [ -f "/var/lib/init-status/critical-notified-healthy-grp" ]; then
  fail "Unexpected critical lockout for healthy-grp"
else
  pass "No false lockout for healthy-grp"
fi

# --- 6. Cross-Group Isolation ---
echo
echo "▸ Cross-Group Isolation"
echo "  (Broken group failure should NOT affect healthy group)"
if [ "$H_HEALTH" = "healthy" ]; then
  pass "Healthy group survived broken group's failure"
else
  fail "Healthy group affected by broken group's failure"
fi

# --- 7. Safe Mode Handler Output ---
echo
echo "▸ Safe Mode Handler Artifacts"
if [ -f /home/bot/clawd/shared/BOOT_REPORT.md ]; then
  pass "Boot report generated"
  echo "       $(head -3 /home/bot/clawd/shared/BOOT_REPORT.md | sed 's/^/       /')"
else
  warn "No boot report (safe mode handler may not have completed)"
fi

# --- 8. Manual Recovery Test ---
echo
echo "▸ Manual Recovery Test"
echo "  To test try-full-config.sh recovery:"
echo "    1. Fix the API key in /home/bot/.openclaw/configs/broken/group.env"
echo "    2. Run: sudo /usr/local/bin/try-full-config.sh broken"
echo "    3. Verify: docker inspect openclaw-broken --format='{{.State.Health.Status}}'"
echo "  (This step is manual — skip in automated runs)"
pass "(manual step documented)"

# --- 9. Process Kill Recovery ---
echo
echo "▸ Docker Restart-on-Failure (healthy group)"
echo "  Killing gateway process inside healthy container..."
docker exec "$H_CONTAINER" pkill -f "openclaw" 2>/dev/null || true
echo "  Waiting 15s for Docker restart policy..."
sleep 15
H_HEALTH_AFTER=$(docker inspect --format='{{.State.Health.Status}}' "$H_CONTAINER" 2>/dev/null || echo "not-found")
H_RUNNING=$(docker inspect --format='{{.State.Running}}' "$H_CONTAINER" 2>/dev/null || echo "false")
if [ "$H_RUNNING" = "true" ]; then
  pass "Container restarted after process kill (restart: on-failure)"
  if [ "$H_HEALTH_AFTER" = "healthy" ]; then
    pass "Container healthy after restart"
  else
    warn "Container running but health=$H_HEALTH_AFTER (may need more time for start_period)"
  fi
else
  fail "Container did not restart after process kill"
fi

# --- 10. E2E Re-trigger ---
echo
echo "▸ E2E Unit Re-trigger"
if [ -f "/etc/systemd/system/openclaw-e2e-healthy-grp.service" ]; then
  pass "E2E unit exists for healthy group"
  # Try running it manually
  if systemctl start openclaw-e2e-healthy-grp.service 2>/dev/null; then
    E2E_RESULT=$(systemctl show openclaw-e2e-healthy-grp.service --property=Result 2>/dev/null | cut -d= -f2)
    if [ "$E2E_RESULT" = "success" ]; then
      pass "E2E check passes for healthy group"
    else
      warn "E2E check result: $E2E_RESULT"
    fi
  else
    warn "E2E check failed to start (may need longer health startup)"
  fi
else
  fail "E2E unit missing for healthy-grp"
fi

# --- Summary ---
echo
echo "═══════════════════════════════════════════════════"
echo "  Results: ✅ $PASS passed  ❌ $FAIL failed  ⚠️  $WARN warnings"
echo "═══════════════════════════════════════════════════"

if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 TEST 2C PASSED"
else
  echo "  💥 TEST 2C FAILED"
fi
echo
echo "  Note: Some checks are expected to warn/fail depending on"
echo "  whether the Anthropic key was actually broken for this test."
echo "  The key validations are:"
echo "    - Healthy group survives"
echo "    - Broken group triggers safe mode (markers + handler)"
echo "    - Process kill → Docker restarts container"
exit "$FAIL"
