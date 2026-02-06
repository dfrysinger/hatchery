"""
Tests for rclone path validation (Issue #68).

Validates that scripts using rclone refuse to run with dangerous paths:
- Empty source/destination
- Root paths (/, /*, dropbox:/, etc.)
- Paths outside expected directories
- Destinations not matching expected prefix (for uploads)
"""

import os
import subprocess
import tempfile
import pytest

# Root of the repository
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")
VALIDATE_SCRIPT = os.path.join(SCRIPTS_DIR, "rclone-validate.sh")


class TestValidateScriptExists:
    """Verify rclone-validate.sh exists and has correct properties."""

    def test_script_exists(self):
        """rclone-validate.sh must exist in scripts/."""
        assert os.path.isfile(VALIDATE_SCRIPT), "rclone-validate.sh not found"

    def test_script_has_shebang(self):
        """rclone-validate.sh must have bash shebang."""
        with open(VALIDATE_SCRIPT, "r") as f:
            first_line = f.readline().strip()
        assert first_line == "#!/bin/bash"

    def test_script_syntax(self):
        """rclone-validate.sh must have no syntax errors."""
        result = subprocess.run(
            ["bash", "-n", VALIDATE_SCRIPT],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"Syntax error: {result.stderr}"

    def test_script_has_functions(self):
        """rclone-validate.sh should define expected functions."""
        with open(VALIDATE_SCRIPT, "r") as f:
            content = f.read()
        assert "validate_rclone_path" in content
        assert "safe_rclone_copy" in content


class TestValidateFunction:
    """Test the validate_rclone_path function."""

    @pytest.fixture
    def run_validation(self):
        """Helper to run the validation function with given args."""
        def _run(src, dst):
            # Source the script and call the function
            cmd = f'''
                source "{VALIDATE_SCRIPT}"
                validate_rclone_path "{src}" "{dst}"
            '''
            result = subprocess.run(
                ["bash", "-c", cmd],
                capture_output=True,
                text=True,
            )
            return result
        return _run

    def test_valid_paths_succeed(self, run_validation):
        """Valid local->remote paths should succeed."""
        result = run_validation(
            "/home/user/clawd/MEMORY.md",
            "dropbox:clawdbot-memory/habitat1/"
        )
        assert result.returncode == 0, f"Unexpected failure: {result.stderr}"

    def test_valid_clawdbot_path_succeeds(self, run_validation):
        """Valid .clawdbot paths should succeed."""
        result = run_validation(
            "/home/user/.clawdbot/sessions/",
            "dropbox:clawdbot-memory/habitat1/sessions/"
        )
        assert result.returncode == 0, f"Unexpected failure: {result.stderr}"

    def test_empty_source_rejected(self, run_validation):
        """Empty source should be rejected."""
        result = run_validation("", "dropbox:clawdbot-memory/test/")
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_empty_destination_rejected(self, run_validation):
        """Empty destination should be rejected."""
        result = run_validation("/home/user/clawd/data", "")
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_root_source_rejected(self, run_validation):
        """Root path '/' as source should be rejected."""
        result = run_validation("/", "dropbox:clawdbot-memory/test/")
        assert result.returncode != 0
        assert "refusing" in result.stderr.lower()

    def test_root_destination_rejected(self, run_validation):
        """Root path '/' as destination should be rejected."""
        result = run_validation("/home/user/clawd/data", "/")
        assert result.returncode != 0
        assert "refusing" in result.stderr.lower()

    def test_remote_root_rejected(self, run_validation):
        """Remote root path 'dropbox:/' should be rejected."""
        result = run_validation(
            "/home/user/clawd/data",
            "dropbox:/"
        )
        assert result.returncode != 0

    def test_remote_no_path_rejected(self, run_validation):
        """Remote with no path 'dropbox:' should be rejected."""
        result = run_validation(
            "/home/user/clawd/data",
            "dropbox:"
        )
        assert result.returncode != 0

    def test_unexpected_local_source_rejected(self, run_validation):
        """Local paths outside /home/<user>/clawd or .clawdbot should be rejected."""
        result = run_validation(
            "/etc/passwd",
            "dropbox:clawdbot-memory/test/"
        )
        assert result.returncode != 0
        assert "unexpected" in result.stderr.lower()

    def test_unexpected_remote_rejected(self, run_validation):
        """Remote paths outside clawdbot-memory should be rejected."""
        result = run_validation(
            "/home/user/clawd/data",
            "dropbox:other-bucket/data/"
        )
        assert result.returncode != 0
        assert "unexpected" in result.stderr.lower()

    def test_whitespace_only_rejected(self, run_validation):
        """Whitespace-only paths should be rejected."""
        result = run_validation("   ", "dropbox:clawdbot-memory/test/")
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()


class TestSafeCopyFunction:
    """Test the safe_rclone_copy wrapper function."""

    @pytest.fixture
    def run_safe_copy(self):
        """Helper to run safe copy validation."""
        def _run(src, dst):
            cmd = f'''
                source "{VALIDATE_SCRIPT}"
                # Override rclone to just echo (don't actually run)
                rclone() {{ echo "RCLONE: $*"; }}
                export -f rclone
                safe_rclone_copy "{src}" "{dst}"
            '''
            result = subprocess.run(
                ["bash", "-c", cmd],
                capture_output=True,
                text=True,
            )
            return result
        return _run

    def test_safe_copy_validates_source(self, run_safe_copy):
        """safe_copy should reject empty source."""
        result = run_safe_copy("", "dropbox:clawdbot-memory/test/")
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_safe_copy_validates_dest(self, run_safe_copy):
        """safe_copy should reject empty destination."""
        result = run_safe_copy("/home/user/clawd/data", "")
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_safe_copy_passes_validation_on_valid_paths(self, run_safe_copy):
        """safe_copy should pass validation for valid paths (rclone may fail if path doesn't exist)."""
        result = run_safe_copy(
            "/home/user/clawd/MEMORY.md",
            "dropbox:clawdbot-memory/test/"
        )
        # Validation passes - any failure would be from rclone, not validation
        assert "refusing" not in result.stderr.lower()
        assert "empty" not in result.stderr.lower()


class TestSafeSuCopyFunction:
    """Test the safe_rclone_su_copy wrapper function."""

    @pytest.fixture
    def run_safe_su_copy(self):
        """Helper to run safe su copy validation."""
        def _run(user, src, dst):
            cmd = f'''
                source "{VALIDATE_SCRIPT}"
                # Override su to just echo (don't actually run)
                su() {{ echo "SU: $*"; }}
                export -f su
                safe_rclone_su_copy "{user}" "{src}" "{dst}"
            '''
            result = subprocess.run(
                ["bash", "-c", cmd],
                capture_output=True,
                text=True,
            )
            return result
        return _run

    def test_su_copy_validates_user(self, run_safe_su_copy):
        """safe_rclone_su_copy should reject empty user."""
        result = run_safe_su_copy(
            "",
            "/home/user/clawd/data",
            "dropbox:clawdbot-memory/test/"
        )
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_su_copy_validates_source(self, run_safe_su_copy):
        """safe_rclone_su_copy should reject empty source."""
        result = run_safe_su_copy(
            "testuser",
            "",
            "dropbox:clawdbot-memory/test/"
        )
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_su_copy_validates_dest(self, run_safe_su_copy):
        """safe_rclone_su_copy should reject empty destination."""
        result = run_safe_su_copy(
            "testuser",
            "/home/user/clawd/data",
            ""
        )
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()

    def test_su_copy_calls_su_on_valid_paths(self, run_safe_su_copy):
        """safe_rclone_su_copy should call su on valid paths."""
        result = run_safe_su_copy(
            "testuser",
            "/home/testuser/clawd/MEMORY.md",
            "dropbox:clawdbot-memory/test/"
        )
        assert result.returncode == 0
        assert "SU:" in result.stdout


class TestSyncScriptValidation:
    """Test that sync-clawdbot-state.sh uses path validation."""

    SYNC_SCRIPT = os.path.join(SCRIPTS_DIR, "sync-clawdbot-state.sh")

    def test_script_sources_validate_lib(self):
        """sync-clawdbot-state.sh should source rclone-validate.sh."""
        with open(self.SYNC_SCRIPT, "r") as f:
            content = f.read()
        assert "rclone-validate.sh" in content, "sync script must source rclone-validate.sh"

    def test_script_uses_safe_copy(self):
        """sync-clawdbot-state.sh should use safe_rclone_su_copy."""
        with open(self.SYNC_SCRIPT, "r") as f:
            content = f.read()
        assert "safe_rclone" in content

    def test_script_refuses_on_empty_username(self):
        """sync-clawdbot-state.sh should refuse if USERNAME is empty."""
        with open(self.SYNC_SCRIPT, "r") as f:
            content = f.read()
        assert (
            '-z "$USERNAME"' in content or
            '[ -z "$USERNAME" ]' in content
        ), "sync script must check for empty USERNAME"


class TestRestoreScriptValidation:
    """Test that restore-clawdbot-state.sh uses path validation."""

    RESTORE_SCRIPT = os.path.join(SCRIPTS_DIR, "restore-clawdbot-state.sh")

    def test_script_sources_validate_lib(self):
        """restore-clawdbot-state.sh should source rclone-validate.sh."""
        with open(self.RESTORE_SCRIPT, "r") as f:
            content = f.read()
        assert "rclone-validate.sh" in content, "restore script must source rclone-validate.sh"

    def test_script_uses_safe_copy(self):
        """restore-clawdbot-state.sh should use safe_rclone_su_copy."""
        with open(self.RESTORE_SCRIPT, "r") as f:
            content = f.read()
        assert "safe_rclone" in content

    def test_script_checks_habitat_name(self):
        """restore-clawdbot-state.sh should validate HABITAT_NAME."""
        with open(self.RESTORE_SCRIPT, "r") as f:
            content = f.read()
        assert "HABITAT_NAME" in content
        # Should have validation for empty/invalid habitat name
        assert "ERROR" in content and "HABITAT" in content


class TestNoRcloneOnEmptyPath:
    """Integration test: verify rclone is NOT invoked with empty/invalid paths."""

    def test_safe_copy_rejects_empty_source(self, tmp_path):
        """Safe copy function should reject empty source and not call rclone."""
        rclone_log = tmp_path / "rclone.log"
        fake_rclone = tmp_path / "bin" / "rclone"
        fake_rclone.parent.mkdir()
        fake_rclone.write_text(f'#!/bin/bash\necho "CALLED: $*" >> "{rclone_log}"\n')
        fake_rclone.chmod(0o755)
        
        result = subprocess.run(
            ["bash", "-c", f'''
                export PATH="{fake_rclone.parent}:$PATH"
                source "{VALIDATE_SCRIPT}"
                safe_rclone_copy "" "dropbox:clawdbot-memory/test/"
            '''],
            capture_output=True,
            text=True,
        )
        
        assert result.returncode != 0
        assert "refusing" in result.stderr.lower() or "empty" in result.stderr.lower()
        assert not rclone_log.exists() or "CALLED" not in rclone_log.read_text()

    def test_safe_copy_rejects_root_path(self, tmp_path):
        """Safe copy function should reject root source and not call rclone."""
        rclone_log = tmp_path / "rclone.log"
        fake_rclone = tmp_path / "bin" / "rclone"
        fake_rclone.parent.mkdir()
        fake_rclone.write_text(f'#!/bin/bash\necho "CALLED: $*" >> "{rclone_log}"\n')
        fake_rclone.chmod(0o755)
        
        result = subprocess.run(
            ["bash", "-c", f'''
                export PATH="{fake_rclone.parent}:$PATH"
                source "{VALIDATE_SCRIPT}"
                safe_rclone_copy "/" "dropbox:clawdbot-memory/test/"
            '''],
            capture_output=True,
            text=True,
        )
        
        assert result.returncode != 0
        assert "refusing" in result.stderr.lower()
        assert not rclone_log.exists() or "CALLED" not in rclone_log.read_text()

    def test_safe_su_copy_rejects_empty_user(self, tmp_path):
        """safe_rclone_su_copy should reject empty user and not call su."""
        su_log = tmp_path / "su.log"
        fake_su = tmp_path / "bin" / "su"
        fake_su.parent.mkdir()
        fake_su.write_text(f'#!/bin/bash\necho "CALLED: $*" >> "{su_log}"\n')
        fake_su.chmod(0o755)
        
        result = subprocess.run(
            ["bash", "-c", f'''
                export PATH="{fake_su.parent}:$PATH"
                source "{VALIDATE_SCRIPT}"
                safe_rclone_su_copy "" "/home/user/clawd/data" "dropbox:clawdbot-memory/test/"
            '''],
            capture_output=True,
            text=True,
        )
        
        assert result.returncode != 0
        assert "empty" in result.stderr.lower()
        assert not su_log.exists() or "CALLED" not in su_log.read_text()


class TestScriptHeaders:
    """Verify scripts have proper documentation headers."""

    @pytest.mark.parametrize("script_name", [
        "sync-clawdbot-state.sh",
        "restore-clawdbot-state.sh",
        "rclone-validate.sh",
    ])
    def test_script_has_header_or_comment(self, script_name):
        """Each script should have a header or purpose comment."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        with open(path, "r") as f:
            content = f.read(3000)
        # Either has a full header block or at least a purpose comment
        has_header = "============" in content or "Purpose:" in content
        has_comment = "#" in content[:500] and len([l for l in content[:500].split('\n') if l.strip().startswith('#')]) >= 2
        assert has_header or has_comment, f"{script_name}: missing header/comments"

    @pytest.mark.parametrize("script_name", [
        "sync-clawdbot-state.sh",
        "restore-clawdbot-state.sh",
    ])
    def test_script_mentions_validation(self, script_name):
        """Scripts using rclone should reference rclone-validate.sh."""
        path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(path):
            pytest.skip(f"{script_name} does not exist")
        with open(path, "r") as f:
            content = f.read(3000)
        assert "rclone-validate" in content, f"{script_name}: should reference rclone-validate.sh"
