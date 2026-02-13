#!/usr/bin/env python3
"""Handler-level authentication tests for API endpoints (TASK-170).

Tests that HTTP handlers actually enforce HMAC authentication on protected endpoints.
Unlike test_api_auth.py which only tests verify_hmac_auth(), these tests verify
the actual HTTP handler behavior.
"""
import os
import sys
import time
import json
import hmac
import hashlib
import unittest
import http.server
import socketserver
import threading
from pathlib import Path
import requests


def load_api_server_module(api_secret):
    """Load api-server.py as a module for testing.
    
    Args:
        api_secret: API secret to set before loading module
    """
    import importlib.util
    
    # Set API_SECRET BEFORE loading module
    os.environ['API_SECRET'] = api_secret
    
    repo_root = Path(__file__).parent.parent
    api_server_path = repo_root / "scripts" / "api-server.py"
    
    spec = importlib.util.spec_from_file_location("api_server", api_server_path)
    module = importlib.util.module_from_spec(spec)
    
    # Execute module to populate functions
    spec.loader.exec_module(module)
    
    return module


def compute_hmac_signature(secret, timestamp, method, path, body):
    """Compute HMAC-SHA256 signature for a request."""
    if isinstance(body, bytes):
        body = body.decode('utf-8')
    elif body is None:
        body = ''
    
    message = f"{timestamp}.{method}.{path}.{body}"
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


class TestEndpointAuth(unittest.TestCase):
    """Test that HTTP endpoints actually enforce HMAC authentication."""
    
    @classmethod
    def setUpClass(cls):
        """Start test API server."""
        # Set test API secret BEFORE loading module
        cls.api_secret = 'test-secret-key-endpoint-auth'
        cls.api_module = load_api_server_module(cls.api_secret)
        
        # Start server in background thread
        cls.port = 18080  # Use different port to avoid conflicts
        cls.server = socketserver.TCPServer(
            ('127.0.0.1', cls.port),
            cls.api_module.H,
            bind_and_activate=False
        )
        cls.server.allow_reuse_address = True
        cls.server.server_bind()
        cls.server.server_activate()
        
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        
        # Base URL for requests
        cls.base_url = f'http://127.0.0.1:{cls.port}'
        
        # Wait for server to be ready
        time.sleep(0.5)
    
    @classmethod
    def tearDownClass(cls):
        """Stop test API server."""
        cls.server.shutdown()
        cls.server.server_close()
    
    def make_authenticated_request(self, method, path, body=None):
        """Make an authenticated request to the API."""
        timestamp = int(time.time())
        
        # For POST requests, default body is '{}'
        if body is None and method == 'POST':
            body = '{}'
        
        body_bytes = body.encode('utf-8') if body else b''
        
        signature = compute_hmac_signature(
            self.api_secret,
            timestamp,
            method,
            path,
            body_bytes
        )
        
        headers = {
            'X-Timestamp': str(timestamp),
            'X-Signature': signature,
            'Content-Type': 'application/json'
        }
        
        if method == 'GET':
            return requests.get(f'{self.base_url}{path}', headers=headers)
        elif method == 'POST':
            return requests.post(
                f'{self.base_url}{path}',
                data=body_bytes,
                headers=headers
            )
    
    def make_unauthenticated_request(self, method, path, body=None):
        """Make an unauthenticated request to the API."""
        headers = {'Content-Type': 'application/json'}
        
        if method == 'GET':
            return requests.get(f'{self.base_url}{path}', headers=headers)
        elif method == 'POST':
            return requests.post(
                f'{self.base_url}{path}',
                data=body.encode('utf-8') if body else b'{}',
                headers=headers
            )


class TestUnprotectedEndpoints(TestEndpointAuth):
    """Test that unprotected endpoints work without HMAC authentication."""
    
    def test_status_endpoint_works_without_auth(self):
        """TASK-170 AC2: /status works without HMAC."""
        response = self.make_unauthenticated_request('GET', '/status')
        
        self.assertEqual(response.status_code, 200,
                        "/status should return 200 without authentication")
        
        # Verify response is valid JSON
        data = response.json()
        self.assertIn('phase', data, "/status should return phase info")
    
    def test_health_endpoint_works_without_auth(self):
        """TASK-170 AC2: /health works without HMAC."""
        response = self.make_unauthenticated_request('GET', '/health')
        
        # Health returns 200 or 503 depending on bot status
        self.assertIn(response.status_code, [200, 503],
                     "/health should return 200 or 503 without authentication")
        
        # Verify response is valid JSON
        data = response.json()
        self.assertIn('healthy', data, "/health should return healthy status")
    
    def test_config_status_works_without_auth(self):
        """TASK-170 AC2: /config/status works without HMAC (issue #130)."""
        response = self.make_unauthenticated_request('GET', '/config/status')
        
        self.assertEqual(response.status_code, 200,
                        "/config/status should return 200 without authentication")
        
        # Verify response contains expected fields
        data = response.json()
        self.assertIn('api_uploaded', data,
                     "/config/status should return api_uploaded field")


class TestProtectedEndpoints(TestEndpointAuth):
    """Test that protected endpoints reject requests without valid HMAC."""
    
    def test_sync_rejects_unauthenticated_request(self):
        """TASK-170 AC1: /sync rejects requests without HMAC."""
        response = self.make_unauthenticated_request('POST', '/sync')
        
        self.assertEqual(response.status_code, 403,
                        "/sync should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_sync_accepts_authenticated_request(self):
        """TASK-170 AC1: /sync accepts requests with valid HMAC."""
        # Note: This will fail if sync script doesn't exist, which is expected in test env
        # We're just verifying the auth check passes
        response = self.make_authenticated_request('POST', '/sync')
        
        # Should get past auth (200), even if script execution fails
        self.assertEqual(response.status_code, 200,
                        "/sync should return 200 with valid authentication")
    
    def test_prepare_shutdown_rejects_unauthenticated_request(self):
        """TASK-170 AC1: /prepare-shutdown rejects requests without HMAC."""
        response = self.make_unauthenticated_request('POST', '/prepare-shutdown')
        
        self.assertEqual(response.status_code, 403,
                        "/prepare-shutdown should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_prepare_shutdown_accepts_authenticated_request(self):
        """TASK-170 AC1: /prepare-shutdown accepts requests with valid HMAC."""
        response = self.make_authenticated_request('POST', '/prepare-shutdown')
        
        # Should get past auth (200), even if script execution fails
        self.assertEqual(response.status_code, 200,
                        "/prepare-shutdown should return 200 with valid authentication")
    
    def test_config_upload_rejects_unauthenticated_request(self):
        """TASK-170 AC3: /config/upload rejects requests without HMAC."""
        body = json.dumps({"habitat": {"name": "test"}})
        response = self.make_unauthenticated_request('POST', '/config/upload', body)
        
        self.assertEqual(response.status_code, 403,
                        "/config/upload should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_config_upload_accepts_authenticated_request(self):
        """TASK-170 AC3: /config/upload accepts requests with valid HMAC."""
        body = json.dumps({"habitat": {"name": "test"}})
        response = self.make_authenticated_request('POST', '/config/upload', body)
        
        # Should get past auth (200 or 500 depending on file write)
        self.assertIn(response.status_code, [200, 500],
                     "/config/upload should not return 403 with valid authentication")
    
    def test_config_apply_rejects_unauthenticated_request(self):
        """TASK-170 AC3: /config/apply rejects requests without HMAC."""
        response = self.make_unauthenticated_request('POST', '/config/apply')
        
        self.assertEqual(response.status_code, 403,
                        "/config/apply should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_config_apply_accepts_authenticated_request(self):
        """TASK-170 AC3: /config/apply accepts requests with valid HMAC."""
        response = self.make_authenticated_request('POST', '/config/apply')
        
        # Should get past auth (200 or 500 if script fails)
        self.assertIn(response.status_code, [200, 500],
                     "/config/apply should not return 403 with valid authentication")
    
    def test_config_get_rejects_unauthenticated_request(self):
        """TASK-170 AC3: /config (GET) rejects requests without HMAC."""
        response = self.make_unauthenticated_request('GET', '/config')
        
        self.assertEqual(response.status_code, 403,
                        "/config should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_config_get_accepts_authenticated_request(self):
        """TASK-170 AC3: /config (GET) accepts requests with valid HMAC."""
        response = self.make_authenticated_request('GET', '/config')
        
        self.assertEqual(response.status_code, 200,
                        "/config should return 200 with valid authentication")
    
    def test_stages_rejects_unauthenticated_request(self):
        """TASK-170 AC4: /stages rejects requests without HMAC."""
        response = self.make_unauthenticated_request('GET', '/stages')
        
        self.assertEqual(response.status_code, 403,
                        "/stages should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_stages_accepts_authenticated_request(self):
        """TASK-170 AC4: /stages accepts requests with valid HMAC."""
        response = self.make_authenticated_request('GET', '/stages')
        
        # Should get past auth (200), even if log file doesn't exist
        self.assertEqual(response.status_code, 200,
                        "/stages should return 200 with valid authentication")
    
    def test_log_rejects_unauthenticated_request(self):
        """TASK-170 AC4: /log rejects requests without HMAC."""
        response = self.make_unauthenticated_request('GET', '/log')
        
        self.assertEqual(response.status_code, 403,
                        "/log should return 403 without authentication")
        
        data = response.json()
        self.assertEqual(data['ok'], False, "Response should indicate failure")
        self.assertIn('error', data, "Response should contain error message")
    
    def test_log_accepts_authenticated_request(self):
        """TASK-170 AC4: /log accepts requests with valid HMAC."""
        response = self.make_authenticated_request('GET', '/log')
        
        # Should get past auth (200), even if log files don't exist
        self.assertEqual(response.status_code, 200,
                        "/log should return 200 with valid authentication")


if __name__ == '__main__':
    unittest.main()
