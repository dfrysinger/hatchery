#!/usr/bin/env python3
"""Tests for generate-config.sh config generation.

Calls generate-config.sh directly with appropriate env vars and CLI args,
validates the generated JSON config for all modes (full, session, safe-mode).
"""

import base64
import json
import os
import subprocess
import tempfile

import pytest

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "scripts")
GENERATE_SCRIPT = os.path.join(SCRIPTS_DIR, "generate-config.sh")


def b64(s):
    """Base64-encode a string."""
    return base64.b64encode(s.encode()).decode()


def run_generate_config(mode="full", platform="telegram", agent_count=1, agents=None,
                        discord_guild_id="", discord_owner_id="",
                        telegram_user_id="12345", council_group_id="",
                        council_group_name="", council_judge="",
                        gateway_token="test-gateway-token-abc123",
                        group=None, group_agents=None, port="18789",
                        # safe-mode specific
                        sm_token="", sm_provider="anthropic", sm_platform=None,
                        sm_bot_token="", sm_owner_id="", sm_model=""):
    """Run generate-config.sh and return parsed JSON."""

    with tempfile.TemporaryDirectory() as tmp_dir:
        home = os.path.join(tmp_dir, "home", "bot")
        os.makedirs(os.path.join(home, "clawd", "agents", "safe-mode"), exist_ok=True)
        for i in range(1, max(agent_count + 1, 5)):
            os.makedirs(os.path.join(home, "clawd", "agents", f"agent{i}", "memory"), exist_ok=True)

        # Build environment — start clean to avoid host env leakage
        env = {k: v for k, v in os.environ.items()
               if k in ("PATH", "HOME", "TERM", "SHELL", "LANG", "USER", "TMPDIR")}
        env["TEST_MODE"] = "1"
        env["USERNAME"] = "bot"
        env["HOME"] = home
        env["PLATFORM"] = platform
        env["PLATFORM_B64"] = b64(platform)
        env["DISCORD_GUILD_ID"] = discord_guild_id
        env["DISCORD_GUILD_ID_B64"] = b64(discord_guild_id) if discord_guild_id else ""
        env["DISCORD_OWNER_ID"] = discord_owner_id
        env["DISCORD_OWNER_ID_B64"] = b64(discord_owner_id) if discord_owner_id else ""
        env["TELEGRAM_OWNER_ID"] = telegram_user_id
        env["TELEGRAM_USER_ID_B64"] = b64(telegram_user_id)
        env["ANTHROPIC_KEY_B64"] = b64("sk-ant-test-key")
        env["GOOGLE_API_KEY_B64"] = ""
        env["BRAVE_KEY_B64"] = ""
        env["OPENAI_ACCESS_B64"] = ""
        env["OPENAI_REFRESH_B64"] = ""
        env["OPENAI_EXPIRES_B64"] = ""
        env["OPENAI_ACCOUNT_ID_B64"] = ""
        env["GLOBAL_IDENTITY_B64"] = ""
        env["GLOBAL_BOOT_B64"] = ""
        env["GLOBAL_BOOTSTRAP_B64"] = ""
        env["GLOBAL_SOUL_B64"] = ""
        env["GLOBAL_AGENTS_B64"] = ""
        env["GLOBAL_USER_B64"] = ""
        env["HABITAT_NAME"] = "test-habitat"
        env["COUNCIL_GROUP_ID"] = council_group_id
        env["COUNCIL_GROUP_NAME"] = council_group_name
        env["COUNCIL_JUDGE"] = council_judge
        env["AGENT_COUNT"] = str(agent_count)

        if agents is None:
            agents = [{"name": "Claude", "tg_token": "tg-token-1", "dc_token": "dc-token-1",
                        "model": "anthropic/claude-opus-4-5"}]

        for i, agent in enumerate(agents, 1):
            env[f"AGENT{i}_NAME"] = agent.get("name", f"Agent{i}")
            env[f"AGENT{i}_NAME_B64"] = b64(agent.get("name", f"Agent{i}"))
            env[f"AGENT{i}_BOT_TOKEN"] = agent.get("tg_token", "")
            env[f"AGENT{i}_BOT_TOKEN_B64"] = b64(agent.get("tg_token", "")) if agent.get("tg_token") else ""
            env[f"AGENT{i}_TELEGRAM_BOT_TOKEN"] = agent.get("tg_token", "")
            env[f"AGENT{i}_TELEGRAM_BOT_TOKEN_B64"] = b64(agent.get("tg_token", "")) if agent.get("tg_token") else ""
            env[f"AGENT{i}_DISCORD_BOT_TOKEN"] = agent.get("dc_token", "")
            env[f"AGENT{i}_DISCORD_BOT_TOKEN_B64"] = b64(agent.get("dc_token", "")) if agent.get("dc_token") else ""
            env[f"AGENT{i}_MODEL"] = agent.get("model", "anthropic/claude-opus-4-5")
            env[f"AGENT{i}_ISOLATION_GROUP"] = agent.get("isolation_group", "")
            env[f"AGENT{i}_IDENTITY_B64"] = ""
            env[f"AGENT{i}_SOUL_B64"] = ""
            env[f"AGENT{i}_AGENTS_B64"] = ""
            env[f"AGENT{i}_BOOT_B64"] = ""
            env[f"AGENT{i}_BOOTSTRAP_B64"] = ""
            env[f"AGENT{i}_USER_B64"] = ""
            env[f"AGENT{i}_CAPABILITIES"] = ""
            env[f"AGENT{i}_REASONING"] = ""

        # Build CLI args
        cmd = ["bash", GENERATE_SCRIPT, "--mode", mode, "--gateway-token", gateway_token, "--port", port]
        if group:
            cmd.extend(["--group", group])
        if group_agents:
            cmd.extend(["--agents", group_agents])
        if mode == "safe-mode":
            if sm_token:
                cmd.extend(["--token", sm_token])
            if sm_provider:
                cmd.extend(["--provider", sm_provider])
            if sm_platform or platform:
                cmd.extend(["--platform", sm_platform or platform])
            if sm_bot_token:
                cmd.extend(["--bot-token", sm_bot_token])
            if sm_owner_id or telegram_user_id:
                cmd.extend(["--owner-id", sm_owner_id or telegram_user_id])
            if sm_model:
                cmd.extend(["--model", sm_model])

        result = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            pytest.fail(f"generate-config.sh failed (rc={result.returncode}):\nstdout: {result.stdout}\nstderr: {result.stderr}")

        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as e:
            pytest.fail(f"Invalid JSON output:\n{result.stdout}\nError: {e}")


# === Tests ===


class TestPlatformTelegram:
    """Tests for PLATFORM=telegram (default)."""

    def test_telegram_enabled(self):
        config = run_generate_config(platform="telegram")
        assert config["channels"]["telegram"]["enabled"] is True

    def test_discord_disabled(self):
        config = run_generate_config(platform="telegram")
        assert config["channels"]["discord"]["enabled"] is False

    def test_telegram_plugin_enabled(self):
        config = run_generate_config(platform="telegram")
        assert config["plugins"]["entries"]["telegram"]["enabled"] is True

    def test_discord_plugin_disabled(self):
        config = run_generate_config(platform="telegram")
        assert config["plugins"]["entries"]["discord"]["enabled"] is False

    def test_telegram_single_account(self):
        """Single agent uses accounts.agent1 (agent-ID policy)."""
        config = run_generate_config(platform="telegram")
        acct = config["channels"]["telegram"]["accounts"]["agent1"]
        assert acct["botToken"] == "tg-token-1"

    def test_telegram_dm_policy(self):
        config = run_generate_config(platform="telegram")
        acct = config["channels"]["telegram"]["accounts"]["agent1"]
        assert acct["dmPolicy"] == "allowlist"
        assert "12345" in acct["allowFrom"]

    def test_default_platform_is_telegram(self):
        """When PLATFORM is telegram, should enable telegram and disable discord."""
        config = run_generate_config(platform="telegram")
        assert config["channels"]["telegram"]["enabled"] is True
        assert config["channels"]["discord"]["enabled"] is False


class TestPlatformDiscord:
    """Tests for PLATFORM=discord."""

    def test_discord_enabled(self):
        config = run_generate_config(platform="discord")
        assert config["channels"]["discord"]["enabled"] is True

    def test_telegram_disabled(self):
        config = run_generate_config(platform="discord")
        assert config["channels"]["telegram"]["enabled"] is False

    def test_discord_plugin_enabled(self):
        config = run_generate_config(platform="discord")
        assert config["plugins"]["entries"]["discord"]["enabled"] is True

    def test_telegram_plugin_disabled(self):
        config = run_generate_config(platform="discord")
        assert config["plugins"]["entries"]["telegram"]["enabled"] is False

    def test_discord_single_account(self):
        """Single agent uses accounts.agent1 (agent-ID policy)."""
        config = run_generate_config(platform="discord")
        acct = config["channels"]["discord"]["accounts"]["agent1"]
        assert acct["token"] == "dc-token-1"

    def test_discord_dm_config(self):
        """DM config uses flat keys (dmPolicy, allowFrom), not nested dm object."""
        config = run_generate_config(platform="discord")
        dc = config["channels"]["discord"]
        assert dc["dmPolicy"] == "pairing"
        # Ensure no nested dm object (triggers Doctor migration prompt)
        assert "dm" not in dc

    def test_discord_group_policy(self):
        config = run_generate_config(platform="discord")
        assert config["channels"]["discord"]["groupPolicy"] == "allowlist"

    def test_discord_guild_id(self):
        config = run_generate_config(platform="discord", discord_guild_id="123456789")
        guilds = config["channels"]["discord"]["guilds"]
        assert "123456789" in guilds
        assert guilds["123456789"]["requireMention"] is True

    def test_discord_owner_id_in_dm_allow(self):
        config = run_generate_config(platform="discord", discord_owner_id="owner-999")
        dc = config["channels"]["discord"]
        assert "owner-999" in dc["allowFrom"]

    def test_no_guild_when_empty(self):
        config = run_generate_config(platform="discord", discord_guild_id="")
        assert "guilds" not in config["channels"]["discord"]

    def test_no_allow_from_when_no_owner(self):
        config = run_generate_config(platform="discord", discord_owner_id="")
        dc = config["channels"]["discord"]
        assert "allowFrom" not in dc


class TestPlatformBoth:
    """Tests for PLATFORM=both."""

    def test_both_channels_enabled(self):
        config = run_generate_config(platform="both")
        assert config["channels"]["telegram"]["enabled"] is True
        assert config["channels"]["discord"]["enabled"] is True

    def test_both_plugins_enabled(self):
        config = run_generate_config(platform="both")
        assert config["plugins"]["entries"]["telegram"]["enabled"] is True
        assert config["plugins"]["entries"]["discord"]["enabled"] is True

    def test_both_single_agent(self):
        """Single agent with both platforms uses accounts.agent1 (agent-ID policy)."""
        config = run_generate_config(platform="both")
        assert "agent1" in config["channels"]["telegram"]["accounts"]
        assert "agent1" in config["channels"]["discord"]["accounts"]


class TestBindings:
    """Tests for multi-agent bindings."""

    MULTI_AGENTS = [
        {"name": "Claude", "tg_token": "tg-1", "dc_token": "dc-1", "model": "anthropic/claude-opus-4-5"},
        {"name": "ChatGPT", "tg_token": "tg-2", "dc_token": "dc-2", "model": "openai/gpt-5.2"},
        {"name": "Gemini", "tg_token": "tg-3", "dc_token": "dc-3", "model": "google/gemini-3-pro"},
    ]

    def test_telegram_bindings_only(self):
        config = run_generate_config(platform="telegram", agent_count=3, agents=self.MULTI_AGENTS)
        bindings = config["bindings"]
        channels = [b["match"]["channel"] for b in bindings]
        assert all(c == "telegram" for c in channels)
        assert len(bindings) == 3  # all agents get explicit bindings

    def test_discord_bindings_only(self):
        config = run_generate_config(platform="discord", agent_count=3, agents=self.MULTI_AGENTS)
        bindings = config["bindings"]
        channels = [b["match"]["channel"] for b in bindings]
        assert all(c == "discord" for c in channels)
        assert len(bindings) == 3

    def test_both_bindings(self):
        config = run_generate_config(platform="both", agent_count=3, agents=self.MULTI_AGENTS)
        bindings = config["bindings"]
        tg_bindings = [b for b in bindings if b["match"]["channel"] == "telegram"]
        dc_bindings = [b for b in bindings if b["match"]["channel"] == "discord"]
        assert len(tg_bindings) == 3
        assert len(dc_bindings) == 3

    def test_single_agent_no_bindings(self):
        config = run_generate_config(platform="both", agent_count=1)
        assert config["bindings"] == []

    def test_multi_agent_telegram_accounts(self):
        config = run_generate_config(platform="telegram", agent_count=3, agents=self.MULTI_AGENTS)
        ta = config["channels"]["telegram"]["accounts"]
        assert ta["agent1"]["botToken"] == "tg-1"
        assert ta["agent2"]["botToken"] == "tg-2"
        assert ta["agent3"]["botToken"] == "tg-3"

    def test_multi_agent_discord_accounts(self):
        config = run_generate_config(platform="discord", agent_count=3, agents=self.MULTI_AGENTS)
        da = config["channels"]["discord"]["accounts"]
        assert da["agent1"]["token"] == "dc-1"
        assert da["agent2"]["token"] == "dc-2"
        assert da["agent3"]["token"] == "dc-3"


class TestPlatformFailFast:
    """Tests for fail-fast behavior on invalid PLATFORM values."""

    def _run_with_platform(self, platform):
        """Run generate-config.sh with a specific PLATFORM and return the result."""
        env = {k: v for k, v in os.environ.items()
               if k in ("PATH", "HOME", "TERM", "SHELL", "LANG", "USER", "TMPDIR")}
        env["TEST_MODE"] = "1"
        env["USERNAME"] = "bot"
        env["PLATFORM"] = platform
        env["PLATFORM_B64"] = b64(platform) if platform else ""
        env["AGENT_COUNT"] = "1"
        env["AGENT1_NAME"] = "Claude"
        env["AGENT1_NAME_B64"] = b64("Claude")
        env["AGENT1_MODEL"] = "anthropic/claude-opus-4-5"
        env["AGENT1_BOT_TOKEN"] = "test-token"
        env["AGENT1_TELEGRAM_BOT_TOKEN"] = "test-token"
        env["AGENT1_DISCORD_BOT_TOKEN"] = ""
        env["ANTHROPIC_KEY_B64"] = b64("sk-ant-test-key")
        env["TELEGRAM_OWNER_ID"] = "12345"
        env["TELEGRAM_USER_ID_B64"] = b64("12345")
        for key in ["GOOGLE_API_KEY_B64", "BRAVE_KEY_B64", "OPENAI_ACCESS_B64",
                    "OPENAI_REFRESH_B64", "OPENAI_EXPIRES_B64", "OPENAI_ACCOUNT_ID_B64",
                    "DISCORD_GUILD_ID", "DISCORD_GUILD_ID_B64", "DISCORD_OWNER_ID",
                    "DISCORD_OWNER_ID_B64", "GLOBAL_IDENTITY_B64", "GLOBAL_BOOT_B64",
                    "GLOBAL_BOOTSTRAP_B64", "GLOBAL_SOUL_B64", "GLOBAL_AGENTS_B64",
                    "GLOBAL_USER_B64", "COUNCIL_GROUP_ID", "COUNCIL_GROUP_NAME", "COUNCIL_JUDGE"]:
            env[key] = ""

        return subprocess.run(
            ["bash", GENERATE_SCRIPT, "--mode", "full", "--gateway-token", "test-token"],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_empty_platform_defaults_to_telegram(self):
        """Empty PLATFORM should default to telegram (not fail)."""
        result = self._run_with_platform("")
        assert result.returncode == 0, f"Empty PLATFORM should default to telegram: {result.stderr}"
        config = json.loads(result.stdout)
        assert config["channels"]["telegram"]["enabled"] is True

    def test_invalid_platform_fails(self):
        """Invalid PLATFORM value (e.g., 'slack') should fail with non-zero exit."""
        result = self._run_with_platform("slack")
        assert result.returncode != 0, "Invalid PLATFORM='slack' should cause script to fail"

    def test_wrong_case_platform_fails(self):
        """Wrong case PLATFORM (e.g., 'TELEGRAM') should fail with non-zero exit."""
        result = self._run_with_platform("TELEGRAM")
        assert result.returncode != 0, "Wrong case PLATFORM='TELEGRAM' should cause script to fail"


class TestConfigStructure:
    """Tests for overall config structure integrity."""

    def test_valid_json(self):
        """Config should always be valid JSON."""
        for platform in ["telegram", "discord", "both"]:
            config = run_generate_config(platform=platform)
            assert isinstance(config, dict)

    def test_has_required_sections(self):
        config = run_generate_config(platform="both")
        for key in ["env", "browser", "agents", "bindings", "gateway", "plugins", "channels", "skills", "hooks"]:
            assert key in config, f"Missing required section: {key}"

    def test_gateway_config(self):
        config = run_generate_config(platform="telegram")
        gw = config["gateway"]
        assert gw["port"] == 18789
        assert gw["auth"]["token"] == "test-gateway-token-abc123"

    def test_env_has_anthropic_key(self):
        config = run_generate_config(platform="telegram")
        assert "ANTHROPIC_API_KEY" in config["env"], "Config should include ANTHROPIC_API_KEY"
        assert config["env"]["ANTHROPIC_API_KEY"] == "sk-ant-test-key"

    def test_discord_with_guild_and_owner(self):
        """Full discord config with all options."""
        config = run_generate_config(
            platform="discord",
            discord_guild_id="guild-123",
            discord_owner_id="owner-456",
            agent_count=2,
            agents=[
                {"name": "Claude", "tg_token": "tg-1", "dc_token": "dc-1", "model": "anthropic/claude-opus-4-5"},
                {"name": "ChatGPT", "tg_token": "tg-2", "dc_token": "dc-2", "model": "openai/gpt-5.2"},
            ],
        )
        dc = config["channels"]["discord"]
        assert dc["enabled"] is True
        assert dc["guilds"]["guild-123"]["requireMention"] is True
        assert "owner-456" in dc["allowFrom"]
        assert dc["accounts"]["agent2"]["token"] == "dc-2"


class TestJSONEscaping:
    """Tests for JSON escaping of special characters."""

    def test_agent_name_with_quotes(self):
        agents = [{"name": 'My "Test" Channel', "tg_token": "tg-1", "dc_token": "dc-1",
                   "model": "anthropic/claude-opus-4-5"}]
        config = run_generate_config(platform="telegram", agent_count=1, agents=agents)
        agent_list = config["agents"]["list"]
        assert len(agent_list) == 1
        assert agent_list[0]["name"] == 'My "Test" Channel'

    def test_agent_name_with_backslash(self):
        agents = [{"name": "Test\\Channel", "tg_token": "tg-1", "dc_token": "dc-1",
                   "model": "anthropic/claude-opus-4-5"}]
        config = run_generate_config(platform="telegram", agent_count=1, agents=agents)
        agent_list = config["agents"]["list"]
        assert len(agent_list) == 1
        assert agent_list[0]["name"] == "Test\\Channel"

    def test_agent_name_with_unicode_emoji(self):
        agents = [{"name": "Rocket Launches", "tg_token": "tg-1", "dc_token": "dc-1",
                   "model": "anthropic/claude-opus-4-5"}]
        config = run_generate_config(platform="telegram", agent_count=1, agents=agents)
        agent_list = config["agents"]["list"]
        assert len(agent_list) == 1
        assert agent_list[0]["name"] == "Rocket Launches"

    def test_telegram_user_id_with_leading_zero(self):
        config = run_generate_config(platform="telegram", telegram_user_id="0123456789")
        acct = config["channels"]["telegram"]["accounts"]["agent1"]
        assert "0123456789" in acct["allowFrom"]


class TestJSONValidation:
    """Tests for JSON validation across all platform configs."""

    def test_all_existing_configs_still_validate(self):
        """Regression test: all platform configs should produce valid JSON."""
        for platform in ["telegram", "discord", "both"]:
            config = run_generate_config(platform=platform)
            assert isinstance(config, dict)

    def test_multi_agent_config_validates(self):
        """Multi-agent configuration should produce valid JSON."""
        agents = [
            {"name": "Claude", "tg_token": "tg-1", "dc_token": "dc-1", "model": "anthropic/claude-opus-4-5"},
            {"name": "ChatGPT", "tg_token": "tg-2", "dc_token": "dc-2", "model": "openai/gpt-5.2"},
            {"name": "Gemini", "tg_token": "tg-3", "dc_token": "dc-3", "model": "google/gemini-3-pro"},
        ]
        config = run_generate_config(platform="both", agent_count=3, agents=agents)
        assert len(config["agents"]["list"]) == 3

    def test_council_config_validates(self):
        """Council configuration should produce valid JSON."""
        agents = [
            {"name": "Claude", "tg_token": "tg-1", "dc_token": "dc-1", "model": "anthropic/claude-opus-4-5"},
            {"name": "Opus", "tg_token": "tg-2", "dc_token": "dc-2", "model": "anthropic/claude-opus-4-5"},
        ]
        config = run_generate_config(
            platform="telegram",
            agent_count=2,
            agents=agents,
            council_group_id="-100123456789",
            council_group_name="The Council",
            council_judge="Opus"
        )
        assert len(config["agents"]["list"]) == 2


# === Safe-mode config tests ===

class TestSafeModeConfig:
    """Tests for safe-mode config generation — the root cause of the Telegram outage."""

    def test_safe_mode_telegram_has_plugin(self):
        """Safe-mode config MUST include plugins.entries.telegram.enabled=true."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        assert config["plugins"]["entries"]["telegram"]["enabled"] is True

    def test_safe_mode_discord_has_plugin(self):
        """Safe-mode config MUST include plugins.entries.discord.enabled=true."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="discord",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        assert config["plugins"]["entries"]["discord"]["enabled"] is True

    def test_safe_mode_telegram_only_includes_telegram_channel(self):
        """When platform=telegram, only telegram should be in channels."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        assert "telegram" in config["channels"]
        assert "discord" not in config["channels"], \
            "Discord should not be in channels when platform is telegram"

    def test_safe_mode_discord_only_includes_discord_channel(self):
        """When platform=discord, only discord should be in channels."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="discord",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        assert "discord" in config["channels"]
        assert "telegram" not in config["channels"], \
            "Telegram should not be in channels when platform is discord"

    def test_safe_mode_telegram_no_discord_plugin(self):
        """When platform=telegram, discord plugin should not be enabled."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        # Discord plugin entry should either not exist or be disabled
        discord_entry = config["plugins"]["entries"].get("discord", {})
        assert not discord_entry.get("enabled", False), \
            "Discord plugin should not be enabled in telegram-only safe mode"

    def test_safe_mode_agent_is_safe_mode(self):
        """Safe-mode config should have a single 'safe-mode' agent."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        agents = config["agents"]["list"]
        assert len(agents) == 1
        assert agents[0]["id"] == "safe-mode"
        assert agents[0]["default"] is True
        assert agents[0]["name"] == "SafeModeBot"

    def test_safe_mode_telegram_account_matches_agent(self):
        """Safe-mode Telegram uses accounts.safe-mode (safe-mode account key policy)."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="test-bot-token-123",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        acct = config["channels"]["telegram"]["accounts"]["safe-mode"]
        assert acct["botToken"] == "test-bot-token-123"

    def test_safe_mode_discord_account(self):
        """Safe-mode Discord uses accounts.safe-mode (safe-mode account key policy)."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="discord-bot-token-123",
            sm_provider="anthropic",
            sm_platform="discord",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        acct = config["channels"]["discord"]["accounts"]["safe-mode"]
        assert acct["token"] == "discord-bot-token-123"

    def test_safe_mode_dm_policy(self):
        """Safe-mode config should have allowlist dmPolicy with owner."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="99999",
        )
        acct = config["channels"]["telegram"]["accounts"]["safe-mode"]
        assert acct["dmPolicy"] == "allowlist"
        assert "99999" in acct["allowFrom"]

    def test_safe_mode_anthropic_env(self):
        """Anthropic provider should set ANTHROPIC_API_KEY in env."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-key-123",
            sm_owner_id="12345",
        )
        assert config["env"]["ANTHROPIC_API_KEY"] == "sk-ant-key-123"

    def test_safe_mode_openai_env(self):
        """OpenAI provider should set OPENAI_API_KEY in env."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="openai",
            sm_platform="telegram",
            sm_token="sk-openai-key-123",
            sm_owner_id="12345",
        )
        assert config["env"]["OPENAI_API_KEY"] == "sk-openai-key-123"

    def test_safe_mode_google_env(self):
        """Google provider should set both GOOGLE_API_KEY and GEMINI_API_KEY."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="google",
            sm_platform="telegram",
            sm_token="AIza-google-key",
            sm_owner_id="12345",
        )
        assert config["env"]["GOOGLE_API_KEY"] == "AIza-google-key"
        assert config["env"]["GEMINI_API_KEY"] == "AIza-google-key"

    def test_safe_mode_valid_json(self):
        """Safe-mode config should be valid JSON for both platforms."""
        for platform in ["telegram", "discord"]:
            config = run_generate_config(
                mode="safe-mode",
                sm_bot_token="123:ABC",
                sm_provider="anthropic",
                sm_platform=platform,
                sm_token="sk-ant-test",
                sm_owner_id="12345",
            )
            assert isinstance(config, dict)

    def test_safe_mode_has_browser_disabled(self):
        """Safe-mode config disables browser (container has no Chrome)."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
        )
        assert config["browser"]["enabled"] is False

    def test_safe_mode_has_gateway(self):
        """Safe-mode config should include gateway settings."""
        config = run_generate_config(
            mode="safe-mode",
            sm_bot_token="123:ABC",
            sm_provider="anthropic",
            sm_platform="telegram",
            sm_token="sk-ant-test",
            sm_owner_id="12345",
            gateway_token="safe-mode-gw-token",
        )
        gw = config["gateway"]
        assert gw["auth"]["token"] == "safe-mode-gw-token"
        assert gw["bind"] == "loopback"


# === Session mode tests ===

class TestSessionConfig:
    """Tests for session isolation config generation."""

    def test_session_mode_filters_agents(self):
        """Session mode should only include agents in the specified group."""
        agents = [
            {"name": "Claude", "tg_token": "tg-1", "dc_token": "", "model": "anthropic/claude-opus-4-5",
             "isolation_group": "browser"},
            {"name": "ChatGPT", "tg_token": "tg-2", "dc_token": "", "model": "openai/gpt-5.2",
             "isolation_group": "documents"},
        ]
        config = run_generate_config(
            mode="session",
            platform="telegram",
            agent_count=2,
            agents=agents,
            group="browser",
            group_agents="agent1",
            port="18790",
        )
        agent_ids = [a["id"] for a in config["agents"]["list"]]
        assert "agent1" in agent_ids
        assert "agent2" not in agent_ids

    def test_session_mode_uses_correct_port(self):
        """Session mode should use the specified port."""
        config = run_generate_config(
            mode="session",
            platform="telegram",
            group="browser",
            group_agents="agent1",
            port="18790",
        )
        assert config["gateway"]["port"] == 18790

    def test_session_mode_has_plugins(self):
        """Session mode should include plugins section."""
        config = run_generate_config(
            mode="session",
            platform="telegram",
            group="browser",
            group_agents="agent1",
            port="18790",
        )
        assert "plugins" in config
        assert config["plugins"]["entries"]["telegram"]["enabled"] is True
