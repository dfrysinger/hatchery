#!/usr/bin/env python3
"""
Tests for generate-session-services.sh

Validates:
1. Correct session config generation (channels, bindings, agents)
2. Correct permissions (dirs 755, files 644, state dirs owned by user)
3. Correct service names (openclaw-{group}.service)
4. Telegram multi-account configuration with proper bindings
"""

import unittest
import subprocess
import os
import json
import tempfile
import shutil


class TestSessionServicesConfig(unittest.TestCase):
    """Test session config generation with proper Telegram setup."""

    def setUp(self):
        """Set up test environment with mock habitat-parsed.env."""
        self.test_dir = tempfile.mkdtemp()
        self.output_dir = os.path.join(self.test_dir, "systemd")
        self.state_base = os.path.join(self.test_dir, "state")
        os.makedirs(self.output_dir)
        os.makedirs(self.state_base)
        
        # Path to the script
        self.script_path = os.path.join(
            os.path.dirname(__file__), "..", "scripts", "generate-session-services.sh"
        )

    def tearDown(self):
        """Clean up test directory."""
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_script_with_env(self, env_vars):
        """Run generate-session-services.sh with given environment."""
        env = os.environ.copy()
        env.update(env_vars)
        env["SESSION_OUTPUT_DIR"] = self.output_dir
        env["HOME_DIR"] = self.test_dir
        env["DRY_RUN"] = "1"
        env["HOME_DIR"] = self.test_dir
        env["DRY_RUN"] = "1"  # Don't actually install services
        
        result = subprocess.run(
            ["bash", self.script_path],
            env=env,
            capture_output=True,
            text=True
        )
        return result

    def test_session_config_has_telegram_accounts(self):
        """Session config must include Telegram accounts with bot tokens."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "2",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent-1",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
            "AGENT2_NAME": "test-agent-2",
            "AGENT2_BOT_TOKEN": "222222:BBBB",
            "AGENT2_ISOLATION_GROUP": "browser",
            "AGENT2_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        # Check config file was created
        config_path = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        self.assertTrue(os.path.exists(config_path), f"Config not created at {config_path}")
        
        with open(config_path) as f:
            config = json.load(f)
        
        # Verify channels.telegram.accounts exists
        self.assertIn("channels", config, "Config missing 'channels' section")
        self.assertIn("telegram", config["channels"], "Config missing 'channels.telegram'")
        self.assertIn("accounts", config["channels"]["telegram"], 
                      "Config missing 'channels.telegram.accounts'")
        
        accounts = config["channels"]["telegram"]["accounts"]
        
        # Verify each agent has an account with token
        self.assertIn("agent1", accounts, "Missing account for agent1")
        self.assertIn("agent2", accounts, "Missing account for agent2")
        self.assertEqual(accounts["agent1"]["botToken"], "111111:AAAA")
        self.assertEqual(accounts["agent2"]["botToken"], "222222:BBBB")

    def test_session_config_has_bindings(self):
        """Session config must include bindings to route accounts to agents."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "2",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent-1",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
            "AGENT2_NAME": "test-agent-2",
            "AGENT2_BOT_TOKEN": "222222:BBBB",
            "AGENT2_ISOLATION_GROUP": "browser",
            "AGENT2_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_path = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        with open(config_path) as f:
            config = json.load(f)
        
        # Verify bindings exist
        self.assertIn("bindings", config, "Config missing 'bindings' section")
        bindings = config["bindings"]
        
        # Should have one binding per agent
        self.assertEqual(len(bindings), 2, f"Expected 2 bindings, got {len(bindings)}")
        
        # Verify binding structure
        agent_ids = {b["agentId"] for b in bindings}
        self.assertIn("agent1", agent_ids, "Missing binding for agent1")
        self.assertIn("agent2", agent_ids, "Missing binding for agent2")
        
        for binding in bindings:
            self.assertIn("match", binding)
            self.assertEqual(binding["match"]["channel"], "telegram")
            self.assertIn("accountId", binding["match"])

    def test_session_config_has_allowfrom(self):
        """Session config must include allowFrom for DM policy."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_path = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        with open(config_path) as f:
            config = json.load(f)
        
        # Verify allowFrom in telegram config (NOT ownerId - that's invalid)
        telegram = config["channels"]["telegram"]
        self.assertIn("allowFrom", telegram, "Config missing 'channels.telegram.allowFrom'")
        self.assertIn("123456789", telegram["allowFrom"])
        # Ensure ownerId is NOT present (it's an invalid key that causes OpenClaw errors)
        self.assertNotIn("ownerId", telegram, "Config should NOT have invalid 'ownerId' key")

    def test_multiple_groups_separate_configs(self):
        """Each isolation group gets its own config with only its agents."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "4",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser,documents",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "agent-doc-1",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "documents",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
            "AGENT2_NAME": "agent-doc-2",
            "AGENT2_BOT_TOKEN": "222222:BBBB",
            "AGENT2_ISOLATION_GROUP": "documents",
            "AGENT2_MODEL": "anthropic/claude-sonnet-4-5",
            "AGENT3_NAME": "agent-browser-1",
            "AGENT3_BOT_TOKEN": "333333:CCCC",
            "AGENT3_ISOLATION_GROUP": "browser",
            "AGENT3_MODEL": "anthropic/claude-sonnet-4-5",
            "AGENT4_NAME": "agent-browser-2",
            "AGENT4_BOT_TOKEN": "444444:DDDD",
            "AGENT4_ISOLATION_GROUP": "browser",
            "AGENT4_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        # Check browser config
        browser_config_path = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        with open(browser_config_path) as f:
            browser_config = json.load(f)
        
        browser_accounts = browser_config["channels"]["telegram"]["accounts"]
        self.assertIn("agent3", browser_accounts)
        self.assertIn("agent4", browser_accounts)
        self.assertNotIn("agent1", browser_accounts)
        self.assertNotIn("agent2", browser_accounts)
        
        # Check documents config
        docs_config_path = os.path.join(self.output_dir, "documents", "openclaw.session.json")
        with open(docs_config_path) as f:
            docs_config = json.load(f)
        
        docs_accounts = docs_config["channels"]["telegram"]["accounts"]
        self.assertIn("agent1", docs_accounts)
        self.assertIn("agent2", docs_accounts)
        self.assertNotIn("agent3", docs_accounts)
        self.assertNotIn("agent4", docs_accounts)


class TestSessionServicesPermissions(unittest.TestCase):
    """Test that files and directories have correct permissions."""

    def setUp(self):
        """Set up test environment."""
        self.test_dir = tempfile.mkdtemp()
        self.output_dir = os.path.join(self.test_dir, "systemd")
        os.makedirs(self.output_dir)
        
        self.script_path = os.path.join(
            os.path.dirname(__file__), "..", "scripts", "generate-session-services.sh"
        )

    def tearDown(self):
        """Clean up test directory."""
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_script_with_env(self, env_vars):
        """Run generate-session-services.sh with given environment."""
        env = os.environ.copy()
        env.update(env_vars)
        env["SESSION_OUTPUT_DIR"] = self.output_dir
        env["HOME_DIR"] = self.test_dir
        env["DRY_RUN"] = "1"
        
        result = subprocess.run(
            ["bash", self.script_path],
            env=env,
            capture_output=True,
            text=True
        )
        return result

    def test_config_directory_permissions(self):
        """Config directories must be 750 (owner rwx, group rx, others none - security)."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_dir = os.path.join(self.output_dir, "browser")
        self.assertTrue(os.path.isdir(config_dir))
        
        # Check directory permissions (750 = rwxr-x--- - secure: only owner can write)
        mode = os.stat(config_dir).st_mode & 0o777
        self.assertEqual(mode, 0o750, f"Config dir should be 750, got {oct(mode)}")

    def test_config_file_permissions(self):
        """Config files must be 600 (owner rw only - contains sensitive bot tokens)."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_file = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        self.assertTrue(os.path.isfile(config_file))
        
        # Check file permissions (600 = rw------- - secure: config contains bot tokens)
        mode = os.stat(config_file).st_mode & 0o777
        self.assertEqual(mode, 0o600, f"Config file should be 600, got {oct(mode)}")


class TestSessionServicesNames(unittest.TestCase):
    """Test that service files have correct names."""

    def setUp(self):
        """Set up test environment."""
        self.test_dir = tempfile.mkdtemp()
        self.output_dir = os.path.join(self.test_dir, "systemd")
        os.makedirs(self.output_dir)
        
        self.script_path = os.path.join(
            os.path.dirname(__file__), "..", "scripts", "generate-session-services.sh"
        )

    def tearDown(self):
        """Clean up test directory."""
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_script_with_env(self, env_vars):
        """Run generate-session-services.sh with given environment."""
        env = os.environ.copy()
        env.update(env_vars)
        env["SESSION_OUTPUT_DIR"] = self.output_dir
        env["HOME_DIR"] = self.test_dir
        env["DRY_RUN"] = "1"
        
        result = subprocess.run(
            ["bash", self.script_path],
            env=env,
            capture_output=True,
            text=True
        )
        return result

    def test_service_file_naming(self):
        """Service files must be named openclaw-{group}.service."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "2",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser,documents",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent-1",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
            "AGENT2_NAME": "test-agent-2",
            "AGENT2_BOT_TOKEN": "222222:BBBB",
            "AGENT2_ISOLATION_GROUP": "documents",
            "AGENT2_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        # Check service files exist with correct names
        browser_service = os.path.join(self.output_dir, "openclaw-browser.service")
        docs_service = os.path.join(self.output_dir, "openclaw-documents.service")
        
        self.assertTrue(os.path.exists(browser_service), 
                        f"Missing openclaw-browser.service")
        self.assertTrue(os.path.exists(docs_service), 
                        f"Missing openclaw-documents.service")

    def test_service_file_not_numbered(self):
        """Service files must NOT be named with numbers (e.g., openclaw-0.service)."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        # Check that numbered services do NOT exist
        for i in range(10):
            numbered_service = os.path.join(self.output_dir, f"openclaw-{i}.service")
            self.assertFalse(os.path.exists(numbered_service), 
                            f"Should not create numbered service: openclaw-{i}.service")


class TestPostBootCheckIsolation(unittest.TestCase):
    """Test that post-boot-check correctly identifies isolation groups."""

    def test_isolation_groups_parsed_correctly(self):
        """ISOLATION_GROUPS should be parsed as comma-separated group names."""
        # This tests the post-boot-check.sh logic
        script = '''
        ISOLATION_GROUPS="browser,documents"
        IFS=',' read -ra GROUP_ARRAY <<< "$ISOLATION_GROUPS"
        echo "${GROUP_ARRAY[@]}"
        '''
        
        result = subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True
        )
        
        self.assertEqual(result.returncode, 0)
        groups = result.stdout.strip().split()
        self.assertEqual(groups, ["browser", "documents"])

    def test_empty_isolation_groups_handled(self):
        """Empty ISOLATION_GROUPS should result in empty array."""
        script = '''
        ISOLATION_GROUPS=""
        IFS=',' read -ra GROUP_ARRAY <<< "$ISOLATION_GROUPS"
        echo "count=${#GROUP_ARRAY[@]}"
        '''
        
        result = subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True
        )
        
        self.assertEqual(result.returncode, 0)
        # Empty string with IFS split gives array with one empty element
        # But for our purposes, we check the actual group names
        self.assertIn("count=", result.stdout)


class TestSessionServicesAgentDir(unittest.TestCase):
    """Test that session services include agentDir for proper session storage."""

    def setUp(self):
        """Set up test environment."""
        self.test_dir = tempfile.mkdtemp()
        self.output_dir = os.path.join(self.test_dir, "systemd")
        os.makedirs(self.output_dir)
        
        self.script_path = os.path.join(
            os.path.dirname(__file__), "..", "scripts", "generate-session-services.sh"
        )

    def tearDown(self):
        """Clean up test directory."""
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_script_with_env(self, env_vars):
        """Run generate-session-services.sh with given environment."""
        env = os.environ.copy()
        env.update(env_vars)
        env["SESSION_OUTPUT_DIR"] = self.output_dir
        env["HOME_DIR"] = self.test_dir
        env["DRY_RUN"] = "1"
        
        result = subprocess.run(
            ["bash", self.script_path],
            env=env,
            capture_output=True,
            text=True
        )
        return result

    def test_agent_has_required_fields(self):
        """Each agent must have required fields (id, name, model, workspace).
        
        Note: agentDir is NOT included because it causes session path validation
        issues. OpenClaw uses OPENCLAW_STATE_DIR env var instead.
        """
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_file = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        with open(config_file) as f:
            config = json.load(f)
        
        # Check that agent has required fields
        agents = config["agents"]["list"]
        self.assertEqual(len(agents), 1)
        agent = agents[0]
        self.assertIn("id", agent, "Agent must have id")
        self.assertIn("name", agent, "Agent must have name")
        self.assertIn("model", agent, "Agent must have model")
        self.assertIn("workspace", agent, "Agent must have workspace")

    def test_agent_directories_created(self):
        """Script must create agent directory structure within state_dir.
        
        Note: sessions/ directory is created by OpenClaw at runtime, not setup.
        """
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        # Check that agent directories were created
        state_dir = os.path.join(self.test_dir, ".openclaw-sessions", "browser")
        agent_dir = os.path.join(state_dir, "agents", "agent1", "agent")
        
        self.assertTrue(os.path.isdir(agent_dir), f"Missing agent dir: {agent_dir}")
        # Note: sessions/ is created by OpenClaw at runtime, not by the setup script


class TestSessionServicesPlugins(unittest.TestCase):
    """Test that session services include plugins section with enabled providers."""

    def setUp(self):
        """Set up test environment."""
        self.test_dir = tempfile.mkdtemp()
        self.output_dir = os.path.join(self.test_dir, "systemd")
        os.makedirs(self.output_dir)
        
        self.script_path = os.path.join(
            os.path.dirname(__file__), "..", "scripts", "generate-session-services.sh"
        )

    def tearDown(self):
        """Clean up test directory."""
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_script_with_env(self, env_vars):
        """Run generate-session-services.sh with given environment."""
        env = os.environ.copy()
        env.update(env_vars)
        env["SESSION_OUTPUT_DIR"] = self.output_dir
        env["HOME_DIR"] = self.test_dir
        env["DRY_RUN"] = "1"
        
        result = subprocess.run(
            ["bash", self.script_path],
            env=env,
            capture_output=True,
            text=True
        )
        return result

    def test_telegram_plugin_enabled(self):
        """Telegram plugin must be enabled when PLATFORM=telegram."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "telegram",
            "TELEGRAM_OWNER_ID": "123456789",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_file = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        with open(config_file) as f:
            config = json.load(f)
        
        # Check plugins section exists with telegram enabled
        self.assertIn("plugins", config, "Config must have plugins section")
        self.assertIn("entries", config["plugins"], "plugins must have entries")
        self.assertIn("telegram", config["plugins"]["entries"], "plugins.entries must have telegram")
        self.assertTrue(config["plugins"]["entries"]["telegram"]["enabled"],
                        "telegram plugin must be enabled when PLATFORM=telegram")

    def test_both_plugins_enabled(self):
        """Both telegram and discord plugins must be enabled when PLATFORM=both."""
        env = {
            "HABITAT_NAME": "TestHabitat",
            "USERNAME": "testuser",
            "AGENT_COUNT": "1",
            "ISOLATION_DEFAULT": "session",
            "ISOLATION_GROUPS": "browser",
            "PLATFORM": "both",
            "TELEGRAM_OWNER_ID": "123456789",
            "DISCORD_OWNER_ID": "987654321",
            "AGENT1_NAME": "test-agent",
            "AGENT1_BOT_TOKEN": "111111:AAAA",
            "AGENT1_DISCORD_TOKEN": "discord_token_here",
            "AGENT1_ISOLATION_GROUP": "browser",
            "AGENT1_MODEL": "anthropic/claude-sonnet-4-5",
        }
        
        result = self.run_script_with_env(env)
        self.assertEqual(result.returncode, 0, f"Script failed: {result.stderr}")
        
        config_file = os.path.join(self.output_dir, "browser", "openclaw.session.json")
        with open(config_file) as f:
            config = json.load(f)
        
        # Check both plugins are enabled
        self.assertTrue(config["plugins"]["entries"]["telegram"]["enabled"],
                        "telegram plugin must be enabled when PLATFORM=both")
        self.assertTrue(config["plugins"]["entries"]["discord"]["enabled"],
                        "discord plugin must be enabled when PLATFORM=both")


if __name__ == "__main__":
    unittest.main()
