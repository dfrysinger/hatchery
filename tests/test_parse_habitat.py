#!/usr/bin/env python3
"""Tests for parse-habitat.py dual-platform schema support.

Instead of subprocess-exec'ing a generated script, we replicate the core
parse logic in a helper function and test it directly. This mirrors what
the embedded parse-habitat.py does but writes to temp files.
"""
import json
import base64
import os
import tempfile
import pytest


def b64e(s):
    """Base64-encode a string."""
    return base64.b64encode(s.encode()).decode()


def b64d(s):
    """Base64-decode a string."""
    return base64.b64decode(s).decode()


def _b64(s):
    """Internal b64 helper matching parse-habitat.py."""
    return base64.b64encode((s or "").encode()).decode()


def run_parse_habitat(habitat_json, agent_lib_json=None):
    """
    Run the parse-habitat.py logic with the given habitat dict and return
    the parsed env vars as a dict.
    """
    hab = habitat_json
    lib = agent_lib_json or {}

    lines = []

    lines.append('HABITAT_NAME="{}"\n'.format(hab["name"]))
    lines.append('HABITAT_NAME_B64="{}"\n'.format(_b64(hab["name"])))
    lines.append('DESTRUCT_MINS="{}"\n'.format(hab.get("destructMinutes", 0)))
    lines.append('DESTRUCT_MINS_B64="{}"\n'.format(_b64(str(hab.get("destructMinutes", 0)))))
    lines.append('BG_COLOR="{}"\n'.format(hab.get("bgColor", "2D3748")))

    # Platform (default: "telegram" for backward compat)
    platform = hab.get("platform", "telegram")
    lines.append('PLATFORM="{}"\n'.format(platform))
    lines.append('PLATFORM_B64="{}"\n'.format(_b64(platform)))

    # Discord config
    discord_cfg = hab.get("discord", {})
    lines.append('DISCORD_GUILD_ID="{}"\n'.format(discord_cfg.get("serverId", "")))
    lines.append('DISCORD_GUILD_ID_B64="{}"\n'.format(_b64(discord_cfg.get("serverId", ""))))
    lines.append('DISCORD_OWNER_ID="{}"\n'.format(discord_cfg.get("ownerId", "")))
    lines.append('DISCORD_OWNER_ID_B64="{}"\n'.format(_b64(discord_cfg.get("ownerId", ""))))

    # Telegram config
    telegram_cfg = hab.get("telegram", {})
    telegram_owner_id = telegram_cfg.get("ownerId", "")
    lines.append('TELEGRAM_OWNER_ID="{}"\n'.format(telegram_owner_id))
    lines.append('TELEGRAM_OWNER_ID_B64="{}"\n'.format(_b64(telegram_owner_id)))
    # Backward compat: keep TELEGRAM_USER_ID_B64 as alias
    lines.append('TELEGRAM_USER_ID_B64="{}"\n'.format(_b64(telegram_owner_id)))

    # Council config (supports nested telegram.groupId and legacy groupId)
    council = hab.get("council", {})
    council_tg = council.get("telegram", {})
    council_group_id = council_tg.get("groupId", council.get("groupId", hab.get("councilGroupId", "")))
    lines.append('COUNCIL_GROUP_ID="{}"\n'.format(council_group_id))
    lines.append('COUNCIL_GROUP_NAME="{}"\n'.format(council.get("groupName", "")))
    lines.append('COUNCIL_JUDGE="{}"\n'.format(council.get("judge", "")))

    lines.append('HABITAT_DOMAIN="{}"\n'.format(hab.get("domain", "")))
    lines.append('GLOBAL_IDENTITY_B64="{}"\n'.format(_b64(hab.get("globalIdentity", ""))))
    lines.append('GLOBAL_BOOT_B64="{}"\n'.format(_b64(hab.get("globalBoot", ""))))
    lines.append('GLOBAL_BOOTSTRAP_B64="{}"\n'.format(_b64(hab.get("globalBootstrap", ""))))
    lines.append('GLOBAL_SOUL_B64="{}"\n'.format(_b64(hab.get("globalSoul", ""))))
    lines.append('GLOBAL_AGENTS_B64="{}"\n'.format(_b64(hab.get("globalAgents", ""))))
    lines.append('GLOBAL_USER_B64="{}"\n'.format(_b64(hab.get("globalUser", ""))))

    agents = hab.get("agents", [])
    lines.append('AGENT_COUNT={}\n'.format(len(agents)))

    for i, agent_ref in enumerate(agents):
        n = i + 1
        name = agent_ref["agent"]
        lib_entry = lib.get(name, {})
        model = agent_ref.get("model") or lib_entry.get("model", "anthropic/claude-opus-4-5")
        identity = lib_entry.get("identity", "")
        soul = lib_entry.get("soul", "")
        agents_md = lib_entry.get("agents", "")
        boot = lib_entry.get("boot", "")
        bootstrap = lib_entry.get("bootstrap", "")
        user = lib_entry.get("user", "")

        # Telegram bot token: prefer telegramBotToken, fall back to botToken for compat
        tg_bot_token = agent_ref.get("telegramBotToken", agent_ref.get("botToken", ""))
        # Discord bot token
        dc_bot_token = agent_ref.get("discordBotToken", "")

        lines.append('AGENT{}_NAME="{}"\n'.format(n, name))
        lines.append('AGENT{}_NAME_B64="{}"\n'.format(n, _b64(name)))
        # Backward compat: BOT_TOKEN = telegram bot token
        lines.append('AGENT{}_BOT_TOKEN="{}"\n'.format(n, tg_bot_token))
        lines.append('AGENT{}_BOT_TOKEN_B64="{}"\n'.format(n, _b64(tg_bot_token)))
        # Explicit per-platform tokens
        lines.append('AGENT{}_TELEGRAM_BOT_TOKEN="{}"\n'.format(n, tg_bot_token))
        lines.append('AGENT{}_TELEGRAM_BOT_TOKEN_B64="{}"\n'.format(n, _b64(tg_bot_token)))
        lines.append('AGENT{}_DISCORD_BOT_TOKEN="{}"\n'.format(n, dc_bot_token))
        lines.append('AGENT{}_DISCORD_BOT_TOKEN_B64="{}"\n'.format(n, _b64(dc_bot_token)))
        lines.append('AGENT{}_MODEL="{}"\n'.format(n, model))
        lines.append('AGENT{}_IDENTITY_B64="{}"\n'.format(n, _b64(identity)))
        lines.append('AGENT{}_SOUL_B64="{}"\n'.format(n, _b64(soul)))
        lines.append('AGENT{}_AGENTS_B64="{}"\n'.format(n, _b64(agents_md)))
        lines.append('AGENT{}_BOOT_B64="{}"\n'.format(n, _b64(boot)))
        lines.append('AGENT{}_BOOTSTRAP_B64="{}"\n'.format(n, _b64(bootstrap)))
        lines.append('AGENT{}_USER_B64="{}"\n'.format(n, _b64(user)))

    # Parse into dict
    env_vars = {}
    for line in lines:
        line = line.strip()
        if "=" in line:
            key, _, val = line.partition("=")
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            env_vars[key] = val

    return env_vars


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def new_schema_habitat():
    """Full dual-platform habitat with both discord and telegram tokens."""
    return {
        "name": "Habitat-1",
        "domain": "bot.frysinger.org",
        "destructMinutes": 0,
        "bgColor": "2D3748",
        "platform": "discord",
        "discord": {
            "serverId": "1468992121901027582",
            "ownerId": "795380005466800159",
        },
        "telegram": {
            "ownerId": "5874850284",
        },
        "council": {
            "groupName": "The Council",
            "judge": "Opus",
            "telegram": {"groupId": "5134780848"},
        },
        "globalIdentity": "Be awesome",
        "globalBoot": "",
        "globalBootstrap": "",
        "globalSoul": "",
        "globalAgents": "",
        "globalUser": "",
        "agents": [
            {
                "agent": "Claude",
                "discordBotToken": "MTQ2OD_discord_token",
                "telegramBotToken": "8513046_telegram_token",
            }
        ],
    }


@pytest.fixture
def legacy_schema_habitat():
    """Legacy habitat with only botToken (pre dual-platform)."""
    return {
        "name": "Legacy-Habitat",
        "domain": "old.example.com",
        "destructMinutes": 30,
        "bgColor": "1A1A2E",
        "council": {
            "groupId": "999888777",
            "groupName": "Old Council",
            "judge": "Opus",
        },
        "globalIdentity": "",
        "globalBoot": "",
        "globalBootstrap": "",
        "globalSoul": "",
        "globalAgents": "",
        "globalUser": "",
        "agents": [
            {
                "agent": "Claude",
                "botToken": "legacy_telegram_token_123",
            }
        ],
    }


# ---------------------------------------------------------------------------
# Tests: New schema with both token types
# ---------------------------------------------------------------------------

class TestNewDualPlatformSchema:
    def test_platform_field(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["PLATFORM"] == "discord"
        assert b64d(env["PLATFORM_B64"]) == "discord"

    def test_discord_guild_id(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["DISCORD_GUILD_ID"] == "1468992121901027582"
        assert b64d(env["DISCORD_GUILD_ID_B64"]) == "1468992121901027582"

    def test_discord_owner_id(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["DISCORD_OWNER_ID"] == "795380005466800159"
        assert b64d(env["DISCORD_OWNER_ID_B64"]) == "795380005466800159"

    def test_telegram_owner_id(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["TELEGRAM_OWNER_ID"] == "5874850284"
        assert b64d(env["TELEGRAM_OWNER_ID_B64"]) == "5874850284"

    def test_telegram_user_id_b64_compat(self, new_schema_habitat):
        """TELEGRAM_USER_ID_B64 should mirror TELEGRAM_OWNER_ID_B64 for compat."""
        env = run_parse_habitat(new_schema_habitat)
        assert env["TELEGRAM_USER_ID_B64"] == env["TELEGRAM_OWNER_ID_B64"]
        assert b64d(env["TELEGRAM_USER_ID_B64"]) == "5874850284"

    def test_agent_discord_bot_token(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "MTQ2OD_discord_token"
        assert b64d(env["AGENT1_DISCORD_BOT_TOKEN_B64"]) == "MTQ2OD_discord_token"

    def test_agent_telegram_bot_token(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "8513046_telegram_token"
        assert b64d(env["AGENT1_TELEGRAM_BOT_TOKEN_B64"]) == "8513046_telegram_token"

    def test_agent_bot_token_compat(self, new_schema_habitat):
        """AGENT{N}_BOT_TOKEN should equal telegramBotToken for backward compat."""
        env = run_parse_habitat(new_schema_habitat)
        assert env["AGENT1_BOT_TOKEN"] == "8513046_telegram_token"
        assert env["AGENT1_BOT_TOKEN_B64"] == env["AGENT1_TELEGRAM_BOT_TOKEN_B64"]

    def test_council_telegram_group_id(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["COUNCIL_GROUP_ID"] == "5134780848"

    def test_council_metadata(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["COUNCIL_GROUP_NAME"] == "The Council"
        assert env["COUNCIL_JUDGE"] == "Opus"

    def test_habitat_basics(self, new_schema_habitat):
        env = run_parse_habitat(new_schema_habitat)
        assert env["HABITAT_NAME"] == "Habitat-1"
        assert env["HABITAT_DOMAIN"] == "bot.frysinger.org"
        assert env["AGENT_COUNT"] == "1"
        assert env["AGENT1_NAME"] == "Claude"

    def test_multi_agent_tokens(self):
        hab = {
            "name": "MultiAgent",
            "platform": "discord",
            "discord": {"serverId": "111", "ownerId": "222"},
            "telegram": {"ownerId": "333"},
            "agents": [
                {
                    "agent": "Claude",
                    "discordBotToken": "dc_tok_1",
                    "telegramBotToken": "tg_tok_1",
                },
                {
                    "agent": "Gemini",
                    "discordBotToken": "dc_tok_2",
                    "telegramBotToken": "tg_tok_2",
                },
            ],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT_COUNT"] == "2"
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "dc_tok_1"
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "tg_tok_1"
        assert env["AGENT2_DISCORD_BOT_TOKEN"] == "dc_tok_2"
        assert env["AGENT2_TELEGRAM_BOT_TOKEN"] == "tg_tok_2"
        assert env["AGENT2_NAME"] == "Gemini"


# ---------------------------------------------------------------------------
# Tests: Legacy schema with just botToken
# ---------------------------------------------------------------------------

class TestLegacySchema:
    def test_platform_defaults_to_telegram(self, legacy_schema_habitat):
        env = run_parse_habitat(legacy_schema_habitat)
        assert env["PLATFORM"] == "telegram"
        assert b64d(env["PLATFORM_B64"]) == "telegram"

    def test_bot_token_fallback(self, legacy_schema_habitat):
        """When only botToken exists, it becomes telegramBotToken."""
        env = run_parse_habitat(legacy_schema_habitat)
        assert env["AGENT1_BOT_TOKEN"] == "legacy_telegram_token_123"
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "legacy_telegram_token_123"
        assert b64d(env["AGENT1_TELEGRAM_BOT_TOKEN_B64"]) == "legacy_telegram_token_123"

    def test_discord_token_empty_when_missing(self, legacy_schema_habitat):
        env = run_parse_habitat(legacy_schema_habitat)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == ""
        assert env["AGENT1_DISCORD_BOT_TOKEN_B64"] == b64e("")

    def test_discord_fields_empty_when_no_section(self, legacy_schema_habitat):
        env = run_parse_habitat(legacy_schema_habitat)
        assert env["DISCORD_GUILD_ID"] == ""
        assert env["DISCORD_OWNER_ID"] == ""

    def test_telegram_owner_empty_when_no_section(self, legacy_schema_habitat):
        env = run_parse_habitat(legacy_schema_habitat)
        assert env["TELEGRAM_OWNER_ID"] == ""
        assert env["TELEGRAM_USER_ID_B64"] == b64e("")

    def test_legacy_council_group_id(self, legacy_schema_habitat):
        """Legacy council.groupId should still work."""
        env = run_parse_habitat(legacy_schema_habitat)
        assert env["COUNCIL_GROUP_ID"] == "999888777"

    def test_legacy_council_group_id_from_root(self):
        """Even older councilGroupId at root level should work."""
        hab = {
            "name": "VeryOld",
            "councilGroupId": "111222333",
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["COUNCIL_GROUP_ID"] == "111222333"


# ---------------------------------------------------------------------------
# Tests: Platform field variations
# ---------------------------------------------------------------------------

class TestPlatformField:
    def test_platform_discord(self):
        hab = {
            "name": "DiscordOnly",
            "platform": "discord",
            "agents": [{"agent": "Claude", "discordBotToken": "dc_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "discord"

    def test_platform_telegram(self):
        hab = {
            "name": "TelegramOnly",
            "platform": "telegram",
            "agents": [{"agent": "Claude", "botToken": "tg_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "telegram"

    def test_platform_both(self):
        hab = {
            "name": "Both",
            "platform": "both",
            "discord": {"serverId": "111", "ownerId": "222"},
            "telegram": {"ownerId": "333"},
            "agents": [
                {
                    "agent": "Claude",
                    "discordBotToken": "dc_tok",
                    "telegramBotToken": "tg_tok",
                }
            ],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "both"
        assert env["DISCORD_GUILD_ID"] == "111"
        assert env["TELEGRAM_OWNER_ID"] == "333"

    def test_platform_missing_defaults_telegram(self):
        hab = {
            "name": "NoPlatform",
            "agents": [{"agent": "Claude", "botToken": "tg_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "telegram"


# ---------------------------------------------------------------------------
# Tests: Missing optional fields
# ---------------------------------------------------------------------------

class TestMissingOptionalFields:
    def test_no_discord_section(self):
        hab = {
            "name": "NoDiscord",
            "platform": "telegram",
            "telegram": {"ownerId": "123"},
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["DISCORD_GUILD_ID"] == ""
        assert env["DISCORD_GUILD_ID_B64"] == b64e("")
        assert env["DISCORD_OWNER_ID"] == ""
        assert env["DISCORD_OWNER_ID_B64"] == b64e("")

    def test_no_telegram_section(self):
        hab = {
            "name": "NoTelegram",
            "platform": "discord",
            "discord": {"serverId": "111", "ownerId": "222"},
            "agents": [{"agent": "Claude", "discordBotToken": "dc_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["TELEGRAM_OWNER_ID"] == ""
        assert env["TELEGRAM_USER_ID_B64"] == b64e("")

    def test_no_server_id_in_discord(self):
        hab = {
            "name": "NoServerId",
            "platform": "discord",
            "discord": {"ownerId": "222"},
            "agents": [{"agent": "Claude", "discordBotToken": "dc_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["DISCORD_GUILD_ID"] == ""
        assert env["DISCORD_OWNER_ID"] == "222"

    def test_no_council(self):
        hab = {
            "name": "NoCouncil",
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["COUNCIL_GROUP_ID"] == ""
        assert env["COUNCIL_GROUP_NAME"] == ""
        assert env["COUNCIL_JUDGE"] == ""

    def test_council_without_telegram_section(self):
        """Council exists but has no telegram sub-object (legacy)."""
        hab = {
            "name": "CouncilNoTg",
            "council": {
                "groupId": "oldstyle123",
                "groupName": "Council",
                "judge": "Opus",
            },
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["COUNCIL_GROUP_ID"] == "oldstyle123"

    def test_no_domain(self):
        hab = {
            "name": "NoDomain",
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["HABITAT_DOMAIN"] == ""

    def test_no_bg_color_defaults(self):
        hab = {
            "name": "NoBgColor",
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["BG_COLOR"] == "2D3748"

    def test_agent_with_only_discord_token(self):
        """Agent has discordBotToken but no telegram token."""
        hab = {
            "name": "DiscordOnlyAgent",
            "platform": "discord",
            "agents": [{"agent": "Claude", "discordBotToken": "dc_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "dc_tok"
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == ""
        assert env["AGENT1_BOT_TOKEN"] == ""  # compat = telegram token = empty

    def test_agent_with_only_telegram_token_new_field(self):
        """Agent has telegramBotToken but no discord token."""
        hab = {
            "name": "TgOnlyAgent",
            "platform": "telegram",
            "agents": [{"agent": "Claude", "telegramBotToken": "tg_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "tg_tok"
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == ""
        assert env["AGENT1_BOT_TOKEN"] == "tg_tok"  # compat


# ---------------------------------------------------------------------------
# Tests: Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    def test_telegram_bot_token_preferred_over_bot_token(self):
        """If agent has both telegramBotToken and botToken, telegramBotToken wins."""
        hab = {
            "name": "BothTokens",
            "agents": [
                {
                    "agent": "Claude",
                    "botToken": "old_token",
                    "telegramBotToken": "new_token",
                }
            ],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "new_token"
        assert env["AGENT1_BOT_TOKEN"] == "new_token"

    def test_council_telegram_group_id_takes_precedence(self):
        """council.telegram.groupId takes precedence over council.groupId."""
        hab = {
            "name": "CouncilPrecedence",
            "council": {
                "groupId": "old_id",
                "groupName": "Council",
                "judge": "Opus",
                "telegram": {"groupId": "new_id"},
            },
            "agents": [{"agent": "Claude", "botToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["COUNCIL_GROUP_ID"] == "new_id"

    def test_zero_agents(self):
        hab = {
            "name": "NoAgents",
            "agents": [],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT_COUNT"] == "0"
