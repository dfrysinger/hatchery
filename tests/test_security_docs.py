"""
Test for Issue #169: SECURITY.md documentation accuracy

Verifies that security documentation matches actual implementation.
"""

import os
import re
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECURITY_DOC = os.path.join(REPO_ROOT, "docs", "SECURITY.md")
API_SERVER = os.path.join(REPO_ROOT, "scripts", "api-server.py")


class TestSecurityDocumentation:
    """Test that SECURITY.md accurately reflects implementation."""

    def test_security_doc_exists(self):
        """SECURITY.md must exist."""
        assert os.path.isfile(SECURITY_DOC), "docs/SECURITY.md not found"

    def test_api_server_exists(self):
        """api-server.py must exist for reference."""
        assert os.path.isfile(API_SERVER), "scripts/api-server.py not found"

    def test_default_bind_is_localhost(self):
        """API server defaults to 127.0.0.1 (localhost-only)."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Verify default bind address is 127.0.0.1
        assert "API_BIND_ADDRESS=os.getenv('API_BIND_ADDRESS','127.0.0.1')" in content, (
            "API server should default to 127.0.0.1"
        )

    def test_docs_state_secure_by_default(self):
        """SECURITY.md must state that API defaults to 127.0.0.1."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Should mention 127.0.0.1 as default
        assert "127.0.0.1" in content, "SECURITY.md should mention 127.0.0.1 default"
        assert "localhost-only" in content.lower() or "localhost only" in content.lower(), (
            "SECURITY.md should describe localhost-only default"
        )

    def test_docs_describe_0_0_0_0_as_opt_in(self):
        """SECURITY.md must describe 0.0.0.0 binding as opt-in."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Should mention opt-in or remote access enabling
        assert "opt-in" in content.lower() or "remoteApi" in content, (
            "SECURITY.md should describe 0.0.0.0 as opt-in"
        )

    def test_no_contradictory_default_statements(self):
        """SECURITY.md must not have contradictory statements about default binding."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Check for bad patterns that claim 0.0.0.0 is default
        bad_patterns = [
            r"API Server \(0\.0\.0\.0:8080\)",  # Diagram showing 0.0.0.0 without "opt-in" context
            r"defaults? to.*?0\.0\.0\.0",  # "defaults to 0.0.0.0"
            r"0\.0\.0\.0.*?by default",  # "0.0.0.0 by default"
        ]

        for pattern in bad_patterns:
            match = re.search(pattern, content, re.IGNORECASE)
            # Allow the pattern if it's explicitly about opt-in or remote access
            if match:
                context = content[max(0, match.start() - 100):match.end() + 100]
                # Skip if the context mentions opt-in, remote, or similar qualifiers
                if not re.search(r"opt-in|remote|when.*enabled", context, re.IGNORECASE):
                    pytest.fail(
                        f"Found misleading default statement: {match.group(0)}\n"
                        f"Context: ...{context}..."
                    )

        # Verify 127.0.0.1 is stated as default
        assert re.search(r"default.*?127\.0\.0\.1|127\.0\.0\.1.*?default", content, re.IGNORECASE), (
            "SECURITY.md should state 127.0.0.1 as default"
        )


class TestEndpointAuthTable:
    """Test that endpoint authentication table matches actual implementation."""

    def test_stages_endpoint_requires_auth(self):
        """Verify /stages endpoint requires HMAC auth in code."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Find /stages endpoint handler
        stages_section = re.search(
            r"elif self\.path=='/stages':.*?elif self\.path",
            content,
            re.DOTALL
        )
        assert stages_section, "/stages endpoint not found in api-server.py"

        # Should call verify_hmac_auth
        assert "verify_hmac_auth" in stages_section.group(0), (
            "/stages endpoint should require HMAC authentication"
        )

    def test_config_endpoint_requires_auth(self):
        """Verify /config endpoint requires HMAC auth in code."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Find /config endpoint handler (not /config/status)
        config_section = re.search(
            r"elif self\.path=='/config':.*?else:self\.send_response\(404\)",
            content,
            re.DOTALL
        )
        assert config_section, "/config endpoint not found in api-server.py"

        # Should call verify_hmac_auth
        assert "verify_hmac_auth" in config_section.group(0), (
            "/config endpoint should require HMAC authentication"
        )

    def test_config_status_no_auth(self):
        """Verify /config/status endpoint does NOT require auth."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Find /config/status endpoint handler
        config_status_section = re.search(
            r"elif self\.path=='/config/status':.*?elif self\.path",
            content,
            re.DOTALL
        )
        assert config_status_section, "/config/status endpoint not found"

        # Should NOT call verify_hmac_auth
        assert "verify_hmac_auth" not in config_status_section.group(0), (
            "/config/status should be unauthenticated (by design)"
        )

    def test_docs_endpoint_table_accurate(self):
        """SECURITY.md endpoint table must match actual implementation."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Extract the endpoint table from "API Endpoints by Sensitivity" section
        table_section = re.search(
            r"## API Endpoints by Sensitivity.*?\n\n##",
            content,
            re.DOTALL
        )
        assert table_section, "API Endpoints by Sensitivity table not found in SECURITY.md"

        table_text = table_section.group(0)

        # Verify /stages requires auth
        stages_row = re.search(r"\| `/stages`\s*\|([^|]+)\|", table_text)
        assert stages_row, "/stages not found in endpoint table"
        assert "yes" in stages_row.group(1).lower() or "hmac" in stages_row.group(1).lower(), (
            "/stages should be marked as requiring HMAC auth in table"
        )

        # Verify /config requires auth
        # Use negative lookahead to exclude /config/status
        config_row = re.search(r"\| `/config`(?!/status)\s*\|([^|]+)\|", table_text)
        assert config_row, "/config not found in endpoint table"
        assert "yes" in config_row.group(1).lower() or "hmac" in config_row.group(1).lower(), (
            "/config should be marked as requiring HMAC auth in table"
        )

        # Verify /config/status does NOT require auth
        config_status_row = re.search(r"\| `/config/status`\s*\|([^|]+)\|", table_text)
        if config_status_row:  # Optional - may not be documented yet
            assert "no" in config_status_row.group(1).lower(), (
                "/config/status should be marked as not requiring auth"
            )

        # Verify /status and /health are still public
        status_row = re.search(r"\| `/status`\s*\|([^|]+)\|", table_text)
        assert status_row, "/status not found in endpoint table"
        assert "no" in status_row.group(1).lower(), "/status should be public"

        health_row = re.search(r"\| `/health`\s*\|([^|]+)\|", table_text)
        assert health_row, "/health not found in endpoint table"
        assert "no" in health_row.group(1).lower(), "/health should be public"
