#!/usr/bin/env python3
"""TDD tests for TASK-204: Container mode — Docker Compose generation.

Container mode generates a docker-compose.yaml when isolation is 'container',
with one service per isolation group, proper volume mounts for shared paths,
network modes, and resource limits.

These tests verify:
1. docker-compose.yaml is generated with correct structure
2. One service per isolation group
3. sharedPaths mapped as volumes
4. Network mode per service (host, internal, none)
5. Resource limits (memory, cpu) applied
6. No generation for non-container modes
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

import yaml  # PyYAML — if not available, tests will skip

SCRIPT = os.path.join(os.path.dirname(__file__), '..', 'scripts', 'generate-docker-compose.sh')


def run_generator(env_vars, expect_fail=False):
    """Run generate-docker-compose.sh with given env vars.

    Returns (compose_dict, all_files, stdout, stderr).
    compose_dict is the parsed docker-compose.yaml (or {} on failure).
    all_files is a dict of {filename: content}.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        env = os.environ.copy()
        env['COMPOSE_OUTPUT_DIR'] = tmpdir
        env['DRY_RUN'] = '1'
        env.update(env_vars)

        result = subprocess.run(
            ['bash', SCRIPT],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

        if expect_fail:
            assert result.returncode != 0, \
                f"Expected failure but got rc=0.\nstdout: {result.stdout}\nstderr: {result.stderr}"
            return {}, {}, result.stdout, result.stderr

        assert result.returncode == 0, \
            f"Script failed (rc={result.returncode}).\nstderr: {result.stderr}"

        all_files = {}
        for root, dirs, files in os.walk(tmpdir):
            for fname in files:
                fpath = os.path.join(root, fname)
                rel = os.path.relpath(fpath, tmpdir)
                with open(fpath) as f:
                    all_files[rel] = f.read()

        compose_path = os.path.join(tmpdir, 'docker-compose.yaml')
        compose_dict = {}
        if os.path.exists(compose_path):
            with open(compose_path) as f:
                compose_dict = yaml.safe_load(f)

        return compose_dict, all_files, result.stdout, result.stderr


def make_container_env(isolation='container', groups='council,workers',
                       agent_count=4, agent_groups=None, agent_names=None,
                       shared_paths='/clawd/shared', extra=None):
    """Build env vars that simulate habitat-parsed.env for container mode."""
    env = {
        'ISOLATION_DEFAULT': isolation,
        'ISOLATION_GROUPS': groups,
        'AGENT_COUNT': str(agent_count),
        'HABITAT_NAME': 'TestHabitat',
        'ISOLATION_SHARED_PATHS': shared_paths,
        'USERNAME': 'bot',
        'PLATFORM': 'telegram',
    }

    if agent_groups is None:
        agent_groups = ['council', 'council', 'workers', 'workers']
    if agent_names is None:
        agent_names = [f'Agent{i+1}' for i in range(agent_count)]

    for i in range(agent_count):
        n = i + 1
        env[f'AGENT{n}_NAME'] = agent_names[i] if i < len(agent_names) else f'Agent{n}'
        env[f'AGENT{n}_ISOLATION_GROUP'] = agent_groups[i] if i < len(agent_groups) else ''
        env[f'AGENT{n}_ISOLATION'] = ''
        env[f'AGENT{n}_MODEL'] = 'anthropic/claude-opus-4-5'
        env[f'AGENT{n}_BOT_TOKEN'] = f'tok{n}'
        env[f'AGENT{n}_NETWORK'] = ''
        env[f'AGENT{n}_RESOURCES_MEMORY'] = ''
        env[f'AGENT{n}_RESOURCES_CPU'] = ''
        env[f'AGENT{n}_CAPABILITIES'] = ''

    if extra:
        env.update(extra)

    return env


# Check if PyYAML is available
try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestContainerModeNoOp(unittest.TestCase):
    """When isolation is not container, nothing should be generated."""

    def test_none_isolation_skips(self):
        """isolation=none should produce no docker-compose."""
        env = make_container_env(isolation='none', groups='')
        compose, files, stdout, _ = run_generator(env)
        self.assertEqual(compose, {})
        self.assertIn('no docker-compose', stdout.lower())

    def test_session_isolation_skips(self):
        """isolation=session should produce no docker-compose."""
        env = make_container_env(isolation='session')
        compose, files, stdout, _ = run_generator(env)
        self.assertEqual(compose, {})

    def test_empty_groups_skips(self):
        """No isolation groups means nothing to generate."""
        env = make_container_env(isolation='container', groups='')
        compose, files, stdout, _ = run_generator(env)
        self.assertEqual(compose, {})


@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestDockerComposeStructure(unittest.TestCase):
    """Test the generated docker-compose.yaml structure."""

    def test_generates_compose_file(self):
        """docker-compose.yaml is created."""
        env = make_container_env()
        compose, files, _, _ = run_generator(env)
        self.assertIn('docker-compose.yaml', files)

    def test_compose_has_services(self):
        """Compose file has a services section."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        self.assertIn('services', compose)

    def test_one_service_per_group(self):
        """Each isolation group gets its own service."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        self.assertIn('council', compose['services'])
        self.assertIn('workers', compose['services'])

    def test_service_image(self):
        """Each service uses the correct base image."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        self.assertEqual(svc['image'], 'hatchery/agent:latest')

    def test_custom_image(self):
        """Custom image can be set via CONTAINER_IMAGE env var."""
        env = make_container_env(extra={'CONTAINER_IMAGE': 'myregistry/agent:v2'})
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        self.assertEqual(svc['image'], 'myregistry/agent:v2')

    def test_compose_no_version(self):
        """Compose file must not contain deprecated version field."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        self.assertNotIn('version', compose)

@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestDockerComposeVolumes(unittest.TestCase):
    """Test volume mounts in generated docker-compose."""

    def test_shared_paths_mounted(self):
        """sharedPaths are mounted as volumes in each service."""
        env = make_container_env(shared_paths='/clawd/shared')
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        volumes = svc.get('volumes', [])
        shared_vols = [v for v in volumes if '/clawd/shared' in str(v)]
        self.assertTrue(len(shared_vols) > 0, f"No /clawd/shared volume found in {volumes}")

    def test_multiple_shared_paths(self):
        """Multiple shared paths each get mounted."""
        env = make_container_env(shared_paths='/clawd/shared,/tmp/exchange')
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        volumes = svc.get('volumes', [])
        vol_str = str(volumes)
        self.assertIn('/clawd/shared', vol_str)
        self.assertIn('/tmp/exchange', vol_str)

    def test_openclaw_config_volume(self):
        """Each service mounts its OpenClaw config directory."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        volumes = svc.get('volumes', [])
        config_vols = [v for v in volumes if '.openclaw' in str(v) or 'config' in str(v)]
        self.assertTrue(len(config_vols) > 0, f"No config volume found in {volumes}")

    def test_no_shared_paths_still_has_config_volume(self):
        """Even with no shared paths, config volume is present."""
        env = make_container_env(shared_paths='')
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        volumes = svc.get('volumes', [])
        self.assertTrue(len(volumes) > 0)


@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestDockerComposeNetwork(unittest.TestCase):
    """Test network mode configuration."""

    def test_default_network_host(self):
        """Default network mode is host."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        self.assertEqual(svc.get('network_mode'), 'host')

    def test_network_none(self):
        """network=none sets network_mode: none."""
        env = make_container_env(
            groups='sandbox',
            agent_count=1,
            agent_groups=['sandbox'],
        )
        env['AGENT1_NETWORK'] = 'none'
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['sandbox']
        self.assertEqual(svc.get('network_mode'), 'none')

    def test_network_internal(self):
        """network=internal creates a custom bridge network."""
        env = make_container_env(
            groups='sandbox',
            agent_count=1,
            agent_groups=['sandbox'],
        )
        env['AGENT1_NETWORK'] = 'internal'
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['sandbox']
        # Internal uses custom network, not network_mode
        networks = svc.get('networks', [])
        self.assertTrue(len(networks) > 0 or 'network_mode' not in svc,
                        "Internal network should use networks, not network_mode")

    def test_mixed_network_modes(self):
        """Different groups can have different network modes."""
        env = make_container_env(
            groups='trusted,sandbox',
            agent_count=2,
            agent_groups=['trusted', 'sandbox'],
            agent_names=['Admin', 'Runner'],
        )
        env['AGENT1_NETWORK'] = 'host'
        env['AGENT2_NETWORK'] = 'none'
        compose, _, _, _ = run_generator(env)
        self.assertEqual(compose['services']['trusted'].get('network_mode'), 'host')
        self.assertEqual(compose['services']['sandbox'].get('network_mode'), 'none')


@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestDockerComposeResources(unittest.TestCase):
    """Test resource limits in generated docker-compose."""

    def test_memory_limit(self):
        """Memory limit is applied via mem_limit."""
        env = make_container_env(
            groups='sandbox',
            agent_count=1,
            agent_groups=['sandbox'],
        )
        env['AGENT1_RESOURCES_MEMORY'] = '512Mi'
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['sandbox']
        self.assertEqual(svc.get('mem_limit'), '512Mi')

    def test_cpu_limit(self):
        """CPU limit is applied."""
        env = make_container_env(
            groups='sandbox',
            agent_count=1,
            agent_groups=['sandbox'],
        )
        env['AGENT1_RESOURCES_CPU'] = '2.0'
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['sandbox']
        # cpus is the docker-compose v3 way
        self.assertEqual(str(svc.get('cpus', '')), '2.0')

    def test_no_limits_omits_fields(self):
        """Without resource limits, mem_limit/cpus are omitted."""
        env = make_container_env()
        compose, _, _, _ = run_generator(env)
        svc = compose['services']['council']
        self.assertNotIn('mem_limit', svc)
        self.assertNotIn('cpus', svc)


@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestDockerComposeAgents(unittest.TestCase):
    """Test agent assignment in docker-compose services."""

    def test_agent_names_in_environment(self):
        """Agent names are listed in service environment."""
        env = make_container_env(
            agent_names=['Opus', 'Claude', 'Worker1', 'Worker2'],
            agent_groups=['council', 'council', 'workers', 'workers'],
        )
        compose, _, _, _ = run_generator(env)
        council_svc = compose['services']['council']
        env_list = council_svc.get('environment', [])
        # Find AGENT_NAMES entry
        agent_names_entry = [e for e in env_list if 'AGENT_NAMES' in str(e)]
        self.assertTrue(len(agent_names_entry) > 0)
        names_str = str(agent_names_entry[0])
        self.assertIn('Opus', names_str)
        self.assertIn('Claude', names_str)
        self.assertNotIn('Worker1', names_str)

    def test_three_groups(self):
        """Three groups generate three services."""
        env = make_container_env(
            groups='alpha,beta,gamma',
            agent_count=6,
            agent_groups=['alpha', 'alpha', 'beta', 'beta', 'gamma', 'gamma'],
        )
        compose, _, _, _ = run_generator(env)
        self.assertEqual(len(compose['services']), 3)

    def test_single_group(self):
        """Single group generates one service."""
        env = make_container_env(
            groups='all',
            agent_count=3,
            agent_groups=['all', 'all', 'all'],
        )
        compose, _, _, _ = run_generator(env)
        self.assertEqual(len(compose['services']), 1)
        self.assertIn('all', compose['services'])


@unittest.skipUnless(HAS_YAML, "PyYAML required for docker-compose tests")
class TestDockerComposeEdgeCases(unittest.TestCase):
    """Edge cases for docker-compose generation."""

    def test_missing_agent_count_fails(self):
        """Missing AGENT_COUNT should fail gracefully."""
        env = make_container_env()
        del env['AGENT_COUNT']
        _, _, _, stderr = run_generator(env, expect_fail=True)
        self.assertIn('AGENT_COUNT', stderr)

    def test_summary_output(self):
        """Script outputs summary of generated compose file."""
        env = make_container_env()
        _, _, stdout, _ = run_generator(env)
        self.assertIn('council', stdout)
        self.assertIn('workers', stdout)

    def test_only_container_groups_included(self):
        """Only groups with container isolation get compose services."""
        env = make_container_env(groups='containers,sessions')
        env['AGENT1_ISOLATION'] = 'container'
        env['AGENT1_ISOLATION_GROUP'] = 'containers'
        env['AGENT2_ISOLATION'] = 'session'
        env['AGENT2_ISOLATION_GROUP'] = 'sessions'
        env['AGENT3_ISOLATION'] = 'container'
        env['AGENT3_ISOLATION_GROUP'] = 'containers'
        env['AGENT4_ISOLATION'] = 'session'
        env['AGENT4_ISOLATION_GROUP'] = 'sessions'
        compose, _, _, _ = run_generator(env)
        self.assertIn('containers', compose.get('services', {}))
        self.assertNotIn('sessions', compose.get('services', {}))


if __name__ == '__main__':
    unittest.main()
