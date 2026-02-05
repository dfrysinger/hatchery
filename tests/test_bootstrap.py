"""Tests for scripts/bootstrap.sh"""
import subprocess, re, pathlib

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "bootstrap.sh"
SRC = SCRIPT.read_text()


def test_syntax_check():
    """bash -n accepts the script without errors."""
    result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0, f"Syntax error:\n{result.stderr}"


def test_install_dir():
    """INSTALL_DIR is set to /opt/hatchery."""
    assert 'INSTALL_DIR="/opt/hatchery"' in SRC


def test_retry_delays():
    """Retry delays are 5, 15, 30 seconds."""
    assert re.search(r"delays=\(\s*5\s+15\s+30\s*\)", SRC), "Expected delays=(5 15 30)"


def test_dev_mode_url():
    """Dev mode fetches from archive/refs/heads/main."""
    assert "archive/refs/heads/main" in SRC


def test_release_mode_url():
    """Release mode fetches from releases/download."""
    assert "releases/download" in SRC


def test_calls_phase1():
    """Script hands off to phase1-critical.sh via exec."""
    assert re.search(r'exec\s+.*phase1-critical\.sh', SRC)


def test_sha256_verification():
    """Release mode verifies SHA256 checksum."""
    assert "sha256sum" in SRC
    assert "SHA256" in SRC  # log/notify references
