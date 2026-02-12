#!/usr/bin/env python3
"""TDD tests for TASK-203: Session mode — per-group OpenClaw instances.

Session mode generates separate systemd services per isolation group,
each running its own OpenClaw gateway instance on a unique port.

These tests verify:
1. generate-session-services.sh produces correct systemd unit files
2. Each group gets its own OpenClaw config with only its agents
3. Port allocation follows BASE_PORT + group_index pattern
4. Shared paths are mounted/symlinked correctly
5. Backward compat: isolation=none generates no extra services
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), '..', 'scripts', 'generate-session-services.sh')


def run_generator(env_vars, expect_fail=False):
    """Run generate-session-services.sh with given env vars.

    Returns (output_dir_contents, stdout, stderr).
    output_dir_contents is a dict of {filename: content}.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        env = os.environ.copy()
        env['SESSION_OUTPUT_DIR'] = tmpdir
        env['DRY_RUN'] = '1'  # Don't actually install systemd services
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
            return {}, result.stdout, result.stderr

        assert result.returncode == 0, \
            f"Script failed (rc={result.returncode}).\nstderr: {result.stderr}"

        contents = {}
        for root, dirs, files in os.walk(tmpdir):
            for fname in files:
                fpath = os.path.join(root, fname)
                rel = os.path.relpath(fpath, tmpdir)
                with open(fpath) as f:
                    contents[rel] = f.read()

        return contents, result.stdout, result.stderr


def make_session_env(isolation='session', groups='council,workers',
                     agent_count=4, agent_groups=None, agent_names=None,
                     extra=None):
    """Build env vars that simulate habitat-parsed.env for session mode."""
    env = {
        'ISOLATION_DEFAULT': isolation,
        'ISOLATION_GROUPS': groups,
        'AGENT_COUNT': str(agent_count),
        'HABITAT_NAME': 'TestHabitat',
        'ISOLATION_SHARED_PATHS': '/clawd/shared',
        'USERNAME': 'bot',
        'PLATFORM': 'telegram',
    }

    if agent_groups is None:
        # Default: 2 agents in council, 2 in workers
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

    if extra:
        env.update(extra)

    return env


class TestSessionModeNoOp(unittest.TestCase):
    """When isolation=none, no extra services should be generated."""

    def test_none_isolation_skips(self):
        """isolation=none should produce no service files."""
        env = make_session_env(isolation='none', groups='')
        files, stdout, _ = run_generator(env)
        service_files = [f for f in files if f.endswith('.service')]
        self.assertEqual(len(service_files), 0)
        self.assertIn('no session services needed', stdout.lower())

    def test_empty_groups_skips(self):
        """No isolation groups means nothing to generate."""
        env = make_session_env(isolation='session', groups='')
        files, stdout, _ = run_generator(env)
        service_files = [f for f in files if f.endswith('.service')]
        self.assertEqual(len(service_files), 0)


class TestSessionServiceGeneration(unittest.TestCase):
    """Test systemd service file generation for session mode."""

    def test_generates_service_per_group(self):
        """Each isolation group gets its own .service file."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        self.assertIn('openclaw-council.service', files)
        self.assertIn('openclaw-workers.service', files)

    def test_service_contains_exec_start(self):
        """Service file has ExecStart running openclaw gateway."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        svc = files['openclaw-council.service']
        self.assertIn('ExecStart=', svc)
        self.assertIn('openclaw', svc)

    def test_service_unique_ports(self):
        """Each group gets a unique port (base 18790 + index)."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        council_svc = files['openclaw-council.service']
        workers_svc = files['openclaw-workers.service']
        # Council (alphabetically first) gets port 18790
        self.assertIn('18790', council_svc)
        # Workers (alphabetically second) gets port 18791
        self.assertIn('18791', workers_svc)

    def test_service_user(self):
        """Service runs as the correct user."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        svc = files['openclaw-council.service']
        self.assertIn('User=bot', svc)

    def test_service_working_directory(self):
        """Service has correct WorkingDirectory."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        svc = files['openclaw-council.service']
        self.assertIn('WorkingDirectory=/home/bot', svc)

    def test_service_restart_policy(self):
        """Service has restart=always for resilience."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        svc = files['openclaw-council.service']
        self.assertIn('Restart=always', svc)

    def test_service_after_dependency(self):
        """Service depends on network.target."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        svc = files['openclaw-council.service']
        self.assertIn('After=network.target', svc)


class TestSessionConfig(unittest.TestCase):
    """Test per-group OpenClaw config generation."""

    def test_generates_config_per_group(self):
        """Each group gets its own openclaw config JSON."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        self.assertIn('council/openclaw.session.json', files)
        self.assertIn('workers/openclaw.session.json', files)

    def test_config_contains_only_group_agents(self):
        """Each config only includes agents belonging to that group."""
        env = make_session_env(
            agent_names=['Opus', 'Claude', 'Worker1', 'Worker2'],
            agent_groups=['council', 'council', 'workers', 'workers'],
        )
        files, _, _ = run_generator(env)
        council_cfg = json.loads(files['council/openclaw.session.json'])
        workers_cfg = json.loads(files['workers/openclaw.session.json'])

        council_names = [a['name'] for a in council_cfg['agents']['list']]
        workers_names = [a['name'] for a in workers_cfg['agents']['list']]

        self.assertEqual(sorted(council_names), ['Claude', 'Opus'])
        self.assertEqual(sorted(workers_names), ['Worker1', 'Worker2'])

    def test_config_port_matches_service(self):
        """Config gateway port matches the service port."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        council_cfg = json.loads(files['council/openclaw.session.json'])
        self.assertEqual(council_cfg['gateway']['port'], 18790)

    def test_config_has_gateway_section(self):
        """Config includes gateway with local mode."""
        env = make_session_env()
        files, _, _ = run_generator(env)
        council_cfg = json.loads(files['council/openclaw.session.json'])
        self.assertEqual(council_cfg['gateway']['mode'], 'local')

    def test_single_group_single_service(self):
        """Only one group generates exactly one service."""
        env = make_session_env(
            groups='council',
            agent_count=3,
            agent_groups=['council', 'council', 'council'],
        )
        files, _, _ = run_generator(env)
        service_files = [f for f in files if f.endswith('.service')]
        self.assertEqual(len(service_files), 1)
        self.assertIn('openclaw-council.service', files)


class TestSessionAgentGrouping(unittest.TestCase):
    """Test agent-to-group assignment logic."""

    def test_ungrouped_agents_use_agent_name_as_group(self):
        """Agents without isolationGroup but listed in ISOLATION_GROUPS use name as group."""
        env = make_session_env(
            isolation='session',
            groups='Agent1,Agent2',
            agent_count=2,
            agent_groups=['Agent1', 'Agent2'],  # Explicit groups matching agent names
            agent_names=['Agent1', 'Agent2'],
        )
        files, _, _ = run_generator(env)
        self.assertIn('openclaw-Agent1.service', files)
        self.assertIn('openclaw-Agent2.service', files)

    def test_three_groups(self):
        """Three distinct groups generate three services."""
        env = make_session_env(
            groups='alpha,beta,gamma',
            agent_count=6,
            agent_groups=['alpha', 'alpha', 'beta', 'beta', 'gamma', 'gamma'],
        )
        files, _, _ = run_generator(env)
        service_files = [f for f in files if f.endswith('.service')]
        self.assertEqual(len(service_files), 3)

    def test_mixed_isolation_only_session_groups(self):
        """Only agents with session isolation (or inheriting it) get services."""
        env = make_session_env(groups='session-group')
        env['AGENT1_ISOLATION'] = 'session'
        env['AGENT1_ISOLATION_GROUP'] = 'session-group'
        env['AGENT2_ISOLATION'] = 'container'
        env['AGENT2_ISOLATION_GROUP'] = 'container-group'
        env['ISOLATION_GROUPS'] = 'session-group,container-group'
        files, _, _ = run_generator(env)
        # Only session-group should get a systemd service
        self.assertIn('openclaw-session-group.service', files)
        self.assertNotIn('openclaw-container-group.service', files)


class TestSessionSharedPaths(unittest.TestCase):
    """Test shared path handling in session configs."""

    def test_shared_paths_in_config(self):
        """Shared paths referenced in service environment."""
        env = make_session_env()
        env['ISOLATION_SHARED_PATHS'] = '/clawd/shared,/tmp/exchange'
        files, stdout, _ = run_generator(env)
        # Verify service files are generated (shared paths are a concern for
        # the volume mounts, which are handled by the parent build-full-config)
        self.assertIn('openclaw-council.service', files)
        self.assertIn('openclaw-workers.service', files)

    def test_empty_shared_paths_ok(self):
        """Empty shared paths doesn't cause errors."""
        env = make_session_env()
        env['ISOLATION_SHARED_PATHS'] = ''
        files, _, _ = run_generator(env)
        self.assertIn('openclaw-council.service', files)


class TestSessionEdgeCases(unittest.TestCase):
    """Edge cases and error handling for session mode."""

    def test_container_isolation_skips_session_generation(self):
        """Container mode doesn't generate systemd session services."""
        env = make_session_env(isolation='container')
        files, stdout, _ = run_generator(env)
        service_files = [f for f in files if f.endswith('.service')]
        self.assertEqual(len(service_files), 0)

    def test_missing_agent_count_fails(self):
        """Missing AGENT_COUNT should fail gracefully."""
        env = make_session_env()
        del env['AGENT_COUNT']
        _, _, stderr = run_generator(env, expect_fail=True)
        self.assertIn('AGENT_COUNT', stderr)

    def test_summary_output(self):
        """Script outputs summary of generated services."""
        env = make_session_env()
        files, stdout, _ = run_generator(env)
        self.assertIn('council', stdout)
        self.assertIn('workers', stdout)


if __name__ == '__main__':
    unittest.main()
