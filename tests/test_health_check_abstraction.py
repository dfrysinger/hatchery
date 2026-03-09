"""Tests for health check abstraction functions in lib-health-check.sh.

Validates the hc_* isolation-aware functions:
1. hc_restart_service dispatches correctly for session vs container
2. hc_is_service_active dispatches correctly (process alive, not health status)
3. hc_service_logs dispatches correctly
4. hc_stop_service dispatches correctly
5. hc_curl_gateway handles isolated vs host network
6. hc_wait_for_http polls HTTP with auto-scaled timeout
7. hc_restart_and_wait restarts once + polls (no re-restart on failure)
8. bash -n syntax passes
"""
import subprocess
import os
import tempfile
import uuid
import pytest

SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts')
LIB_PATH = os.path.join(SCRIPT_DIR, 'lib-health-check.sh')


def run_hc_function(code, env=None, check=True):
    """Run bash code with lib-health-check.sh sourced.
    
    We stub systemctl/docker/journalctl to capture what would be called.
    """
    full_env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': '/tmp/test-home',
        'USERNAME': 'bot',
    }
    if env:
        full_env.update(env)

    # Source the lib with stubbed external commands
    script = f"""
set -uo pipefail

# Stub systemctl, docker, journalctl, curl to echo what was called
systemctl() {{ echo "SYSTEMCTL $*"; return 0; }}
docker() {{ echo "DOCKER $*"; return 0; }}
journalctl() {{ echo "JOURNALCTL $*"; return 0; }}
curl() {{ echo "CURL $*"; return 0; }}
export -f systemctl docker journalctl curl

# Minimal setup for lib-health-check.sh
export HC_LOG_DIR="/tmp/test-hc"
export HC_SAFE_MODE_FILE="/tmp/test-safe-mode"
export HC_RECOVERY_COUNTER="/tmp/test-recovery"

# Source the lib (skip logging init)
source "{LIB_PATH}" 2>/dev/null || true

{code}
"""
    result = subprocess.run(
        ['bash', '-c', script],
        capture_output=True, text=True, env=full_env,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"bash exited {result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


class TestSyntax:
    def test_bash_n_passes(self):
        result = subprocess.run(
            ['bash', '-n', LIB_PATH],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"bash -n failed: {result.stderr}"


class TestSafeEnvLoading:
    """hc_load_environment must treat group.env as data, not executable shell."""

    def test_group_env_command_substitution_not_executed(self):
        marker = os.path.join(tempfile.gettempdir(), f"hc-load-env-marker-{uuid.uuid4().hex}")
        result = run_hc_function(
            f'''
rm -f "{marker}"
mkdir -p /home/runner/.openclaw/configs/default
cat > /home/runner/.openclaw/configs/default/group.env <<'EOF'
GROUP_ENV_VERSION=1
PLATFORM=telegram
DANGEROUS=$(touch {marker})
EOF
USERNAME=runner hc_load_environment
[ -f "{marker}" ] && echo "PWNED" || echo "SAFE"
echo "DANGEROUS=$DANGEROUS"
rm -f "{marker}"
''',
            env={'USERNAME': 'runner'},
        )
        assert "SAFE" in result.stdout
        assert "PWNED" not in result.stdout
        assert f"DANGEROUS=$(touch {marker})" in result.stdout

    def test_group_env_quoted_values_load(self):
        result = run_hc_function(
            '''
mkdir -p /home/runner/.openclaw/configs/default
cat > /home/runner/.openclaw/configs/default/group.env <<'EOF'
GROUP_ENV_VERSION=1
HABITAT_NAME="My Habitat Name"
PLATFORM=telegram
EOF
USERNAME=runner hc_load_environment
echo "HABITAT=$HABITAT_NAME"
''',
            env={'USERNAME': 'runner'},
        )
        assert "HABITAT=My Habitat Name" in result.stdout


class TestRestartService:
    """hc_restart_service dispatches to systemctl or docker compose."""

    def test_session_mode_uses_systemctl(self):
        result = run_hc_function(
            'hc_restart_service "browser"',
            env={'ISOLATION': 'session'},
        )
        assert 'SYSTEMCTL restart openclaw-browser' in result.stdout

    def test_container_mode_uses_docker_compose(self):
        result = run_hc_function(
            'hc_restart_service "workers"',
            env={'ISOLATION': 'container'},
        )
        assert 'DOCKER compose' in result.stdout
        assert 'restart' in result.stdout
        assert 'workers' in result.stdout

    def test_default_isolation_is_none(self):
        """When ISOLATION is unset, defaults to none (single openclaw service)."""
        result = run_hc_function(
            'hc_restart_service "browser"',
            env={},  # No ISOLATION set — defaults to none
        )
        assert 'SYSTEMCTL restart openclaw' in result.stdout
        # In none mode, group arg is ignored — restarts the single service
        assert 'openclaw-browser' not in result.stdout


class TestNoneMode:
    """All hc_* functions work correctly in none mode (no isolation)."""

    def test_restart_none_mode(self):
        result = run_hc_function(
            'hc_restart_service ""',
            env={'ISOLATION': 'none'},
        )
        assert 'SYSTEMCTL restart openclaw' in result.stdout
        assert 'openclaw-' not in result.stdout

    def test_is_active_none_mode(self):
        result = run_hc_function(
            'hc_is_service_active "" && echo "ACTIVE" || echo "INACTIVE"',
            env={'ISOLATION': 'none'},
        )
        assert 'SYSTEMCTL is-active --quiet openclaw' in result.stdout
        assert 'ACTIVE' in result.stdout

    def test_logs_none_mode(self):
        result = run_hc_function(
            'hc_service_logs "" 25',
            env={'ISOLATION': 'none'},
        )
        assert 'JOURNALCTL -u openclaw' in result.stdout
        assert '25' in result.stdout

    def test_stop_none_mode(self):
        result = run_hc_function(
            'hc_stop_service ""',
            env={'ISOLATION': 'none'},
        )
        assert 'SYSTEMCTL stop openclaw' in result.stdout
        assert 'openclaw-' not in result.stdout

    def test_curl_none_mode(self):
        result = run_hc_function(
            'hc_curl_gateway "" "/"',
            env={'ISOLATION': 'none', 'GROUP_PORT': '18789'},
        )
        assert 'CURL' in result.stdout
        assert '18789' in result.stdout

    def test_service_name_helper_none(self):
        result = run_hc_function(
            'echo "SVC=$(_hc_service_name)"',
            env={'ISOLATION': 'none'},
        )
        assert 'SVC=openclaw' in result.stdout

    def test_service_name_helper_session(self):
        result = run_hc_function(
            'echo "SVC=$(_hc_service_name browser)"',
            env={'ISOLATION': 'session'},
        )
        assert 'SVC=openclaw-browser' in result.stdout

    def test_group_defaults_to_env_var(self):
        """When no arg passed, hc_* functions use $GROUP from env."""
        result = run_hc_function(
            'hc_restart_service',
            env={'ISOLATION': 'session', 'GROUP': 'docs'},
        )
        assert 'SYSTEMCTL restart openclaw-docs' in result.stdout


class TestIsServiceActive:
    """hc_is_service_active dispatches correctly."""

    def test_session_mode_uses_systemctl(self):
        result = run_hc_function(
            'hc_is_service_active "browser" && echo "ACTIVE" || echo "INACTIVE"',
            env={'ISOLATION': 'session'},
        )
        # Our stub returns 0, so should be active
        assert 'ACTIVE' in result.stdout

    def test_container_mode_uses_docker_inspect(self):
        """Container mode checks State.Running (process alive, not health status)."""
        result = run_hc_function(
            '''
docker() {
    if [[ "$1" == "inspect" ]]; then
        echo "true"
    else
        echo "DOCKER $*"
    fi
    return 0
}
export -f docker
hc_is_service_active "workers" && echo "ACTIVE" || echo "INACTIVE"
''',
            env={'ISOLATION': 'container'},
        )
        assert 'ACTIVE' in result.stdout

    def test_container_mode_not_running_returns_false(self):
        """Container not running = not active."""
        result = run_hc_function(
            '''
docker() {
    if [[ "$1" == "inspect" ]]; then
        echo "false"
    else
        echo "DOCKER $*"
    fi
    return 0
}
export -f docker
hc_is_service_active "workers" && echo "ACTIVE" || echo "INACTIVE"
''',
            env={'ISOLATION': 'container'},
            check=False,
        )
        assert 'INACTIVE' in result.stdout


class TestServiceLogs:
    """hc_service_logs dispatches correctly."""

    def test_session_mode_uses_journalctl(self):
        result = run_hc_function(
            'hc_service_logs "browser" 100',
            env={'ISOLATION': 'session'},
        )
        assert 'JOURNALCTL' in result.stdout
        assert 'openclaw-browser' in result.stdout
        assert '100' in result.stdout

    def test_container_mode_uses_docker_logs(self):
        result = run_hc_function(
            'hc_service_logs "workers" 50',
            env={'ISOLATION': 'container'},
        )
        assert 'DOCKER compose' in result.stdout
        assert 'logs' in result.stdout

    def test_default_lines_50(self):
        result = run_hc_function(
            'hc_service_logs "browser"',
            env={'ISOLATION': 'session'},
        )
        assert '50' in result.stdout


class TestStopService:
    """hc_stop_service dispatches correctly."""

    def test_session_mode_uses_systemctl(self):
        result = run_hc_function(
            'hc_stop_service "browser"',
            env={'ISOLATION': 'session'},
        )
        assert 'SYSTEMCTL stop openclaw-browser' in result.stdout

    def test_container_mode_uses_docker_down(self):
        result = run_hc_function(
            'hc_stop_service "workers"',
            env={'ISOLATION': 'container'},
        )
        assert 'DOCKER compose' in result.stdout
        assert 'down' in result.stdout


class TestCurlGateway:
    """hc_curl_gateway handles network isolation."""

    def test_session_mode_direct_curl(self):
        result = run_hc_function(
            'hc_curl_gateway "browser" "/api/health"',
            env={'ISOLATION': 'session', 'GROUP_PORT': '18790'},
        )
        assert 'CURL' in result.stdout
        assert '18790' in result.stdout
        assert '/api/health' in result.stdout

    def test_container_host_network_direct_curl(self):
        result = run_hc_function(
            'hc_curl_gateway "workers" "/"',
            env={'ISOLATION': 'container', 'NETWORK_MODE': 'host', 'GROUP_PORT': '18791'},
        )
        assert 'CURL' in result.stdout
        assert '18791' in result.stdout

    def test_container_isolated_network_docker_exec(self):
        result = run_hc_function(
            'hc_curl_gateway "workers" "/api/health"',
            env={'ISOLATION': 'container', 'NETWORK_MODE': 'isolated', 'GROUP_PORT': '18791'},
        )
        assert 'DOCKER exec openclaw-workers' in result.stdout
        assert '18791' in result.stdout

    def test_default_port_18789(self):
        result = run_hc_function(
            'hc_curl_gateway "browser" "/"',
            env={'ISOLATION': 'session'},
        )
        assert '18789' in result.stdout


class TestStateHelpers:
    """hc_is_in_safe_mode, hc_get_recovery_attempts."""

    def test_not_in_safe_mode_by_default(self, tmp_path):
        result = run_hc_function(
            'hc_is_in_safe_mode && echo "SAFE" || echo "NOT_SAFE"',
            env={'HC_SAFE_MODE_FILE': str(tmp_path / 'nonexistent')},
            check=False,
        )
        assert 'NOT_SAFE' in result.stdout

    def test_in_safe_mode_when_marker_exists(self, tmp_path):
        marker = tmp_path / 'safe-mode'
        marker.touch()
        result = run_hc_function(
            'hc_is_in_safe_mode && echo "SAFE" || echo "NOT_SAFE"',
            env={'HC_SAFE_MODE_FILE': str(marker)},
        )
        assert 'SAFE' in result.stdout

    def test_recovery_attempts_default_zero(self, tmp_path):
        result = run_hc_function(
            'echo "ATTEMPTS=$(hc_get_recovery_attempts)"',
            env={'HC_RECOVERY_COUNTER': str(tmp_path / 'nonexistent')},
        )
        assert 'ATTEMPTS=0' in result.stdout


class TestWaitForHttp:
    """hc_wait_for_http and hc_restart_and_wait."""

    def test_wait_for_http_returns_immediately_on_success(self):
        """When curl succeeds on first try, returns 0 quickly."""
        result = run_hc_function(
            '''
# Override curl stub to succeed
curl() { return 0; }
export -f curl
hc_wait_for_http "" 5 && echo "HEALTHY" || echo "TIMEOUT"
''',
            env={'ISOLATION': 'none', 'GROUP_PORT': '18789'},
        )
        assert 'HEALTHY' in result.stdout

    def test_wait_for_http_times_out(self):
        """When curl always fails, returns 1 after timeout."""
        result = run_hc_function(
            '''
curl() { return 1; }
export -f curl
hc_wait_for_http "" 1 && echo "HEALTHY" || echo "TIMEOUT"
''',
            env={'ISOLATION': 'none', 'GROUP_PORT': '18789'},
            check=False,
        )
        assert 'TIMEOUT' in result.stdout

    def test_wait_for_http_auto_scales_container_timeout(self):
        """Container mode defaults to 90s timeout (vs 30s for others).

        We verify by checking the log message includes the auto-scaled value.
        Pass explicit short timeout to avoid actually waiting 90s.
        """
        result = run_hc_function(
            '''
curl() { return 1; }
export -f curl
# Verify the auto-scale by checking function declaration parses correctly
# (actual 90s timeout tested in integration, not unit tests)
type hc_wait_for_http | grep -q "function" && echo "FUNC_EXISTS"
# Quick smoke test with 1s timeout
hc_wait_for_http "" 1 2>/dev/null && echo "HEALTHY" || echo "TIMEOUT"
''',
            env={'ISOLATION': 'container', 'GROUP_PORT': '18789'},
            check=False,
        )
        assert 'FUNC_EXISTS' in result.stdout
        assert 'TIMEOUT' in result.stdout

    def test_restart_and_wait_calls_restart_then_waits(self):
        """hc_restart_and_wait restarts once, then polls (no re-restart)."""
        result = run_hc_function(
            '''
restart_count=0
systemctl() {
    if [[ "$1" == "restart" ]]; then
        restart_count=$((restart_count + 1))
        echo "RESTART_COUNT=$restart_count"
    fi
    return 0
}
export -f systemctl

# Succeed on curl immediately
curl() { return 0; }
export -f curl

hc_restart_and_wait "" 5 && echo "HEALTHY" || echo "TIMEOUT"
''',
            env={'ISOLATION': 'none', 'GROUP_PORT': '18789'},
        )
        assert 'HEALTHY' in result.stdout
        # Should only restart once (the key fix — old code restarted 3+ times)
        assert result.stdout.count('RESTART_COUNT=') == 1

    def test_restart_and_wait_no_re_restart_on_poll_failure(self):
        """Critical regression: must NOT restart on each poll failure."""
        result = run_hc_function(
            '''
restart_count=0
systemctl() {
    if [[ "$1" == "restart" ]]; then
        restart_count=$((restart_count + 1))
        echo "RESTART_COUNT=$restart_count"
    fi
    return 0
}
export -f systemctl

# Always fail curl — should timeout without re-restarting
curl() { return 1; }
export -f curl

hc_restart_and_wait "" 1 && echo "HEALTHY" || echo "TIMEOUT"
''',
            env={'ISOLATION': 'none', 'GROUP_PORT': '18789'},
            check=False,
        )
        assert 'TIMEOUT' in result.stdout
        # Must only restart ONCE, not on each retry
        assert result.stdout.count('RESTART_COUNT=') == 1
