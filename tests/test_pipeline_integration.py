#!/usr/bin/env python3
"""Tests for GitHub Issue #223: Pipeline integration of isolation scripts.

Verifies:
1. build-full-config.sh calls generate-session-services.sh for session mode
2. build-full-config.sh calls generate-docker-compose.sh for container mode
3. build-full-config.sh does NOT call isolation scripts for none mode
4. Session auth tokens are not predictable (Bug #224)
5. Docker Compose output omits deprecated version field (Bug #225)
"""

import json
import os
import subprocess
import tempfile
import unittest

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')
BUILD_SCRIPT = os.path.join(SCRIPTS_DIR, 'build-full-config.sh')
SESSION_SCRIPT = os.path.join(SCRIPTS_DIR, 'generate-session-services.sh')
COMPOSE_SCRIPT = os.path.join(SCRIPTS_DIR, 'generate-docker-compose.sh')

class TestBuildScriptContainsIsolationWiring(unittest.TestCase):
    """Static analysis: build-full-config.sh must reference the isolation scripts."""
    # Static analysis is used because the actual pipeline runs during droplet
    # provisioning with real systemctl/docker — these checks verify the wiring
    # exists without needing the full environment.

    def setUp(self):
        with open(BUILD_SCRIPT) as f:
            self.script_content = f.read()

    def test_references_session_script(self):
        """build-full-config.sh must call generate-session-services.sh."""
        self.assertIn('generate-session-services', self.script_content,
                      "build-full-config.sh must call generate-session-services.sh")

    def test_references_compose_script(self):
        """build-full-config.sh must call generate-docker-compose.sh."""
        self.assertIn('generate-docker-compose', self.script_content,
                      "build-full-config.sh must call generate-docker-compose.sh")

    def test_checks_isolation_default(self):
        """build-full-config.sh must check ISOLATION_DEFAULT before calling scripts."""
        self.assertIn('ISOLATION_DEFAULT', self.script_content,
                      "build-full-config.sh must reference ISOLATION_DEFAULT")

    def test_isolation_wiring_after_config_generation(self):
        """Isolation script calls must come after the main config is generated."""
        config_pos = self.script_content.find('openclaw.full.json')
        isolation_pos = self.script_content.find('generate-session-services')
        self.assertGreater(config_pos, -1, "openclaw.full.json not found")
        self.assertGreater(isolation_pos, -1, "generate-session-services not found")
        self.assertGreater(isolation_pos, config_pos,
                           "Isolation wiring must come after config generation")

    def test_isolation_none_does_not_force_call(self):
        """The wiring must be conditional, not unconditionally calling scripts."""
        lines = self.script_content.split('\n')
        found_conditional = False
        for i, line in enumerate(lines):
            if 'generate-session-services' in line or 'generate-docker-compose' in line:
                context = '\n'.join(lines[max(0, i-5):i+1])
                if 'if ' in context or 'case ' in context or '&&' in line:
                    found_conditional = True
                    break
        self.assertTrue(found_conditional,
                        "Isolation script calls must be wrapped in a conditional")


LIB_ISOLATION = os.path.join(SCRIPTS_DIR, 'lib-isolation.sh')


def _build_session_manifest_and_tokens(tmpdir):
    """Build a manifest and generate tokens for session groups using lib-isolation.sh."""
    home_dir = os.path.join(tmpdir, 'home', 'bot')
    manifest_path = os.path.join(tmpdir, 'groups.json')
    config_base = os.path.join(home_dir, '.openclaw', 'configs')
    os.makedirs(config_base, exist_ok=True)
    for grp in ('council', 'workers'):
        os.makedirs(os.path.join(config_base, grp), exist_ok=True)

    env = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': home_dir,
        'MANIFEST': manifest_path,
        'HOME_DIR': home_dir,
        'ISOLATION_DEFAULT': 'session',
        'ISOLATION_GROUPS': 'council,workers',
        'AGENT_COUNT': '4',
        'USERNAME': 'bot',
        'SVC_USER': 'bot',
    }
    for i in range(4):
        n = i + 1
        grp = 'council' if i < 2 else 'workers'
        env[f'AGENT{n}_NAME'] = f'Agent{n}'
        env[f'AGENT{n}_ISOLATION_GROUP'] = grp
        env[f'AGENT{n}_ISOLATION'] = 'session'
        env[f'AGENT{n}_NETWORK'] = 'host'
        env[f'AGENT{n}_RESOURCES_MEMORY'] = ''
        env[f'AGENT{n}_RESOURCES_CPU'] = ''

    # Generate manifest + tokens using lib-isolation.sh
    script = f"""
set -euo pipefail
source "{LIB_ISOLATION}"
generate_groups_manifest
for grp in council workers; do
    generate_group_token "$grp"
done
"""
    result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, env=env)
    assert result.returncode == 0, f"Manifest generation failed: {result.stderr}"

    # Read generated tokens
    tokens = {}
    for grp in ('council', 'workers'):
        token_file = os.path.join(config_base, grp, 'gateway-token.txt')
        if os.path.exists(token_file):
            with open(token_file) as f:
                tokens[grp] = f.read().strip()
    return tokens


class TestSessionAuthTokenNotPredictable(unittest.TestCase):
    """Bug #224: Session mode must not use predictable auth tokens.
    
    Post-refactor: tokens are generated by lib-isolation.sh's generate_group_token(),
    not by the thin generator. Tests verify the token generation contract directly.
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.tokens = _build_session_manifest_and_tokens(self.tmpdir)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_token_not_predictable_prefix(self):
        """Auth token must not be session-groupname pattern."""
        for group, token in self.tokens.items():
            self.assertFalse(token.startswith("session-"),
                             f"Token for {group} is predictable: {token}")

    def test_tokens_differ_between_groups(self):
        """Each group must get a unique auth token."""
        self.assertEqual(len(set(self.tokens.values())), len(self.tokens),
                         f"Tokens should be unique: {self.tokens}")

    def test_token_minimum_length(self):
        """Auth tokens should be at least 16 characters (openssl rand -hex 16 = 32 chars)."""
        for group, token in self.tokens.items():
            self.assertGreaterEqual(len(token), 16,
                                    f"Token too short for {group}: {token}")


@unittest.skipUnless(HAS_YAML, "PyYAML required")
class TestDockerComposeNoVersionField(unittest.TestCase):
    """Bug #225: Docker Compose should not include deprecated version field.
    
    Post-refactor: compose files are generated by the thin generator reading
    from a manifest. Tests provide a manifest fixture.
    """

    def _run_compose(self):
        tmpdir = tempfile.mkdtemp()
        home_dir = os.path.join(tmpdir, 'home', 'bot')
        manifest_path = os.path.join(tmpdir, 'groups.json')
        compose_base = os.path.join(home_dir, '.openclaw', 'compose')
        unit_dir = os.path.join(tmpdir, 'units')
        os.makedirs(compose_base, exist_ok=True)
        os.makedirs(unit_dir, exist_ok=True)

        # Build manifest
        manifest = {"generated": "2026-02-24T09:00:00Z", "groups": {
            "council": {
                "isolation": "container", "port": 18790, "network": "host",
                "agents": ["agent1", "agent2"],
                "configPath": f"{home_dir}/.openclaw/configs/council/openclaw.session.json",
                "statePath": f"{home_dir}/.openclaw-sessions/council",
                "envFile": f"{home_dir}/.openclaw/configs/council/group.env",
                "serviceName": "openclaw-container-council",
                "composePath": f"{compose_base}/council/docker-compose.yaml",
            },
            "workers": {
                "isolation": "container", "port": 18791, "network": "host",
                "agents": ["agent3", "agent4"],
                "configPath": f"{home_dir}/.openclaw/configs/workers/openclaw.session.json",
                "statePath": f"{home_dir}/.openclaw-sessions/workers",
                "envFile": f"{home_dir}/.openclaw/configs/workers/group.env",
                "serviceName": "openclaw-container-workers",
                "composePath": f"{compose_base}/workers/docker-compose.yaml",
            },
        }}
        with open(manifest_path, 'w') as f:
            json.dump(manifest, f)

        env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': home_dir,
            'MANIFEST': manifest_path,
            'ISOLATION_DEFAULT': 'container',
            'ISOLATION_GROUPS': 'council,workers',
            'AGENT_COUNT': '4',
            'USERNAME': 'bot',
            'HOME_DIR': home_dir,
            'HABITAT_NAME': 'TestHabitat',
            'COMPOSE_SYSTEMD_DIR': unit_dir,
            'DRY_RUN': '1',
        }
        for i in range(4):
            n = i + 1
            grp = 'council' if i < 2 else 'workers'
            env[f'AGENT{n}_ISOLATION_GROUP'] = grp
            env[f'AGENT{n}_ISOLATION'] = 'container'
            env[f'AGENT{n}_NETWORK'] = 'host'
            env[f'AGENT{n}_RESOURCES_MEMORY'] = ''
            env[f'AGENT{n}_RESOURCES_CPU'] = ''

        result = subprocess.run(
            ["bash", COMPOSE_SCRIPT], env=env,
            capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, f"Failed: {result.stderr}\nstdout: {result.stdout}"

        compose_path = os.path.join(compose_base, "council", "docker-compose.yaml")
        with open(compose_path) as f:
            raw = f.read()
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)
        return yaml.safe_load(raw), raw

    def test_no_version_field(self):
        """docker-compose.yaml should not contain deprecated version field."""
        parsed, raw = self._run_compose()
        self.assertNotIn("version", parsed,
                         "Should not contain deprecated version field")

    def test_still_has_services(self):
        """docker-compose.yaml must still have services without version."""
        parsed, raw = self._run_compose()
        self.assertIn("services", parsed)
        self.assertGreater(len(parsed["services"]), 0)


if __name__ == "__main__":
    unittest.main()
