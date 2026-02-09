"""
Tests for scripts in the scripts/ directory.

With the slim YAML approach, scripts/ is the source of truth. The scripts
are fetched from GitHub by bootstrap.sh during provisioning. This file
validates that all scripts exist, are executable, have proper shebangs,
and can be parsed without syntax errors.
"""

import os
import re
import stat
import subprocess
import pytest

# Root of the repository
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")

# All expected scripts with their type and minimum line count
EXPECTED_SCRIPTS = {
    "parse-habitat.py": {"type": "python", "shebang": "#!/usr/bin/env python3", "min_lines": 90},
    "tg-notify.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 50},
    "api-server.py": {"type": "python", "shebang": "#!/usr/bin/env python3", "min_lines": 40},
    "phase1-critical.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 150},
    "phase2-background.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 200},
    "build-full-config.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 300},
    "post-boot-check.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 50},
    "try-full-config.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 30},
    "restore-openclaw-state.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 50},
    "rename-bots.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 40},
}

# Utility scripts that require executable permissions (Issue #168)
# These scripts are smaller utilities that don't require full documentation
UTILITY_SCRIPTS = [
    "kill-droplet.sh",
    "mount-dropbox.sh",
    "schedule-destruct.sh",
    "verify-firewall.sh",
]

BASH_SCRIPTS = [name for name, info in EXPECTED_SCRIPTS.items() if info["type"] == "bash"]
PYTHON_SCRIPTS = [name for name, info in EXPECTED_SCRIPTS.items() if info["type"] == "python"]


class TestScriptFiles:
    """Test that all expected script files exist and have correct properties."""

    @pytest.mark.parametrize("script_name", EXPECTED_SCRIPTS.keys())
    def test_script_exists(self, script_name):
        """Each expected script file must exist in scripts/."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        assert os.path.isfile(path), f"Script {script_name} not found in scripts/"

    @pytest.mark.parametrize("script_name", EXPECTED_SCRIPTS.keys())
    def test_script_is_executable(self, script_name):
        """Each script must have the executable bit set."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        mode = os.stat(path).st_mode
        assert mode & stat.S_IXUSR, f"{script_name} is not executable (owner)"
        assert mode & stat.S_IXGRP, f"{script_name} is not executable (group)"
        assert mode & stat.S_IXOTH, f"{script_name} is not executable (other)"

    @pytest.mark.parametrize("script_name", EXPECTED_SCRIPTS.keys())
    def test_script_has_correct_shebang(self, script_name):
        """Each script must have the correct shebang line."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        expected_shebang = EXPECTED_SCRIPTS[script_name]["shebang"]
        with open(path, "r") as f:
            first_line = f.readline().strip()
        assert first_line == expected_shebang, (
            f"{script_name}: expected shebang '{expected_shebang}', got '{first_line}'"
        )

    @pytest.mark.parametrize("script_name", EXPECTED_SCRIPTS.keys())
    def test_script_has_header_comment(self, script_name):
        """Each script should have a descriptive header comment."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        with open(path, "r") as f:
            content = f.read(2000)  # Read first 2KB
        # Check for header block (=== ... === pattern)
        assert "============" in content, (
            f"{script_name}: missing header comment block"
        )
        # Check for purpose description
        assert "Purpose:" in content or "purpose" in content.lower(), (
            f"{script_name}: missing purpose description in header"
        )

    @pytest.mark.parametrize("script_name", EXPECTED_SCRIPTS.keys())
    def test_script_minimum_lines(self, script_name):
        """Each script should have at least the expected number of lines."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        with open(path, "r") as f:
            line_count = sum(1 for _ in f)
        min_lines = EXPECTED_SCRIPTS[script_name]["min_lines"]
        assert line_count >= min_lines, (
            f"{script_name}: expected >= {min_lines} lines, got {line_count}"
        )


class TestBashScriptSyntax:
    """Validate bash scripts can be parsed without syntax errors."""

    @pytest.mark.parametrize("script_name", BASH_SCRIPTS)
    def test_bash_syntax(self, script_name):
        """bash -n should succeed (no syntax errors)."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        result = subprocess.run(
            ["bash", "-n", path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"Bash syntax error in {script_name}:\n{result.stderr}"
        )


class TestPythonScriptSyntax:
    """Validate Python scripts can be compiled without syntax errors."""

    @pytest.mark.parametrize("script_name", PYTHON_SCRIPTS)
    def test_python_syntax(self, script_name):
        """py_compile should succeed (no syntax errors)."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        result = subprocess.run(
            ["python3", "-m", "py_compile", path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"Python syntax error in {script_name}:\n{result.stderr}"
        )


class TestBashScriptEnvSourcing:
    """Validate bash scripts source the expected environment files."""

    @pytest.mark.parametrize("script_name", BASH_SCRIPTS)
    def test_sources_droplet_env(self, script_name):
        """All bash scripts should source /etc/droplet.env."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "source /etc/droplet.env" in content, (
            f"{script_name} does not source /etc/droplet.env"
        )

    @pytest.mark.parametrize(
        "script_name",
        [s for s in BASH_SCRIPTS if s not in ("phase1-critical.sh", "tg-notify.sh")],
    )
    def test_sources_habitat_parsed_env(self, script_name):
        """Most bash scripts should source /etc/habitat-parsed.env."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "habitat-parsed.env" in content, (
            f"{script_name} does not reference /etc/habitat-parsed.env"
        )


class TestScriptContent:
    """Validate key content patterns in critical scripts."""

    def test_phase1_starts_clawdbot(self):
        """phase1-critical.sh should start the clawdbot service."""
        path = os.path.join(SCRIPTS_DIR, "phase1-critical.sh")
        if not os.path.isfile(path):
            pytest.skip("phase1-critical.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "systemctl start clawdbot" in content
        assert "systemctl enable clawdbot" in content

    def test_phase1_installs_node(self):
        """phase1-critical.sh should install Node.js."""
        path = os.path.join(SCRIPTS_DIR, "phase1-critical.sh")
        if not os.path.isfile(path):
            pytest.skip("phase1-critical.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "node.tar.xz" in content or "nodejs" in content

    def test_phase1_launches_phase2(self):
        """phase1-critical.sh should launch phase2-background.sh."""
        path = os.path.join(SCRIPTS_DIR, "phase1-critical.sh")
        if not os.path.isfile(path):
            pytest.skip("phase1-critical.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "phase2-background.sh" in content

    def test_phase2_installs_desktop(self):
        """phase2-background.sh should install XFCE desktop."""
        path = os.path.join(SCRIPTS_DIR, "phase2-background.sh")
        if not os.path.isfile(path):
            pytest.skip("phase2-background.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "xfce4" in content
        assert "xrdp" in content

    def test_phase2_calls_build_full_config(self):
        """phase2-background.sh should call build-full-config.sh."""
        path = os.path.join(SCRIPTS_DIR, "phase2-background.sh")
        if not os.path.isfile(path):
            pytest.skip("phase2-background.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "build-full-config.sh" in content

    def test_build_config_generates_json(self):
        """build-full-config.sh should generate openclaw.full.json."""
        path = os.path.join(SCRIPTS_DIR, "build-full-config.sh")
        if not os.path.isfile(path):
            pytest.skip("build-full-config.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "openclaw.full.json" in content
        assert "ANTHROPIC_API_KEY" in content

    def test_build_config_multi_agent(self):
        """build-full-config.sh should support multiple agents."""
        path = os.path.join(SCRIPTS_DIR, "build-full-config.sh")
        if not os.path.isfile(path):
            pytest.skip("build-full-config.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "AGENT_COUNT" in content
        assert "AGENT${i}" in content or "AGENT{" in content

    def test_post_boot_check_safe_mode(self):
        """post-boot-check.sh should implement safe mode fallback."""
        path = os.path.join(SCRIPTS_DIR, "post-boot-check.sh")
        if not os.path.isfile(path):
            pytest.skip("post-boot-check.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "safe-mode" in content or "SAFE_MODE" in content
        assert "openclaw.minimal.json" in content

    def test_rename_bots_platform_aware(self):
        """rename-bots.sh should handle telegram/discord/both platforms."""
        path = os.path.join(SCRIPTS_DIR, "rename-bots.sh")
        if not os.path.isfile(path):
            pytest.skip("rename-bots.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "telegram)" in content
        assert "discord)" in content
        assert "both)" in content
        assert "setMyName" in content

    def test_restore_uses_rclone(self):
        """restore-openclaw-state.sh should use rclone for Dropbox sync."""
        path = os.path.join(SCRIPTS_DIR, "restore-openclaw-state.sh")
        if not os.path.isfile(path):
            pytest.skip("restore-openclaw-state.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        # Script may use direct rclone copy or safe wrapper
        assert "rclone" in content or "safe_rclone" in content
        assert "DROPBOX_TOKEN" in content

    def test_api_server_endpoints(self):
        """api-server.py should expose /status, /health, /stages endpoints."""
        path = os.path.join(SCRIPTS_DIR, "api-server.py")
        if not os.path.isfile(path):
            pytest.skip("api-server.py does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "/status" in content
        assert "/health" in content
        assert "/stages" in content
        assert "8080" in content


class TestVariableOrdering:
    """Verify critical variables are defined before first use in bash scripts."""

    CRITICAL_VARS = {
        "phase1-critical.sh": {
            "H": {"assign": r'^\s*H=', "use": r'\$H[/\s"\']'},
            "USERNAME": {"assign": r'^\s*USERNAME=|source /etc/droplet\.env', "use": r'\$USERNAME'},
        },
        "phase2-background.sh": {
            "H": {"assign": r'^\s*H=', "use": r'\$H[/\s"\']'},
        },
        "build-full-config.sh": {
            "H": {"assign": r'^\s*H=', "use": r'\$H[/\s"\']'},
        },
    }

    @pytest.mark.parametrize("script_name", CRITICAL_VARS.keys())
    def test_variables_defined_before_use(self, script_name):
        """Critical variables must be assigned before their first use."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")

        with open(path, "r") as f:
            lines = f.readlines()

        for var_name, patterns in self.CRITICAL_VARS[script_name].items():
            assign_pattern = re.compile(patterns["assign"])
            use_pattern = re.compile(patterns["use"])

            first_assign = None
            first_use = None

            for i, line in enumerate(lines, 1):
                # Skip comments
                stripped = line.lstrip()
                if stripped.startswith("#"):
                    continue
                if first_assign is None and assign_pattern.search(line):
                    first_assign = i
                if first_use is None and use_pattern.search(line):
                    # Don't count the assignment line itself as a use
                    if not assign_pattern.search(line):
                        first_use = i

            assert first_assign is not None, (
                f"{script_name}: variable ${var_name} is never assigned"
            )
            if first_use is not None:
                assert first_assign < first_use, (
                    f"{script_name}: ${var_name} used on line {first_use} "
                    f"before assignment on line {first_assign}"
                )


class TestReadme:
    """Validate scripts/README.md exists and documents all scripts."""

    def test_readme_exists(self):
        path = os.path.join(SCRIPTS_DIR, "README.md")
        assert os.path.isfile(path), "scripts/README.md not found"

    def test_readme_documents_all_scripts(self):
        path = os.path.join(SCRIPTS_DIR, "README.md")
        if not os.path.isfile(path):
            pytest.skip("README.md does not exist")
        with open(path, "r") as f:
            content = f.read()
        for script_name in EXPECTED_SCRIPTS:
            assert script_name in content, (
                f"README.md does not mention {script_name}"
            )

    def test_readme_has_boot_flow(self):
        path = os.path.join(SCRIPTS_DIR, "README.md")
        if not os.path.isfile(path):
            pytest.skip("README.md does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "Boot Flow" in content or "boot flow" in content


class TestUtilityScripts:
    """Test utility scripts that need executable permissions (Issue #168)."""

    @pytest.mark.parametrize("script_name", UTILITY_SCRIPTS)
    def test_utility_script_exists(self, script_name):
        """Each utility script must exist in scripts/."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        assert os.path.isfile(path), f"Utility script {script_name} not found in scripts/"

    @pytest.mark.parametrize("script_name", UTILITY_SCRIPTS)
    def test_utility_script_is_executable(self, script_name):
        """Each utility script must have the executable bit set (Issue #168)."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        mode = os.stat(path).st_mode
        assert mode & stat.S_IXUSR, f"{script_name} is not executable (owner)"
        assert mode & stat.S_IXGRP, f"{script_name} is not executable (group)"
        assert mode & stat.S_IXOTH, f"{script_name} is not executable (other)"


class TestSetCouncilGroup:
    """Tests for set-council-group.sh dual-platform support (Issue #40)."""

    SET_COUNCIL_SCRIPT = os.path.join(REPO_ROOT, "set-council-group.sh")

    @pytest.fixture
    def mock_env(self, tmp_path, monkeypatch):
        """Set up a mock environment for testing the script."""
        # Create temp directories structure
        home = tmp_path / "home" / "testuser"
        openclaw_dir = home / ".openclaw"
        clawd_dir = home / "clawd"
        openclaw_dir.mkdir(parents=True)
        clawd_dir.mkdir(parents=True)

        # Create mock config file with telegram enabled
        config = openclaw_dir / "openclaw.json"
        config.write_text('{"channels":{"telegram":{"enabled":true},"discord":{"enabled":true}}}')

        # Create mock droplet.env
        droplet_env = tmp_path / "etc" / "droplet.env"
        droplet_env.parent.mkdir(parents=True)
        droplet_env.write_text(f'USERNAME=testuser\n')

        return {
            "home": home,
            "config": config,
            "clawd_dir": clawd_dir,
            "droplet_env": droplet_env,
            "tmp_path": tmp_path,
        }

    def test_script_exists(self):
        """set-council-group.sh must exist at repo root."""
        assert os.path.isfile(self.SET_COUNCIL_SCRIPT), (
            "set-council-group.sh not found at repo root"
        )

    def test_script_has_shebang(self):
        """set-council-group.sh must have bash shebang."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            first_line = f.readline().strip()
        assert first_line == "#!/bin/bash", f"Expected bash shebang, got: {first_line}"

    def test_script_syntax(self):
        """set-council-group.sh must have no syntax errors."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        result = subprocess.run(
            ["bash", "-n", self.SET_COUNCIL_SCRIPT],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, f"Bash syntax error:\n{result.stderr}"

    def test_accepts_platform_flag(self):
        """Script should accept --platform flag."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            content = f.read()
        assert "--platform" in content, "Script must support --platform flag"

    def test_uses_platform_env_var(self):
        """Script should check PLATFORM environment variable."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            content = f.read()
        assert "PLATFORM" in content, "Script must check PLATFORM env var"

    def test_handles_telegram_platform(self):
        """Script should handle telegram platform with groups.<group_id> format."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            content = f.read()
        # Should contain telegram-specific logic
        assert "telegram" in content.lower(), "Script must handle telegram platform"
        assert "groups" in content, "Script must use 'groups' for telegram"

    def test_handles_discord_platform(self):
        """Script should handle discord platform with guilds.<guild_id>.channels.<channel_id> format."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            content = f.read()
        # Should contain discord-specific logic
        assert "discord" in content.lower(), "Script must handle discord platform"
        assert "guilds" in content or "guild" in content, "Script must use 'guilds' for discord"
        assert "channel" in content.lower(), "Script must handle channel ID for discord"

    def test_unknown_platform_logs_warning(self):
        """Script should log warning to stderr for unknown platform."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            content = f.read()
        # Should contain logic for unknown platform warning
        assert ">&2" in content or "stderr" in content.lower(), (
            "Script must log warning to stderr for unknown platform"
        )
        # Should exit 0 for unknown platform (don't crash boot)
        assert "exit 0" in content, "Script must exit 0 for unknown platform"

    def test_flag_takes_priority_over_env(self):
        """--platform flag should take priority over PLATFORM env var."""
        if not os.path.isfile(self.SET_COUNCIL_SCRIPT):
            pytest.skip("Script does not exist")
        with open(self.SET_COUNCIL_SCRIPT, "r") as f:
            content = f.read()
        # Check that CLI parsing happens and can override env
        # The flag should be processed and if set, used instead of env
        assert "while" in content or "getopts" in content or "case" in content, (
            "Script must parse CLI arguments"
        )


# NOTE: TestScriptsMatchYaml removed -- with slim YAML approach, scripts are 
# fetched from GitHub by bootstrap.sh, not embedded in hatch.yaml.
# The scripts/ directory IS the source of truth now.
