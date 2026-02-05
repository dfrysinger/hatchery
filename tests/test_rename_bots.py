#!/usr/bin/env python3
"""Tests for rename-bots.sh platform-aware bot renaming.

Extracts rename-bots.sh from hatch.yaml and tests its platform routing
logic by stubbing out curl and python3 calls.
"""

import base64
import os
import subprocess
import tempfile

import pytest
import yaml


def b64(s):
    """Base64-encode a string."""
    return base64.b64encode(s.encode()).decode()


def extract_rename_script():
    """Extract rename-bots.sh content from hatch.yaml."""
    hatch_path = os.path.join(os.path.dirname(__file__), "..", "hatch.yaml")
    with open(hatch_path) as f:
        data = yaml.safe_load(f)

    for entry in data.get("write_files", []):
        if entry.get("path") == "/usr/local/bin/rename-bots.sh":
            return entry["content"]
    raise RuntimeError("rename-bots.sh not found in hatch.yaml")


def make_rename_stub(script_content, tmp_dir):
    """Create a test-friendly version of rename-bots.sh.

    Stubs:
    - /etc/droplet.env and /etc/habitat-parsed.env with test values
    - curl with a logging fake that records calls
    - parse-habitat.py (skipped)
    """
    droplet_env = os.path.join(tmp_dir, "droplet.env")
    parsed_env = os.path.join(tmp_dir, "habitat-parsed.env")
    curl_log = os.path.join(tmp_dir, "curl_calls.log")

    # Create fake curl
    curl_path = os.path.join(tmp_dir, "bin", "curl")
    os.makedirs(os.path.join(tmp_dir, "bin"), exist_ok=True)

    curl_script = f"""#!/bin/bash
echo "$@" >> "{curl_log}"
exit 0
"""
    with open(curl_path, "w") as f:
        f.write(curl_script)
    os.chmod(curl_path, 0o755)

    # Modify the script to use our test paths
    modified = script_content
    modified = modified.replace(
        "source /etc/droplet.env",
        f"source {droplet_env}",
    )
    modified = modified.replace(
        "source /etc/habitat-parsed.env",
        f"source {parsed_env}",
    )
    modified = modified.replace(
        "[ ! -f /etc/habitat-parsed.env ] && python3 /usr/local/bin/parse-habitat.py 2>/dev/null",
        "# skipped parse-habitat",
    )
    modified = modified.replace(
        "[ -f /etc/habitat-parsed.env ]",
        f"[ -f {parsed_env} ]",
    )

    # Prepend PATH override so our fake curl is used
    modified = f'export PATH="{os.path.join(tmp_dir, "bin")}:$PATH"\n' + modified

    return modified, droplet_env, parsed_env, curl_log


def run_rename(platform="telegram", agent_count=1, agents=None,
               habitat_name="test-habitat"):
    """Run rename-bots.sh and return (exit_code, stdout, curl_calls).

    agents: list of dicts with 'name' and 'bot_token' keys.
             Defaults to [{"name": "Claude", "bot_token": "tg-token-123"}]
    """
    if agents is None:
        agents = [{"name": "Claude", "bot_token": "tg-token-123"}]

    script_content = extract_rename_script()

    with tempfile.TemporaryDirectory() as tmp_dir:
        modified, droplet_env, parsed_env, curl_log = make_rename_stub(
            script_content, tmp_dir
        )

        # Write env files
        with open(droplet_env, "w") as f:
            f.write(f'PLATFORM_B64="{b64(platform)}"\n')

        with open(parsed_env, "w") as f:
            f.write(f'PLATFORM="{platform}"\n')
            f.write(f'AGENT_COUNT={len(agents)}\n')
            f.write(f'HABITAT_NAME="{habitat_name}"\n')
            for i, agent in enumerate(agents, 1):
                f.write(f'AGENT{i}_NAME="{agent["name"]}"\n')
                f.write(f'AGENT{i}_BOT_TOKEN="{agent.get("bot_token", "")}"\n')

        script_path = os.path.join(tmp_dir, "test-rename.sh")
        with open(script_path, "w") as f:
            f.write(modified)
        os.chmod(script_path, 0o755)

        result = subprocess.run(
            ["bash", script_path],
            capture_output=True,
            text=True,
            timeout=30,
        )

        curl_calls = []
        if os.path.exists(curl_log):
            with open(curl_log) as f:
                curl_calls = [line.strip() for line in f if line.strip()]

        return result.returncode, result.stdout, curl_calls


# === Tests ===


class TestRenameTelegram:
    """PLATFORM=telegram: should rename Telegram bots via API."""

    def test_calls_telegram_api(self):
        rc, stdout, calls = run_rename(platform="telegram")
        assert rc == 0
        assert any("api.telegram.org" in c for c in calls)

    def test_calls_setMyName(self):
        rc, stdout, calls = run_rename(platform="telegram")
        assert any("setMyName" in c for c in calls)

    def test_uses_bot_token(self):
        rc, stdout, calls = run_rename(
            platform="telegram",
            agents=[{"name": "Claude", "bot_token": "my-special-token"}],
        )
        tg_calls = [c for c in calls if "api.telegram.org" in c]
        assert any("my-special-token" in c for c in tg_calls)

    def test_includes_habitat_name(self):
        rc, stdout, calls = run_rename(
            platform="telegram", habitat_name="MyHabitat"
        )
        tg_calls = [c for c in calls if "setMyName" in c]
        assert any("MyHabitat" in c for c in tg_calls)

    def test_display_name_format(self):
        rc, stdout, calls = run_rename(
            platform="telegram",
            agents=[{"name": "Claude", "bot_token": "tok"}],
            habitat_name="TestHab",
        )
        tg_calls = [c for c in calls if "setMyName" in c]
        assert any("ClaudeBot (TestHab)" in c for c in tg_calls)

    def test_logs_rename_action(self):
        rc, stdout, calls = run_rename(platform="telegram")
        assert "[rename-bots] Telegram: renamed" in stdout

    def test_skips_agent_without_token(self):
        rc, stdout, calls = run_rename(
            platform="telegram",
            agents=[{"name": "Claude", "bot_token": ""}],
        )
        assert rc == 0
        assert "[rename-bots] Telegram: skipping" in stdout
        assert not any("api.telegram.org" in c for c in calls)

    def test_multi_agent(self):
        agents = [
            {"name": "Claude", "bot_token": "tok1"},
            {"name": "Gemini", "bot_token": "tok2"},
        ]
        rc, stdout, calls = run_rename(platform="telegram", agents=agents)
        assert rc == 0
        tg_calls = [c for c in calls if "setMyName" in c]
        assert len(tg_calls) == 2
        assert any("tok1" in c for c in tg_calls)
        assert any("tok2" in c for c in tg_calls)

    def test_no_discord_calls(self):
        rc, stdout, calls = run_rename(platform="telegram")
        assert not any("discord.com" in c for c in calls)


class TestRenameDiscord:
    """PLATFORM=discord: should skip renaming, log Developer Portal message."""

    def test_no_api_calls(self):
        rc, stdout, calls = run_rename(platform="discord")
        assert rc == 0
        assert len(calls) == 0

    def test_no_telegram_calls(self):
        rc, stdout, calls = run_rename(platform="discord")
        assert not any("api.telegram.org" in c for c in calls)

    def test_logs_developer_portal_message(self):
        rc, stdout, calls = run_rename(platform="discord")
        assert "Developer Portal" in stdout

    def test_logs_skip_message(self):
        rc, stdout, calls = run_rename(platform="discord")
        assert "[rename-bots] Discord:" in stdout

    def test_no_errors(self):
        """Discord-only platform should never error."""
        rc, stdout, calls = run_rename(platform="discord")
        assert rc == 0

    def test_no_errors_without_telegram_tokens(self):
        """Should not error even when no Telegram tokens are configured."""
        rc, stdout, calls = run_rename(
            platform="discord",
            agents=[{"name": "Claude", "bot_token": ""}],
        )
        assert rc == 0


class TestRenameBoth:
    """PLATFORM=both: should rename Telegram bots and skip Discord."""

    def test_renames_telegram(self):
        rc, stdout, calls = run_rename(platform="both")
        assert rc == 0
        assert any("api.telegram.org" in c for c in calls)

    def test_logs_discord_skip(self):
        rc, stdout, calls = run_rename(platform="both")
        assert "Developer Portal" in stdout

    def test_no_discord_api_calls(self):
        rc, stdout, calls = run_rename(platform="both")
        assert not any("discord.com" in c for c in calls)

    def test_telegram_and_discord_log_messages(self):
        rc, stdout, calls = run_rename(platform="both")
        assert "[rename-bots] Telegram:" in stdout
        assert "[rename-bots] Discord:" in stdout


class TestRenameUnknownPlatform:
    """Unknown/empty platform: should default to telegram behavior."""

    def test_defaults_to_telegram(self):
        rc, stdout, calls = run_rename(platform="unknown_platform")
        assert rc == 0
        assert any("api.telegram.org" in c for c in calls)

    def test_logs_unknown_warning(self):
        rc, stdout, calls = run_rename(platform="unknown_platform")
        assert "Unknown platform" in stdout
        assert "defaulting to telegram" in stdout


class TestRenameExitCode:
    """Script should always exit 0 regardless of platform."""

    def test_telegram_exits_zero(self):
        rc, _, _ = run_rename(platform="telegram")
        assert rc == 0

    def test_discord_exits_zero(self):
        rc, _, _ = run_rename(platform="discord")
        assert rc == 0

    def test_both_exits_zero(self):
        rc, _, _ = run_rename(platform="both")
        assert rc == 0

    def test_unknown_exits_zero(self):
        rc, _, _ = run_rename(platform="weird")
        assert rc == 0
