"""Tests for script path alignment across the codebase.

Ensures that when bootstrap.sh copies scripts to specific paths,
all references to those scripts use the correct paths.

Based on bootstrap.sh logic:
- /usr/local/sbin/: phase1-critical.sh, phase2-background.sh, build-full-config.sh
- /usr/local/bin/: all other scripts
"""

import os
import re
import pytest
from pathlib import Path

# Repository root
REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"

# Scripts that go to /usr/local/sbin/ (from bootstrap.sh case statement)
SBIN_SCRIPTS = {
    "phase1-critical.sh",
    "phase2-background.sh",
    "build-full-config.sh",
    "generate-session-services.sh",
    "generate-docker-compose.sh",
    "lib-permissions.sh",
    "lib-auth.sh",
}

# Scripts that go to /usr/local/bin/ (everything else)
# We'll derive this from the scripts directory
def get_bin_scripts():
    """Get list of scripts that should be in /usr/local/bin/."""
    all_scripts = set()
    for f in SCRIPTS_DIR.iterdir():
        if f.suffix in (".sh", ".py") and f.is_file():
            all_scripts.add(f.name)
    # Remove bootstrap.sh (stays in /opt/hatchery, not copied to bin)
    all_scripts.discard("bootstrap.sh")
    # Remove sbin scripts
    return all_scripts - SBIN_SCRIPTS


class TestPathAlignment:
    """Test that script paths are consistent across the codebase."""

    def test_sbin_scripts_referenced_correctly(self):
        """Scripts in /usr/local/sbin/ must not be referenced as /usr/local/bin/."""
        errors = []
        
        for script_file in SCRIPTS_DIR.glob("*.sh"):
            if not script_file.is_file():
                continue
                
            content = script_file.read_text()
            
            for sbin_script in SBIN_SCRIPTS:
                # Look for wrong path: /usr/local/bin/<sbin_script>
                wrong_pattern = f"/usr/local/bin/{sbin_script}"
                if wrong_pattern in content:
                    # Find line numbers
                    for i, line in enumerate(content.split('\n'), 1):
                        if wrong_pattern in line and not line.strip().startswith('#'):
                            errors.append(
                                f"{script_file.name}:{i} - References {sbin_script} "
                                f"as /usr/local/bin/ but it's installed to /usr/local/sbin/"
                            )
        
        assert not errors, "Path misalignments found:\n" + "\n".join(errors)

    def test_bin_scripts_referenced_correctly(self):
        """Scripts in /usr/local/bin/ must not be referenced as /usr/local/sbin/."""
        bin_scripts = get_bin_scripts()
        errors = []
        
        for script_file in SCRIPTS_DIR.glob("*.sh"):
            if not script_file.is_file():
                continue
                
            content = script_file.read_text()
            
            for bin_script in bin_scripts:
                # Look for wrong path: /usr/local/sbin/<bin_script>
                wrong_pattern = f"/usr/local/sbin/{bin_script}"
                if wrong_pattern in content:
                    # Find line numbers
                    for i, line in enumerate(content.split('\n'), 1):
                        if wrong_pattern in line and not line.strip().startswith('#'):
                            errors.append(
                                f"{script_file.name}:{i} - References {bin_script} "
                                f"as /usr/local/sbin/ but it's installed to /usr/local/bin/"
                            )
        
        assert not errors, "Path misalignments found:\n" + "\n".join(errors)

    def test_bootstrap_sbin_scripts_match_constant(self):
        """bootstrap.sh's sbin case statement should match our SBIN_SCRIPTS constant."""
        bootstrap_path = SCRIPTS_DIR / "bootstrap.sh"
        if not bootstrap_path.exists():
            pytest.skip("bootstrap.sh not found")
            
        content = bootstrap_path.read_text()
        
        # Find the case pattern for sbin scripts
        # Pattern: phase1-critical.sh|phase2-background.sh|build-full-config.sh)
        match = re.search(
            r'([\w-]+\.sh(?:\|[\w-]+\.sh)*)\)\s*(?:cp\s+.*\s+)?/usr/local/sbin/',
            content
        )
        
        assert match, "Could not find sbin case pattern in bootstrap.sh"
        
        # Parse the scripts from the pattern
        bootstrap_sbin = set(match.group(1).split('|'))
        
        assert bootstrap_sbin == SBIN_SCRIPTS, (
            f"SBIN_SCRIPTS constant ({SBIN_SCRIPTS}) doesn't match "
            f"bootstrap.sh pattern ({bootstrap_sbin})"
        )

    def test_hatch_yaml_paths_consistent(self):
        """hatch.yaml write_files paths should be consistent with bootstrap.sh destinations."""
        hatch_yaml = REPO_ROOT / "hatch.yaml"
        if not hatch_yaml.exists():
            pytest.skip("hatch.yaml not found")
            
        content = hatch_yaml.read_text()
        errors = []
        
        # Check for sbin scripts incorrectly placed in /usr/local/bin in write_files
        for sbin_script in SBIN_SCRIPTS:
            pattern = rf'path:\s*/usr/local/bin/{re.escape(sbin_script)}'
            if re.search(pattern, content):
                errors.append(
                    f"hatch.yaml has write_files entry for {sbin_script} at "
                    f"/usr/local/bin/ but bootstrap.sh copies it to /usr/local/sbin/"
                )
        
        # Note: We don't check the inverse because hatch.yaml write_files
        # may define scripts that bootstrap.sh then copies to final location
        
        assert not errors, "hatch.yaml path inconsistencies:\n" + "\n".join(errors)

    def test_systemd_service_paths(self):
        """Systemd service files should reference scripts at correct paths."""
        systemd_dir = REPO_ROOT / "systemd"
        if not systemd_dir.exists():
            pytest.skip("systemd/ directory not found")
            
        errors = []
        
        for service_file in systemd_dir.glob("*.service"):
            content = service_file.read_text()
            
            # Check for sbin scripts incorrectly at /usr/local/bin/
            for sbin_script in SBIN_SCRIPTS:
                wrong_pattern = f"/usr/local/bin/{sbin_script}"
                if wrong_pattern in content:
                    errors.append(
                        f"{service_file.name} - References {sbin_script} at "
                        f"/usr/local/bin/ but it's installed to /usr/local/sbin/"
                    )
            
            # Check for bin scripts incorrectly at /usr/local/sbin/
            for bin_script in get_bin_scripts():
                wrong_pattern = f"/usr/local/sbin/{bin_script}"
                if wrong_pattern in content:
                    errors.append(
                        f"{service_file.name} - References {bin_script} at "
                        f"/usr/local/sbin/ but it's installed to /usr/local/bin/"
                    )
        
        assert not errors, "Systemd service path errors:\n" + "\n".join(errors)


class TestHardcodedPaths:
    """Test for other hardcoded paths that could cause issues."""

    def test_parse_habitat_path_consistency(self):
        """parse-habitat.py should be referenced consistently as /usr/local/bin/."""
        expected_path = "/usr/local/bin/parse-habitat.py"
        errors = []
        
        for script_file in SCRIPTS_DIR.glob("*.sh"):
            content = script_file.read_text()
            
            # Look for parse-habitat.py references
            if "parse-habitat.py" in content:
                for i, line in enumerate(content.split('\n'), 1):
                    if "parse-habitat.py" in line and not line.strip().startswith('#'):
                        # Check if it uses the correct path
                        if "/usr/local/sbin/parse-habitat.py" in line:
                            errors.append(
                                f"{script_file.name}:{i} - parse-habitat.py should be "
                                f"at /usr/local/bin/, not /usr/local/sbin/"
                            )
        
        assert not errors, "parse-habitat.py path errors:\n" + "\n".join(errors)

    def test_openclaw_path_consistency(self):
        """openclaw binary should be referenced at /usr/local/bin/."""
        errors = []
        
        for script_file in SCRIPTS_DIR.glob("*.sh"):
            content = script_file.read_text()
            
            for i, line in enumerate(content.split('\n'), 1):
                if "/usr/local/sbin/openclaw" in line and not line.strip().startswith('#'):
                    errors.append(
                        f"{script_file.name}:{i} - openclaw should be at "
                        f"/usr/local/bin/, not /usr/local/sbin/"
                    )
        
        assert not errors, "openclaw path errors:\n" + "\n".join(errors)

    def test_api_server_path_consistency(self):
        """api-server.py should be referenced at /usr/local/bin/."""
        errors = []
        
        all_files = list(SCRIPTS_DIR.glob("*.sh")) + list((REPO_ROOT / "systemd").glob("*.service"))
        
        for file_path in all_files:
            if not file_path.exists():
                continue
            content = file_path.read_text()
            
            if "/usr/local/sbin/api-server.py" in content:
                for i, line in enumerate(content.split('\n'), 1):
                    if "/usr/local/sbin/api-server.py" in line:
                        errors.append(
                            f"{file_path.name}:{i} - api-server.py should be at "
                            f"/usr/local/bin/, not /usr/local/sbin/"
                        )
        
        assert not errors, "api-server.py path errors:\n" + "\n".join(errors)

    def test_no_hardcoded_home_paths(self):
        """Scripts should not have hardcoded /home/<user> paths (use $HOME or ~)."""
        errors = []
        
        # Pattern for hardcoded home paths (but allow /home/bot which is our standard)
        home_pattern = re.compile(r'/home/(?!bot\b)[a-z_][a-z0-9_-]*/')
        
        for script_file in SCRIPTS_DIR.glob("*.sh"):
            content = script_file.read_text()
            
            for i, line in enumerate(content.split('\n'), 1):
                if home_pattern.search(line) and not line.strip().startswith('#'):
                    errors.append(
                        f"{script_file.name}:{i} - Hardcoded home path found. "
                        f"Use $HOME or /home/bot instead."
                    )
        
        # This is a warning-level check, not a hard failure
        if errors:
            pytest.skip("Hardcoded home paths (non-blocking):\n" + "\n".join(errors))


class TestPathDocumentation:
    """Test that script headers document correct paths."""

    def test_script_headers_match_destinations(self):
        """Script 'Original:' comments should match actual installation paths."""
        errors = []
        
        for script_file in SCRIPTS_DIR.glob("*.sh"):
            content = script_file.read_text()
            
            # Look for "Original: /path/to/script" in header
            # Pattern matches path ending in .sh or .py
            match = re.search(r'#\s*Original:\s*(/usr/local/[a-z]+/[\w.-]+\.(?:sh|py))', content[:1000])
            if not match:
                continue  # Not all scripts have this header
                
            documented_path = match.group(1)
            script_name = script_file.name
            
            # Determine expected path
            if script_name in SBIN_SCRIPTS:
                expected_path = f"/usr/local/sbin/{script_name}"
            else:
                expected_path = f"/usr/local/bin/{script_name}"
            
            if documented_path != expected_path:
                errors.append(
                    f"{script_name} - Header says 'Original: {documented_path}' "
                    f"but script is installed to {expected_path}"
                )
        
        assert not errors, "Header path documentation errors:\n" + "\n".join(errors)


class TestIsolationDeployment:
    """Tests for isolation script deployment paths (#229)."""

    def test_hatch_yaml_sbin_case_matches_constant(self):
        """hatch.yaml sbin case statement must match the SBIN_SCRIPTS constant."""
        hatch_yaml = REPO_ROOT / "hatch.yaml"
        if not hatch_yaml.exists():
            pytest.skip("hatch.yaml not found")

        content = hatch_yaml.read_text()

        # Extract pipe-delimited script names from the sbin branch of case statement
        # Pattern: scriptA|scriptB|scriptC)cp "$f" /usr/local/sbin/
        match = re.search(
            r'([\w.-]+\.sh(?:\|[\w.-]+\.sh)*)\)cp\s+"\$f"\s+/usr/local/sbin/',
            content
        )
        assert match, "Could not find sbin case pattern in hatch.yaml"

        hatch_sbin = set(match.group(1).split('|'))
        assert hatch_sbin == SBIN_SCRIPTS, (
            f"SBIN_SCRIPTS constant ({SBIN_SCRIPTS}) doesn't match "
            f"hatch.yaml case pattern ({hatch_sbin})"
        )

    def test_build_pipeline_isolation_scripts_in_sbin(self):
        """All sbin-path scripts called from build-full-config.sh must be in SBIN_SCRIPTS."""
        build_script = SCRIPTS_DIR / "build-full-config.sh"
        if not build_script.exists():
            pytest.skip("build-full-config.sh not found")

        content = build_script.read_text()

        # Find all scripts referenced at /usr/local/sbin/
        sbin_refs = set(re.findall(r'/usr/local/sbin/([\w.-]+\.sh)', content))
        missing = sbin_refs - SBIN_SCRIPTS
        assert not missing, (
            f"Scripts referenced at /usr/local/sbin/ in build-full-config.sh "
            f"but not in SBIN_SCRIPTS: {missing}"
        )

    def test_isolation_scripts_deployed(self):
        """Isolation generator scripts must exist in the scripts directory."""
        for script_name in ("generate-session-services.sh", "generate-docker-compose.sh"):
            script_path = SCRIPTS_DIR / script_name
            assert script_path.exists(), (
                f"{script_name} not found in scripts/ — "
                f"isolation will fail on deployment"
            )
