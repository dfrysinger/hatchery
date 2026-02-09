#!/usr/bin/env python3
"""Tests for systemd service files in the systemd/ directory.

Verifies that service files have required configuration for proper operation.
Issue #139: api-server.service must have EnvironmentFile entries.
"""
import os
import pytest

SYSTEMD_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "systemd")


class TestApiServerService:
    """Test api-server.service configuration."""

    @pytest.fixture
    def service_content(self):
        """Load api-server.service content."""
        service_path = os.path.join(SYSTEMD_DIR, "api-server.service")
        if not os.path.exists(service_path):
            pytest.skip("api-server.service not found")
        with open(service_path, "r") as f:
            return f.read()

    def test_service_file_exists(self):
        """api-server.service should exist in systemd/ directory."""
        service_path = os.path.join(SYSTEMD_DIR, "api-server.service")
        assert os.path.exists(service_path), "systemd/api-server.service not found"

    def test_has_environment_file_api_server_env(self, service_content):
        """Service should load /etc/api-server.env for API_SECRET (optional)."""
        assert "EnvironmentFile=-/etc/api-server.env" in service_content, \
            "Missing EnvironmentFile=-/etc/api-server.env (with - prefix for optional)"

    def test_has_environment_file_habitat_parsed(self, service_content):
        """Service should load /etc/habitat-parsed.env (optional, with -)."""
        assert "EnvironmentFile=-/etc/habitat-parsed.env" in service_content, \
            "Missing EnvironmentFile=-/etc/habitat-parsed.env"

    def test_has_exec_start(self, service_content):
        """Service should have ExecStart for api-server.py."""
        assert "ExecStart=/usr/local/bin/api-server.py" in service_content, \
            "Missing ExecStart=/usr/local/bin/api-server.py"

    def test_has_restart_policy(self, service_content):
        """Service should have restart policy."""
        assert "Restart=always" in service_content, "Missing Restart=always"

    def test_runs_as_root(self, service_content):
        """Service should run as root (needed to read /etc files)."""
        assert "User=root" in service_content, "Missing User=root"


class TestBootstrapInstallsServices:
    """Test that bootstrap.sh installs systemd service files."""

    @pytest.fixture
    def bootstrap_content(self):
        """Load bootstrap.sh content."""
        scripts_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts")
        bootstrap_path = os.path.join(scripts_dir, "bootstrap.sh")
        if not os.path.exists(bootstrap_path):
            pytest.skip("bootstrap.sh not found")
        with open(bootstrap_path, "r") as f:
            return f.read()

    def test_copies_service_files(self, bootstrap_content):
        """bootstrap.sh should copy .service files to /etc/systemd/system/."""
        assert "systemd/*.service" in bootstrap_content, \
            "bootstrap.sh should iterate over systemd/*.service files"
        assert "/etc/systemd/system/" in bootstrap_content, \
            "bootstrap.sh should copy to /etc/systemd/system/"

    def test_reloads_systemd(self, bootstrap_content):
        """bootstrap.sh should run systemctl daemon-reload after copying."""
        assert "systemctl daemon-reload" in bootstrap_content, \
            "bootstrap.sh should reload systemd daemon"

    def test_restarts_api_server(self, bootstrap_content):
        """bootstrap.sh should restart api-server after update."""
        assert "systemctl restart api-server" in bootstrap_content, \
            "bootstrap.sh should restart api-server"
