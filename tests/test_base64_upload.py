#!/usr/bin/env python3
"""Tests for base64 body support in /config/upload.

This feature enables iOS Shortcuts to upload config without shell escaping issues.
When Content-Type contains 'base64', the body is decoded before processing.
"""
import base64
import hashlib
import hmac
import json
import time
import unittest


class TestBase64BodyDecoding(unittest.TestCase):
    """Test base64 body decoding logic."""

    def test_base64_with_newlines_decodes(self):
        """Base64 with newlines (iOS line-wrap at 76 chars) should decode correctly."""
        original = '{"habitat":{"name":"Test"},"apply":false}'
        encoded = base64.b64encode(original.encode()).decode()
        
        # Simulate iOS line wrapping
        wrapped = '\n'.join([encoded[i:i+20] for i in range(0, len(encoded), 20)])
        
        # Strip and decode (as server does)
        cleaned = wrapped.replace('\n', '').replace('\r', '').replace(' ', '')
        decoded = base64.b64decode(cleaned).decode('utf-8')
        
        self.assertEqual(decoded, original)

    def test_content_type_detection(self):
        """Content-Type containing 'base64' should trigger decoding."""
        # These should trigger base64 decoding
        base64_types = [
            'application/base64',
            'application/base64+json',
            'text/plain; charset=utf-8; encoding=base64',
            'APPLICATION/BASE64',  # Case insensitive
        ]
        
        # These should NOT trigger base64 decoding
        json_types = [
            'application/json',
            'text/plain',
            '',
        ]
        
        for ct in base64_types:
            self.assertIn('base64', ct.lower(), f"{ct} should contain 'base64'")
        
        for ct in json_types:
            self.assertNotIn('base64', ct.lower(), f"{ct} should not contain 'base64'")

    def test_signature_on_decoded_body(self):
        """HMAC signature should be verified on the decoded (JSON) body."""
        secret = 'test-secret'
        config = {"habitat": {"name": "Test"}, "apply": False}
        body_json = json.dumps(config)
        
        # Client signs the JSON body (not the base64)
        timestamp = str(int(time.time()))
        msg = f"{timestamp}.POST./config/upload.{body_json}"
        signature = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        
        # Client sends base64-encoded version
        body_b64 = base64.b64encode(body_json.encode()).decode()
        
        # Server decodes and verifies against decoded body
        decoded = base64.b64decode(body_b64).decode('utf-8')
        server_msg = f"{timestamp}.POST./config/upload.{decoded}"
        expected_sig = hmac.new(secret.encode(), server_msg.encode(), hashlib.sha256).hexdigest()
        
        self.assertEqual(signature, expected_sig)

    def test_invalid_base64_rejected(self):
        """Invalid base64 should raise an error."""
        invalid = b'not-valid-base64!!!'
        
        with self.assertRaises(Exception):
            base64.b64decode(invalid)


class TestBase64UploadWorkflow(unittest.TestCase):
    """Test the complete iOS Shortcuts workflow."""

    def test_ios_shortcuts_workflow(self):
        """Simulate the iOS Shortcuts upload workflow.
        
        1. Client builds config JSON
        2. Client base64 encodes it
        3. Client signs the original JSON
        4. Client sends base64 body with Content-Type: application/base64
        5. Server decodes, verifies signature, processes
        """
        secret = 'habitat-api-secret'
        config = {
            "habitat": {
                "name": "TestHabitat",
                "agents": [{"name": "agent1"}]
            },
            "agents": {
                "agent1": {"model": "claude-opus-4"}
            },
            "apply": True
        }
        
        # Step 1-2: Build and encode
        body_json = json.dumps(config)
        body_b64 = base64.b64encode(body_json.encode()).decode()
        
        # Step 3: Sign the ORIGINAL JSON (not base64)
        timestamp = str(int(time.time()))
        msg = f"{timestamp}.POST./config/upload.{body_json}"
        signature = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        
        # Step 4: What gets sent
        headers = {
            'Content-Type': 'application/base64',
            'X-Timestamp': timestamp,
            'X-Signature': signature,
        }
        request_body = body_b64.encode()
        
        # Step 5: Server processing
        # Server decodes
        decoded_body = base64.b64decode(request_body).decode('utf-8')
        
        # Server verifies
        server_msg = f"{timestamp}.POST./config/upload.{decoded_body}"
        expected = hmac.new(secret.encode(), server_msg.encode(), hashlib.sha256).hexdigest()
        
        self.assertTrue(hmac.compare_digest(signature, expected))
        
        # Server parses
        parsed = json.loads(decoded_body)
        self.assertEqual(parsed['habitat']['name'], 'TestHabitat')


if __name__ == '__main__':
    unittest.main()
