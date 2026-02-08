"""Tests for API server HMAC authentication (SEC-001)."""
import pytest
import hmac
import hashlib
import time
import json
import os

# Load the api-server module by executing it
def load_api_server():
    with open('scripts/api-server.py', 'r') as f:
        code = f.read()
    # Extract just the functions we need
    globals_dict = {'__name__': '__test__'}
    exec(code, globals_dict)
    return globals_dict

def test_unsigned_request_rejected():
    """Requests without X-Signature header are rejected with 403."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    
    result = api['verify_hmac_auth']('POST', '/config/upload', timestamp, None, body)
    assert result is False, "Unsigned request should be rejected"

def test_bad_signature_rejected():
    """Requests with invalid signature are rejected with 403."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    bad_signature = "invalid-signature"
    
    result = api['verify_hmac_auth']('POST', '/config/upload', timestamp, bad_signature, body)
    assert result is False, "Bad signature should be rejected"

def test_stale_timestamp_rejected():
    """Requests with timestamp >300s old are rejected with 403."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    # Create stale timestamp (400s ago)
    stale_timestamp = str(int(time.time()) - 400)
    body = b'{"habitat": {}}'
    method = 'POST'
    path = '/config/upload'
    
    # Generate valid signature for stale timestamp
    message = f"{method}.{path}.{stale_timestamp}.{body.decode('utf-8')}"
    signature = hmac.new(
        'test-secret-123'.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    
    result = api['verify_hmac_auth'](method, path, stale_timestamp, signature, body)
    assert result is False, "Stale timestamp should be rejected"

def test_valid_signature_accepted():
    """Requests with valid signature and fresh timestamp are accepted with 200."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    method = 'POST'
    path = '/config/upload'
    
    # Generate valid signature including method and path
    message = f"{method}.{path}.{timestamp}.{body.decode('utf-8')}"
    signature = hmac.new(
        'test-secret-123'.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    
    result = api['verify_hmac_auth'](method, path, timestamp, signature, body)
    assert result is True, "Valid signature should be accepted"

def test_missing_api_secret():
    """Server rejects all auth when API_SECRET is not set."""
    if 'API_SECRET' in os.environ:
        del os.environ['API_SECRET']
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    
    result = api['verify_hmac_auth']('POST', '/config/upload', timestamp, "any-signature", body)
    assert result is False, "Should reject when API_SECRET is missing"

def test_signature_binds_method():
    """Signature for one method doesn't work for another."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    path = '/config/upload'
    
    # Generate signature for POST
    message = f"POST.{path}.{timestamp}.{body.decode('utf-8')}"
    post_signature = hmac.new(
        'test-secret-123'.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    
    # Try to use POST signature for GET (should fail)
    result = api['verify_hmac_auth']('GET', path, timestamp, post_signature, body)
    assert result is False, "POST signature should not work for GET"

def test_signature_binds_path():
    """Signature for one path doesn't work for another (replay protection)."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{}'
    method = 'POST'
    
    # Generate signature for /config/upload
    message = f"{method}./config/upload.{timestamp}.{body.decode('utf-8')}"
    upload_signature = hmac.new(
        'test-secret-123'.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    
    # Try to use /config/upload signature for /config/apply (should fail)
    result = api['verify_hmac_auth'](method, '/config/apply', timestamp, upload_signature, body)
    assert result is False, "Signature for /config/upload should not work for /config/apply"

def test_api_secret_auto_generation():
    """API secret is auto-generated if not set (persisted to file)."""
    import tempfile
    import shutil
    
    # Clear environment
    if 'API_SECRET' in os.environ:
        del os.environ['API_SECRET']
    
    # Create a temp directory for the secret
    tmpdir = tempfile.mkdtemp()
    try:
        # Modify the script to use temp path
        with open('scripts/api-server.py', 'r') as f:
            code = f.read()
        code = code.replace("/var/lib/api-server/secret", f"{tmpdir}/secret")
        globals_dict = {'__name__': '__test__'}
        exec(code, globals_dict)
        
        secret = globals_dict['API_SECRET']
        
        # Secret should be generated (64 hex chars = 32 bytes)
        assert secret is not None, "Secret should be generated"
        assert len(secret) == 64, f"Secret should be 64 hex chars, got {len(secret)}"
        assert all(c in '0123456789abcdef' for c in secret), "Secret should be hex"
        
        # Verify it was persisted
        with open(f"{tmpdir}/secret", 'r') as f:
            persisted = f.read().strip()
        assert persisted == secret, "Secret should be persisted to file"
    finally:
        shutil.rmtree(tmpdir)
