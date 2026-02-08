#!/usr/bin/env python3
"""Tests for parse-habitat.py v2 schema with v1 backward compatibility.

Instead of subprocess-exec'ing a generated script, we replicate the core
parse logic in a helper function and test it directly. This mirrors what
the embedded parse-habitat.py does but writes to temp files.

Schema versions:
- v2 (new): platforms.discord, agents[].tokens.discord
- v1 (legacy): discord, agents[].discordBotToken

See issue #112 for v1 deprecation timeline.
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


def get_platform_config(hab, platform_name):
    """Get platform config: v2 (platforms.X) or v1 (X) format."""
    platforms = hab.get("platforms", {})
    if platform_name in platforms:
        return platforms[platform_name]
    # v1 fallback: top-level discord/telegram
    return hab.get(platform_name, {})


def get_agent_token(agent_ref, platform_name):
    """Get agent token: v2 (tokens.X) or v1 (XBotToken) format."""
    tokens = agent_ref.get("tokens", {})
    if platform_name in tokens:
        return tokens[platform_name]
    # v1 fallback: discordBotToken, telegramBotToken, botToken
    if platform_name == "discord":
        return agent_ref.get("discordBotToken", "")
    elif platform_name == "telegram":
        return agent_ref.get("telegramBotToken", agent_ref.get("botToken", ""))
    return ""


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

    # Discord config (v2: platforms.discord, v1: discord)
    discord_cfg = get_platform_config(hab, "discord")
    lines.append('DISCORD_GUILD_ID="{}"\n'.format(discord_cfg.get("serverId", "")))
    lines.append('DISCORD_GUILD_ID_B64="{}"\n'.format(_b64(discord_cfg.get("serverId", ""))))
    lines.append('DISCORD_OWNER_ID="{}"\n'.format(discord_cfg.get("ownerId", "")))
    lines.append('DISCORD_OWNER_ID_B64="{}"\n'.format(_b64(discord_cfg.get("ownerId", ""))))

    # Telegram config (v2: platforms.telegram, v1: telegram)
    telegram_cfg = get_platform_config(hab, "telegram")
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

    # API server bind address
    lines.append('API_BIND_ADDRESS="{}"\n'.format(hab.get("apiBindAddress", "0.0.0.0")))

    lines.append('GLOBAL_IDENTITY_B64="{}"\n'.format(_b64(hab.get("globalIdentity", ""))))
    lines.append('GLOBAL_BOOT_B64="{}"\n'.format(_b64(hab.get("globalBoot", ""))))
    lines.append('GLOBAL_BOOTSTRAP_B64="{}"\n'.format(_b64(hab.get("globalBootstrap", ""))))
    lines.append('GLOBAL_SOUL_B64="{}"\n'.format(_b64(hab.get("globalSoul", ""))))
    lines.append('GLOBAL_AGENTS_B64="{}"\n'.format(_b64(hab.get("globalAgents", ""))))
    lines.append('GLOBAL_USER_B64="{}"\n'.format(_b64(hab.get("globalUser", ""))))
    lines.append('GLOBAL_TOOLS_B64="{}"\n'.format(_b64(hab.get("globalTools", ""))))

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

        # Get tokens (v2: tokens.X, v1: XBotToken)
        tg_bot_token = get_agent_token(agent_ref, "telegram")
        dc_bot_token = get_agent_token(agent_ref, "discord")

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
def v2_schema_habitat():
    """v2 schema with platforms.discord and agents[].tokens.discord."""
    return {
        "name": "Habitat-v2",
        "domain": "bot.frysinger.org",
        "destructMinutes": 0,
        "bgColor": "2D3748",
        "platform": "discord",
        "platforms": {
            "discord": {
                "serverId": "1468992121901027582",
                "ownerId": "795380005466800159",
            },
            "telegram": {
                "ownerId": "5874850284",
            },
        },
        "council": {
            "groupName": "The Council",
            "judge": "Opus",
            "telegram": {"groupId": "5134780848"},
        },
        "globalIdentity": "Be awesome",
        "agents": [
            {
                "agent": "Claude",
                "tokens": {
                    "discord": "MTQ2OD_discord_token",
                    "telegram": "8513046_telegram_token",
                },
            }
        ],
    }


@pytest.fixture
def v1_schema_habitat():
    """v1 (legacy) schema with top-level discord and discordBotToken."""
    return {
        "name": "Habitat-v1",
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
        "agents": [
            {
                "agent": "Claude",
                "discordBotToken": "MTQ2OD_discord_token",
                "telegramBotToken": "8513046_telegram_token",
            }
        ],
    }


@pytest.fixture
def legacy_bottoken_habitat():
    """Very old schema with only botToken (pre dual-platform)."""
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
        "agents": [
            {
                "agent": "Claude",
                "botToken": "legacy_telegram_token_123",
            }
        ],
    }


# ---------------------------------------------------------------------------
# Tests: v2 schema (new format)
# ---------------------------------------------------------------------------

class TestV2Schema:
    """Tests for v2 schema: platforms.X and agents[].tokens.X"""

    def test_platform_field(self, v2_schema_habitat):
        env = run_parse_habitat(v2_schema_habitat)
        assert env["PLATFORM"] == "discord"
        assert b64d(env["PLATFORM_B64"]) == "discord"

    def test_discord_guild_id(self, v2_schema_habitat):
        env = run_parse_habitat(v2_schema_habitat)
        assert env["DISCORD_GUILD_ID"] == "1468992121901027582"
        assert b64d(env["DISCORD_GUILD_ID_B64"]) == "1468992121901027582"

    def test_discord_owner_id(self, v2_schema_habitat):
        env = run_parse_habitat(v2_schema_habitat)
        assert env["DISCORD_OWNER_ID"] == "795380005466800159"
        assert b64d(env["DISCORD_OWNER_ID_B64"]) == "795380005466800159"

    def test_telegram_owner_id(self, v2_schema_habitat):
        env = run_parse_habitat(v2_schema_habitat)
        assert env["TELEGRAM_OWNER_ID"] == "5874850284"
        assert b64d(env["TELEGRAM_OWNER_ID_B64"]) == "5874850284"

    def test_agent_discord_token_from_tokens(self, v2_schema_habitat):
        env = run_parse_habitat(v2_schema_habitat)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "MTQ2OD_discord_token"
        assert b64d(env["AGENT1_DISCORD_BOT_TOKEN_B64"]) == "MTQ2OD_discord_token"

    def test_agent_telegram_token_from_tokens(self, v2_schema_habitat):
        env = run_parse_habitat(v2_schema_habitat)
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "8513046_telegram_token"
        assert b64d(env["AGENT1_TELEGRAM_BOT_TOKEN_B64"]) == "8513046_telegram_token"

    def test_agent_bot_token_compat(self, v2_schema_habitat):
        """AGENT{N}_BOT_TOKEN should equal telegram token for backward compat."""
        env = run_parse_habitat(v2_schema_habitat)
        assert env["AGENT1_BOT_TOKEN"] == "8513046_telegram_token"

    def test_minimal_v2_discord(self):
        """Minimal v2 Discord habitat."""
        hab = {
            "name": "Minimal",
            "platform": "discord",
            "platforms": {
                "discord": {"ownerId": "123456"}
            },
            "agents": [{
                "agent": "bot",
                "tokens": {"discord": "token123"}
            }]
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "discord"
        assert env["DISCORD_OWNER_ID"] == "123456"
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "token123"

    def test_minimal_v2_telegram(self):
        """Minimal v2 Telegram habitat."""
        hab = {
            "name": "Minimal",
            "platform": "telegram",
            "platforms": {
                "telegram": {"ownerId": "789012"}
            },
            "agents": [{
                "agent": "bot",
                "tokens": {"telegram": "tg_token"}
            }]
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "telegram"
        assert env["TELEGRAM_OWNER_ID"] == "789012"
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "tg_token"

    def test_v2_multi_agent(self):
        """v2 with multiple agents."""
        hab = {
            "name": "MultiAgent",
            "platform": "discord",
            "platforms": {
                "discord": {"ownerId": "111"},
                "telegram": {"ownerId": "222"},
            },
            "agents": [
                {"agent": "Claude", "tokens": {"discord": "dc1", "telegram": "tg1"}},
                {"agent": "Gemini", "tokens": {"discord": "dc2", "telegram": "tg2"}},
            ],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT_COUNT"] == "2"
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "dc1"
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "tg1"
        assert env["AGENT2_DISCORD_BOT_TOKEN"] == "dc2"
        assert env["AGENT2_TELEGRAM_BOT_TOKEN"] == "tg2"


# ---------------------------------------------------------------------------
# Tests: v1 schema (legacy format - deprecated)
# ---------------------------------------------------------------------------

class TestV1Schema:
    """Tests for v1 (deprecated) schema: top-level discord and discordBotToken."""

    def test_platform_field(self, v1_schema_habitat):
        env = run_parse_habitat(v1_schema_habitat)
        assert env["PLATFORM"] == "discord"
        assert b64d(env["PLATFORM_B64"]) == "discord"

    def test_discord_guild_id(self, v1_schema_habitat):
        env = run_parse_habitat(v1_schema_habitat)
        assert env["DISCORD_GUILD_ID"] == "1468992121901027582"

    def test_discord_owner_id(self, v1_schema_habitat):
        env = run_parse_habitat(v1_schema_habitat)
        assert env["DISCORD_OWNER_ID"] == "795380005466800159"

    def test_telegram_owner_id(self, v1_schema_habitat):
        env = run_parse_habitat(v1_schema_habitat)
        assert env["TELEGRAM_OWNER_ID"] == "5874850284"

    def test_agent_discord_token(self, v1_schema_habitat):
        env = run_parse_habitat(v1_schema_habitat)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "MTQ2OD_discord_token"

    def test_agent_telegram_token(self, v1_schema_habitat):
        env = run_parse_habitat(v1_schema_habitat)
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "8513046_telegram_token"

    def test_v1_v2_produce_same_output(self, v1_schema_habitat, v2_schema_habitat):
        """v1 and v2 schemas should produce identical env vars (except name)."""
        env_v1 = run_parse_habitat(v1_schema_habitat)
        env_v2 = run_parse_habitat(v2_schema_habitat)

        # Compare all keys except HABITAT_NAME
        for key in env_v1:
            if key.startswith("HABITAT_NAME"):
                continue
            assert env_v1[key] == env_v2[key], f"Mismatch for {key}: v1={env_v1[key]}, v2={env_v2[key]}"


# ---------------------------------------------------------------------------
# Tests: Very old botToken schema
# ---------------------------------------------------------------------------

class TestLegacyBotTokenSchema:
    """Tests for very old schema with just botToken."""

    def test_platform_defaults_to_telegram(self, legacy_bottoken_habitat):
        env = run_parse_habitat(legacy_bottoken_habitat)
        assert env["PLATFORM"] == "telegram"
        assert b64d(env["PLATFORM_B64"]) == "telegram"

    def test_bot_token_fallback(self, legacy_bottoken_habitat):
        """When only botToken exists, it becomes telegramBotToken."""
        env = run_parse_habitat(legacy_bottoken_habitat)
        assert env["AGENT1_BOT_TOKEN"] == "legacy_telegram_token_123"
        assert env["AGENT1_TELEGRAM_BOT_TOKEN"] == "legacy_telegram_token_123"

    def test_discord_token_empty_when_missing(self, legacy_bottoken_habitat):
        env = run_parse_habitat(legacy_bottoken_habitat)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == ""

    def test_discord_fields_empty_when_no_section(self, legacy_bottoken_habitat):
        env = run_parse_habitat(legacy_bottoken_habitat)
        assert env["DISCORD_GUILD_ID"] == ""
        assert env["DISCORD_OWNER_ID"] == ""


# ---------------------------------------------------------------------------
# Tests: Platform field variations
# ---------------------------------------------------------------------------

class TestPlatformField:
    def test_platform_discord(self):
        hab = {
            "name": "DiscordOnly",
            "platform": "discord",
            "platforms": {"discord": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"discord": "dc_tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "discord"

    def test_platform_telegram(self):
        hab = {
            "name": "TelegramOnly",
            "platform": "telegram",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tg_tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "telegram"

    def test_platform_both(self):
        hab = {
            "name": "Both",
            "platform": "both",
            "platforms": {
                "discord": {"serverId": "111", "ownerId": "222"},
                "telegram": {"ownerId": "333"},
            },
            "agents": [{
                "agent": "Claude",
                "tokens": {"discord": "dc_tok", "telegram": "tg_tok"},
            }],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "both"
        assert env["DISCORD_GUILD_ID"] == "111"
        assert env["TELEGRAM_OWNER_ID"] == "333"

    def test_platform_missing_defaults_telegram(self):
        hab = {
            "name": "NoPlatform",
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tg_tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["PLATFORM"] == "telegram"


# ---------------------------------------------------------------------------
# Tests: v2 takes precedence over v1 when both present
# ---------------------------------------------------------------------------

class TestV2Precedence:
    """When both v2 and v1 fields exist, v2 should take precedence."""

    def test_platforms_takes_precedence_over_toplevel(self):
        """platforms.discord should win over discord."""
        hab = {
            "name": "MixedPlatform",
            "platform": "discord",
            "discord": {"ownerId": "v1_owner"},
            "platforms": {"discord": {"ownerId": "v2_owner"}},
            "agents": [{"agent": "Claude", "tokens": {"discord": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["DISCORD_OWNER_ID"] == "v2_owner"

    def test_tokens_takes_precedence_over_bot_token_fields(self):
        """tokens.discord should win over discordBotToken."""
        hab = {
            "name": "MixedTokens",
            "platform": "discord",
            "platforms": {"discord": {"ownerId": "123"}},
            "agents": [{
                "agent": "Claude",
                "discordBotToken": "v1_token",
                "tokens": {"discord": "v2_token"},
            }],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "v2_token"


# ---------------------------------------------------------------------------
# Tests: Missing optional fields
# ---------------------------------------------------------------------------

class TestMissingOptionalFields:
    def test_no_platforms_section(self):
        """No platforms section at all - should use v1 fallback."""
        hab = {
            "name": "NoV2",
            "platform": "discord",
            "discord": {"ownerId": "123"},
            "agents": [{"agent": "Claude", "discordBotToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["DISCORD_OWNER_ID"] == "123"
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "tok"

    def test_empty_platforms_section(self):
        """Empty platforms section - should use v1 fallback."""
        hab = {
            "name": "EmptyV2",
            "platform": "discord",
            "platforms": {},
            "discord": {"ownerId": "456"},
            "agents": [{"agent": "Claude", "discordBotToken": "tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["DISCORD_OWNER_ID"] == "456"

    def test_no_tokens_in_agent(self):
        """Agent without tokens section - should use v1 fallback."""
        hab = {
            "name": "NoTokens",
            "platform": "discord",
            "platforms": {"discord": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "discordBotToken": "v1_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "v1_tok"

    def test_empty_tokens_in_agent(self):
        """Agent with empty tokens section - should use v1 fallback."""
        hab = {
            "name": "EmptyTokens",
            "platform": "discord",
            "platforms": {"discord": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {}, "discordBotToken": "v1_tok"}],
        }
        env = run_parse_habitat(hab)
        assert env["AGENT1_DISCORD_BOT_TOKEN"] == "v1_tok"

    def test_no_council(self):
        hab = {
            "name": "NoCouncil",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["COUNCIL_GROUP_ID"] == ""
        assert env["COUNCIL_GROUP_NAME"] == ""
        assert env["COUNCIL_JUDGE"] == ""

    def test_no_domain(self):
        hab = {
            "name": "NoDomain",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["HABITAT_DOMAIN"] == ""

    def test_no_bg_color_defaults(self):
        hab = {
            "name": "NoBgColor",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["BG_COLOR"] == "2D3748"


# ---------------------------------------------------------------------------
# Tests: globalTools field
# ---------------------------------------------------------------------------

class TestGlobalTools:
    """Tests for globalTools → GLOBAL_TOOLS_B64 parsing."""

    def test_global_tools_parsed(self):
        tools_content = "Cloud VM (Ubuntu), display :10\n\ngmail-api.py for email"
        hab = {
            "name": "WithTools",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
            "globalTools": tools_content,
        }
        env = run_parse_habitat(hab)
        assert env["GLOBAL_TOOLS_B64"] == b64e(tools_content)
        assert b64d(env["GLOBAL_TOOLS_B64"]) == tools_content

    def test_global_tools_empty_when_missing(self):
        hab = {
            "name": "NoTools",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["GLOBAL_TOOLS_B64"] == b64e("")


# ---------------------------------------------------------------------------
# Tests: Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    def test_telegram_token_preferred_over_bot_token_v1(self):
        """If agent has both telegramBotToken and botToken, telegramBotToken wins (v1)."""
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
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
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

    def test_api_bind_address_default(self):
        hab = {
            "name": "NoApiAddr",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["API_BIND_ADDRESS"] == "0.0.0.0"

    def test_api_bind_address_custom(self):
        hab = {
            "name": "CustomApiAddr",
            "apiBindAddress": "127.0.0.1",
            "platforms": {"telegram": {"ownerId": "123"}},
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok"}}],
        }
        env = run_parse_habitat(hab)
        assert env["API_BIND_ADDRESS"] == "127.0.0.1"
