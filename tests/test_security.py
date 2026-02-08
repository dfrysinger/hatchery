#!/usr/bin/env python3
"""
Security tests for hatchery - TASK-11: Dependency scanning.

These tests ensure pip-audit is properly integrated into CI for
vulnerability scanning of Python dependencies.
"""
import os
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_file(path):
    """Read file contents, return empty string if not found."""
    full_path = os.path.join(REPO_ROOT, path)
    if os.path.exists(full_path):
        with open(full_path, 'r') as f:
            return f.read()
    return ""


class TestDependencyScanning:
    """Ensure pip-audit is integrated for dependency vulnerability scanning."""

    def test_requirements_file_exists(self):
        """requirements.txt must exist for pip-audit scanning."""
        content = read_file("requirements.txt")
        assert content, "requirements.txt must exist for pip-audit scanning"
        assert "pytest" in content.lower(), "requirements.txt must include pytest"
        assert "pyyaml" in content.lower(), "requirements.txt must include pyyaml"

    def test_ci_workflow_has_pip_audit(self):
        """CI workflow must include pip-audit security scan step."""
        content = read_file(".github/workflows/ci.yml")
        assert content, ".github/workflows/ci.yml must exist"
        assert "pip-audit" in content, "CI must include pip-audit for security scanning"
        
        # Verify pip-audit runs before tests (fail fast)
        lines = content.split('\n')
        pip_audit_line = None
        pytest_line = None
        
        for i, line in enumerate(lines):
            if "pip-audit" in line:
                pip_audit_line = i
            if "pytest" in line and "name:" in lines[i-1]:
                pytest_line = i
        
        assert pip_audit_line is not None, "pip-audit step not found in CI"
        assert pytest_line is not None, "pytest step not found in CI"
        assert pip_audit_line < pytest_line, "pip-audit should run before pytest (fail fast)"

    def test_ci_installs_from_requirements(self):
        """CI must install dependencies from requirements.txt."""
        content = read_file(".github/workflows/ci.yml")
        assert "-r requirements.txt" in content, "CI must use 'pip install -r requirements.txt'"
