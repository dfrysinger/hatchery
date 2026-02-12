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


class TestSessionAuthTokenNotPredictable(unittest.TestCase):
    """Bug #224: Session mode must not use predictable auth tokens."""

    def _run_session(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env = os.environ.copy()
            env['SESSION_OUTPUT_DIR'] = tmpdir
            env['DRY_RUN'] = '1'
            env['ISOLATION_DEFAULT'] = 'session'
            env['ISOLATION_GROUPS'] = 'council,workers'
            env['AGENT_COUNT'] = '4'
            env['HABITAT_NAME'] = 'TestHabitat'
            env['ISOLATION_SHARED_PATHS'] = '/clawd/shared'
            env['USERNAME'] = 'bot'
            env['PLATFORM'] = 'telegram'
            for i in range(4):
                n = i + 1
                grp = 'council' if i < 2 else 'workers'
                env[f'AGENT{n}_NAME'] = f'Agent{n}'
                env[f'AGENT{n}_ISOLATION_GROUP'] = grp
                env[f'AGENT{n}_ISOLATION'] = ''
                env[f'AGENT{n}_MODEL'] = 'anthropic/claude-opus-4-5'
                env[f'AGENT{n}_BOT_TOKEN'] = f'tok{n}'
                env[f'AGENT{n}_NETWORK'] = ''
            result = subprocess.run(
                ['bash', SESSION_SCRIPT], env=env,
                capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, f"Failed: {result.stderr}"
            configs = {}
            for root, dirs, files in os.walk(tmpdir):
                for fname in files:
                    if fname.endswith('.json'):
                        fpath = os.path.join(root, fname)
                        rel = os.path.relpath(fpath, tmpdir)
                        with open(fpath) as f:
                            configs[rel] = json.loads(f.read())
            return configs

    def test_token_not_predictable_prefix(self):
        """Auth token must not be session-groupname pattern."""
        configs = self._run_session()
        for path, cfg in configs.items():
            token = cfg.get("gateway", {}).get("auth", {}).get("token", "")
            self.assertFalse(token.startswith("session-"),
                             f"Token in {path} is predictable: {token}")

    def test_tokens_differ_between_groups(self):
        """Each group must get a unique auth token."""
        configs = self._run_session()
        tokens = set()
        for path, cfg in configs.items():
            token = cfg.get("gateway", {}).get("auth", {}).get("token", "")
            tokens.add(token)
        self.assertEqual(len(tokens), len(configs),
                         f"Tokens should be unique per group: {tokens}")

    def test_token_minimum_length(self):
        """Auth tokens should be at least 16 characters."""
        configs = self._run_session()
        for path, cfg in configs.items():
            token = cfg.get("gateway", {}).get("auth", {}).get("token", "")
            self.assertGreaterEqual(len(token), 16,
                                    f"Token too short in {path}: {token}")


@unittest.skipUnless(HAS_YAML, "PyYAML required")
class TestDockerComposeNoVersionField(unittest.TestCase):
    """Bug #225: Docker Compose should not include deprecated version field."""

    def _run_compose(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env = os.environ.copy()
            env["COMPOSE_OUTPUT_DIR"] = tmpdir
            env["DRY_RUN"] = "1"
            env["ISOLATION_DEFAULT"] = "container"
            env["ISOLATION_GROUPS"] = "council,workers"
            env["AGENT_COUNT"] = "4"
            env["HABITAT_NAME"] = "TestHabitat"
            env["ISOLATION_SHARED_PATHS"] = "/clawd/shared"
            env["USERNAME"] = "bot"
            env["PLATFORM"] = "telegram"
            for i in range(4):
                n = i + 1
                grp = "council" if i < 2 else "workers"
                env[f"AGENT{n}_NAME"] = f"Agent{n}"
                env[f"AGENT{n}_ISOLATION_GROUP"] = grp
                env[f"AGENT{n}_ISOLATION"] = ""
                env[f"AGENT{n}_MODEL"] = "anthropic/claude-opus-4-5"
                env[f"AGENT{n}_BOT_TOKEN"] = f"tok{n}"
                env[f"AGENT{n}_NETWORK"] = ""
                env[f"AGENT{n}_RESOURCES_MEMORY"] = ""
                env[f"AGENT{n}_RESOURCES_CPU"] = ""
                env[f"AGENT{n}_CAPABILITIES"] = ""
            result = subprocess.run(
                ["bash", COMPOSE_SCRIPT], env=env,
                capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, f"Failed: {result.stderr}"
            compose_path = os.path.join(tmpdir, "docker-compose.yaml")
            with open(compose_path) as f:
                raw = f.read()
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
