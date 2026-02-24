"""Tests for generate-docker-compose.sh — Option A container isolation.

Tests verify:
- Per-group compose files (not monolithic)
- Correct volume mounts (no host scripts/state/logs)
- env_file usage (not inline secrets)
- Proper command (gateway flags, no bash wrapper)
- Container systemd wrapper unit
- Network modes (host, isolated)
- Resource limits
- Manifest-driven (reads from /etc/openclaw-groups.json)
"""
import subprocess
import json
import os
import pytest
import yaml

SCRIPT_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')
COMPOSE_SCRIPT = os.path.join(SCRIPT_DIR, 'generate-docker-compose.sh')


def run_generator(tmp_path, groups, extra_env=None):
    """Run the compose generator with test fixtures.
    
    groups: dict of group_name → config dict with keys:
        port, agents, network, memory, cpu, isolation
    """
    home = str(tmp_path / 'home' / 'bot')
    manifest_path = str(tmp_path / 'groups.json')
    unit_dir = str(tmp_path / 'units')
    compose_base = os.path.join(home, '.openclaw', 'compose')
    
    # Build manifest
    manifest = {"generated": "2026-02-24T09:00:00Z", "groups": {}}
    for name, cfg in groups.items():
        manifest["groups"][name] = {
            "isolation": cfg.get("isolation", "container"),
            "port": cfg.get("port", 18790),
            "network": cfg.get("network", "host"),
            "agents": cfg.get("agents", ["agent1"]),
            "configPath": f"{home}/.openclaw/configs/{name}/openclaw.session.json",
            "statePath": f"{home}/.openclaw-sessions/{name}",
            "envFile": f"{home}/.openclaw/configs/{name}/group.env",
            "serviceName": f"openclaw-container-{name}",
            "composePath": f"{home}/.openclaw/compose/{name}/docker-compose.yaml",
        }
    
    os.makedirs(compose_base, exist_ok=True)
    os.makedirs(unit_dir, exist_ok=True)
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f)
    
    # Build agent env vars
    env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': home,
        'MANIFEST': manifest_path,
        'ISOLATION_DEFAULT': 'container',
        'ISOLATION_GROUPS': ','.join(groups.keys()),
        'USERNAME': 'bot',
        'HOME_DIR': home,
        'HABITAT_NAME': 'test',
        'CONTAINER_IMAGE': 'hatchery/agent:latest',
        'COMPOSE_SYSTEMD_DIR': unit_dir,
        'UNIT_OUTPUT_DIR': unit_dir,
        'DRY_RUN': '1',
        'BOT_UID': '1000',
        'BOT_GID': '1000',
    }
    
    agent_idx = 1
    for gname, gcfg in groups.items():
        for aid in gcfg.get('agents', ['agent1']):
            env[f'AGENT{agent_idx}_ISOLATION_GROUP'] = gname
            env[f'AGENT{agent_idx}_ISOLATION'] = gcfg.get('isolation', 'container')
            env[f'AGENT{agent_idx}_NETWORK'] = gcfg.get('network', 'host')
            env[f'AGENT{agent_idx}_RESOURCES_MEMORY'] = gcfg.get('memory', '')
            env[f'AGENT{agent_idx}_RESOURCES_CPU'] = gcfg.get('cpu', '')
            env[f'AGENT{agent_idx}_NAME'] = aid
            agent_idx += 1
    env['AGENT_COUNT'] = str(agent_idx - 1)
    
    if extra_env:
        env.update(extra_env)
    
    result = subprocess.run(['bash', COMPOSE_SCRIPT], capture_output=True, text=True, env=env)
    return result, compose_base, unit_dir, home


def get_svc(compose_dir, group):
    """Load the compose file and return the first (only) service."""
    path = os.path.join(compose_dir, group, 'docker-compose.yaml')
    with open(path) as f:
        data = yaml.safe_load(f)
    svc_name = f'openclaw-{group}'
    return data, data['services'][svc_name]


def get_unit(unit_dir, group):
    """Load the systemd unit file as text."""
    path = os.path.join(unit_dir, f'openclaw-container-{group}.service')
    with open(path) as f:
        return f.read()


# =========================================================================
# Basic Generation
# =========================================================================

class TestBasicGeneration:
    def test_generates_compose_file(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        assert r.returncode == 0, f"stderr: {r.stderr}"
        assert os.path.exists(os.path.join(cd, 'sandbox', 'docker-compose.yaml'))

    def test_generates_systemd_unit(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        assert r.returncode == 0
        assert os.path.exists(os.path.join(ud, 'openclaw-container-sandbox.service'))

    def test_per_group_compose_files(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {
            'council': {'port': 18790, 'agents': ['agent1']},
            'sandbox': {'port': 18791, 'agents': ['agent2']},
        })
        assert r.returncode == 0
        assert os.path.exists(os.path.join(cd, 'council', 'docker-compose.yaml'))
        assert os.path.exists(os.path.join(cd, 'sandbox', 'docker-compose.yaml'))

    def test_skips_non_container_mode(self, tmp_path):
        mp = str(tmp_path / 'groups.json')
        with open(mp, 'w') as f:
            json.dump({"groups": {}}, f)
        env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'MANIFEST': mp,
            'ISOLATION_DEFAULT': 'session',
            'ISOLATION_GROUPS': 'council',
            'AGENT_COUNT': '1',
            'USERNAME': 'bot',
            'DRY_RUN': '1',
            'AGENT1_ISOLATION_GROUP': 'council',
            'AGENT1_ISOLATION': 'session',
        }
        r = subprocess.run(['bash', COMPOSE_SCRIPT], capture_output=True, text=True, env=env)
        assert r.returncode == 0
        assert 'no docker-compose needed' in r.stdout.lower()


# =========================================================================
# Volume Mounts (Option A)
# =========================================================================

class TestVolumeMounts:
    def test_config_mount_readonly(self, tmp_path):
        r, cd, _, h = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        config_vols = [v for v in svc['volumes'] if 'openclaw.json:ro' in v]
        assert len(config_vols) == 1

    def test_token_mount_readonly(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        token_vols = [v for v in svc['volumes'] if 'gateway-token.txt' in v]
        assert len(token_vols) == 1
        assert ':ro' in token_vols[0]

    def test_state_dir_mount_rw(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        state_vols = [v for v in svc['volumes'] if 'openclaw-sessions' in v]
        assert len(state_vols) == 1
        assert ':rw' in state_vols[0]

    def test_agent_workspace_mounts(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'agents': ['agent1', 'agent3']}
        })
        _, svc = get_svc(cd, 'sandbox')
        ws_vols = [v for v in svc['volumes'] if '/clawd/agents/' in v]
        assert len(ws_vols) == 2
        assert any('agent1' in v for v in ws_vols)
        assert any('agent3' in v for v in ws_vols)

    def test_shared_workspace_mount(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        shared_vols = [v for v in svc['volumes'] if '/clawd/shared' in v]
        assert len(shared_vols) == 1

    def test_no_host_script_mounts(self, tmp_path):
        """Option A: no host scripts mounted into container."""
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        bad = [v for v in svc['volumes'] if any(x in v for x in [
            'gateway-health-check.sh', 'safe-mode-recovery.sh',
            'setup-safe-mode-workspace.sh', 'lib-permissions.sh',
            'droplet.env', 'habitat-parsed.env', 'init-status', '/var/log',
        ])]
        assert bad == [], f"Unexpected host mounts: {bad}"

    def test_additional_shared_paths(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}},
            extra_env={'ISOLATION_SHARED_PATHS': '/opt/tools,/data/models'})
        _, svc = get_svc(cd, 'sandbox')
        vols_str = str(svc['volumes'])
        assert '/opt/tools' in vols_str
        assert '/data/models' in vols_str


# =========================================================================
# Command / Entrypoint
# =========================================================================

class TestEntrypoint:
    def test_no_bash_wrapper(self, tmp_path):
        """Option A: no bash -c entrypoint override."""
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert 'entrypoint' not in svc
        cmd = svc.get('command', [])
        assert '--bind' in cmd
        assert 'loopback' in cmd

    def test_container_name(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert svc['container_name'] == 'openclaw-sandbox'


# =========================================================================
# Environment
# =========================================================================

class TestEnvironment:
    def test_uses_env_file(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert 'env_file' in svc
        assert any('group.env' in f for f in svc['env_file'])

    def test_no_inline_secrets(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        env_str = str(svc.get('environment', []))
        for key in ['ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'BRAVE_API_KEY']:
            assert key not in env_str


# =========================================================================
# Network Modes
# =========================================================================

class TestNetworkModes:
    def test_host_network(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'network': 'host'}
        })
        _, svc = get_svc(cd, 'sandbox')
        assert svc.get('network_mode') == 'host'
        assert 'networks' not in svc

    def test_isolated_network(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'network': 'isolated'}
        })
        data, svc = get_svc(cd, 'sandbox')
        assert 'networks' in svc
        # Verify network definition has internal: true
        nets = data.get('networks', {})
        net_name = list(svc['networks'])[0] if isinstance(svc['networks'], list) else list(svc['networks'].keys())[0]
        assert nets[net_name].get('internal') is True


# =========================================================================
# Resource Limits
# =========================================================================

class TestResourceLimits:
    def test_memory_limit(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'memory': '512m'}
        })
        _, svc = get_svc(cd, 'sandbox')
        assert svc.get('mem_limit') == '512m'

    def test_cpu_limit(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'cpu': '0.5'}
        })
        _, svc = get_svc(cd, 'sandbox')
        # YAML may parse "0.5" as float
        assert float(svc.get('cpus', 0)) == 0.5

    def test_no_limits_when_unset(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert 'mem_limit' not in svc
        assert 'cpus' not in svc


# =========================================================================
# Health Check
# =========================================================================

class TestHealthCheck:
    def test_healthcheck_present(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        hc = svc.get('healthcheck', {})
        assert 'test' in hc
        assert '18790' in str(hc['test'])


# =========================================================================
# Systemd Wrapper Unit
# =========================================================================

class TestSystemdUnit:
    def test_unit_type_oneshot(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        u = get_unit(ud, 'sandbox')
        assert 'Type=oneshot' in u
        assert 'RemainAfterExit=yes' in u

    def test_unit_requires_docker(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        assert 'Requires=docker.service' in get_unit(ud, 'sandbox')

    def test_unit_user_root(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        assert 'User=root' in get_unit(ud, 'sandbox')

    def test_unit_exec_start(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        u = get_unit(ud, 'sandbox')
        assert 'docker compose' in u
        assert 'up -d --wait' in u

    def test_unit_exec_stop(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        assert 'down' in get_unit(ud, 'sandbox')

    def test_unit_health_check_post(self, tmp_path):
        r, _, ud, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        u = get_unit(ud, 'sandbox')
        assert 'ExecStartPost' in u
        assert 'gateway-health-check.sh' in u


# =========================================================================
# Network Isolation (Phase 6)
# =========================================================================

class TestNetworkIsolation:
    """Phase 6: Isolated network gets port mapping and no DNS."""

    def test_isolated_has_port_mapping(self, tmp_path):
        """Isolated network must map port so host health check can reach gateway."""
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'network': 'isolated'}
        })
        _, svc = get_svc(cd, 'sandbox')
        ports = svc.get('ports', [])
        assert len(ports) >= 1, f"Isolated network needs port mapping: {svc}"
        assert '18790:18790' in str(ports[0]), f"Port mapping wrong: {ports}"

    def test_isolated_has_no_dns(self, tmp_path):
        """Isolated containers should have empty DNS to prevent resolution."""
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'network': 'isolated'}
        })
        _, svc = get_svc(cd, 'sandbox')
        dns = svc.get('dns', None)
        assert dns == [], f"Isolated network should have dns: []: {dns}"

    def test_host_has_no_port_mapping(self, tmp_path):
        """Host network doesn't need port mapping."""
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'network': 'host'}
        })
        _, svc = get_svc(cd, 'sandbox')
        assert 'ports' not in svc


# =========================================================================
# Security Hardening (Phase 7)
# =========================================================================

class TestSecurityHardening:
    """Phase 7: cap_drop, security_opt, read_only, tmpfs, pids_limit."""

    def test_cap_drop_all(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert svc.get('cap_drop') == ['ALL'], \
            f"Should drop all capabilities: {svc.get('cap_drop')}"

    def test_no_new_privileges(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        sec_opt = svc.get('security_opt', [])
        assert 'no-new-privileges:true' in sec_opt, \
            f"Should have no-new-privileges: {sec_opt}"

    def test_read_only_rootfs(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert svc.get('read_only') is True, \
            f"Should have read_only: true: {svc.get('read_only')}"

    def test_tmpfs_mounts(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        tmpfs = svc.get('tmpfs', [])
        assert any('/tmp' in str(t) for t in tmpfs), f"Missing /tmp tmpfs: {tmpfs}"
        assert any('/run' in str(t) for t in tmpfs), f"Missing /run tmpfs: {tmpfs}"

    def test_pids_limit(self, tmp_path):
        r, cd, _, _ = run_generator(tmp_path, {'sandbox': {'port': 18790}})
        _, svc = get_svc(cd, 'sandbox')
        assert svc.get('pids_limit') == 256, \
            f"pids_limit should be 256: {svc.get('pids_limit')}"

    def test_memswap_equals_mem_limit(self, tmp_path):
        """memswap_limit should equal mem_limit to prevent swap."""
        r, cd, _, _ = run_generator(tmp_path, {
            'sandbox': {'port': 18790, 'memory': '1g'}
        })
        _, svc = get_svc(cd, 'sandbox')
        assert svc.get('mem_limit') == '1g'
        assert svc.get('memswap_limit') == '1g', \
            f"memswap_limit should match mem_limit: {svc.get('memswap_limit')}"


# =========================================================================
# Syntax
# =========================================================================

class TestSyntax:
    def test_bash_n_passes(self):
        r = subprocess.run(['bash', '-n', COMPOSE_SCRIPT], capture_output=True, text=True)
        assert r.returncode == 0, f"bash -n failed: {r.stderr}"
