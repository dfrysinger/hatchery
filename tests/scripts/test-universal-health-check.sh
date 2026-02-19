#!/bin/bash
# =============================================================================
# test-universal-health-check.sh -- Tests for universal health check pattern
# =============================================================================
# Validates that the health check works identically across all isolation modes:
#   - none (single service)
#   - session (per-group systemd services)
#   - container (per-group docker containers)
#
# The universal pattern: every health check invocation handles ONE group.
# The only differences are: service name, port, and how to restart.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"

PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}✓${NC} $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILED=$((FAILED + 1))
}

HEALTH_CHECK="$REPO_DIR/scripts/gateway-health-check.sh"
BUILD_CONFIG="$REPO_DIR/scripts/build-full-config.sh"
DOCKER_COMPOSE="$REPO_DIR/scripts/generate-docker-compose.sh"
SESSION_SERVICES="$REPO_DIR/scripts/generate-session-services.sh"
SAFE_MODE_RECOVERY="$REPO_DIR/scripts/safe-mode-recovery.sh"

# =============================================================================
# 1. Universal: SERVICE_NAME derivation
#    Every mode should derive a single service name for this group
# =============================================================================
echo ""
echo "=== Universal service name derivation ==="

# GROUP set → service name is openclaw-${GROUP}
if grep -q 'SERVICE_NAME="openclaw-\${GROUP}"' "$HEALTH_CHECK"; then
  pass "GROUP set → SERVICE_NAME=openclaw-\${GROUP}"
else
  fail "Should set SERVICE_NAME=openclaw-\${GROUP} when GROUP is set"
fi

# GROUP not set, standard → service name is openclaw
if grep -q 'SERVICE_NAME="openclaw"' "$HEALTH_CHECK"; then
  pass "No GROUP → SERVICE_NAME=openclaw"
else
  fail "Should set SERVICE_NAME=openclaw when GROUP not set"
fi

# =============================================================================
# 2. Universal: Per-group state files
#    Safe mode and recovery state must be per-group to avoid interference
# =============================================================================
echo ""
echo "=== Per-group state files ==="

# Recovery counter is per-group when GROUP set
if grep -q 'recovery-attempts-\${GROUP}' "$HEALTH_CHECK"; then
  pass "Recovery counter is per-group"
else
  fail "Recovery counter should be per-group: recovery-attempts-\${GROUP}"
fi

# Safe mode flag is per-group when GROUP set
if grep -q 'safe-mode-\${GROUP}' "$HEALTH_CHECK"; then
  pass "Safe mode flag is per-group"
else
  fail "Safe mode flag should be per-group: safe-mode-\${GROUP}"
fi

# Notification markers should be per-group
if grep -q 'notification-sent-.*\${' "$HEALTH_CHECK"; then
  pass "Notification markers include group context"
else
  fail "Notification markers should include group context"
fi

# =============================================================================
# 3. Universal: Config path
#    Each mode needs to know where its config file lives
# =============================================================================
echo ""
echo "=== Config path per isolation mode ==="

# Standard mode: ~/.openclaw/openclaw.json
if grep -q 'CONFIG_PATH.*\.openclaw/openclaw.json' "$HEALTH_CHECK"; then
  pass "Standard mode config path: ~/.openclaw/openclaw.json"
else
  fail "Standard mode should use ~/.openclaw/openclaw.json"
fi

# Session mode: from OPENCLAW_CONFIG_PATH env or constructed path
if grep -q 'OPENCLAW_CONFIG_PATH' "$HEALTH_CHECK"; then
  pass "Session mode respects OPENCLAW_CONFIG_PATH env var"
else
  fail "Should respect OPENCLAW_CONFIG_PATH for session isolation"
fi

# =============================================================================
# 4. Universal: check_service_health is the same for all modes
#    It just takes a service name and port — no branching needed
# =============================================================================
echo ""
echo "=== check_service_health is universal ==="

# check_service_health takes service name and port as arguments
if grep -q 'check_service_health.*\$.*PORT\|check_service_health.*\$.*port\|check_service_health.*SERVICE_NAME.*GROUP_PORT' "$HEALTH_CHECK"; then
  pass "check_service_health accepts variable service/port"
else
  fail "check_service_health should accept variable service name and port"
fi

# The main dispatch should use GROUP_PORT for group mode
if grep -q 'check_service_health.*\$SERVICE_NAME.*\$GROUP_PORT\|check_service_health.*SERVICE_NAME.*GROUP_PORT' "$HEALTH_CHECK"; then
  pass "Group mode uses SERVICE_NAME and GROUP_PORT"
else
  fail "Group mode should use SERVICE_NAME and GROUP_PORT"
fi

# =============================================================================
# 5. Universal: restart_gateway handles all isolation types
# =============================================================================
echo ""
echo "=== restart_gateway handles all types ==="

# Session mode
if grep -A20 'restart_gateway' "$HEALTH_CHECK" | grep -q 'session'; then
  pass "restart_gateway handles session isolation"
else
  fail "restart_gateway should handle session isolation"
fi

# Container mode
if grep -A30 'restart_gateway' "$HEALTH_CHECK" | grep -q 'container'; then
  pass "restart_gateway handles container isolation"
else
  fail "restart_gateway should handle container isolation"
fi

# Standard mode
if grep -A30 'restart_gateway' "$HEALTH_CHECK" | grep -q 'openclaw'; then
  pass "restart_gateway handles standard mode"
else
  fail "restart_gateway should handle standard mode"
fi

# =============================================================================
# 6. Container mode: docker-compose generates per-group services
# =============================================================================
echo ""
echo "=== Docker compose generates per-group services ==="

if [ -f "$DOCKER_COMPOSE" ]; then
  # Each container group gets its own service in docker-compose
  if grep -q 'CONTAINER_GROUPS\|container.*group' "$DOCKER_COMPOSE"; then
    pass "Docker compose iterates over container groups"
  else
    fail "Docker compose should iterate over container groups"
  fi

  # Health check should be part of container setup
  if grep -q 'healthcheck\|health.*check\|HEALTHCHECK\|gateway-health-check' "$DOCKER_COMPOSE"; then
    pass "Docker compose includes health check"
  else
    fail "Docker compose should include health check for each container"
  fi
else
  fail "generate-docker-compose.sh not found"
fi

# =============================================================================
# 7. Container mode: enter_safe_mode handles containers
# =============================================================================
echo ""
echo "=== enter_safe_mode handles containers ==="

# enter_safe_mode should handle container mode (function is large, search whole body)
ENTER_SM_BODY=$(sed -n '/^enter_safe_mode()/,/^}/p' "$HEALTH_CHECK")
if echo "$ENTER_SM_BODY" | grep -q 'container'; then
  pass "enter_safe_mode handles container isolation"
else
  fail "enter_safe_mode should handle container isolation"
fi

# =============================================================================
# 8. No legacy all-groups dispatch in main path
#    Each group should check itself — no central orchestrator
# =============================================================================
echo ""
echo "=== No central orchestrator for multi-group ==="

# The main health check dispatch should not iterate over all groups
# Each group's service/container runs its own health check
MAIN_DISPATCH=$(sed -n '/^# Main Health Check/,/^# =====/p' "$HEALTH_CHECK")

# Should have a simple GROUP check, then standard fallback — not iteration
if echo "$MAIN_DISPATCH" | grep -q 'for group in'; then
  fail "Main dispatch should NOT iterate over groups (each group checks itself)"
else
  pass "Main dispatch does not iterate over groups"
fi

# =============================================================================
# 9. Container mode: restart uses docker, not systemctl
#    When running inside a container, restart should use docker-appropriate method
# =============================================================================
echo ""
echo "=== Container restart method ==="

# For container mode, restart should use docker restart or docker-compose restart
if grep -q 'docker.*restart\|docker-compose.*restart\|container.*restart' "$HEALTH_CHECK"; then
  pass "Container mode uses docker-appropriate restart"
else
  fail "Container mode should use docker restart (not just systemctl)"
fi

# =============================================================================
# 10. Universal: safe mode recovery writes to CONFIG_PATH
#     Not hardcoded to ~/.openclaw/openclaw.json
# =============================================================================
echo ""
echo "=== Safe mode recovery uses CONFIG_PATH ==="

# Recovery should write to CONFIG_PATH (set per isolation mode)
if grep -q 'CONFIG_PATH\|config_path' "$SAFE_MODE_RECOVERY" || grep -q 'CONFIG_PATH' "$HEALTH_CHECK"; then
  pass "Recovery config path is configurable"
else
  fail "Recovery should write to CONFIG_PATH, not hardcoded path"
fi

# =============================================================================
# 11. Universal: E2E check respects GROUP_PORT for gateway connection
# =============================================================================
echo ""
echo "=== E2E check connects to correct port ==="

# check_agents_e2e or the openclaw agent command should use GROUP_PORT
if grep -q 'OPENCLAW_GATEWAY_URL\|gateway_url\|GROUP_PORT' "$HEALTH_CHECK"; then
  pass "E2E check can connect to non-default ports"
else
  fail "E2E check should support non-default gateway ports"
fi

# =============================================================================
# 12. Docker compose: entrypoint pattern
#     Container should run gateway then health check (like ExecStart + ExecStartPost)
# =============================================================================
echo ""
echo "=== Container entrypoint pattern ==="

if [ -f "$DOCKER_COMPOSE" ]; then
  # Container should have an entrypoint or command that includes health check
  if grep -q 'entrypoint\|command.*health\|gateway-health-check\|ExecStartPost' "$DOCKER_COMPOSE"; then
    pass "Container includes health check in startup"
  else
    fail "Container should include health check in entrypoint/command"
  fi
else
  fail "generate-docker-compose.sh not found"
fi

# =============================================================================
# 13. Universal: health check log is per-group
# =============================================================================
echo ""
echo "=== Health check log is per-group ==="

if grep -q 'gateway-health-check-\${GROUP}' "$HEALTH_CHECK"; then
  pass "Health check log is per-group when GROUP set"
else
  fail "Health check log should be per-group: gateway-health-check-\${GROUP}.log"
fi

# =============================================================================
# 14. Container mode: scripts must be available inside container
# =============================================================================
echo ""
echo "=== Container has required scripts ==="

if [ -f "$DOCKER_COMPOSE" ]; then
  # Container should mount or copy health check scripts
  if grep -q 'gateway-health-check\|/usr/local/bin\|scripts' "$DOCKER_COMPOSE"; then
    pass "Container has access to health check scripts"
  else
    fail "Container should mount or include health check scripts"
  fi
else
  fail "generate-docker-compose.sh not found"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "Universal Health Check Tests Complete"
echo "========================================="
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo ""

exit $FAILED
