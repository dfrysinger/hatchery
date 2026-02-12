#!/usr/bin/env python3
"""Tests for improved timestamp parse error handling.

Issue #120: Add better error messages for invalid timestamp formats.

These tests verify that api-server.py:
- Catches timestamp parse failures with clear error messages
- Includes the invalid value and expected format in error output
- Handles various malformed timestamp inputs gracefully
"""
import hashlib
import hmac
import json
import sys
import time
from pathlib import Path
from unittest import mock

import pytest

# Add scripts directory to path for imports
REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))


# Mock the API_SECRET before importing
@pytest.fixture(autouse=True)
def mock_api_secret(monkeypatch):
    """Set API_SECRET for all tests."""
    monkeypatch.setenv('API_SECRET', 'test-secret-key')


def get_verify_hmac_auth():
    """Import verify_hmac_auth fresh (to pick up mocked env)."""
    # Clear any cached import
    if 'api-server' in sys.modules:
        del sys.modules['api-server']
    
    # Read and exec just the verify_hmac_auth function
    api_server_path = SCRIPTS_DIR / "api-server.py"
    source = api_server_path.read_text()
    
    # Extract imports and function
    namespace = {'__name__': 'test'}
    exec("import hmac, hashlib, time, os", namespace)
    namespace['API_SECRET'] = 'test-secret-key'
    
    # Find and execute verify_hmac_auth function
    start = source.find('def verify_hmac_auth')
    end = source.find('\nclass H', start)
    func_source = source[start:end]
    exec(func_source, namespace)
    
    return namespace['verify_hmac_auth']


def make_valid_signature(timestamp, method, path, body=''):
    """Create a valid HMAC signature for testing."""
    secret = 'test-secret-key'
    msg = f"{timestamp}.{method}.{path}.{body}"
    return hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()


class TestTimestampMissing:
    """Test error messages when timestamp header is missing."""

    def test_missing_timestamp_header(self):
        """Missing X-Timestamp should return clear error."""
        verify = get_verify_hmac_auth()
        ok, err = verify(None, "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert err is not None
        assert "Missing X-Timestamp" in err

    def test_empty_timestamp_header(self):
        """Empty X-Timestamp should return clear error."""
        verify = get_verify_hmac_auth()
        ok, err = verify("", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert err is not None
        assert "Missing X-Timestamp" in err


class TestTimestampFormat:
    """Test error messages for invalid timestamp formats."""

    def test_non_integer_timestamp(self):
        """Non-integer timestamp should include the invalid value."""
        verify = get_verify_hmac_auth()
        ok, err = verify("abc", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert err is not None
        assert "Invalid timestamp format" in err
        assert "'abc'" in err
        assert "integer" in err.lower()

    def test_float_timestamp(self):
        """Float timestamp should explain it must be integer."""
        verify = get_verify_hmac_auth()
        ok, err = verify("1707676800.123", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert err is not None
        assert "Invalid timestamp format" in err
        assert "1707676800.123" in err
        assert "not float" in err.lower() or "integer" in err.lower()

    def test_negative_timestamp(self):
        """Negative timestamp should be accepted (valid Unix time, just old)."""
        verify = get_verify_hmac_auth()
        timestamp = "-1000"
        sig = make_valid_signature(timestamp, "GET", "/test")
        ok, err = verify(timestamp, sig, "GET", "/test", b'')
        
        # Negative is technically parseable, but will be expired
        assert ok is False
        assert "expired" in err.lower() or "old" in err.lower()

    def test_very_large_timestamp(self):
        """Very large timestamp should work (far future)."""
        verify = get_verify_hmac_auth()
        timestamp = "9999999999"  # Year 2286
        sig = make_valid_signature(timestamp, "GET", "/test")
        ok, err = verify(timestamp, sig, "GET", "/test", b'')
        
        # Should fail due to being in future, not parse error
        assert ok is False
        assert "future" in err.lower()

    def test_timestamp_with_leading_trailing_spaces(self):
        """Timestamp with leading/trailing spaces is parsed (Python int() strips whitespace)."""
        verify = get_verify_hmac_auth()
        # Python's int() strips whitespace, so " 123 " becomes 123
        # This should parse successfully but fail on expiry since 1707676800 is in the past
        ok, err = verify(" 1707676800 ", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        # Should fail on expiry, not parse error (int() accepts whitespace)
        assert "expired" in err.lower() or "old" in err.lower()

    def test_timestamp_with_internal_spaces(self):
        """Timestamp with internal spaces should fail clearly."""
        verify = get_verify_hmac_auth()
        ok, err = verify("1707 676800", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert "Invalid timestamp format" in err

    def test_timestamp_with_prefix(self):
        """Timestamp with text prefix should fail clearly."""
        verify = get_verify_hmac_auth()
        ok, err = verify("ts:1707676800", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert "Invalid timestamp format" in err
        assert "ts:1707676800" in err

    def test_iso_format_timestamp(self):
        """ISO format timestamp should fail with clear message."""
        verify = get_verify_hmac_auth()
        ok, err = verify("2024-02-11T12:00:00Z", "some-signature", "GET", "/test", b'')
        
        assert ok is False
        assert "Invalid timestamp format" in err
        assert "2024-02-11" in err

    def test_milliseconds_timestamp(self):
        """Milliseconds timestamp (13 digits) should work if within range."""
        verify = get_verify_hmac_auth()
        # This is far in the future (would be year ~49000 in seconds)
        # but let's test that it's at least parsed
        ok, err = verify("1707676800000", "some-signature", "GET", "/test", b'')
        
        # Should parse but fail on drift
        assert ok is False
        assert "future" in err.lower() or "ahead" in err.lower()


class TestTimestampExpiry:
    """Test error messages for expired/future timestamps."""

    def test_expired_timestamp(self):
        """Expired timestamp should include age in error."""
        verify = get_verify_hmac_auth()
        old_timestamp = str(int(time.time()) - 600)  # 10 minutes ago
        sig = make_valid_signature(old_timestamp, "GET", "/test")
        ok, err = verify(old_timestamp, sig, "GET", "/test", b'')
        
        assert ok is False
        assert "expired" in err.lower() or "old" in err.lower()
        assert "300s" in err  # Should mention max allowed

    def test_future_timestamp(self):
        """Future timestamp should indicate it's ahead."""
        verify = get_verify_hmac_auth()
        future_timestamp = str(int(time.time()) + 600)  # 10 minutes ahead
        sig = make_valid_signature(future_timestamp, "GET", "/test")
        ok, err = verify(future_timestamp, sig, "GET", "/test", b'')
        
        assert ok is False
        assert "future" in err.lower() or "ahead" in err.lower()
        assert "300s" in err  # Should mention max drift

    def test_barely_expired_timestamp(self):
        """Timestamp just over 300s old should fail."""
        verify = get_verify_hmac_auth()
        old_timestamp = str(int(time.time()) - 301)
        sig = make_valid_signature(old_timestamp, "GET", "/test")
        ok, err = verify(old_timestamp, sig, "GET", "/test", b'')
        
        assert ok is False
        assert "expired" in err.lower()

    def test_valid_timestamp_range(self):
        """Timestamp within 300s should pass (if signature valid)."""
        verify = get_verify_hmac_auth()
        timestamp = str(int(time.time()) - 100)  # 100s ago
        sig = make_valid_signature(timestamp, "GET", "/test")
        ok, err = verify(timestamp, sig, "GET", "/test", b'')
        
        assert ok is True
        assert err is None


class TestSignatureMissing:
    """Test error messages when signature header is missing."""

    def test_missing_signature_header(self):
        """Missing X-Signature should return clear error."""
        verify = get_verify_hmac_auth()
        timestamp = str(int(time.time()))
        ok, err = verify(timestamp, None, "GET", "/test", b'')
        
        assert ok is False
        assert "Missing X-Signature" in err

    def test_empty_signature_header(self):
        """Empty X-Signature should return clear error."""
        verify = get_verify_hmac_auth()
        timestamp = str(int(time.time()))
        ok, err = verify(timestamp, "", "GET", "/test", b'')
        
        assert ok is False
        assert "Missing X-Signature" in err


class TestSignatureMismatch:
    """Test error messages for signature verification failures."""

    def test_wrong_signature(self):
        """Wrong signature should indicate mismatch."""
        verify = get_verify_hmac_auth()
        timestamp = str(int(time.time()))
        ok, err = verify(timestamp, "wrong-signature", "GET", "/test", b'')
        
        assert ok is False
        assert "mismatch" in err.lower() or "Signature" in err

    def test_valid_signature(self):
        """Valid signature should pass."""
        verify = get_verify_hmac_auth()
        timestamp = str(int(time.time()))
        sig = make_valid_signature(timestamp, "GET", "/test")
        ok, err = verify(timestamp, sig, "GET", "/test", b'')
        
        assert ok is True
        assert err is None

    def test_valid_signature_with_body(self):
        """Valid signature with body should pass."""
        verify = get_verify_hmac_auth()
        timestamp = str(int(time.time()))
        body = '{"key": "value"}'
        sig = make_valid_signature(timestamp, "POST", "/test", body)
        ok, err = verify(timestamp, sig, "POST", "/test", body.encode())
        
        assert ok is True
        assert err is None


class TestAPISecretMissing:
    """Test error messages when API_SECRET is not configured."""

    def test_no_api_secret(self, monkeypatch):
        """Missing API_SECRET should return clear error."""
        # Get fresh function with no secret
        api_server_path = SCRIPTS_DIR / "api-server.py"
        source = api_server_path.read_text()
        
        namespace = {'__name__': 'test'}
        exec("import hmac, hashlib, time, os", namespace)
        namespace['API_SECRET'] = ''  # Empty = not configured
        
        start = source.find('def verify_hmac_auth')
        end = source.find('\nclass H', start)
        func_source = source[start:end]
        exec(func_source, namespace)
        
        verify = namespace['verify_hmac_auth']
        timestamp = str(int(time.time()))
        ok, err = verify(timestamp, "some-sig", "GET", "/test", b'')
        
        assert ok is False
        assert "API_SECRET" in err


class TestErrorMessageQuality:
    """Test that error messages are user-friendly and actionable."""

    def test_format_example_in_error(self):
        """Invalid format should include example of correct format."""
        verify = get_verify_hmac_auth()
        ok, err = verify("not-a-number", "sig", "GET", "/test", b'')
        
        assert ok is False
        # Should include example like "e.g., 1707676800"
        assert "e.g." in err or "example" in err.lower() or "epoch" in err.lower()

    def test_errors_are_specific(self):
        """Each error type should be distinguishable."""
        verify = get_verify_hmac_auth()
        
        # Missing timestamp
        _, err1 = verify(None, "sig", "GET", "/test", b'')
        # Invalid timestamp
        _, err2 = verify("abc", "sig", "GET", "/test", b'')
        # Expired timestamp
        _, err3 = verify(str(int(time.time()) - 600), 
                        make_valid_signature(str(int(time.time()) - 600), "GET", "/test"),
                        "GET", "/test", b'')
        
        # All should be different
        assert err1 != err2
        assert err2 != err3
        assert err1 != err3


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
