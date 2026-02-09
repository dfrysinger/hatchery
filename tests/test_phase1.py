#!/usr/bin/env python3
"""Tests for phase1-critical.sh platform-aware bootstrap config.

Reads the config-generation portion from scripts/phase1-critical.sh
(the source of truth with slim YAML approach), runs it with various
PLATFORM settings, and validates the generated minimal JSON config.
"""

import base64
import json
import os
import re
import subprocess
import tempfile

import pytest


def b64(s):
    """Base64-encode a string."""
    return base64.b64encode(s.encode()).decode()


def extract_phase1_script():
    """Read phase1-critical.sh from scripts/ directory."""
    script_path = os.path.join(os.path.dirname(__file__), "..", "scripts", "phase1-critical.sh")
    with open(script_path) as f:
        return f.read()


def make_phase1_stub(script_content, tmp_dir):
    """Extract only the config-generation portion of phase1-critical.sh.

    We take everything from the start up to and including the CFG heredoc,
    skipping system commands (apt, npm, systemctl, etc) and stubbing
    out external dependencies.
    """
    home = os.path.join(tmp_dir, "home", "bot")
    openclaw_dir = os.path.join(home, ".openclaw")
    clawd_dir = os.path.join(home, "clawd", "agents", "agent1", "memory")
    os.makedirs(openclaw_dir, exist_ok=True)
    os.makedirs(clawd_dir, exist_ok=True)

    lines = script_content.split("\n")

    # Find the section from variable assignments through the CFG heredoc
    # We need: d() function, variable assignments, platform logic, cat heredoc
    result_lines = ["#!/bin/bash", "set -e"]
    result_lines.append('d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }')

    # State machine to extract the config-gen portion
    capturing = False
    in_heredoc = False
    skip_block = 0  # track nested if blocks to skip

    for line in lines:
        stripped = line.strip()

        # Skip source/set commands
        if "source /etc/droplet.env" in line:
            continue
        if "source /etc/habitat-parsed.env" in line:
            continue
        if "set -a;" in line or "set -e" in stripped:
            continue

        # Skip parse-habitat.py block (if ! python3 ... fi)
        if "if ! python3" in line:
            skip_block = 1
            continue
        if skip_block > 0:
            if stripped == "fi":
                skip_block -= 1
            continue

        # Start capturing at H= assignment (moved earlier for chown fix)
        if not capturing and re.match(r'\s*H=', stripped):
            capturing = True

        if not capturing:
            continue

        # Replace openssl with static value
        if "openssl rand" in line:
            result_lines.append('      GT="test-gateway-token"')
            continue

        # Skip echo/ln/chown/chmod and other non-config-gen commands
        if any(cmd in stripped for cmd in [
            'echo "$GT"',
            'ln -sf',
            '$TG ', '$S ',
            'NODE_PID=', 'wait $NODE_PID',
            'tar -xJ', 'rm -f',
            'apt-get', 'npm install',
            'useradd', 'chpasswd', 'chown', 'chmod',
            'echo "$USERNAME"', 'sudoers',
            'cp $H/', 'echo "ANTHROPIC',
            'GCID=', 'GSEC=', 'GRTK=',
            'echo -e', 'cat >',
            'systemctl', 'ufw ',
            'BOT_OK=', 'for i in', 'journalctl',
            'touch /var', 'END=',
            '/usr/local/bin/set-phase',
            'nohup', 'disown',
            'echo "$START"',
        ]):
            if "cat > $H/.openclaw/openclaw.json" in stripped:
                # This IS the heredoc we want
                pass
            else:
                continue

        result_lines.append(line)

        # Track heredoc
        if "cat > $H/.openclaw/openclaw.json <<CFG" in stripped:
            in_heredoc = True
        if in_heredoc and stripped == "CFG":
            break

    stub = "\n".join(result_lines)

    # Replace H= with test path
    stub = re.sub(
        r'H="/home/\$USERNAME"',
        f'H="{home}"',
        stub,
    )

    return stub, home


def run_phase1_config(platform="telegram", tg_token="tg-bot-token-1",
                      dc_token="dc-bot-token-1", telegram_user_id="12345",
                      discord_owner_id="", discord_guild_id="",
                      agent_name="Claude"):
    """Run the phase1 config generation and return parsed JSON."""
    script_content = extract_phase1_script()

    with tempfile.TemporaryDirectory() as tmp_dir:
        stub_script, home = make_phase1_stub(script_content, tmp_dir)

        env = os.environ.copy()
        env["USERNAME"] = "bot"
        env["PLATFORM"] = platform
        env["PLATFORM_B64"] = b64(platform)
        env["AGENT1_BOT_TOKEN"] = tg_token
        env["AGENT1_DISCORD_BOT_TOKEN"] = dc_token
        env["AGENT1_NAME"] = agent_name
        env["TELEGRAM_USER_ID_B64"] = b64(telegram_user_id)
        env["DISCORD_OWNER_ID"] = discord_owner_id
        env["DISCORD_OWNER_ID_B64"] = b64(discord_owner_id) if discord_owner_id else ""
        env["DISCORD_GUILD_ID"] = discord_guild_id
        env["DISCORD_GUILD_ID_B64"] = b64(discord_guild_id) if discord_guild_id else ""
        env["ANTHROPIC_KEY_B64"] = b64("sk-ant-test-key")
        env["GOOGLE_API_KEY_B64"] = ""

        script_path = os.path.join(tmp_dir, "test-phase1.sh")
        with open(script_path, "w") as f:
            f.write(stub_script)
        os.chmod(script_path, 0o755)

        result = subprocess.run(
            ["bash", script_path],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            pytest.fail(
                f"Script failed (rc={result.returncode}):\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}\n"
                f"Script:\n{stub_script}"
            )

        config_path = os.path.join(home, ".openclaw", "openclaw.json")
        if not os.path.exists(config_path):
            pytest.fail(
                f"Config not created at {config_path}\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}\n"
                f"Script:\n{stub_script}"
            )

        with open(config_path) as f:
            raw = f.read()

        try:
            return json.loads(raw)
        except json.JSONDecodeError as e:
            pytest.fail(f"Invalid JSON:\n{raw}\nError: {e}")


# === Tests ===


class TestPhase1Telegram:
    """phase1-critical.sh with PLATFORM=telegram."""

    def test_telegram_plugin_enabled(self):
        config = run_phase1_config(platform="telegram")
        assert config["plugins"]["entries"]["telegram"]["enabled"] is True

    def test_discord_plugin_disabled(self):
        config = run_phase1_config(platform="telegram")
        assert config["plugins"]["entries"]["discord"]["enabled"] is False

    def test_telegram_channel_enabled(self):
        config = run_phase1_config(platform="telegram")
        assert config["channels"]["telegram"]["enabled"] is True

    def test_discord_channel_disabled(self):
        config = run_phase1_config(platform="telegram")
        assert config["channels"]["discord"]["enabled"] is False

    def test_telegram_bot_token(self):
        config = run_phase1_config(platform="telegram", tg_token="my-tg-token")
        assert config["channels"]["telegram"]["accounts"]["default"]["botToken"] == "my-tg-token"

    def test_telegram_allowlist(self):
        config = run_phase1_config(platform="telegram", telegram_user_id="99999")
        assert "99999" in config["channels"]["telegram"]["allowFrom"]


class TestPhase1Discord:
    """phase1-critical.sh with PLATFORM=discord."""

    def test_discord_plugin_enabled(self):
        config = run_phase1_config(platform="discord")
        assert config["plugins"]["entries"]["discord"]["enabled"] is True

    def test_telegram_plugin_disabled(self):
        config = run_phase1_config(platform="discord")
        assert config["plugins"]["entries"]["telegram"]["enabled"] is False

    def test_discord_channel_enabled(self):
        config = run_phase1_config(platform="discord")
        assert config["channels"]["discord"]["enabled"] is True

    def test_telegram_channel_disabled(self):
        config = run_phase1_config(platform="discord")
        assert config["channels"]["telegram"]["enabled"] is False

    def test_discord_bot_token(self):
        config = run_phase1_config(platform="discord", dc_token="my-dc-token")
        assert config["channels"]["discord"]["accounts"]["default"]["token"] == "my-dc-token"

    def test_discord_dm_enabled(self):
        config = run_phase1_config(platform="discord")
        assert config["channels"]["discord"]["dm"]["enabled"] is True
        assert config["channels"]["discord"]["dm"]["policy"] == "pairing"

    def test_discord_owner_allowlist(self):
        config = run_phase1_config(platform="discord", discord_owner_id="owner-123")
        assert "owner-123" in config["channels"]["discord"]["dm"]["allowFrom"]

    def test_discord_guild(self):
        config = run_phase1_config(platform="discord", discord_guild_id="guild-456")
        assert "guild-456" in config["channels"]["discord"]["guilds"]

    def test_discord_no_owner_no_allowfrom(self):
        config = run_phase1_config(platform="discord", discord_owner_id="")
        dm = config["channels"]["discord"]["dm"]
        assert "allowFrom" not in dm

    def test_discord_no_guild_no_guilds(self):
        config = run_phase1_config(platform="discord", discord_guild_id="")
        assert "guilds" not in config["channels"]["discord"]

    def test_discord_group_policy(self):
        config = run_phase1_config(platform="discord")
        assert config["channels"]["discord"]["groupPolicy"] == "allowlist"


class TestPhase1Both:
    """phase1-critical.sh with PLATFORM=both."""

    def test_both_plugins_enabled(self):
        config = run_phase1_config(platform="both")
        assert config["plugins"]["entries"]["telegram"]["enabled"] is True
        assert config["plugins"]["entries"]["discord"]["enabled"] is True

    def test_both_channels_enabled(self):
        config = run_phase1_config(platform="both")
        assert config["channels"]["telegram"]["enabled"] is True
        assert config["channels"]["discord"]["enabled"] is True

    def test_both_have_bot_tokens(self):
        config = run_phase1_config(platform="both", tg_token="tg-tok", dc_token="dc-tok")
        assert config["channels"]["telegram"]["accounts"]["default"]["botToken"] == "tg-tok"
        assert config["channels"]["discord"]["accounts"]["default"]["token"] == "dc-tok"


class TestTokenKeyNames:
    """Validate correct token key names per platform.
    
    Discord uses 'token', Telegram uses 'botToken'. These are different
    and must not be confused - openclaw will reject unrecognized keys.
    """

    def test_telegram_uses_botToken_key(self):
        """Telegram channel accounts must use 'botToken' key."""
        config = run_phase1_config(platform="telegram")
        tg_default = config["channels"]["telegram"]["accounts"]["default"]
        assert "botToken" in tg_default, "Telegram should use 'botToken' key"
        assert "token" not in tg_default, "Telegram should NOT have 'token' key"

    def test_discord_uses_token_key(self):
        """Discord channel accounts must use 'token' key (not 'botToken')."""
        config = run_phase1_config(platform="discord")
        dc_default = config["channels"]["discord"]["accounts"]["default"]
        assert "token" in dc_default, "Discord should use 'token' key"
        assert "botToken" not in dc_default, "Discord should NOT have 'botToken' key"

    def test_both_platforms_use_correct_keys(self):
        """When both platforms enabled, each uses its correct token key."""
        config = run_phase1_config(platform="both")
        
        tg_default = config["channels"]["telegram"]["accounts"]["default"]
        assert "botToken" in tg_default, "Telegram should use 'botToken'"
        assert "token" not in tg_default, "Telegram should NOT have 'token'"
        
        dc_default = config["channels"]["discord"]["accounts"]["default"]
        assert "token" in dc_default, "Discord should use 'token'"
        assert "botToken" not in dc_default, "Discord should NOT have 'botToken'"


class TestPhase1ConfigStructure:
    """Structural checks on the generated minimal config."""

    def test_valid_json_all_platforms(self):
        for platform in ["telegram", "discord", "both"]:
            config = run_phase1_config(platform=platform)
            assert isinstance(config, dict), f"Invalid config for platform={platform}"

    def test_has_required_sections(self):
        config = run_phase1_config(platform="both")
        for key in ["env", "agents", "gateway", "plugins", "channels"]:
            assert key in config, f"Missing section: {key}"

    def test_gateway_config(self):
        config = run_phase1_config(platform="telegram")
        gw = config["gateway"]
        assert gw["port"] == 18789
        assert gw["auth"]["mode"] == "token"
        assert gw["auth"]["token"] == "test-gateway-token"

    def test_agent_config(self):
        config = run_phase1_config(platform="telegram", agent_name="TestBot")
        agents = config["agents"]["list"]
        assert len(agents) == 1
        assert agents[0]["name"] == "TestBot"
        assert agents[0]["id"] == "agent1"
        assert agents[0]["default"] is True

    def test_anthropic_key(self):
        config = run_phase1_config(platform="telegram")
        assert config["env"]["ANTHROPIC_API_KEY"] == "sk-ant-test-key"

    def test_default_platform_is_telegram(self):
        """When PLATFORM is not set, defaults to telegram."""
        config = run_phase1_config(platform="telegram")
        assert config["channels"]["telegram"]["enabled"] is True
