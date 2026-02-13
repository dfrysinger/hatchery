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
    
    result = api['verify_hmac_auth'](timestamp, None, 'POST', '/config/upload', body)
    assert result[0] is False, "Unsigned request should be rejected"

def test_bad_signature_rejected():
    """Requests with invalid signature are rejected with 403."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    bad_signature = "invalid-signature"
    
    result = api['verify_hmac_auth'](timestamp, bad_signature, 'POST', '/config/upload', body)
    assert result[0] is False, "Bad signature should be rejected"

def test_stale_timestamp_rejected():
    """Requests with timestamp >300s old are rejected with 403."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    # Create stale timestamp (400s ago)
    stale_timestamp = str(int(time.time()) - 400)
    body = b'{"habitat": {}}'
    
    # Generate valid signature for stale timestamp
    message = f"{stale_timestamp}.POST./config/upload.{body.decode('utf-8')}"
    signature = hmac.new(
        'test-secret-123'.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    
    result = api['verify_hmac_auth'](stale_timestamp, signature, 'POST', '/config/upload', body)
    assert result[0] is False, "Stale timestamp should be rejected"

def test_valid_signature_accepted():
    """Requests with valid signature and fresh timestamp are accepted with 200."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    
    # Generate valid signature
    message = f"{timestamp}.POST./config/upload.{body.decode('utf-8')}"
    signature = hmac.new(
        'test-secret-123'.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    
    result = api['verify_hmac_auth'](timestamp, signature, 'POST', '/config/upload', body)
    assert result[0] is True, "Valid signature should be accepted"


def test_signature_binds_method_and_path():
    """A valid signature for one endpoint/method must not work for another."""
    os.environ['API_SECRET'] = 'test-secret-123'
    api = load_api_server()

    timestamp = str(int(time.time()))
    body = b'{"agents": {"a": 1}}'

    # Sign for /config/upload
    msg = f"{timestamp}.POST./config/upload.{body.decode('utf-8')}"
    sig = hmac.new('test-secret-123'.encode(), msg.encode(), hashlib.sha256).hexdigest()

    assert api['verify_hmac_auth'](timestamp, sig, 'POST', '/config/upload', body)[0] is True
    # Same signature must fail for different method/path
    assert api['verify_hmac_auth'](timestamp, sig, 'POST', '/config/apply', body)[0] is False
    assert api['verify_hmac_auth'](timestamp, sig, 'GET', '/config/upload', body)[0] is False

def test_missing_api_secret():
    """Server rejects all auth when API_SECRET is not set."""
    if 'API_SECRET' in os.environ:
        del os.environ['API_SECRET']
    api = load_api_server()
    
    timestamp = str(int(time.time()))
    body = b'{"habitat": {}}'
    
    result = api['verify_hmac_auth'](timestamp, "any-signature", 'POST', '/config/upload', body)
    assert result[0] is False, "Should reject when API_SECRET is missing"
