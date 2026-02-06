#!/usr/bin/env python3
"""Tests for tg-notify.sh platform-aware notifications.

Extracts tg-notify.sh from hatch.yaml and tests its platform routing
logic by stubbing out curl and python3 calls.
"""

import base64
import os
import re
import subprocess
import tempfile

import pytest
import yaml


def b64(s):
    """Base64-encode a string."""
    return base64.b64encode(s.encode()).decode()


def extract_notify_script():
    """Extract tg-notify.sh content from hatch.yaml."""
    hatch_path = os.path.join(os.path.dirname(__file__), "..", "hatch.yaml")
    with open(hatch_path) as f:
        data = yaml.safe_load(f)

    for entry in data.get("write_files", []):
        if entry.get("path") == "/usr/local/bin/tg-notify.sh":
            return entry["content"]
    raise RuntimeError("tg-notify.sh not found in hatch.yaml")


def make_notify_stub(script_content, tmp_dir, curl_behavior="success"):
    """Create a test-friendly version of tg-notify.sh.

    Stubs:
    - /etc/droplet.env and /etc/habitat-parsed.env with test values
    - curl with a logging fake that records calls
    - parse-habitat.py (skipped)

    curl_behavior: "success", "fail_telegram", "fail_discord", "fail_all"
    """
    # Create fake droplet.env
    droplet_env = os.path.join(tmp_dir, "droplet.env")
    parsed_env = os.path.join(tmp_dir, "habitat-parsed.env")
    curl_log = os.path.join(tmp_dir, "curl_calls.log")

    # Create fake curl
    curl_path = os.path.join(tmp_dir, "bin", "curl")
    os.makedirs(os.path.join(tmp_dir, "bin"), exist_ok=True)

    if curl_behavior == "success":
        curl_script = f"""#!/bin/bash
echo "$@" >> "{curl_log}"
# For Discord DM channel creation, return channel JSON
if echo "$@" | grep -q "users/@me/channels"; then
  echo '{{"id":"dm-channel-123"}}'
fi
exit 0
"""
    elif curl_behavior == "fail_telegram":
        curl_script = f"""#!/bin/bash
echo "$@" >> "{curl_log}"
if echo "$@" | grep -q "api.telegram.org"; then
  exit 1
fi
# For Discord: first curl (create DM) returns channel JSON, second (send msg) succeeds
if echo "$@" | grep -q "users/@me/channels"; then
  echo '{{"id":"dm-channel-123"}}'
  exit 0
fi
exit 0
"""
    elif curl_behavior == "fail_discord":
        curl_script = f"""#!/bin/bash
echo "$@" >> "{curl_log}"
if echo "$@" | grep -q "discord.com"; then
  exit 1
fi
exit 0
"""
    elif curl_behavior == "fail_all":
        curl_script = f"""#!/bin/bash
echo "$@" >> "{curl_log}"
exit 1
"""
    else:
        curl_script = f"""#!/bin/bash
echo "$@" >> "{curl_log}"
# For Discord DM channel creation, output JSON
if echo "$@" | grep -q "users/@me/channels"; then
  echo '{{"id":"dm-channel-123"}}'
  exit 0
fi
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


def run_notify(platform="telegram", message="Test notification",
               tg_token="tg-bot-token", tg_user_id="12345",
               dc_token="dc-bot-token", dc_owner_id="owner-999",
               curl_behavior="success"):
    """Run tg-notify.sh and return (exit_code, curl_calls)."""
    script_content = extract_notify_script()

    with tempfile.TemporaryDirectory() as tmp_dir:
        modified, droplet_env, parsed_env, curl_log = make_notify_stub(
            script_content, tmp_dir, curl_behavior
        )

        # Write env files
        with open(droplet_env, "w") as f:
            f.write(f'TELEGRAM_USER_ID_B64="{b64(tg_user_id)}"\n')
            f.write(f'PLATFORM_B64="{b64(platform)}"\n')
            f.write(f'DISCORD_OWNER_ID_B64="{b64(dc_owner_id)}"\n')

        with open(parsed_env, "w") as f:
            f.write(f'AGENT1_BOT_TOKEN="{tg_token}"\n')
            f.write(f'AGENT1_DISCORD_BOT_TOKEN="{dc_token}"\n')
            f.write(f'PLATFORM="{platform}"\n')
            f.write(f'DISCORD_OWNER_ID="{dc_owner_id}"\n')
            f.write(f'TELEGRAM_USER_ID_B64="{b64(tg_user_id)}"\n')

        script_path = os.path.join(tmp_dir, "test-notify.sh")
        with open(script_path, "w") as f:
            f.write(modified)
        os.chmod(script_path, 0o755)

        result = subprocess.run(
            ["bash", script_path, message],
            capture_output=True,
            text=True,
            timeout=30,
        )

        curl_calls = []
        if os.path.exists(curl_log):
            with open(curl_log) as f:
                curl_calls = [line.strip() for line in f if line.strip()]

        return result.returncode, curl_calls


# === Tests ===


class TestNotifyTelegram:
    """PLATFORM=telegram notifications."""

    def test_sends_telegram(self):
        rc, calls = run_notify(platform="telegram")
        assert rc == 0
        assert any("api.telegram.org" in c for c in calls)

    def test_no_discord_calls(self):
        rc, calls = run_notify(platform="telegram")
        assert not any("discord.com" in c for c in calls)

    def test_uses_bot_token(self):
        rc, calls = run_notify(platform="telegram", tg_token="my-special-token")
        tg_calls = [c for c in calls if "api.telegram.org" in c]
        assert any("my-special-token" in c for c in tg_calls)

    def test_fails_without_token(self):
        rc, calls = run_notify(platform="telegram", tg_token="")
        assert rc != 0

    def test_fails_without_user_id(self):
        rc, calls = run_notify(platform="telegram", tg_user_id="")
        assert rc != 0


class TestNotifyDiscord:
    """PLATFORM=discord notifications."""

    def test_sends_discord(self):
        rc, calls = run_notify(platform="discord")
        assert rc == 0
        assert any("discord.com" in c for c in calls)

    def test_no_telegram_calls(self):
        rc, calls = run_notify(platform="discord")
        assert not any("api.telegram.org" in c for c in calls)

    def test_creates_dm_channel(self):
        rc, calls = run_notify(platform="discord")
        assert any("users/@me/channels" in c for c in calls)

    def test_sends_to_dm_channel(self):
        rc, calls = run_notify(platform="discord")
        assert any("channels/" in c and "messages" in c for c in calls)

    def test_uses_bot_token(self):
        rc, calls = run_notify(platform="discord", dc_token="special-dc-token")
        dc_calls = [c for c in calls if "discord.com" in c]
        assert any("special-dc-token" in c for c in dc_calls)

    def test_fails_without_token(self):
        rc, calls = run_notify(platform="discord", dc_token="")
        assert rc != 0

    def test_fails_without_owner_id(self):
        rc, calls = run_notify(platform="discord", dc_owner_id="")
        assert rc != 0


class TestNotifyBoth:
    """PLATFORM=both notifications."""

    def test_sends_both_platforms(self):
        rc, calls = run_notify(platform="both")
        assert rc == 0
        assert any("api.telegram.org" in c for c in calls)
        assert any("discord.com" in c for c in calls)

    def test_succeeds_if_telegram_fails(self):
        """Should succeed if at least one platform works."""
        rc, calls = run_notify(platform="both", curl_behavior="fail_telegram")
        assert rc == 0
        assert any("discord.com" in c for c in calls)

    def test_succeeds_if_discord_fails(self):
        """Should succeed if at least one platform works."""
        rc, calls = run_notify(platform="both", curl_behavior="fail_discord")
        assert rc == 0
        assert any("api.telegram.org" in c for c in calls)

    def test_fails_if_both_fail(self):
        """Should fail only if all platforms fail."""
        rc, calls = run_notify(platform="both", curl_behavior="fail_all")
        assert rc != 0


class TestNotifyEdgeCases:
    """Edge cases and defaults."""

    def test_empty_message_exits(self):
        """Empty message should exit early."""
        rc, calls = run_notify(platform="telegram", message="")
        # Script should exit 1 for empty message
        assert rc != 0

    def test_unknown_platform_fails_fast(self):
        """Unknown platform should fail with non-zero exit (TASK-1 fail-fast)."""
        rc, calls = run_notify(platform="unknown_platform")
        assert rc != 0, "Unknown PLATFORM should cause script to fail"
        # Should NOT have made any API calls
        assert not any("api.telegram.org" in c for c in calls), "Should not fall back to telegram"
        assert not any("discord.com" in c for c in calls), "Should not fall back to discord"
