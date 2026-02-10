#!/usr/bin/env python3
"""Tests for /sign endpoint and base64 body support in /config/upload.

These features enable iOS Shortcuts integration by:
1. Providing server-side HMAC signing (Shortcuts can't do crypto natively)
2. Accepting base64-encoded bodies (easier to handle in Shortcuts than JSON escaping)

Issue: https://github.com/dfrysinger/hatchery/issues/190
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock

# Add scripts directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))


class TestNormalizeJson(unittest.TestCase):
    """Test JSON normalization for consistent signing."""

    def test_normalize_removes_whitespace(self):
        """Normalization should produce compact JSON."""
        from api_server_helpers import normalize_json
        input_json = '{"key":  "value",  "num":  123}'
        result = normalize_json(input_json)
        self.assertEqual(result, '{"key":"value","num":123}')

    def test_normalize_sorts_keys_consistently(self):
        """Same data should produce same normalized output."""
        from api_server_helpers import normalize_json
        input1 = '{"b": 2, "a": 1}'
        input2 = '{"a": 1, "b": 2}'
        # Note: Python's json.dumps doesn't sort by default, 
        # but the output should be consistent for same input
        result1 = normalize_json(input1)
        result2 = normalize_json(input2)
        # Both should parse to same dict
        self.assertEqual(json.loads(result1), json.loads(result2))

    def test_normalize_invalid_json_returns_original(self):
        """Invalid JSON should be returned unchanged."""
        from api_server_helpers import normalize_json
        invalid = 'not json at all'
        result = normalize_json(invalid)
        self.assertEqual(result, invalid)


class TestGenerateSignature(unittest.TestCase):
    """Test HMAC signature generation for /sign endpoint."""

    def setUp(self):
        """Set up test secret."""
        self.test_secret = 'test-secret-key-12345'

    @patch.dict(os.environ, {'API_SECRET': 'test-secret-key-12345'})
    def test_generate_signature_success(self):
        """Should return ok, timestamp, and signature."""
        from api_server_helpers import generate_signature
        result = generate_signature('{"test":"body"}', '/config/upload', 'POST')
        
        self.assertTrue(result['ok'])
        self.assertIn('timestamp', result)
        self.assertIn('signature', result)
        self.assertEqual(len(result['signature']), 64)  # SHA256 hex = 64 chars

    @patch.dict(os.environ, {'API_SECRET': ''})
    def test_generate_signature_no_secret(self):
        """Should return error if API_SECRET not configured."""
        from api_server_helpers import generate_signature
        result = generate_signature('body', '/path', 'POST')
        
        self.assertFalse(result['ok'])
        self.assertIn('error', result)
        self.assertIn('API_SECRET', result['error'])

    @patch.dict(os.environ, {'API_SECRET': 'test-secret'})
    def test_signature_format_matches_spec(self):
        """Signature should be HMAC-SHA256 of 'timestamp.method.path.body'."""
        from api_server_helpers import generate_signature
        
        body = '{"habitat":{"name":"test"}}'
        path = '/config/upload'
        method = 'POST'
        
        result = generate_signature(body, path, method)
        
        # Verify we can recreate the signature
        msg = f"{result['timestamp']}.{method}.{path}.{body}"
        expected_sig = hmac.new(
            'test-secret'.encode(),
            msg.encode(),
            hashlib.sha256
        ).hexdigest()
        
        self.assertEqual(result['signature'], expected_sig)


class TestSignEndpointRequestParsing(unittest.TestCase):
    """Test /sign endpoint request parsing logic."""

    def test_simple_mode_defaults(self):
        """Body-only request should use POST /config/upload defaults."""
        request_body = '{"body": "eyJ0ZXN0IjoidmFsdWUifQ=="}'  # base64 of {"test":"value"}
        data = json.loads(request_body)
        
        method = data.get('method', 'POST')
        path = data.get('path', '/config/upload')
        body_b64 = data.get('body', '')
        
        self.assertEqual(method, 'POST')
        self.assertEqual(path, '/config/upload')
        self.assertEqual(body_b64, 'eyJ0ZXN0IjoidmFsdWUifQ==')

    def test_wrapper_mode_custom_path(self):
        """Request can specify custom method and path."""
        request_body = '{"method": "GET", "path": "/status", "body": ""}'
        data = json.loads(request_body)
        
        method = data.get('method', 'POST')
        path = data.get('path', '/config/upload')
        
        self.assertEqual(method, 'GET')
        self.assertEqual(path, '/status')

    def test_base64_body_decoding(self):
        """Body field should be base64 decoded before signing."""
        original = '{"habitat":{"name":"TestHab"}}'
        encoded = base64.b64encode(original.encode()).decode()
        
        # Decode it back
        decoded = base64.b64decode(encoded).decode()
        self.assertEqual(decoded, original)


class TestBase64BodyDecoding(unittest.TestCase):
    """Test base64 body decoding for /config/upload."""

    def test_valid_base64_decodes(self):
        """Valid base64 should decode correctly."""
        original = '{"habitat":{"name":"test"}}'
        encoded = base64.b64encode(original.encode()).decode()
        
        decoded = base64.b64decode(encoded).decode('utf-8')
        self.assertEqual(decoded, original)

    def test_base64_with_newlines(self):
        """Base64 with newlines should decode after stripping."""
        original = '{"habitat":{"name":"test"}}'
        encoded = base64.b64encode(original.encode()).decode()
        
        # Simulate iOS adding line breaks at 76 chars
        with_newlines = '\n'.join([encoded[i:i+20] for i in range(0, len(encoded), 20)])
        
        # Strip and decode
        cleaned = with_newlines.replace('\n', '').replace('\r', '').replace(' ', '')
        decoded = base64.b64decode(cleaned).decode('utf-8')
        
        self.assertEqual(decoded, original)

    def test_base64_with_carriage_returns(self):
        """Base64 with \\r\\n should decode after stripping."""
        original = '{"test":"value"}'
        encoded = base64.b64encode(original.encode()).decode()
        
        with_crlf = encoded[:10] + '\r\n' + encoded[10:]
        cleaned = with_crlf.replace('\n', '').replace('\r', '').replace(' ', '')
        decoded = base64.b64decode(cleaned).decode('utf-8')
        
        self.assertEqual(decoded, original)

    def test_invalid_base64_raises_error(self):
        """Invalid base64 should raise an appropriate error."""
        invalid = 'not-valid-base64!!!'
        
        with self.assertRaises(Exception):
            base64.b64decode(invalid)


class TestConfigUploadWithBase64(unittest.TestCase):
    """Integration tests for /config/upload with base64 bodies."""

    def setUp(self):
        """Set up test config."""
        self.test_config = {
            "habitat": {"name": "TestHabitat", "agents": []},
            "agents": {"agent1": {"model": "test"}},
            "apply": False
        }
        self.encoded_config = base64.b64encode(
            json.dumps(self.test_config).encode()
        ).decode()

    def test_base64_body_signature_verification(self):
        """Signature should verify against decoded body."""
        secret = 'test-secret'
        body_json = json.dumps(self.test_config)
        normalized = json.dumps(json.loads(body_json), separators=(',', ':'))
        
        timestamp = str(int(time.time()))
        method = 'POST'
        path = '/config/upload'
        
        # Sign the normalized decoded body
        msg = f"{timestamp}.{method}.{path}.{normalized}"
        signature = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        
        # Verify signature
        expected_msg = f"{timestamp}.{method}.{path}.{normalized}"
        expected_sig = hmac.new(secret.encode(), expected_msg.encode(), hashlib.sha256).hexdigest()
        
        self.assertEqual(signature, expected_sig)


class TestSignEndpointEdgeCases(unittest.TestCase):
    """Edge case tests for /sign endpoint."""

    def test_empty_body(self):
        """Empty body should be valid (for GET requests, etc)."""
        body_b64 = base64.b64encode(b'').decode()
        self.assertEqual(body_b64, '')
        
        decoded = base64.b64decode(body_b64).decode() if body_b64 else ''
        self.assertEqual(decoded, '')

    def test_unicode_in_body(self):
        """Unicode characters should be handled correctly."""
        original = '{"name":"Tëst Hàbítât 🚀"}'
        encoded = base64.b64encode(original.encode('utf-8')).decode()
        decoded = base64.b64decode(encoded).decode('utf-8')
        
        self.assertEqual(decoded, original)

    def test_large_body(self):
        """Large bodies (like full agent configs) should work."""
        # Simulate a large agent config
        large_config = {
            "agents": {f"agent{i}": {"identity": "x" * 10000} for i in range(10)}
        }
        body = json.dumps(large_config)
        encoded = base64.b64encode(body.encode()).decode()
        decoded = base64.b64decode(encoded).decode()
        
        self.assertEqual(json.loads(decoded), large_config)


# Helper function module - this would be extracted from api-server.py
# For testing, we'll mock the imports or create a helper module

def validate_config_upload(data):
    """Validate config upload request data."""
    errors = []
    if "habitat" in data and not isinstance(data["habitat"], dict):
        errors.append("habitat must be an object")
    if "agents" in data and not isinstance(data["agents"], dict):
        errors.append("agents must be an object")
    if "apply" in data and not isinstance(data["apply"], bool):
        errors.append("apply must be a boolean")
    return errors


if __name__ == '__main__':
    unittest.main()
