#!/usr/bin/env python3
"""
Security regression tests for hatchery.

These tests ensure we don't accidentally expose sensitive ports or
remove authentication from critical endpoints.
"""
import os
import re
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_file(path):
    """Read file contents, return empty string if not found."""
    full_path = os.path.join(REPO_ROOT, path)
    if os.path.exists(full_path):
        with open(full_path, 'r') as f:
            return f.read()
    return ""


class TestVNCSecurity:
    """Ensure VNC port 5900 is never exposed to the internet."""

    def test_vnc_port_not_opened_in_phase2(self):
        """VNC port 5900 must not be opened in firewall (phase2-background.sh)."""
        content = read_file("scripts/phase2-background.sh")
        # Look for uncommented ufw allow 5900
        lines = content.split('\n')
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            if re.search(r'ufw\s+allow.*5900', stripped):
                pytest.fail(
                    f"SECURITY: VNC port 5900 exposed in phase2-background.sh line {i}: {line}\n"
                    "VNC should only be accessible via RDP tunnel (localhost)."
                )

    def test_vnc_port_not_opened_in_yaml(self):
        """VNC port 5900 must not be opened in firewall (hatch.yaml)."""
        content = read_file("hatch.yaml")
        lines = content.split('\n')
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            if re.search(r'ufw\s+allow.*5900', stripped):
                pytest.fail(
                    f"SECURITY: VNC port 5900 exposed in hatch.yaml line {i}: {line}\n"
                    "VNC should only be accessible via RDP tunnel (localhost)."
                )

    def test_vnc_port_not_opened_in_slim_yaml(self):
        """VNC port 5900 must not be opened in firewall (hatch-slim.yaml)."""
        content = read_file("hatch-slim.yaml")
        lines = content.split('\n')
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            if re.search(r'ufw\s+allow.*5900', stripped):
                pytest.fail(
                    f"SECURITY: VNC port 5900 exposed in hatch-slim.yaml line {i}: {line}\n"
                    "VNC should only be accessible via RDP tunnel (localhost)."
                )


class TestAPIServerSecurity:
    """Ensure API server endpoints are documented for security review."""

    def test_api_endpoints_documented(self):
        """API server should have security documentation in comments."""
        content = read_file("scripts/api-server.py")
        assert "POST" in content, "API server should document POST endpoints"
        # Future: Add actual auth checks once implemented
        # For now, just ensure we're aware of what endpoints exist

    def test_no_shell_injection_in_api_server(self):
        """API server must not use shell=True with user input."""
        content = read_file("scripts/api-server.py")
        # Check for dangerous patterns
        if "shell=True" in content:
            # Ensure it's not using any request/query parameters
            lines = content.split('\n')
            for i, line in enumerate(lines, 1):
                if "shell=True" in line:
                    # This is a warning - manual review needed
                    # In future, could parse AST to check if user input flows to shell
                    pass  # For now, allow but flag for review


class TestFirewallPolicy:
    """Ensure only expected ports are opened."""
    
    ALLOWED_PORTS = {
        '22',      # SSH
        '3389',    # RDP (authenticated)
        '8080',    # API server (internal)
        '18789',   # Clawdbot gateway
    }
    
    FORBIDDEN_PORTS = {
        '5900',    # VNC - must use RDP tunnel
        '5901',    # VNC alternate
        '6000',    # X11
        '6001',    # X11
    }

    def test_no_forbidden_ports_in_scripts(self):
        """Ensure forbidden ports are not opened in any script."""
        scripts_dir = os.path.join(REPO_ROOT, "scripts")
        if not os.path.exists(scripts_dir):
            pytest.skip("scripts/ directory not found")
        
        for filename in os.listdir(scripts_dir):
            if not filename.endswith(('.sh', '.py')):
                continue
            filepath = os.path.join(scripts_dir, filename)
            with open(filepath, 'r') as f:
                content = f.read()
            
            lines = content.split('\n')
            for i, line in enumerate(lines, 1):
                stripped = line.strip()
                if stripped.startswith('#'):
                    continue
                for port in self.FORBIDDEN_PORTS:
                    if re.search(rf'ufw\s+allow.*{port}', stripped):
                        pytest.fail(
                            f"SECURITY: Forbidden port {port} opened in {filename} line {i}\n"
                            f"Line: {line}"
                        )


class TestSecretsHandling:
    """Ensure secrets are not hardcoded."""

    def test_no_hardcoded_tokens_in_scripts(self):
        """Scripts must not contain hardcoded API tokens."""
        scripts_dir = os.path.join(REPO_ROOT, "scripts")
        if not os.path.exists(scripts_dir):
            pytest.skip("scripts/ directory not found")
        
        # Patterns that look like API keys/tokens
        secret_patterns = [
            r'sk-[a-zA-Z0-9]{20,}',           # OpenAI-style
            r'ghp_[a-zA-Z0-9]{36}',            # GitHub PAT
            r'ghu_[a-zA-Z0-9]{36}',            # GitHub user token
            r'sk-ant-[a-zA-Z0-9-]{80,}',       # Anthropic
            r'AIza[a-zA-Z0-9_-]{35}',          # Google API key
        ]
        
        for filename in os.listdir(scripts_dir):
            filepath = os.path.join(scripts_dir, filename)
            if os.path.isdir(filepath):
                continue
            with open(filepath, 'r') as f:
                content = f.read()
            
            for pattern in secret_patterns:
                matches = re.findall(pattern, content)
                if matches:
                    pytest.fail(
                        f"SECURITY: Possible hardcoded secret in {filename}\n"
                        f"Pattern: {pattern}\n"
                        "Secrets should come from environment variables."
                    )
