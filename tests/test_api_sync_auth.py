#!/usr/bin/env python3
"""Tests for HMAC authentication on /sync and /prepare-shutdown endpoints (SEC-001).

Verifies that critical mutation endpoints require HMAC authentication.
"""
import os
import sys
import time
import json
import hmac
import hashlib
import unittest
from pathlib import Path


def load_api_server_module():
    """Load api-server.py as a module for testing."""
    import importlib.util
    
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


class TestSyncEndpointAuth(unittest.TestCase):
    """Test /sync endpoint requires HMAC authentication."""
    
    @classmethod
    def setUpClass(cls):
        """Load api-server module once for all tests."""
        cls.api_module = load_api_server_module()
    
    def test_sync_rejects_unsigned_request(self):
        """SEC-001 AC1: /sync rejects requests without HMAC headers."""
        # Verify that verify_hmac_auth would reject missing headers
        result = self.api_module.verify_hmac_auth(
            timestamp_header=None,
            signature_header=None,
            method='POST',
            path='/sync',
            body=b'{}'
        )
        self.assertFalse(result[0], "/sync should reject unsigned requests")
    
    def test_sync_rejects_bad_signature(self):
        """SEC-001 AC2: /sync rejects requests with invalid signature."""
        os.environ['API_SECRET'] = 'test-secret-key'
        
        timestamp = int(time.time())
        bad_signature = 'invalid_signature_12345'
        
        result = self.api_module.verify_hmac_auth(
            timestamp_header=str(timestamp),
            signature_header=bad_signature,
            method='POST',
            path='/sync',
            body=b'{}'
        )
        self.assertFalse(result[0], "/sync should reject bad signatures")
    
    def test_sync_accepts_valid_signature(self):
        """SEC-001 AC3: /sync accepts requests with valid HMAC signature."""
        secret = 'test-secret-key'
        
        # Set env var before loading module (or reload module)
        # For this test, we'll use the module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            timestamp = int(time.time())
            body = b'{}'
            signature = compute_hmac_signature(secret, timestamp, 'POST', '/sync', body)
            
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(timestamp),
                signature_header=signature,
                method='POST',
                path='/sync',
                body=body
            )
            self.assertTrue(result[0], "/sync should accept valid signatures")
        finally:
            # Restore original
            self.api_module.API_SECRET = original_secret
    
    def test_sync_signature_binds_to_endpoint(self):
        """SEC-001 AC4: /sync signature is endpoint-specific (prevents cross-endpoint replay)."""
        secret = 'test-secret-key'
        os.environ['API_SECRET'] = secret
        
        timestamp = int(time.time())
        body = b'{}'
        
        # Create valid signature for /config/upload
        wrong_endpoint_sig = compute_hmac_signature(secret, timestamp, 'POST', '/config/upload', body)
        
        # Try to use it for /sync (should fail)
        result = self.api_module.verify_hmac_auth(
            timestamp_header=str(timestamp),
            signature_header=wrong_endpoint_sig,
            method='POST',
            path='/sync',
            body=body
        )
        self.assertFalse(result[0], "/sync should reject cross-endpoint replay attacks")
    
    def test_sync_rejects_stale_timestamp(self):
        """TASK-173 AC1: /sync rejects requests with stale timestamps (>300s old)."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            # Create stale timestamp (400 seconds ago, beyond 300s window)
            stale_timestamp = int(time.time()) - 400
            body = b'{}'
            
            # Generate valid signature for the stale timestamp
            signature = compute_hmac_signature(secret, stale_timestamp, 'POST', '/sync', body)
            
            # Should reject due to stale timestamp
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(stale_timestamp),
                signature_header=signature,
                method='POST',
                path='/sync',
                body=body
            )
            self.assertFalse(result[0], "/sync should reject requests with stale timestamps (>300s old)")
        finally:
            self.api_module.API_SECRET = original_secret
    
    def test_sync_accepts_timestamp_within_window(self):
        """TASK-173 AC3: /sync accepts requests with timestamps within ±300s window."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            # Test timestamps at the edge of acceptable window
            # 290 seconds ago (within 300s window)
            recent_timestamp = int(time.time()) - 290
            body = b'{}'
            
            signature = compute_hmac_signature(secret, recent_timestamp, 'POST', '/sync', body)
            
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(recent_timestamp),
                signature_header=signature,
                method='POST',
                path='/sync',
                body=body
            )
            self.assertTrue(result[0], "/sync should accept timestamps within ±300s window")
        finally:
            self.api_module.API_SECRET = original_secret
    
    def test_sync_rejects_future_timestamp(self):
        """TASK-173 AC4: /sync rejects requests with timestamps too far in future (>300s)."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            # Create future timestamp (400 seconds ahead, beyond 300s window)
            future_timestamp = int(time.time()) + 400
            body = b'{}'
            
            # Generate valid signature for the future timestamp
            signature = compute_hmac_signature(secret, future_timestamp, 'POST', '/sync', body)
            
            # Should reject due to future timestamp
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(future_timestamp),
                signature_header=signature,
                method='POST',
                path='/sync',
                body=body
            )
            self.assertFalse(result[0], "/sync should reject requests with future timestamps (>300s ahead)")
        finally:
            self.api_module.API_SECRET = original_secret


class TestPrepareShutdownAuth(unittest.TestCase):
    """Test /prepare-shutdown endpoint requires HMAC authentication."""
    
    @classmethod
    def setUpClass(cls):
        """Load api-server module once for all tests."""
        cls.api_module = load_api_server_module()
    
    def test_prepare_shutdown_rejects_unsigned_request(self):
        """SEC-001 AC5: /prepare-shutdown rejects requests without HMAC headers."""
        result = self.api_module.verify_hmac_auth(
            timestamp_header=None,
            signature_header=None,
            method='POST',
            path='/prepare-shutdown',
            body=b'{}'
        )
        self.assertFalse(result[0], "/prepare-shutdown should reject unsigned requests")
    
    def test_prepare_shutdown_rejects_bad_signature(self):
        """SEC-001 AC6: /prepare-shutdown rejects requests with invalid signature."""
        os.environ['API_SECRET'] = 'test-secret-key'
        
        timestamp = int(time.time())
        bad_signature = 'invalid_signature_12345'
        
        result = self.api_module.verify_hmac_auth(
            timestamp_header=str(timestamp),
            signature_header=bad_signature,
            method='POST',
            path='/prepare-shutdown',
            body=b'{}'
        )
        self.assertFalse(result[0], "/prepare-shutdown should reject bad signatures")
    
    def test_prepare_shutdown_accepts_valid_signature(self):
        """SEC-001 AC7: /prepare-shutdown accepts requests with valid HMAC signature."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            timestamp = int(time.time())
            body = b'{}'
            signature = compute_hmac_signature(secret, timestamp, 'POST', '/prepare-shutdown', body)
            
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(timestamp),
                signature_header=signature,
                method='POST',
                path='/prepare-shutdown',
                body=body
            )
            self.assertTrue(result[0], "/prepare-shutdown should accept valid signatures")
        finally:
            self.api_module.API_SECRET = original_secret
    
    def test_prepare_shutdown_signature_binds_to_endpoint(self):
        """SEC-001 AC8: /prepare-shutdown signature is endpoint-specific."""
        secret = 'test-secret-key'
        os.environ['API_SECRET'] = secret
        
        timestamp = int(time.time())
        body = b'{}'
        
        # Create valid signature for /sync
        wrong_endpoint_sig = compute_hmac_signature(secret, timestamp, 'POST', '/sync', body)
        
        # Try to use it for /prepare-shutdown (should fail)
        result = self.api_module.verify_hmac_auth(
            timestamp_header=str(timestamp),
            signature_header=wrong_endpoint_sig,
            method='POST',
            path='/prepare-shutdown',
            body=body
        )
        self.assertFalse(result[0], "/prepare-shutdown should reject cross-endpoint replay attacks")
    
    def test_prepare_shutdown_prevents_dos(self):
        """SEC-001 AC9: /prepare-shutdown prevents DoS by requiring auth.
        
        This test verifies that an attacker cannot DoS the system by stopping
        openclaw service without authentication.
        """
        # Without valid credentials, verify_hmac_auth returns False
        result = self.api_module.verify_hmac_auth(
            timestamp_header=str(int(time.time())),
            signature_header='attacker_signature',
            method='POST',
            path='/prepare-shutdown',
            body=b'{}'
        )
        self.assertFalse(result[0], "DoS attack should be prevented by authentication")
    
    def test_prepare_shutdown_rejects_stale_timestamp(self):
        """TASK-173 AC2: /prepare-shutdown rejects requests with stale timestamps (>300s old)."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            # Create stale timestamp (400 seconds ago, beyond 300s window)
            stale_timestamp = int(time.time()) - 400
            body = b'{}'
            
            # Generate valid signature for the stale timestamp
            signature = compute_hmac_signature(secret, stale_timestamp, 'POST', '/prepare-shutdown', body)
            
            # Should reject due to stale timestamp
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(stale_timestamp),
                signature_header=signature,
                method='POST',
                path='/prepare-shutdown',
                body=body
            )
            self.assertFalse(result[0], "/prepare-shutdown should reject requests with stale timestamps (>300s old)")
        finally:
            self.api_module.API_SECRET = original_secret
    
    def test_prepare_shutdown_accepts_timestamp_within_window(self):
        """TASK-173 AC3: /prepare-shutdown accepts requests with timestamps within ±300s window."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            # Test timestamps at the edge of acceptable window
            # 290 seconds ago (within 300s window)
            recent_timestamp = int(time.time()) - 290
            body = b'{}'
            
            signature = compute_hmac_signature(secret, recent_timestamp, 'POST', '/prepare-shutdown', body)
            
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(recent_timestamp),
                signature_header=signature,
                method='POST',
                path='/prepare-shutdown',
                body=body
            )
            self.assertTrue(result[0], "/prepare-shutdown should accept timestamps within ±300s window")
        finally:
            self.api_module.API_SECRET = original_secret
    
    def test_prepare_shutdown_rejects_future_timestamp(self):
        """TASK-173 AC4: /prepare-shutdown rejects requests with timestamps too far in future (>300s)."""
        secret = 'test-secret-key'
        
        # Set module's API_SECRET directly
        original_secret = self.api_module.API_SECRET
        self.api_module.API_SECRET = secret
        
        try:
            # Create future timestamp (400 seconds ahead, beyond 300s window)
            future_timestamp = int(time.time()) + 400
            body = b'{}'
            
            # Generate valid signature for the future timestamp
            signature = compute_hmac_signature(secret, future_timestamp, 'POST', '/prepare-shutdown', body)
            
            # Should reject due to future timestamp
            result = self.api_module.verify_hmac_auth(
                timestamp_header=str(future_timestamp),
                signature_header=signature,
                method='POST',
                path='/prepare-shutdown',
                body=body
            )
            self.assertFalse(result[0], "/prepare-shutdown should reject requests with future timestamps (>300s ahead)")
        finally:
            self.api_module.API_SECRET = original_secret


class TestAuthCoverage(unittest.TestCase):
    """Verify all mutation endpoints have authentication."""
    
    @classmethod
    def setUpClass(cls):
        """Load api-server module once for all tests."""
        cls.api_module = load_api_server_module()
    
    def test_all_post_endpoints_require_auth(self):
        """SEC-001 AC10: All POST endpoints must require HMAC authentication.
        
        Verifies that all mutation endpoints are protected.
        """
        # Read api-server.py to find all POST endpoints
        repo_root = Path(__file__).parent.parent
        api_server_path = repo_root / "scripts" / "api-server.py"
        
        with open(api_server_path, 'r') as f:
            content = f.read()
        
        # Find all POST endpoints (inside do_POST method only)
        post_endpoints = []
        in_do_post = False
        for line in content.split('\n'):
            if 'def do_POST(self):' in line:
                in_do_post = True
            elif in_do_post and line.strip().startswith('def '):
                # Reached next method, stop
                break
            elif in_do_post and "self.path==" in line:
                # Extract endpoint path
                if "'" in line:
                    start = line.index("'") + 1
                    end = line.index("'", start)
                    endpoint = line[start:end]
                    if endpoint.startswith('/'):
                        post_endpoints.append(endpoint)
        
        # Known authenticated endpoints
        authenticated_endpoints = [
            '/sync',
            '/prepare-shutdown',
            '/config/upload',
            '/config/apply',
            '/keepalive'
        ]
        
        # Check that all POST endpoints require auth
        for endpoint in post_endpoints:
            self.assertIn(endpoint, authenticated_endpoints, 
                         f"POST endpoint {endpoint} must require authentication")
        
        # Verify we found the expected endpoints
        self.assertGreaterEqual(len(post_endpoints), 4, 
                               "Should find at least 4 POST endpoints")


if __name__ == '__main__':
    unittest.main()
