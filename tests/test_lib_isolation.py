"""Tests for lib-isolation.sh — shared isolation group management functions."""
import subprocess
import json
import os
import tempfile
import pytest

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')
LIB_PATH = os.path.join(SCRIPT_DIR, 'lib-isolation.sh')


def run_bash(code, env=None, check=True):
    """Run bash code with lib-isolation.sh sourced."""
    full_env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': '/tmp/test-home',
    }
    if env:
        full_env.update(env)
    
    # Source the lib with set +e so we can test failure cases
    script = f"""
set -uo pipefail
source "{LIB_PATH}"
{code}
"""
    result = subprocess.run(
        ['bash', '-c', script],
        capture_output=True, text=True, env=full_env
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"bash exited {result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def make_agent_env(agents):
    """Build env vars for a list of agent configs.
    
    agents: list of dicts with keys: id, group, isolation, network, memory, cpu, name, model
    """
    env = {'AGENT_COUNT': str(len(agents))}
    for i, a in enumerate(agents, 1):
        env[f'AGENT{i}_ISOLATION_GROUP'] = a.get('group', '')
        env[f'AGENT{i}_ISOLATION'] = a.get('isolation', '')
        env[f'AGENT{i}_NETWORK'] = a.get('network', '')
        env[f'AGENT{i}_RESOURCES_MEMORY'] = a.get('memory', '')
        env[f'AGENT{i}_RESOURCES_CPU'] = a.get('cpu', '')
        env[f'AGENT{i}_NAME'] = a.get('name', f'Agent{i}')
        env[f'AGENT{i}_MODEL'] = a.get('model', 'anthropic/claude-sonnet-4-5')
    return env


# =========================================================================
# get_group_agents
# =========================================================================

class TestGetGroupAgents:
    def test_single_agent_in_group(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
        ])
        r = run_bash('get_group_agents "council"', env=env)
        assert r.stdout.strip() == 'agent1'

    def test_multiple_agents_in_group(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
            {'group': 'workers', 'isolation': 'session'},
            {'group': 'council', 'isolation': 'session'},
        ])
        r = run_bash('get_group_agents "council"', env=env)
        assert r.stdout.strip() == 'agent1,agent3'

    def test_no_agents_in_group(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
        ])
        r = run_bash('get_group_agents "workers"', env=env)
        assert r.stdout.strip() == ''

    def test_all_agents_in_group(self):
        env = make_agent_env([
            {'group': 'all', 'isolation': 'container'},
            {'group': 'all', 'isolation': 'container'},
        ])
        r = run_bash('get_group_agents "all"', env=env)
        assert r.stdout.strip() == 'agent1,agent2'


# =========================================================================
# get_group_isolation
# =========================================================================

class TestGetGroupIsolation:
    def test_returns_agent_isolation(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'container'},
        ])
        r = run_bash('get_group_isolation "council"', env=env)
        assert r.stdout.strip() == 'container'

    def test_falls_back_to_isolation_default(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': ''},
        ])
        env['ISOLATION_DEFAULT'] = 'session'
        r = run_bash('get_group_isolation "council"', env=env)
        assert r.stdout.strip() == 'session'

    def test_falls_back_to_none(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': ''},
        ])
        r = run_bash('get_group_isolation "council"', env=env)
        assert r.stdout.strip() == 'none'


# =========================================================================
# get_group_network
# =========================================================================

class TestGetGroupNetwork:
    def test_returns_host_by_default(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session', 'network': ''},
        ])
        r = run_bash('get_group_network "council"', env=env)
        assert r.stdout.strip() == 'host'

    def test_returns_isolated(self):
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container', 'network': 'isolated'},
        ])
        r = run_bash('get_group_network "sandbox"', env=env)
        assert r.stdout.strip() == 'isolated'

    def test_maps_internal_to_isolated(self):
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container', 'network': 'internal'},
        ])
        r = run_bash('get_group_network "sandbox"', env=env)
        assert r.stdout.strip() == 'isolated'
        assert 'deprecated' in r.stderr.lower()

    def test_maps_none_to_isolated(self):
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container', 'network': 'none'},
        ])
        r = run_bash('get_group_network "sandbox"', env=env)
        assert r.stdout.strip() == 'isolated'
        assert 'deprecated' in r.stderr.lower()


# =========================================================================
# get_group_resources
# =========================================================================

class TestGetGroupResources:
    def test_returns_resources(self):
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container', 'memory': '512m', 'cpu': '0.5'},
        ])
        r = run_bash('get_group_resources "sandbox"', env=env)
        assert r.stdout.strip() == '512m 0.5'

    def test_returns_empty_when_unset(self):
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container'},
        ])
        r = run_bash('get_group_resources "sandbox"', env=env)
        # Two spaces (empty mem + empty cpu)
        assert r.stdout.strip() == ''

    def test_uses_first_agent_values(self):
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container', 'memory': '512m', 'cpu': '0.5'},
            {'group': 'sandbox', 'isolation': 'container', 'memory': '1g', 'cpu': '1.0'},
        ])
        r = run_bash('get_group_resources "sandbox"', env=env)
        assert r.stdout.strip() == '512m 0.5'


# =========================================================================
# get_groups_by_type
# =========================================================================

class TestGetGroupsByType:
    def test_filters_session_groups(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
            {'group': 'sandbox', 'isolation': 'container'},
            {'group': 'workers', 'isolation': 'session'},
        ])
        env['ISOLATION_GROUPS'] = 'council,sandbox,workers'
        r = run_bash('get_groups_by_type "session"', env=env)
        assert r.stdout.strip() == 'council workers'

    def test_filters_container_groups(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
            {'group': 'sandbox', 'isolation': 'container'},
        ])
        env['ISOLATION_GROUPS'] = 'council,sandbox'
        r = run_bash('get_groups_by_type "container"', env=env)
        assert r.stdout.strip() == 'sandbox'

    def test_empty_when_no_match(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
        ])
        env['ISOLATION_GROUPS'] = 'council'
        r = run_bash('get_groups_by_type "container"', env=env)
        assert r.stdout.strip() == ''


# =========================================================================
# validate_group_consistency
# =========================================================================

class TestValidateGroupConsistency:
    def test_passes_consistent_group(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session', 'network': 'host'},
            {'group': 'council', 'isolation': 'session', 'network': 'host'},
        ])
        r = run_bash('validate_group_consistency "council"', env=env)
        assert r.returncode == 0

    def test_fails_mixed_isolation(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session', 'network': 'host'},
            {'group': 'council', 'isolation': 'container', 'network': 'host'},
        ])
        r = run_bash('validate_group_consistency "council"', env=env, check=False)
        assert r.returncode != 0
        assert 'FATAL' in r.stderr
        assert 'mixed isolation' in r.stderr

    def test_fails_mixed_network(self):
        env = make_agent_env([
            {'group': 'council', 'isolation': 'container', 'network': 'host'},
            {'group': 'council', 'isolation': 'container', 'network': 'isolated'},
        ])
        r = run_bash('validate_group_consistency "council"', env=env, check=False)
        assert r.returncode != 0
        assert 'mixed network' in r.stderr


# =========================================================================
# Manifest Generation
# =========================================================================

class TestManifestGeneration:
    def test_generates_valid_json(self, tmp_path):
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
            {'group': 'sandbox', 'isolation': 'container', 'network': 'isolated'},
        ])
        env['ISOLATION_GROUPS'] = 'council,sandbox'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        run_bash('generate_groups_manifest', env=env)
        
        with open(manifest) as f:
            data = json.load(f)
        
        assert 'groups' in data
        assert 'generated' in data
        assert 'council' in data['groups']
        assert 'sandbox' in data['groups']

    def test_deterministic_port_assignment(self, tmp_path):
        """Ports are assigned alphabetically, so council < sandbox."""
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container'},
            {'group': 'council', 'isolation': 'session'},
        ])
        env['ISOLATION_GROUPS'] = 'sandbox,council'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        run_bash('generate_groups_manifest', env=env)
        
        with open(manifest) as f:
            data = json.load(f)
        
        # Alphabetical: council=18790, sandbox=18791
        assert data['groups']['council']['port'] == 18790
        assert data['groups']['sandbox']['port'] == 18791

    def test_hyphenated_group_names(self, tmp_path):
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'code-sandbox', 'isolation': 'container'},
        ])
        env['ISOLATION_GROUPS'] = 'code-sandbox'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        run_bash('generate_groups_manifest', env=env)
        
        with open(manifest) as f:
            data = json.load(f)
        
        assert 'code-sandbox' in data['groups']
        assert data['groups']['code-sandbox']['port'] == 18790

    def test_container_group_has_compose_path(self, tmp_path):
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'sandbox', 'isolation': 'container'},
        ])
        env['ISOLATION_GROUPS'] = 'sandbox'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        run_bash('generate_groups_manifest', env=env)
        
        with open(manifest) as f:
            data = json.load(f)
        
        assert data['groups']['sandbox']['composePath'] is not None
        assert 'docker-compose.yaml' in data['groups']['sandbox']['composePath']

    def test_session_group_has_null_compose_path(self, tmp_path):
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
        ])
        env['ISOLATION_GROUPS'] = 'council'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        run_bash('generate_groups_manifest', env=env)
        
        with open(manifest) as f:
            data = json.load(f)
        
        assert data['groups']['council']['composePath'] is None

    def test_get_group_port_reads_manifest(self, tmp_path):
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
        ])
        env['ISOLATION_GROUPS'] = 'council'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        run_bash('generate_groups_manifest', env=env)
        
        r = run_bash('get_group_port "council"', env=env)
        assert r.stdout.strip() == '18790'

    def test_idempotent_port_assignment(self, tmp_path):
        """Running manifest generation twice produces the same ports."""
        manifest = str(tmp_path / 'groups.json')
        env = make_agent_env([
            {'group': 'council', 'isolation': 'session'},
            {'group': 'sandbox', 'isolation': 'container'},
        ])
        env['ISOLATION_GROUPS'] = 'council,sandbox'
        env['MANIFEST'] = manifest
        env['HOME_DIR'] = '/home/bot'
        
        run_bash('generate_groups_manifest', env=env)
        with open(manifest) as f:
            data1 = json.load(f)
        
        run_bash('generate_groups_manifest', env=env)
        with open(manifest) as f:
            data2 = json.load(f)
        
        assert data1['groups']['council']['port'] == data2['groups']['council']['port']
        assert data1['groups']['sandbox']['port'] == data2['groups']['sandbox']['port']


# =========================================================================
# Safeguard/E2E Unit Generation
# =========================================================================

class TestUnitGeneration:
    def test_safeguard_path_unit(self, tmp_path):
        env = make_agent_env([{'group': 'council', 'isolation': 'session'}])
        env['CONFIG_BASE'] = str(tmp_path / 'configs')
        os.makedirs(str(tmp_path / 'configs' / 'council'), exist_ok=True)
        
        out_dir = str(tmp_path / 'units')
        os.makedirs(out_dir, exist_ok=True)
        
        run_bash(
            f'generate_safeguard_units "council" "18790" "session" "{out_dir}"',
            env=env
        )
        
        path_unit = os.path.join(out_dir, 'openclaw-safeguard-council.path')
        assert os.path.exists(path_unit)
        content = open(path_unit).read()
        assert 'PathExists=/var/lib/init-status/unhealthy-council' in content

    def test_safeguard_service_uses_envfile(self, tmp_path):
        env = make_agent_env([{'group': 'council', 'isolation': 'session'}])
        env['CONFIG_BASE'] = str(tmp_path / 'configs')
        os.makedirs(str(tmp_path / 'configs' / 'council'), exist_ok=True)
        
        out_dir = str(tmp_path / 'units')
        os.makedirs(out_dir, exist_ok=True)
        
        run_bash(
            f'generate_safeguard_units "council" "18790" "session" "{out_dir}"',
            env=env
        )
        
        svc = os.path.join(out_dir, 'openclaw-safeguard-council.service')
        content = open(svc).read()
        assert 'EnvironmentFile=' in content
        assert 'group.env' in content
        # Should NOT have hardcoded Environment=GROUP=
        assert 'Environment=GROUP=' not in content

    def test_e2e_unit_uses_envfile(self, tmp_path):
        env = make_agent_env([{'group': 'sandbox', 'isolation': 'container'}])
        env['CONFIG_BASE'] = str(tmp_path / 'configs')
        os.makedirs(str(tmp_path / 'configs' / 'sandbox'), exist_ok=True)
        
        out_dir = str(tmp_path / 'units')
        os.makedirs(out_dir, exist_ok=True)
        
        run_bash(
            f'generate_e2e_unit "sandbox" "18791" "container" "{out_dir}"',
            env=env
        )
        
        svc = os.path.join(out_dir, 'openclaw-e2e-sandbox.service')
        content = open(svc).read()
        assert 'EnvironmentFile=' in content
        assert 'gateway-e2e-check.sh' in content


# =========================================================================
# Syntax Check
# =========================================================================

class TestSyntax:
    def test_bash_n_passes(self):
        result = subprocess.run(
            ['bash', '-n', LIB_PATH],
            capture_output=True, text=True
        )
        assert result.returncode == 0, f"bash -n failed: {result.stderr}"
