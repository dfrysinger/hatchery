"""
Test for Issue #181: SECURITY.md endpoint authentication table accuracy

Verifies that the endpoint authentication table in SECURITY.md accurately
reflects the actual authentication requirements in api-server.py.
"""

import os
import re
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECURITY_DOC = os.path.join(REPO_ROOT, "docs", "SECURITY.md")
API_SERVER = os.path.join(REPO_ROOT, "scripts", "api-server.py")


class TestEndpointAuthImplementation:
    """Verify actual authentication requirements in api-server.py."""

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

    def test_log_endpoint_requires_auth(self):
        """Verify /log endpoint requires HMAC auth in code."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Find /log endpoint handler
        log_section = re.search(
            r"elif self\.path=='/log':.*?elif self\.path",
            content,
            re.DOTALL
        )
        assert log_section, "/log endpoint not found in api-server.py"

        # Should call verify_hmac_auth
        assert "verify_hmac_auth" in log_section.group(0), (
            "/log endpoint should require HMAC authentication"
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

    def test_status_endpoint_no_auth(self):
        """Verify /status endpoint does NOT require auth."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Find /status endpoint handler
        status_section = re.search(
            r"if self\.path=='/status':.*?elif self\.path",
            content,
            re.DOTALL
        )
        assert status_section, "/status endpoint not found"

        # Should NOT call verify_hmac_auth
        assert "verify_hmac_auth" not in status_section.group(0), (
            "/status should be unauthenticated"
        )

    def test_health_endpoint_no_auth(self):
        """Verify /health endpoint does NOT require auth."""
        if not os.path.isfile(API_SERVER):
            pytest.skip("api-server.py does not exist")

        with open(API_SERVER, "r") as f:
            content = f.read()

        # Find /health endpoint handler
        health_section = re.search(
            r"elif self\.path=='/health':.*?elif self\.path",
            content,
            re.DOTALL
        )
        assert health_section, "/health endpoint not found"

        # Should NOT call verify_hmac_auth
        assert "verify_hmac_auth" not in health_section.group(0), (
            "/health should be unauthenticated"
        )


class TestEndpointTableDocumentation:
    """Verify SECURITY.md endpoint table matches implementation."""

    def test_docs_endpoint_table_exists(self):
        """SECURITY.md must have an endpoint authentication table."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Look for the API Endpoints section
        assert "## API Endpoints by Sensitivity" in content, (
            "SECURITY.md should have 'API Endpoints by Sensitivity' section"
        )

    def test_stages_marked_as_requiring_auth(self):
        """SECURITY.md must mark /stages as requiring HMAC auth."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Extract the endpoint table
        table_section = re.search(
            r"## API Endpoints by Sensitivity.*?\n\n##",
            content,
            re.DOTALL
        )
        assert table_section, "Endpoint table not found"

        table_text = table_section.group(0)

        # Find /stages row
        stages_row = re.search(r"\| `/stages`\s*\|([^|]+)\|", table_text)
        assert stages_row, "/stages not found in endpoint table"

        auth_column = stages_row.group(1).strip()
        assert "yes" in auth_column.lower() or "hmac" in auth_column.lower(), (
            f"/stages should be marked as requiring HMAC auth, but auth column is: {auth_column}"
        )

    def test_config_marked_as_requiring_auth(self):
        """SECURITY.md must mark /config as requiring HMAC auth."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Extract the endpoint table
        table_section = re.search(
            r"## API Endpoints by Sensitivity.*?\n\n##",
            content,
            re.DOTALL
        )
        assert table_section, "Endpoint table not found"

        table_text = table_section.group(0)

        # Find /config row (but NOT /config/status)
        config_row = re.search(r"\| `/config`(?!/)\s*\|([^|]+)\|", table_text)
        assert config_row, "/config not found in endpoint table"

        auth_column = config_row.group(1).strip()
        assert "yes" in auth_column.lower() or "hmac" in auth_column.lower(), (
            f"/config should be marked as requiring HMAC auth, but auth column is: {auth_column}"
        )

    def test_log_documented(self):
        """SECURITY.md should document /log endpoint."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Extract the endpoint table
        table_section = re.search(
            r"## API Endpoints by Sensitivity.*?\n\n##",
            content,
            re.DOTALL
        )
        assert table_section, "Endpoint table not found"

        table_text = table_section.group(0)

        # /log may or may not be documented yet, but if it is, it should require auth
        log_row = re.search(r"\| `/log`\s*\|([^|]+)\|", table_text)
        if log_row:
            auth_column = log_row.group(1).strip()
            assert "yes" in auth_column.lower() or "hmac" in auth_column.lower(), (
                f"/log should be marked as requiring HMAC auth if documented"
            )

    def test_config_status_marked_as_no_auth(self):
        """SECURITY.md should mark /config/status as not requiring auth."""
        if not os.path.isfile(SECURITY_DOC):
            pytest.skip("SECURITY.md does not exist")

        with open(SECURITY_DOC, "r") as f:
            content = f.read()

        # Extract the endpoint table
        table_section = re.search(
            r"## API Endpoints by Sensitivity.*?\n\n##",
            content,
            re.DOTALL
        )
        assert table_section, "Endpoint table not found"

        table_text = table_section.group(0)

        # /config/status may or may not be documented yet
        config_status_row = re.search(r"\| `/config/status`\s*\|([^|]+)\|", table_text)
        if config_status_row:
            auth_column = config_status_row.group(1).strip()
            assert "no" in auth_column.lower(), (
                f"/config/status should be marked as NOT requiring auth"
            )
