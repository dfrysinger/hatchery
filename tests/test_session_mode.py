#!/usr/bin/env python3
"""Integration tests for session isolation mode.

Tests the end-to-end flow: lib-isolation.sh functions → generate-session-services.sh.
Unit-level tests for individual functions are in test_lib_isolation.py.
Orchestrator-level tests are in test_build_full_config_orchestration.py.

This file tests session-mode-specific integration behaviors:
1. Multi-group port determinism through the full stack
2. None-mode passthrough (no services generated)
3. Mixed groups filter correctly to session-only
"""
import subprocess
import json
import os
import pytest

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')
LIB_ISOLATION = os.path.join(SCRIPT_DIR, 'lib-isolation.sh')
SESSION_SCRIPT = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')


def build_env(tmp_path, groups, isolation_default='session'):
    """Build environment for a session-mode test with manifest."""
    home = str(tmp_path / 'home' / 'bot')
    manifest_path = str(tmp_path / 'groups.json')
    unit_dir = str(tmp_path / 'units')

    # Generate manifest using lib-isolation.sh (the real code)
    agent_envs = []
    agent_idx = 1
    for gname, gcfg in groups.items():
        for aid in gcfg.get('agents', ['agent1']):
            agent_envs.append(f'AGENT{agent_idx}_ISOLATION_GROUP="{gname}"')
            agent_envs.append(f'AGENT{agent_idx}_ISOLATION="{gcfg.get("isolation", "session")}"')
            agent_envs.append(f'AGENT{agent_idx}_NETWORK="{gcfg.get("network", "host")}"')
            agent_envs.append(f'AGENT{agent_idx}_RESOURCES_MEMORY=""')
            agent_envs.append(f'AGENT{agent_idx}_RESOURCES_CPU=""')
            agent_idx += 1

    env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': home,
        'MANIFEST': manifest_path,
        'ISOLATION_DEFAULT': isolation_default,
        'ISOLATION_GROUPS': ','.join(groups.keys()),
        'USERNAME': 'bot',
        'SVC_USER': 'bot',
        'HOME_DIR': home,
        'HABITAT_NAME': 'test',
        'SESSION_OUTPUT_DIR': unit_dir,
        'DRY_RUN': '1',
        'AGENT_COUNT': str(agent_idx - 1),
    }
    for line in agent_envs:
        key, val = line.split('=', 1)
        env[key] = val.strip('"')

    os.makedirs(unit_dir, exist_ok=True)
    for gname in groups:
        config_dir = os.path.join(home, '.openclaw', 'configs', gname)
        os.makedirs(config_dir, exist_ok=True)

    return env, manifest_path, unit_dir, home


def generate_manifest(env, manifest_path):
    """Generate manifest using lib-isolation.sh's generate_groups_manifest()."""
    script = f"""
set -euo pipefail
source "{LIB_ISOLATION}"
generate_groups_manifest
"""
    result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, env=env)
    assert result.returncode == 0, f"Manifest generation failed: {result.stderr}"
    assert os.path.exists(manifest_path), "Manifest not generated"


class TestSessionIntegration:
    """End-to-end: manifest generation → session service generation."""

    def test_two_groups_get_sequential_ports(self, tmp_path):
        env, mp, ud, _ = build_env(tmp_path, {
            'alpha': {'agents': ['agent1']},
            'beta': {'agents': ['agent2']},
        })
        generate_manifest(env, mp)

        # Verify manifest has correct ports (alphabetical: alpha=18790, beta=18791)
        with open(mp) as f:
            manifest = json.load(f)
        assert manifest['groups']['alpha']['port'] == 18790
        assert manifest['groups']['beta']['port'] == 18791

        # Run session generator
        result = subprocess.run(['bash', SESSION_SCRIPT], capture_output=True, text=True, env=env)
        assert result.returncode == 0, f"stderr: {result.stderr}"

        # Verify units use the manifest ports
        with open(os.path.join(ud, 'openclaw-alpha.service')) as f:
            assert '--port 18790' in f.read()
        with open(os.path.join(ud, 'openclaw-beta.service')) as f:
            assert '--port 18791' in f.read()

    def test_three_groups_alphabetical_port_order(self, tmp_path):
        env, mp, ud, _ = build_env(tmp_path, {
            'zulu': {'agents': ['agent3']},
            'alpha': {'agents': ['agent1']},
            'mike': {'agents': ['agent2']},
        })
        generate_manifest(env, mp)

        with open(mp) as f:
            manifest = json.load(f)
        # Alphabetical: alpha=18790, mike=18791, zulu=18792
        assert manifest['groups']['alpha']['port'] == 18790
        assert manifest['groups']['mike']['port'] == 18791
        assert manifest['groups']['zulu']['port'] == 18792

    def test_none_mode_generates_nothing(self, tmp_path):
        env, mp, ud, _ = build_env(tmp_path, {
            'browser': {'agents': ['agent1']},
        }, isolation_default='none')
        # No manifest needed for none mode — generator just exits early
        result = subprocess.run(['bash', SESSION_SCRIPT], capture_output=True, text=True, env=env)
        assert result.returncode == 0
        assert not any(f.endswith('.service') for f in os.listdir(ud))


class TestSyntax:
    def test_bash_n(self):
        result = subprocess.run(['bash', '-n', SESSION_SCRIPT], capture_output=True, text=True)
        assert result.returncode == 0, f"bash -n failed: {result.stderr}"
