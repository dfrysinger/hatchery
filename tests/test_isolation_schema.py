#!/usr/bin/env python3
"""Integration tests for v3 isolation schema parsing.

These tests invoke scripts/parse-habitat.py via subprocess with
HABITAT_OUTPUT_DIR pointed at a temp directory, then verify the
generated habitat-parsed.env contains correct isolation fields.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest

PARSER = os.path.join(os.path.dirname(__file__), '..', 'scripts', 'parse-habitat.py')


def make_habitat(overrides=None, agents=None):
    """Build a minimal v2 habitat dict with optional overrides."""
    hab = {
        "name": "TestHabitat",
        "platform": "telegram",
        "destructMinutes": 0,
        "platforms": {"telegram": {"ownerId": "123"}},
        "agents": agents or [
            {"agent": "Agent1", "tokens": {"telegram": "tok1"}},
        ],
    }
    if overrides:
        hab.update(overrides)
    return hab


def run_parser(habitat_dict, expect_fail=False):
    """Run parse-habitat.py with the given habitat dict.

    Returns (env_dict, stderr_text).
    env_dict is a dict of KEY=VALUE pairs from habitat-parsed.env.
    If expect_fail=True, asserts non-zero exit and returns ({}, stderr).
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        b64 = base64.b64encode(json.dumps(habitat_dict).encode()).decode()
        env = os.environ.copy()
        env['HABITAT_B64'] = b64
        env['HABITAT_OUTPUT_DIR'] = tmpdir
        env.pop('AGENT_LIB_B64', None)

        result = subprocess.run(
            [sys.executable, PARSER],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

        if expect_fail:
            assert result.returncode != 0, \
                f"Expected failure but got rc=0.\nstdout: {result.stdout}\nstderr: {result.stderr}"
            return {}, result.stderr

        assert result.returncode == 0, \
            f"Parser failed (rc={result.returncode}).\nstderr: {result.stderr}"

        env_file = os.path.join(tmpdir, 'habitat-parsed.env')
        assert os.path.exists(env_file), "habitat-parsed.env not created"

        env_dict = {}
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    key, _, val = line.partition('=')
                    env_dict[key] = val.strip('"')
        return env_dict, result.stderr


class TestIsolationTopLevel(unittest.TestCase):
    """Tests for top-level isolation and sharedPaths fields."""

    def test_default_isolation_none(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('ISOLATION_DEFAULT'), 'none')

    def test_isolation_session(self):
        env, _ = run_parser(make_habitat({'isolation': 'session'}))
        self.assertEqual(env['ISOLATION_DEFAULT'], 'session')

    def test_isolation_container(self):
        env, _ = run_parser(make_habitat({'isolation': 'container'}))
        self.assertEqual(env['ISOLATION_DEFAULT'], 'container')

    def test_isolation_droplet_rejected(self):
        _, stderr = run_parser(make_habitat({'isolation': 'droplet'}), expect_fail=True)
        self.assertIn('droplet isolation mode is not yet supported', stderr)

    def test_isolation_invalid_value_warns_and_defaults(self):
        env, stderr = run_parser(make_habitat({'isolation': 'kubernetes'}))
        self.assertIn('Invalid isolation', stderr)
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')

    def test_shared_paths_default_empty(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('ISOLATION_SHARED_PATHS'), '')

    def test_shared_paths_single(self):
        env, _ = run_parser(make_habitat({'sharedPaths': ['/clawd/shared']}))
        self.assertEqual(env['ISOLATION_SHARED_PATHS'], '/clawd/shared')

    def test_shared_paths_multiple(self):
        env, _ = run_parser(make_habitat({'sharedPaths': ['/a', '/b', '/c']}))
        self.assertEqual(env['ISOLATION_SHARED_PATHS'], '/a,/b,/c')

    def test_shared_paths_not_array_rejected_by_schema(self):
        _, stderr = run_parser(make_habitat({'sharedPaths': '/bad'}), expect_fail=True)
        self.assertIn('sharedPaths', stderr)
        self.assertIn('must be array', stderr)


class TestIsolationPerAgent(unittest.TestCase):
    """Tests for per-agent isolation fields."""

    def test_agent_isolation_empty_by_default(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('AGENT1_ISOLATION'), '')

    def test_agent_isolation_set(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolation": "container"}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_ISOLATION'], 'container')

    def test_agent_isolation_droplet_rejected(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolation": "droplet"}]
        _, stderr = run_parser(make_habitat(agents=agents), expect_fail=True)
        self.assertIn('droplet isolation mode is not yet supported', stderr)

    def test_agent_isolation_invalid_warns(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolation": "vm"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('invalid isolation', stderr.lower())
        self.assertEqual(env['AGENT1_ISOLATION'], '')

    def test_agent_isolation_group(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolationGroup": "workers"}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_ISOLATION_GROUP'], 'workers')

    def test_agent_isolation_group_defaults_to_agent_name(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('AGENT1_ISOLATION_GROUP'), 'Agent1')

    def test_agent_isolation_group_invalid_chars_warns(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolationGroup": "bad group!"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('invalid isolationgroup', stderr.lower())
        self.assertEqual(env['AGENT1_ISOLATION_GROUP'], 'A')

    def test_agent_network_default_host(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('AGENT1_NETWORK'), 'host')

    def test_agent_network_host(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": "host", "isolation": "container"}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_NETWORK'], 'host')

    def test_agent_capabilities(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "capabilities": ["exec", "web_search"]}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_CAPABILITIES'], 'exec,web_search')

    def test_agent_capabilities_empty(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('AGENT1_CAPABILITIES'), '')

    def test_agent_resources_memory(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "resources": {"memory": "512Mi"}}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_RESOURCES_MEMORY'], '512Mi')

    def test_agent_resources_cpu(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "resources": {"cpu": "0.5"}}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_RESOURCES_CPU'], '0.5')


class TestIsolationGroupLogic(unittest.TestCase):
    """Tests for isolation group aggregation."""

    def test_isolation_groups_default_to_agent_names(self):
        env, _ = run_parser(make_habitat())
        self.assertEqual(env.get('ISOLATION_GROUPS'), 'Agent1')

    def test_isolation_groups_single(self):
        agents = [
            {"agent": "A", "tokens": {"telegram": "t"}, "isolationGroup": "council"},
        ]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['ISOLATION_GROUPS'], 'council')

    def test_isolation_groups_multiple_deduped(self):
        agents = [
            {"agent": "A", "tokens": {"telegram": "t1"}, "isolationGroup": "council"},
            {"agent": "B", "tokens": {"telegram": "t2"}, "isolationGroup": "workers"},
            {"agent": "C", "tokens": {"telegram": "t3"}, "isolationGroup": "council"},
        ]
        env, _ = run_parser(make_habitat(agents=agents))
        groups = env['ISOLATION_GROUPS'].split(',')
        self.assertEqual(sorted(groups), ['council', 'workers'])

    def test_isolation_groups_sorted(self):
        agents = [
            {"agent": "A", "tokens": {"telegram": "t1"}, "isolationGroup": "zebra"},
            {"agent": "B", "tokens": {"telegram": "t2"}, "isolationGroup": "alpha"},
        ]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['ISOLATION_GROUPS'], 'alpha,zebra')

    def test_group_name_alphanumeric_with_hyphens(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolationGroup": "my-group-1"}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_ISOLATION_GROUP'], 'my-group-1')

    def test_group_name_hyphen_start_is_valid(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolationGroup": "-prefixed"}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_ISOLATION_GROUP'], '-prefixed')

    def test_group_name_no_spaces_warns(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "isolationGroup": "has space"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('invalid isolationgroup', stderr.lower())
        self.assertEqual(env['AGENT1_ISOLATION_GROUP'], 'A')


class TestNetworkValidation(unittest.TestCase):
    """Tests for network field validation."""

    def test_network_invalid_value_warns_and_defaults(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": "bridge"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('invalid network', stderr.lower())
        self.assertEqual(env['AGENT1_NETWORK'], 'host')

    def test_network_valid_values(self):
        for net in ['host', 'internal', 'none']:
            agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": net, "isolation": "container"}]
            env, _ = run_parser(make_habitat(agents=agents))
            self.assertEqual(env['AGENT1_NETWORK'], net)

    def test_network_on_non_container_warns(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": "internal"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('WARN', stderr)
        self.assertIn('network only applies to container/droplet', stderr)

    def test_network_on_session_isolation_warns(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": "internal", "isolation": "session"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('WARN', stderr)

    def test_network_on_container_no_warning(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": "internal", "isolation": "container"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertNotIn('WARN', stderr)


class TestBackwardCompatibility(unittest.TestCase):
    """Ensure v1/v2 habitats work unchanged with v3 parser."""

    def test_v2_habitat_no_isolation(self):
        hab = make_habitat()
        env, _ = run_parser(hab)
        self.assertEqual(env['HABITAT_NAME'], 'TestHabitat')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')
        self.assertEqual(env['ISOLATION_SHARED_PATHS'], '')
        self.assertEqual(env['ISOLATION_GROUPS'], 'Agent1')

    def test_v1_legacy_format(self):
        hab = {
            "name": "LegacyHab",
            "telegram": {"ownerId": "123"},
            "agents": [{"agent": "Bot", "botToken": "tok1"}],
        }
        env, _ = run_parser(hab)
        self.assertEqual(env['HABITAT_NAME'], 'LegacyHab')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')

    def test_v2_with_platform_key(self):
        hab = make_habitat()
        hab['platform'] = 'discord'
        hab['platforms'] = {'discord': {'ownerId': '456', 'serverId': '789'}}
        hab['agents'] = [{"agent": "A", "tokens": {"discord": "dtok"}}]
        env, _ = run_parser(hab)
        self.assertEqual(env['PLATFORM'], 'discord')

    def test_agent_count_preserved(self):
        agents = [
            {"agent": f"Agent{i}", "tokens": {"telegram": f"tok{i}"}}
            for i in range(3)
        ]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT_COUNT'], '3')

    def test_existing_fields_unaffected(self):
        env, _ = run_parser(make_habitat({'bgColor': 'FF0000', 'destructMinutes': 120}))
        self.assertEqual(env['BG_COLOR'], 'FF0000')
        self.assertEqual(env['DESTRUCT_MINS'], '120')

    def test_multiple_agents_backward_compat(self):
        agents = [
            {"agent": "A", "tokens": {"telegram": "t1"}},
            {"agent": "B", "tokens": {"telegram": "t2"}},
        ]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_NAME'], 'A')
        self.assertEqual(env['AGENT2_NAME'], 'B')
        # v3 fields default to empty
        self.assertEqual(env['AGENT1_ISOLATION'], '')
        self.assertEqual(env['AGENT2_ISOLATION'], '')

    def test_council_config_preserved(self):
        hab = make_habitat()
        hab['council'] = {'groupName': 'Council', 'judge': 'Opus'}
        env, _ = run_parser(hab)
        self.assertEqual(env.get('COUNCIL_GROUP_NAME'), 'Council')
        self.assertEqual(env.get('COUNCIL_JUDGE'), 'Opus')

    # --- TASK-205 expanded backward compatibility tests ---

    def test_v2_simple_single_agent(self):
        """Minimal v2 habitat with one agent — all isolation defaults."""
        hab = {"name": "SimpleBot", "agents": [{"agent": "Claude"}]}
        env, _ = run_parser(hab)
        self.assertEqual(env['HABITAT_NAME'], 'SimpleBot')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')
        self.assertEqual(env['ISOLATION_SHARED_PATHS'], '')
        self.assertIn('Claude', env['ISOLATION_GROUPS'])
        self.assertEqual(env['AGENT_COUNT'], '1')
        self.assertEqual(env.get('AGENT1_ISOLATION'), '')
        self.assertEqual(env.get('AGENT1_ISOLATION_GROUP'), 'Claude')
        self.assertEqual(env.get('AGENT1_NETWORK'), 'host')

    def test_v2_multi_agent_no_isolation(self):
        """v2 with multiple agents and no isolation fields at all."""
        hab = {
            "name": "MultiBot",
            "platform": "discord",
            "platforms": {"discord": {"ownerId": "456", "serverId": "789"}},
            "agents": [
                {"agent": "Claude", "tokens": {"discord": "tok1"}},
                {"agent": "ChatGPT", "tokens": {"discord": "tok2"}},
                {"agent": "Gemini", "tokens": {"discord": "tok3"}},
            ],
        }
        env, _ = run_parser(hab)
        self.assertEqual(env['AGENT_COUNT'], '3')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')
        for i in range(1, 4):
            self.assertEqual(env.get(f'AGENT{i}_ISOLATION'), '')
            self.assertEqual(env.get(f'AGENT{i}_ISOLATION_GROUP'), ['Claude', 'ChatGPT', 'Gemini'][i-1])
            self.assertEqual(env.get(f'AGENT{i}_NETWORK'), 'host')
            self.assertEqual(env.get(f'AGENT{i}_CAPABILITIES'), '')
            self.assertEqual(env.get(f'AGENT{i}_RESOURCES_MEMORY'), '')
            self.assertEqual(env.get(f'AGENT{i}_RESOURCES_CPU'), '')

    def test_v1_telegram_legacy_botToken(self):
        """v1 legacy format with botToken field."""
        hab = {
            "name": "OldBot",
            "telegram": {"ownerId": "111"},
            "agents": [{"agent": "Bot", "botToken": "tok_legacy"}],
        }
        env, stderr = run_parser(hab)
        self.assertEqual(env['HABITAT_NAME'], 'OldBot')
        self.assertEqual(env['AGENT1_BOT_TOKEN'], 'tok_legacy')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')
        self.assertIn('DEPRECATION', stderr)

    def test_v1_discord_legacy_discordBotToken(self):
        """v1 legacy format with discordBotToken field."""
        hab = {
            "name": "OldDiscord",
            "platform": "discord",
            "discord": {"ownerId": "222", "serverId": "333"},
            "agents": [{"agent": "Bot", "discordBotToken": "dtok_legacy"}],
        }
        env, stderr = run_parser(hab)
        self.assertEqual(env['AGENT1_DISCORD_BOT_TOKEN'], 'dtok_legacy')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')
        self.assertIn('DEPRECATION', stderr)

    def test_v1_telegramBotToken_legacy(self):
        """v1 legacy format with telegramBotToken field."""
        hab = {
            "name": "OldTG",
            "telegram": {"ownerId": "444"},
            "agents": [{"agent": "Bot", "telegramBotToken": "ttok_legacy"}],
        }
        env, stderr = run_parser(hab)
        self.assertEqual(env['AGENT1_BOT_TOKEN'], 'ttok_legacy')
        self.assertEqual(env['AGENT1_TELEGRAM_BOT_TOKEN'], 'ttok_legacy')
        self.assertIn('DEPRECATION', stderr)

    def test_destruct_minutes_default_zero(self):
        """destructMinutes defaults to 0 for v2 habitats without it."""
        hab = {"name": "NoDM", "agents": [{"agent": "Bot"}]}
        env, _ = run_parser(hab)
        self.assertEqual(env['DESTRUCT_MINS'], '0')

    def test_platform_defaults_telegram(self):
        """Platform defaults to telegram when not specified."""
        hab = {"name": "NoPlat", "agents": [{"agent": "Bot"}]}
        env, _ = run_parser(hab)
        self.assertEqual(env['PLATFORM'], 'telegram')

    def test_global_fields_preserved(self):
        """Global identity/soul/boot fields survive v3 parser."""
        hab = make_habitat({
            'globalIdentity': 'I am a helper',
            'globalSoul': 'Be kind',
            'globalBoot': 'Check services',
        })
        env, _ = run_parser(hab)
        # These are base64-encoded; just verify they are non-empty
        self.assertNotEqual(env.get('GLOBAL_IDENTITY_B64', ''), '')
        self.assertNotEqual(env.get('GLOBAL_SOUL_B64', ''), '')
        self.assertNotEqual(env.get('GLOBAL_BOOT_B64', ''), '')

    def test_api_bind_address_default(self):
        """API bind defaults to 127.0.0.1 (secure-by-default)."""
        hab = make_habitat()
        env, _ = run_parser(hab)
        self.assertEqual(env['API_BIND_ADDRESS'], '127.0.0.1')

    def test_api_bind_remote_enabled(self):
        """remoteApi: true sets API bind to 0.0.0.0."""
        hab = make_habitat({'remoteApi': True})
        env, _ = run_parser(hab)
        self.assertEqual(env['API_BIND_ADDRESS'], '0.0.0.0')

    def test_both_platform_v1(self):
        """v1 dual-platform habitat with both telegram and discord."""
        hab = {
            "name": "DualBot",
            "platform": "both",
            "telegram": {"ownerId": "111"},
            "discord": {"ownerId": "222", "serverId": "333"},
            "agents": [
                {"agent": "Bot1", "telegramBotToken": "tt1", "discordBotToken": "dt1"},
            ],
        }
        env, stderr = run_parser(hab)
        self.assertEqual(env['PLATFORM'], 'both')
        self.assertEqual(env['AGENT1_BOT_TOKEN'], 'tt1')
        self.assertEqual(env['AGENT1_DISCORD_BOT_TOKEN'], 'dt1')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')

    def test_string_agent_shorthand(self):
        """String shorthand for agent ref (just agent name)."""
        hab = {
            "name": "StringAgent",
            "agents": ["Claude"],
        }
        env, _ = run_parser(hab)
        self.assertEqual(env['AGENT1_NAME'], 'Claude')
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')

    def test_domain_field_preserved(self):
        """domain field passes through to HABITAT_DOMAIN."""
        hab = make_habitat({'domain': 'bot.example.com'})
        env, _ = run_parser(hab)
        self.assertEqual(env['HABITAT_DOMAIN'], 'bot.example.com')

    def test_council_group_id_legacy(self):
        """Legacy councilGroupId field still works."""
        hab = make_habitat({'councilGroupId': '-100999'})
        env, _ = run_parser(hab)
        self.assertEqual(env['COUNCIL_GROUP_ID'], '-100999')


class TestExampleFiles(unittest.TestCase):
    """Test that the v3 example habitat files parse correctly."""

    def _load_example(self, filename):
        path = os.path.join(os.path.dirname(__file__), '..', 'examples', filename)
        if not os.path.exists(path):
            self.skipTest(f"Example file {filename} not found")
        with open(path) as f:
            return json.load(f)

    def test_session_example_parses(self):
        hab = self._load_example('habitat-isolation-session.json')
        env, _ = run_parser(hab)
        self.assertEqual(env['ISOLATION_DEFAULT'], 'session')
        self.assertIn('council', env['ISOLATION_GROUPS'])
        self.assertIn('workers', env['ISOLATION_GROUPS'])

    def test_session_example_agent_count(self):
        hab = self._load_example('habitat-isolation-session.json')
        env, _ = run_parser(hab)
        self.assertEqual(env['AGENT_COUNT'], '4')

    def test_container_example_parses(self):
        hab = self._load_example('habitat-isolation-container.json')
        env, _ = run_parser(hab)
        self.assertEqual(env['ISOLATION_DEFAULT'], 'container')

    def test_container_example_agent_overrides(self):
        hab = self._load_example('habitat-isolation-container.json')
        env, _ = run_parser(hab)
        # Orchestrator overrides to session
        self.assertEqual(env['AGENT1_ISOLATION'], 'session')
        # CodeExecutor has network=none
        self.assertEqual(env['AGENT2_NETWORK'], 'none')
        self.assertEqual(env['AGENT2_RESOURCES_MEMORY'], '512Mi')

    def test_container_example_shared_paths(self):
        hab = self._load_example('habitat-isolation-container.json')
        env, _ = run_parser(hab)
        self.assertIn('/clawd/shared/code', env['ISOLATION_SHARED_PATHS'])


class TestComplexScenarios(unittest.TestCase):
    """Test complex multi-agent isolation scenarios."""

    def test_mixed_isolation_levels(self):
        agents = [
            {"agent": "A", "tokens": {"telegram": "t1"}, "isolation": "session", "isolationGroup": "g1"},
            {"agent": "B", "tokens": {"telegram": "t2"}, "isolation": "container", "isolationGroup": "g2"},
            {"agent": "C", "tokens": {"telegram": "t3"}, "isolationGroup": "g1"},
        ]
        env, _ = run_parser(make_habitat({'isolation': 'none'}, agents=agents))
        self.assertEqual(env['AGENT1_ISOLATION'], 'session')
        self.assertEqual(env['AGENT2_ISOLATION'], 'container')
        self.assertEqual(env['AGENT3_ISOLATION'], '')  # inherits default
        groups = env['ISOLATION_GROUPS'].split(',')
        self.assertEqual(sorted(groups), ['g1', 'g2'])

    def test_container_with_full_resources(self):
        agents = [{
            "agent": "Heavy",
            "tokens": {"telegram": "t"},
            "isolation": "container",
            "network": "internal",
            "capabilities": ["exec", "web_search", "web_fetch"],
            "resources": {"memory": "1Gi", "cpu": "2.0"},
        }]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_RESOURCES_MEMORY'], '1Gi')
        self.assertEqual(env['AGENT1_RESOURCES_CPU'], '2.0')
        self.assertEqual(env['AGENT1_CAPABILITIES'], 'exec,web_search,web_fetch')
        self.assertEqual(env['AGENT1_NETWORK'], 'internal')

    def test_ten_agents_all_grouped(self):
        agents = [
            {"agent": f"A{i}", "tokens": {"telegram": f"t{i}"},
             "isolationGroup": f"group-{i % 3}"}
            for i in range(10)
        ]
        env, _ = run_parser(make_habitat({'isolation': 'session'}, agents=agents))
        self.assertEqual(env['AGENT_COUNT'], '10')
        groups = env['ISOLATION_GROUPS'].split(',')
        self.assertEqual(sorted(groups), ['group-0', 'group-1', 'group-2'])

    def test_session_with_shared_paths_and_groups(self):
        agents = [
            {"agent": "Judge", "tokens": {"telegram": "t1"}, "isolationGroup": "council"},
            {"agent": "Worker", "tokens": {"telegram": "t2"}, "isolationGroup": "workers"},
        ]
        env, _ = run_parser(make_habitat({
            'isolation': 'session',
            'sharedPaths': ['/clawd/shared', '/tmp/exchange'],
        }, agents=agents))
        self.assertEqual(env['ISOLATION_SHARED_PATHS'], '/clawd/shared,/tmp/exchange')
        self.assertIn('council', env['ISOLATION_GROUPS'])


class TestSchemaValidation(unittest.TestCase):
    """Test edge cases and validation boundaries."""

    def test_empty_isolation_string_treated_as_none(self):
        """An empty string for isolation should use the default."""
        hab = make_habitat()
        env, _ = run_parser(hab)
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')

    def test_isolation_case_sensitive(self):
        env, stderr = run_parser(make_habitat({'isolation': 'Session'}))
        self.assertIn('Invalid isolation', stderr)
        self.assertEqual(env['ISOLATION_DEFAULT'], 'none')

    def test_network_case_sensitive(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "network": "Host"}]
        env, stderr = run_parser(make_habitat(agents=agents))
        self.assertIn('invalid network', stderr.lower())
        self.assertEqual(env['AGENT1_NETWORK'], 'host')

    def test_capabilities_as_empty_list(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "capabilities": []}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_CAPABILITIES'], '')

    def test_resources_empty_dict(self):
        agents = [{"agent": "A", "tokens": {"telegram": "t"}, "resources": {}}]
        env, _ = run_parser(make_habitat(agents=agents))
        self.assertEqual(env['AGENT1_RESOURCES_MEMORY'], '')
        self.assertEqual(env['AGENT1_RESOURCES_CPU'], '')

    def test_habitat_json_written(self):
        """Verify habitat.json is also written to output dir."""
        hab = make_habitat({'isolation': 'session'})
        with tempfile.TemporaryDirectory() as tmpdir:
            b64 = base64.b64encode(json.dumps(hab).encode()).decode()
            env = os.environ.copy()
            env['HABITAT_B64'] = b64
            env['HABITAT_OUTPUT_DIR'] = tmpdir
            env.pop('AGENT_LIB_B64', None)
            subprocess.run([sys.executable, PARSER], env=env, capture_output=True, timeout=10)
            hab_path = os.path.join(tmpdir, 'habitat.json')
            self.assertTrue(os.path.exists(hab_path))
            with open(hab_path) as f:
                written = json.load(f)
            self.assertEqual(written['isolation'], 'session')


if __name__ == '__main__':
    unittest.main()
