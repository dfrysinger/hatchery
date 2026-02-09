"""Comprehensive tests for bad signature rejection (Issue #174).

This test suite validates that the HMAC authentication properly rejects
all variations of invalid signatures. Each test is deterministic and
documents exactly what scenario it validates.

Covers scenarios not tested elsewhere:
- Signature signed with wrong secret key
- Signature for wrong request body
- Empty/malformed signatures
- Hex-like but invalid signatures
"""

import pytest
import hmac
import hashlib
import time
import os


def load_api_server():
    """Load api-server.py as a module for testing."""
    with open('scripts/api-server.py', 'r') as f:
        code = f.read()
    globals_dict = {'__name__': '__test__'}
    exec(code, globals_dict)
    return globals_dict


def compute_hmac_signature(secret, timestamp, method, path, body):
    """Compute HMAC-SHA256 signature for a request."""
    if isinstance(body, bytes):
        body = body.decode('utf-8')
    elif body is None:
        body = ''
    
    message = f"{timestamp}.{method}.{path}.{body}"
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


class TestBadSignatureScenarios:
    """Comprehensive tests for invalid signature rejection."""
    
    @pytest.fixture(autouse=True)
    def setup(self):
        """Set up test environment with known API_SECRET."""
        os.environ['API_SECRET'] = 'test-secret-key-123'
        self.api = load_api_server()
        yield
        # Cleanup not strictly necessary since each test gets fresh env
    
    def test_random_string_signature_rejected(self):
        """TASK-174 AC2.1: Completely invalid signature (random string) is rejected.
        
        Validates: Server rejects signatures that are not valid hex strings.
        Scenario: Attacker tries "invalid-signature" or other random text.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Try various random string signatures
        bad_signatures = [
            "invalid-signature",
            "not-a-signature",
            "123456",
            "random_text_12345",
            "攻撃者",  # Unicode characters
        ]
        
        for bad_sig in bad_signatures:
            result = self.api['verify_hmac_auth'](
                timestamp, bad_sig, 'POST', '/config/upload', body
            )
            assert result is False, f"Random string signature '{bad_sig}' should be rejected"
    
    def test_wrong_secret_key_signature_rejected(self):
        """TASK-174 AC2.5: Signature signed with wrong secret key is rejected.
        
        Validates: Server only accepts signatures signed with correct API_SECRET.
        Scenario: Attacker uses leaked/guessed wrong secret key.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Sign with WRONG secret key
        wrong_secret = 'different-secret-key'
        signature = compute_hmac_signature(wrong_secret, timestamp, 'POST', '/config/upload', body)
        
        # Should reject (API_SECRET is 'test-secret-key-123')
        result = self.api['verify_hmac_auth'](
            timestamp, signature, 'POST', '/config/upload', body
        )
        assert result is False, "Signature with wrong secret key should be rejected"
    
    def test_wrong_body_signature_rejected(self):
        """TASK-174 Bonus: Signature for different body is rejected.
        
        Validates: Signature binds to exact request body (prevents body tampering).
        Scenario: Attacker modifies body after signing.
        """
        timestamp = str(int(time.time()))
        original_body = b'{"value": 100}'
        tampered_body = b'{"value": 999999}'  # Attacker changes value
        
        # Sign the original body
        signature = compute_hmac_signature(
            'test-secret-key-123', timestamp, 'POST', '/config/upload', original_body
        )
        
        # Try to use signature with tampered body
        result = self.api['verify_hmac_auth'](
            timestamp, signature, 'POST', '/config/upload', tampered_body
        )
        assert result is False, "Signature for different body should be rejected"
    
    def test_empty_signature_rejected(self):
        """TASK-174 Bonus: Empty signature is rejected.
        
        Validates: Server handles edge case of empty signature string.
        Scenario: Client sends X-Signature header but with empty value.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        result = self.api['verify_hmac_auth'](
            timestamp, "", 'POST', '/config/upload', body
        )
        assert result is False, "Empty signature should be rejected"
    
    def test_hex_like_but_invalid_signature_rejected(self):
        """TASK-174 Bonus: Valid hex format but wrong signature is rejected.
        
        Validates: Server doesn't just check hex format, but validates actual signature.
        Scenario: Attacker generates valid-looking hex but incorrect signature.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Generate valid hex string that's NOT the correct signature
        fake_hex_sig = "a" * 64  # Valid hex format (64 chars), wrong value
        
        result = self.api['verify_hmac_auth'](
            timestamp, fake_hex_sig, 'POST', '/config/upload', body
        )
        assert result is False, "Valid hex but incorrect signature should be rejected"
    
    def test_signature_with_wrong_timestamp_rejected(self):
        """TASK-174 AC2.4: Valid signature but with wrong timestamp is rejected.
        
        Validates: Signature binds to exact timestamp (prevents timestamp manipulation).
        Scenario: Attacker tries to use signature from earlier request with new timestamp.
        """
        original_timestamp = int(time.time()) - 100
        new_timestamp = int(time.time())
        body = b'{"test": "data"}'
        
        # Sign with original timestamp
        signature = compute_hmac_signature(
            'test-secret-key-123', original_timestamp, 'POST', '/config/upload', body
        )
        
        # Try to use with different timestamp
        result = self.api['verify_hmac_auth'](
            str(new_timestamp), signature, 'POST', '/config/upload', body
        )
        assert result is False, "Signature with wrong timestamp should be rejected"
    
    def test_case_sensitivity_of_signature(self):
        """TASK-174 Bonus: Signature is case-sensitive.
        
        Validates: Server performs case-sensitive comparison of signatures.
        Scenario: Attacker tries uppercase/mixed case version of valid signature.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Generate valid signature
        valid_signature = compute_hmac_signature(
            'test-secret-key-123', timestamp, 'POST', '/config/upload', body
        )
        
        # Try uppercase version
        uppercase_sig = valid_signature.upper()
        
        # If valid_signature is already lowercase (as HMAC typically is), this should fail
        if uppercase_sig != valid_signature:
            result = self.api['verify_hmac_auth'](
                timestamp, uppercase_sig, 'POST', '/config/upload', body
            )
            assert result is False, "Uppercase version of signature should be rejected"
    
    def test_signature_with_extra_whitespace_rejected(self):
        """TASK-174 Bonus: Signature with whitespace is rejected.
        
        Validates: Server doesn't trim/normalize signature input.
        Scenario: Client accidentally includes whitespace in signature header.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Generate valid signature
        valid_signature = compute_hmac_signature(
            'test-secret-key-123', timestamp, 'POST', '/config/upload', body
        )
        
        # Add whitespace
        signature_with_space = f" {valid_signature} "
        
        result = self.api['verify_hmac_auth'](
            timestamp, signature_with_space, 'POST', '/config/upload', body
        )
        assert result is False, "Signature with whitespace should be rejected"
    
    def test_truncated_signature_rejected(self):
        """TASK-174 Bonus: Truncated signature is rejected.
        
        Validates: Server checks full signature length.
        Scenario: Transmission error or attacker truncates signature.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Generate valid signature and truncate it
        valid_signature = compute_hmac_signature(
            'test-secret-key-123', timestamp, 'POST', '/config/upload', body
        )
        
        truncated_sig = valid_signature[:32]  # Only half the signature
        
        result = self.api['verify_hmac_auth'](
            timestamp, truncated_sig, 'POST', '/config/upload', body
        )
        assert result is False, "Truncated signature should be rejected"
    
    def test_signature_with_null_bytes_rejected(self):
        """TASK-174 Bonus: Signature with null bytes is rejected.
        
        Validates: Server handles null bytes safely.
        Scenario: Attacker tries null byte injection.
        """
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Signature with null byte
        bad_signature = "abc123\x00def456"
        
        result = self.api['verify_hmac_auth'](
            timestamp, bad_signature, 'POST', '/config/upload', body
        )
        assert result is False, "Signature with null bytes should be rejected"


class TestDeterministicBehavior:
    """Verify that bad signature tests are deterministic and reliable."""
    
    def test_same_bad_signature_always_rejected(self):
        """TASK-174 AC4: Bad signature rejection is deterministic.
        
        Validates: Same bad signature is consistently rejected across multiple calls.
        """
        os.environ['API_SECRET'] = 'test-secret-key-123'
        api = load_api_server()
        
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        bad_signature = "invalid-signature-12345"
        
        # Run same test 10 times
        for i in range(10):
            result = api['verify_hmac_auth'](
                timestamp, bad_signature, 'POST', '/config/upload', body
            )
            assert result is False, f"Iteration {i+1}: Bad signature should always be rejected"
    
    def test_wrong_secret_consistently_rejected(self):
        """TASK-174 AC4: Wrong secret signature is consistently rejected.
        
        Validates: Signature with wrong secret is reliably rejected.
        """
        os.environ['API_SECRET'] = 'correct-secret'
        api = load_api_server()
        
        timestamp = str(int(time.time()))
        body = b'{"test": "data"}'
        
        # Sign with wrong secret
        wrong_signature = compute_hmac_signature(
            'wrong-secret', timestamp, 'POST', '/config/upload', body
        )
        
        # Run same test 10 times
        for i in range(10):
            result = api['verify_hmac_auth'](
                timestamp, wrong_signature, 'POST', '/config/upload', body
            )
            assert result is False, f"Iteration {i+1}: Wrong secret should always be rejected"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
