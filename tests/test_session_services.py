#!/usr/bin/env python3
"""Tests for generate-session-services.sh — thin systemd unit generator.

Post-refactor: generate-session-services.sh is a thin generator that ONLY creates
systemd .service files. All other concerns (configs, dirs, auth-profiles, env files,
safeguard/E2E units) are handled by the orchestrator (build-full-config.sh +
lib-isolation.sh) BEFORE this script runs.

This test verifies the thin generator's contract:
1. Reads ports/paths from the manifest (not computed)
2. Generates correct systemd units
3. Skips non-session modes
4. Requires manifest to exist
"""
import subprocess
import json
import os
import pytest

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')
SESSION_SCRIPT = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')


def run_generator(tmp_path, groups, extra_env=None):
    """Run the session generator with a pre-built manifest (as orchestrator would)."""
    home = str(tmp_path / 'home' / 'bot')
    manifest_path = str(tmp_path / 'groups.json')
    unit_dir = str(tmp_path / 'units')

    # Build manifest (simulating what build-full-config.sh generates)
    manifest = {"generated": "2026-02-24T09:00:00Z", "groups": {}}
    for name, cfg in groups.items():
        config_dir = f"{home}/.openclaw/configs/{name}"
        os.makedirs(config_dir, exist_ok=True)
        manifest["groups"][name] = {
            "isolation": "session",
            "port": cfg.get("port", 18790),
            "network": "host",
            "agents": cfg.get("agents", ["agent1"]),
            "configPath": f"{config_dir}/openclaw.session.json",
            "statePath": f"{home}/.openclaw-sessions/{name}",
            "envFile": f"{config_dir}/group.env",
            "serviceName": f"openclaw-{name}",
            "composePath": None,
        }

    os.makedirs(unit_dir, exist_ok=True)
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f)

    env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': home,
        'MANIFEST': manifest_path,
        'ISOLATION_DEFAULT': 'session',
        'ISOLATION_GROUPS': ','.join(groups.keys()),
        'USERNAME': 'bot',
        'HOME_DIR': home,
        'HABITAT_NAME': 'test',
        'SESSION_OUTPUT_DIR': unit_dir,
        'DRY_RUN': '1',
    }
    # Agent env vars (needed by lib-isolation.sh for group queries)
    agent_idx = 1
    for gname, gcfg in groups.items():
        for aid in gcfg.get('agents', ['agent1']):
            env[f'AGENT{agent_idx}_ISOLATION_GROUP'] = gname
            env[f'AGENT{agent_idx}_ISOLATION'] = 'session'
            env[f'AGENT{agent_idx}_NETWORK'] = 'host'
            env[f'AGENT{agent_idx}_NAME'] = aid
            agent_idx += 1
    env['AGENT_COUNT'] = str(agent_idx - 1)

    if extra_env:
        env.update(extra_env)

    result = subprocess.run(['bash', SESSION_SCRIPT], capture_output=True, text=True, env=env)
    return result, unit_dir, home


def read_unit(unit_dir, group):
    """Read a generated systemd unit file."""
    path = os.path.join(unit_dir, f'openclaw-{group}.service')
    with open(path) as f:
        return f.read()


class TestThinGenerator:
    """Verify the generator only creates systemd units from manifest data."""

    def test_generates_service_file(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18790}})
        assert r.returncode == 0, f"stderr: {r.stderr}"
        assert os.path.exists(os.path.join(ud, 'openclaw-browser.service'))

    def test_multiple_groups(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {
            'browser': {'port': 18790},
            'workers': {'port': 18791},
        })
        assert r.returncode == 0
        assert os.path.exists(os.path.join(ud, 'openclaw-browser.service'))
        assert os.path.exists(os.path.join(ud, 'openclaw-workers.service'))

    def test_skips_non_session_mode(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18790}},
                                  extra_env={'ISOLATION_DEFAULT': 'container'})
        assert r.returncode == 0
        assert not os.path.exists(os.path.join(ud, 'openclaw-browser.service'))

    def test_skips_none_mode(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18790}},
                                  extra_env={'ISOLATION_DEFAULT': 'none'})
        assert r.returncode == 0
        assert not os.path.exists(os.path.join(ud, 'openclaw-browser.service'))


class TestServiceUnit:
    """Verify systemd unit contents."""

    def test_port_from_manifest(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18793}})
        assert r.returncode == 0
        unit = read_unit(ud, 'browser')
        assert '--port 18793' in unit

    def test_environment_file(self, tmp_path):
        r, ud, home = run_generator(tmp_path, {'browser': {'port': 18790}})
        assert r.returncode == 0
        unit = read_unit(ud, 'browser')
        assert f'EnvironmentFile={home}/.openclaw/configs/browser/group.env' in unit

    def test_exec_start(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18790}})
        unit = read_unit(ud, 'browser')
        assert 'ExecStart=/usr/local/bin/openclaw gateway --bind loopback --port 18790' in unit

    def test_exec_start_post_health_check(self, tmp_path):
        r, ud, home = run_generator(tmp_path, {'browser': {'port': 18790}})
        unit = read_unit(ud, 'browser')
        assert 'ExecStartPost=' in unit
        assert 'gateway-health-check.sh' in unit

    def test_config_path_env(self, tmp_path):
        r, ud, home = run_generator(tmp_path, {'browser': {'port': 18790}})
        unit = read_unit(ud, 'browser')
        assert f'OPENCLAW_CONFIG_PATH={home}/.openclaw/configs/browser/openclaw.session.json' in unit

    def test_state_dir_env(self, tmp_path):
        r, ud, home = run_generator(tmp_path, {'browser': {'port': 18790}})
        unit = read_unit(ud, 'browser')
        assert f'OPENCLAW_STATE_DIR={home}/.openclaw-sessions/browser' in unit

    def test_user_is_svc_user(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18790}})
        unit = read_unit(ud, 'browser')
        assert 'User=bot' in unit

    def test_restart_policy(self, tmp_path):
        r, ud, _ = run_generator(tmp_path, {'browser': {'port': 18790}})
        unit = read_unit(ud, 'browser')
        assert 'Restart=always' in unit

    def test_service_naming(self, tmp_path):
        """Service name is openclaw-{group}, not numbered."""
        r, ud, _ = run_generator(tmp_path, {'code-sandbox': {'port': 18790}})
        assert os.path.exists(os.path.join(ud, 'openclaw-code-sandbox.service'))
        # Not numbered
        for f in os.listdir(ud):
            assert not any(c.isdigit() for c in f.split('.')[0].split('-')[-1]), \
                f"Service name should not be numbered: {f}"


class TestManifestRequired:
    """Verify the generator fails gracefully without a manifest."""

    def test_fails_without_manifest(self, tmp_path):
        """Generator requires manifest — no standalone mode."""
        env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': str(tmp_path),
            'MANIFEST': str(tmp_path / 'nonexistent.json'),
            'ISOLATION_DEFAULT': 'session',
            'ISOLATION_GROUPS': 'browser',
            'USERNAME': 'bot',
            'HOME_DIR': str(tmp_path),
            'HABITAT_NAME': 'test',
            'SESSION_OUTPUT_DIR': str(tmp_path / 'units'),
            'DRY_RUN': '1',
            'AGENT_COUNT': '1',
            'AGENT1_ISOLATION_GROUP': 'browser',
            'AGENT1_ISOLATION': 'session',
            'AGENT1_NETWORK': 'host',
        }
        os.makedirs(str(tmp_path / 'units'), exist_ok=True)
        result = subprocess.run(['bash', SESSION_SCRIPT], capture_output=True, text=True, env=env)
        assert result.returncode != 0


class TestSyntax:
    def test_bash_n(self):
        result = subprocess.run(['bash', '-n', SESSION_SCRIPT], capture_output=True, text=True)
        assert result.returncode == 0, f"bash -n failed: {result.stderr}"
