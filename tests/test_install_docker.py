"""Tests for install-docker.sh — Docker installation gating and configuration.

We can't test actual Docker installation in test environments, but we can verify:
1. needs_docker logic (when to install)
2. bash -n syntax
3. Log rotation config structure
4. Script skips correctly when not needed
"""
import subprocess
import os
import pytest

SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts')
SCRIPT_PATH = os.path.join(SCRIPT_DIR, 'install-docker.sh')


def run_needs_docker(env, check=True):
    """Run just the needs_docker function from the script."""
    script = f"""
set -euo pipefail
source <(sed -n '/^needs_docker/,/^}}/p' "{SCRIPT_PATH}")
needs_docker && echo "NEEDS_DOCKER" || echo "NO_DOCKER"
"""
    full_env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
    }
    full_env.update(env)
    result = subprocess.run(
        ['bash', '-c', script],
        capture_output=True, text=True, env=full_env,
    )
    return result


class TestSyntax:
    def test_bash_n_passes(self):
        result = subprocess.run(
            ['bash', '-n', SCRIPT_PATH],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"bash -n failed: {result.stderr}"


class TestNeedsDocker:
    """Test the needs_docker gating function."""

    def test_container_default_needs_docker(self):
        result = run_needs_docker({
            'ISOLATION_DEFAULT': 'container',
            'AGENT_COUNT': '1',
        })
        assert 'NEEDS_DOCKER' in result.stdout

    def test_session_default_no_docker(self):
        result = run_needs_docker({
            'ISOLATION_DEFAULT': 'session',
            'AGENT_COUNT': '1',
            'AGENT1_ISOLATION': 'session',
        })
        assert 'NO_DOCKER' in result.stdout

    def test_none_default_no_docker(self):
        result = run_needs_docker({
            'ISOLATION_DEFAULT': 'none',
            'AGENT_COUNT': '0',
        })
        assert 'NO_DOCKER' in result.stdout

    def test_mixed_mode_with_container_agent(self):
        """If any agent is container mode, Docker is needed."""
        result = run_needs_docker({
            'ISOLATION_DEFAULT': 'session',
            'AGENT_COUNT': '3',
            'AGENT1_ISOLATION': 'session',
            'AGENT2_ISOLATION': 'container',
            'AGENT3_ISOLATION': 'session',
        })
        assert 'NEEDS_DOCKER' in result.stdout

    def test_all_session_agents_no_docker(self):
        result = run_needs_docker({
            'ISOLATION_DEFAULT': 'session',
            'AGENT_COUNT': '2',
            'AGENT1_ISOLATION': 'session',
            'AGENT2_ISOLATION': 'session',
        })
        assert 'NO_DOCKER' in result.stdout


class TestDryRun:
    """DRY_RUN skips installation."""

    def test_dry_run_exits_cleanly(self):
        env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'ISOLATION_DEFAULT': 'container',
            'AGENT_COUNT': '1',
            'DRY_RUN': '1',
            'USERNAME': 'bot',
        }
        result = subprocess.run(
            ['bash', SCRIPT_PATH],
            capture_output=True, text=True, env=env,
        )
        assert result.returncode == 0
        assert 'DRY_RUN' in result.stdout

    def test_no_docker_exits_cleanly(self):
        env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'ISOLATION_DEFAULT': 'session',
            'AGENT_COUNT': '1',
            'AGENT1_ISOLATION': 'session',
            'USERNAME': 'bot',
        }
        result = subprocess.run(
            ['bash', SCRIPT_PATH],
            capture_output=True, text=True, env=env,
        )
        assert result.returncode == 0
        assert 'skipping Docker install' in result.stdout
