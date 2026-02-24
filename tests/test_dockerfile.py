"""Tests for Dockerfile — hatchery/agent:latest image definition.

Validates:
1. Dockerfile syntax (docker build --check or manual parse)
2. Required instructions (FROM, ENTRYPOINT, HEALTHCHECK, USER, WORKDIR)
3. No secrets baked into the image
4. BOT_UID build arg for bind mount permissions
5. OPENCLAW_VERSION build arg for pinned installs
6. Correct entrypoint (openclaw gateway, not bash)
"""
import os
import re
import pytest

DOCKERFILE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'Dockerfile'
)


def read_dockerfile():
    """Read and return the Dockerfile contents."""
    with open(DOCKERFILE_PATH) as f:
        return f.read()


class TestDockerfileSyntax:
    """Basic Dockerfile structure."""

    def test_dockerfile_exists(self):
        assert os.path.exists(DOCKERFILE_PATH), "Dockerfile not found at project root"

    def test_starts_with_from(self):
        content = read_dockerfile()
        # First non-comment, non-ARG line should be FROM
        lines = [l.strip() for l in content.split('\n')
                 if l.strip() and not l.strip().startswith('#')]
        # ARG before FROM is allowed for build args
        first_non_arg = next(l for l in lines if not l.startswith('ARG'))
        assert first_non_arg.startswith('FROM'), \
            f"First instruction should be FROM, got: {first_non_arg}"

    def test_uses_bookworm_slim(self):
        """bookworm-slim (not alpine) for native Node module compatibility."""
        content = read_dockerfile()
        assert 'bookworm-slim' in content, \
            "Should use bookworm-slim base image (not alpine)"


class TestBuildArgs:
    """Build arguments for customization."""

    def test_bot_uid_arg(self):
        content = read_dockerfile()
        assert 'BOT_UID' in content, "Missing BOT_UID build arg"

    def test_openclaw_version_arg(self):
        content = read_dockerfile()
        assert 'OPENCLAW_VERSION' in content, "Missing OPENCLAW_VERSION build arg"

    def test_node_version_arg(self):
        content = read_dockerfile()
        assert 'NODE_VERSION' in content, "Missing NODE_VERSION build arg"


class TestSecurity:
    """No secrets or sensitive data in image."""

    def test_no_api_keys(self):
        content = read_dockerfile()
        for key in ['ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'OPENAI_API_KEY',
                     'BRAVE_API_KEY', 'sk-ant-', 'sk-proj-']:
            assert key not in content, f"Secret '{key}' found in Dockerfile"

    def test_no_env_secrets(self):
        """ENV lines should not contain credential values."""
        content = read_dockerfile()
        env_lines = [l for l in content.split('\n') if l.strip().startswith('ENV')]
        for line in env_lines:
            for pattern in ['KEY=', 'TOKEN=', 'SECRET=', 'PASSWORD=']:
                # Allow NODE_ENV, but not API_KEY=something
                if pattern in line and 'NODE_' not in line:
                    assert False, f"Possible secret in ENV: {line}"

    def test_runs_as_non_root(self):
        """Container should run as bot user, not root."""
        content = read_dockerfile()
        # USER instruction should be present and not root
        user_lines = [l.strip() for l in content.split('\n')
                      if l.strip().startswith('USER')]
        assert len(user_lines) >= 1, "Missing USER instruction"
        last_user = user_lines[-1]
        assert 'root' not in last_user, f"Container runs as root: {last_user}"
        assert 'bot' in last_user, f"Container should run as bot: {last_user}"


class TestEntrypoint:
    """Container entrypoint configuration."""

    def test_entrypoint_is_openclaw_gateway(self):
        content = read_dockerfile()
        assert 'ENTRYPOINT' in content
        # Should be exec form with openclaw gateway
        assert 'openclaw' in content.split('ENTRYPOINT')[1].split('\n')[0]
        assert 'gateway' in content.split('ENTRYPOINT')[1].split('\n')[0]

    def test_no_bash_entrypoint(self):
        """Entrypoint should NOT be bash — use exec form."""
        content = read_dockerfile()
        entrypoint_line = [l for l in content.split('\n')
                           if l.strip().startswith('ENTRYPOINT')][0]
        assert '/bin/bash' not in entrypoint_line, \
            "Entrypoint should be openclaw directly, not bash"

    def test_default_cmd(self):
        """CMD provides default port (overridden by compose command:)."""
        content = read_dockerfile()
        # Find CMD lines that aren't part of HEALTHCHECK
        cmd_lines = [l.strip() for l in content.split('\n')
                     if l.strip().startswith('CMD')]
        assert len(cmd_lines) >= 1, "Missing CMD instruction"
        # The last CMD should have --port
        assert '--port' in cmd_lines[-1], \
            f"CMD should include --port: {cmd_lines[-1]}"


class TestHealthcheck:
    """Compose healthcheck for --wait support."""

    def test_healthcheck_present(self):
        content = read_dockerfile()
        assert 'HEALTHCHECK' in content

    def test_healthcheck_uses_curl(self):
        content = read_dockerfile()
        hc_section = content[content.index('HEALTHCHECK'):]
        assert 'curl' in hc_section

    def test_healthcheck_uses_group_port(self):
        """Healthcheck should reference GROUP_PORT env var."""
        content = read_dockerfile()
        hc_section = content[content.index('HEALTHCHECK'):]
        assert 'GROUP_PORT' in hc_section


class TestDependencies:
    """Required system packages."""

    def test_installs_curl(self):
        """curl needed for healthcheck."""
        content = read_dockerfile()
        assert 'curl' in content

    def test_installs_jq(self):
        """jq used by various OpenClaw operations."""
        content = read_dockerfile()
        assert 'jq' in content

    def test_cleans_apt_cache(self):
        """Image should clean apt cache to stay small."""
        content = read_dockerfile()
        assert 'rm -rf /var/lib/apt/lists' in content


class TestWorkdir:
    """Working directory configuration."""

    def test_workdir_is_home(self):
        content = read_dockerfile()
        workdir_lines = [l.strip() for l in content.split('\n')
                         if l.strip().startswith('WORKDIR')]
        assert any('/home/bot' in l for l in workdir_lines), \
            f"WORKDIR should be /home/bot: {workdir_lines}"
