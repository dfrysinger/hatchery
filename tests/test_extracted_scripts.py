"""
Tests for extracted scripts in scripts/ directory.

Validates that all scripts extracted from hatch.yaml exist, are executable,
have proper shebangs, and can be parsed without syntax errors.
"""

import os
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
    "restore-clawdbot-state.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 50},
    "rename-bots.sh": {"type": "bash", "shebang": "#!/bin/bash", "min_lines": 40},
}

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
        """build-full-config.sh should generate clawdbot.full.json."""
        path = os.path.join(SCRIPTS_DIR, "build-full-config.sh")
        if not os.path.isfile(path):
            pytest.skip("build-full-config.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "clawdbot.full.json" in content
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
        assert "clawdbot.minimal.json" in content

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
        """restore-clawdbot-state.sh should use rclone for Dropbox sync."""
        path = os.path.join(SCRIPTS_DIR, "restore-clawdbot-state.sh")
        if not os.path.isfile(path):
            pytest.skip("restore-clawdbot-state.sh does not exist")
        with open(path, "r") as f:
            content = f.read()
        assert "rclone copy" in content
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


class TestScriptsMatchYaml:
    """Verify extracted scripts contain the same logic as hatch.yaml originals."""

    @pytest.fixture
    def yaml_scripts(self):
        """Extract script contents from hatch.yaml for comparison."""
        try:
            import yaml
        except ImportError:
            pytest.skip("PyYAML not installed")
        yaml_path = os.path.join(REPO_ROOT, "hatch.yaml")
        with open(yaml_path) as f:
            data = yaml.safe_load(f)
        scripts = {}
        for entry in data.get("write_files", []):
            path = entry.get("path", "")
            content = entry.get("content", "")
            scripts[path] = content
        return scripts

    YAML_PATH_MAP = {
        "parse-habitat.py": "/usr/local/bin/parse-habitat.py",
        "tg-notify.sh": "/usr/local/bin/tg-notify.sh",
        "api-server.py": "/usr/local/bin/api-server.py",
        "phase1-critical.sh": "/usr/local/sbin/phase1-critical.sh",
        "phase2-background.sh": "/usr/local/sbin/phase2-background.sh",
        "build-full-config.sh": "/usr/local/sbin/build-full-config.sh",
        "post-boot-check.sh": "/usr/local/bin/post-boot-check.sh",
        "try-full-config.sh": "/usr/local/bin/try-full-config.sh",
        "restore-clawdbot-state.sh": "/usr/local/bin/restore-clawdbot-state.sh",
        "rename-bots.sh": "/usr/local/bin/rename-bots.sh",
    }

    @pytest.mark.parametrize("script_name", EXPECTED_SCRIPTS.keys())
    def test_script_contains_yaml_content(self, script_name, yaml_scripts):
        """Extracted script should contain all functional lines from YAML original."""
        yaml_path = self.YAML_PATH_MAP[script_name]
        yaml_content = yaml_scripts.get(yaml_path, "")
        if not yaml_content:
            pytest.skip(f"Could not find {yaml_path} in hatch.yaml")

        script_path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(script_path):
            pytest.skip(f"{script_name} does not exist")

        with open(script_path, "r") as f:
            extracted_content = f.read()

        # Compare functional lines (skip comments and blank lines)
        yaml_lines = [
            line.strip()
            for line in yaml_content.strip().split("\n")
            if line.strip() and not line.strip().startswith("#")
        ]
        for line in yaml_lines:
            assert line in extracted_content, (
                f"{script_name}: missing YAML line: {line[:80]}..."
            )
