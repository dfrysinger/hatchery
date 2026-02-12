"""
Tests for SECURITY.md documentation consistency (Issue #169).

Ensures SECURITY.md accurately reflects actual API server binding behavior:
- Default: 127.0.0.1:8080 (localhost-only, secure-by-default)
- Opt-in: 0.0.0.0:8080 (when remoteApi: true or apiBindAddress set)
"""

import os
import re
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECURITY_MD = os.path.join(REPO_ROOT, "docs", "security", "SECURITY.md")
API_SERVER_PY = os.path.join(REPO_ROOT, "scripts", "api-server.py")


class TestApiServerBindingDefaults:
    """Test that api-server.py has correct default binding (source of truth)."""

    def test_api_server_exists(self):
        """api-server.py must exist."""
        assert os.path.isfile(API_SERVER_PY), "scripts/api-server.py not found"

    def test_default_bind_is_localhost(self):
        """API_BIND_ADDRESS default must be 127.0.0.1 (secure-by-default)."""
        with open(API_SERVER_PY, "r") as f:
            content = f.read()
        
        # Look for the default binding line
        match = re.search(r"API_BIND_ADDRESS\s*=\s*os\.getenv\(['\"]API_BIND_ADDRESS['\"]\s*,\s*['\"]([^'\"]+)['\"]\)", content)
        assert match, "Could not find API_BIND_ADDRESS default in api-server.py"
        
        default_bind = match.group(1)
        assert default_bind == "127.0.0.1", (
            f"API server default must be 127.0.0.1 (localhost), got: {default_bind}"
        )


class TestSecurityDocConsistency:
    """Test that SECURITY.md is consistent about API binding behavior."""

    def test_security_md_exists(self):
        """SECURITY.md must exist."""
        assert os.path.isfile(SECURITY_MD), "docs/SECURITY.md not found"

    def test_states_default_is_localhost(self):
        """SECURITY.md must explicitly state the default is 127.0.0.1 (localhost-only)."""
        with open(SECURITY_MD, "r") as f:
            content = f.read()
        
        # Must contain explicit statement about default being 127.0.0.1
        assert re.search(r"default.*127\.0\.0\.1", content, re.IGNORECASE), (
            "SECURITY.md must state that default binding is 127.0.0.1"
        )
        
        # Must contain "localhost-only" or "localhost only"
        assert re.search(r"localhost[- ]only", content, re.IGNORECASE), (
            "SECURITY.md must describe 127.0.0.1 as localhost-only"
        )

    def test_no_contradictory_default_statements(self):
        """SECURITY.md must not claim default is 0.0.0.0 anywhere."""
        with open(SECURITY_MD, "r") as f:
            lines = f.readlines()
        
        # Check for misleading statements
        for i, line in enumerate(lines, 1):
            # Skip lines that correctly describe opt-in remote access
            if "remoteApi" in line or "apiBindAddress" in line:
                continue
            if "when configured" in line.lower() or "opt-in" in line.lower():
                continue
            if "can bind" in line.lower() or "can safely bind" in line.lower():
                continue
            
            # Now check for statements that might imply default is 0.0.0.0
            if "default" in line.lower() and "0.0.0.0" in line:
                pytest.fail(
                    f"Line {i} incorrectly implies default is 0.0.0.0: {line.strip()}\n"
                    "Default must be 127.0.0.1 per api-server.py"
                )

    def test_diagram_shows_correct_binding(self):
        """Architecture diagram must show 127.0.0.1:8080 or clarify opt-in for 0.0.0.0."""
        with open(SECURITY_MD, "r") as f:
            content = f.read()
        
        # Find the diagram section (between ``` markers near "How It Works")
        diagram_match = re.search(r"### How It Works.*?```(.*?)```", content, re.DOTALL)
        assert diagram_match, "Could not find architecture diagram in SECURITY.md"
        
        diagram = diagram_match.group(1)
        
        # If diagram mentions 0.0.0.0, it must include a note about remoteApi
        if "0.0.0.0:8080" in diagram:
            # Check if there's a clarifying note nearby
            context = content[diagram_match.start():diagram_match.end() + 500]
            assert (
                "remoteApi" in context or 
                "opt-in" in context.lower() or
                "when configured" in context.lower()
            ), (
                "Diagram shows 0.0.0.0:8080 but doesn't clarify this is opt-in behavior.\n"
                "Either show 127.0.0.1:8080 as default or add note about remoteApi requirement."
            )

    def test_secure_by_default_mentioned(self):
        """SECURITY.md must describe the API as 'secure-by-default'."""
        with open(SECURITY_MD, "r") as f:
            content = f.read()
        
        assert re.search(r"secure[- ]by[- ]default", content, re.IGNORECASE), (
            "SECURITY.md should describe localhost binding as 'secure-by-default'"
        )

    def test_opt_in_remote_access_documented(self):
        """SECURITY.md must document how to opt-in to remote API access (0.0.0.0)."""
        with open(SECURITY_MD, "r") as f:
            content = f.read()
        
        # Must mention remoteApi option
        assert '"remoteApi"' in content, (
            "SECURITY.md must document remoteApi config option for remote access"
        )
        
        # Must mention apiBindAddress option
        assert '"apiBindAddress"' in content, (
            "SECURITY.md must document apiBindAddress config option"
        )

    def test_firewall_protection_documented_for_remote_binding(self):
        """When discussing 0.0.0.0 binding, must mention firewall protection."""
        with open(SECURITY_MD, "r") as f:
            content = f.read()
        
        # Find sections discussing 0.0.0.0 binding
        lines = content.split('\n')
        for i, line in enumerate(lines):
            if "0.0.0.0" in line:
                # Check surrounding context (±10 lines) for firewall mention
                context_start = max(0, i - 10)
                context_end = min(len(lines), i + 10)
                context = '\n'.join(lines[context_start:context_end])
                
                # Skip if it's in a code block showing config override
                if '"apiBindAddress": "0.0.0.0"' in line:
                    continue
                
                # Must mention firewall, allowlist, or DO cloud protection
                has_security_context = any(
                    term in context.lower() 
                    for term in ["firewall", "allowlist", "cloud", "digitalocean", "hmac"]
                )
                
                assert has_security_context, (
                    f"Line {i+1} mentions 0.0.0.0 without firewall/security context:\n{line}\n"
                    "When discussing 0.0.0.0 binding, must explain firewall protection."
                )
