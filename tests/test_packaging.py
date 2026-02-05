"""Tests for release tarball packaging (scripts/package.sh)."""

import hashlib
import json
import os
import subprocess
import tarfile
import tempfile

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VERSION_FILE = os.path.join(REPO_ROOT, "version.json")


def _get_version():
    with open(VERSION_FILE) as f:
        return json.load(f)["version"]


@pytest.fixture(scope="module")
def built_tarball(tmp_path_factory):
    """Run package.sh once and return paths to tarball + checksum."""
    workdir = tmp_path_factory.mktemp("pkg")

    # Run package.sh from a temp working copy so artifacts land in workdir
    result = subprocess.run(
        ["bash", os.path.join(REPO_ROOT, "scripts", "package.sh")],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"package.sh failed:\n{result.stderr}"

    version = _get_version()
    tarball = os.path.join(REPO_ROOT, f"hatchery-{version}.tar.gz")
    checksum = tarball + ".sha256"

    assert os.path.isfile(tarball), f"Tarball not found: {tarball}"
    assert os.path.isfile(checksum), f"Checksum not found: {checksum}"

    yield {"tarball": tarball, "checksum": checksum, "version": version}

    # Cleanup
    for f in (tarball, checksum):
        if os.path.exists(f):
            os.remove(f)


class TestPackageScript:
    """Test that package.sh produces a valid tarball."""

    def test_tarball_is_valid(self, built_tarball):
        """Tarball should be a valid gzip-compressed tar archive."""
        assert tarfile.is_tarfile(built_tarball["tarball"])

    def test_tarball_contains_expected_files(self, built_tarball):
        """Tarball must contain scripts/, tests/, examples/, version.json, README.md."""
        with tarfile.open(built_tarball["tarball"], "r:gz") as tf:
            names = tf.getnames()

        expected_prefixes = [
            "hatchery/scripts/",
            "hatchery/tests/",
            "hatchery/examples/",
        ]
        expected_files = [
            "hatchery/version.json",
            "hatchery/README.md",
        ]

        for prefix in expected_prefixes:
            assert any(
                n.startswith(prefix) for n in names
            ), f"No entries starting with {prefix}"

        for fname in expected_files:
            assert fname in names, f"{fname} not found in tarball"

    def test_tarball_has_hatchery_prefix(self, built_tarball):
        """All entries should be under the hatchery/ prefix."""
        with tarfile.open(built_tarball["tarball"], "r:gz") as tf:
            for member in tf.getmembers():
                assert member.name.startswith(
                    "hatchery/"
                ), f"Entry {member.name} missing hatchery/ prefix"

    def test_tarball_extracts_with_correct_prefix(self, built_tarball):
        """Extracting to a directory should produce a hatchery/ subdirectory."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with tarfile.open(built_tarball["tarball"], "r:gz") as tf:
                tf.extractall(tmpdir)

            hatchery_dir = os.path.join(tmpdir, "hatchery")
            assert os.path.isdir(hatchery_dir)
            assert os.path.isfile(os.path.join(hatchery_dir, "version.json"))
            assert os.path.isfile(os.path.join(hatchery_dir, "README.md"))
            assert os.path.isdir(os.path.join(hatchery_dir, "scripts"))

    def test_sha256_checksum_valid(self, built_tarball):
        """SHA256 checksum file should match the actual tarball digest."""
        # Read the recorded checksum
        with open(built_tarball["checksum"]) as f:
            recorded = f.read().strip().split()[0]

        # Compute actual checksum
        sha256 = hashlib.sha256()
        with open(built_tarball["tarball"], "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                sha256.update(chunk)

        assert sha256.hexdigest() == recorded, "SHA256 mismatch"

    def test_tarball_name_contains_version(self, built_tarball):
        """Tarball filename should contain the version from version.json."""
        version = built_tarball["version"]
        basename = os.path.basename(built_tarball["tarball"])
        assert basename == f"hatchery-{version}.tar.gz"
