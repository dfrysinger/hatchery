#!/usr/bin/env python3
"""Helper functions for api-server.py.

Extracted for testability. These functions handle:
- JSON normalization for consistent HMAC signing
- Signature generation for /sign endpoint
- Base64 body decoding for /config/upload
- HMAC authentication verification
"""
import base64
import hashlib
import hmac
import json
import os
import time


def normalize_json(s):
    """Normalize JSON string for consistent signing.
    
    Parses and re-serializes JSON with compact separators to ensure
    consistent signing regardless of whitespace in original.
    
    Args:
        s: JSON string to normalize
        
    Returns:
        Normalized JSON string, or original if parsing fails
    """
    try:
        return json.dumps(json.loads(s), separators=(',', ':'))
    except (json.JSONDecodeError, TypeError):
        return s


def generate_signature(body_str, path, method, api_secret=None):
    """Generate HMAC-SHA256 signature for API authentication.
    
    Creates a signature using the format: {timestamp}.{method}.{path}.{body}
    
    Args:
        body_str: Request body string (should be normalized JSON)
        path: API endpoint path (e.g., '/config/upload')
        method: HTTP method (e.g., 'POST')
        api_secret: Optional API secret (defaults to API_SECRET env var)
        
    Returns:
        dict with 'ok', 'timestamp', 'signature' on success
        dict with 'ok': False, 'error' on failure
    """
    if api_secret is None:
        api_secret = os.getenv('API_SECRET', '')
    
    if not api_secret:
        return {"ok": False, "error": "API_SECRET not configured"}
    
    timestamp = str(int(time.time()))
    msg = f"{timestamp}.{method}.{path}.{body_str}"
    sig = hmac.new(api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
    
    return {
        "ok": True,
        "timestamp": timestamp,
        "signature": sig
    }


def decode_base64_body(raw_body):
    """Decode base64-encoded request body with whitespace handling.
    
    Strips newlines, carriage returns, and spaces before decoding
    to handle iOS Shortcuts line-wrapped base64.
    
    Args:
        raw_body: bytes object containing base64 data
        
    Returns:
        tuple: (decoded_string, None) on success
        tuple: (None, error_message) on failure
    """
    try:
        # Strip whitespace that iOS Shortcuts might add
        cleaned = raw_body.replace(b'\n', b'').replace(b'\r', b'').replace(b' ', b'')
        decoded = base64.b64decode(cleaned).decode('utf-8')
        return decoded, None
    except Exception as e:
        return None, f"Invalid base64: {e}"


def verify_hmac_auth(timestamp_header, signature_header, method, path, body, 
                     normalize=False, api_secret=None, max_age=300):
    """Verify HMAC-SHA256 signature for authenticated endpoints.

    Signature binds:
    - timestamp (replay protection)
    - HTTP method + path (prevents cross-endpoint replay/substitution)
    - request body (integrity)

    Message format:
        "{timestamp}.{method}.{path}.{body}" where body is UTF-8 JSON string.
    
    Args:
        timestamp_header: X-Timestamp header value
        signature_header: X-Signature header value
        method: HTTP method
        path: Request path
        body: Request body (string or bytes)
        normalize: If True, normalize body as JSON before verification
        api_secret: Optional API secret (defaults to API_SECRET env var)
        max_age: Maximum age of signature in seconds (default 300 = 5 min)
        
    Returns:
        True if signature is valid, False otherwise
    """
    if api_secret is None:
        api_secret = os.getenv('API_SECRET', '')
    
    if not api_secret:
        return False
    if not timestamp_header or not signature_header:
        return False
    
    try:
        timestamp = int(timestamp_header)
        now = int(time.time())
        if abs(now - timestamp) > max_age:
            return False

        # Handle bytes or string body
        b = body.decode('utf-8') if isinstance(body, (bytes, bytearray)) else (body or '')
        if normalize:
            b = normalize_json(b)
        
        msg = f"{timestamp}.{method}.{path}.{b}"
        expected_sig = hmac.new(api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(signature_header, expected_sig)
    except Exception:
        return False


def validate_config_upload(data):
    """Validate config upload request data.
    
    Args:
        data: Parsed JSON request body
        
    Returns:
        List of validation error messages (empty if valid)
    """
    errors = []
    if "habitat" in data and not isinstance(data["habitat"], dict):
        errors.append("habitat must be an object")
    if "agents" in data and not isinstance(data["agents"], dict):
        errors.append("agents must be an object")
    if "apply" in data and not isinstance(data["apply"], bool):
        errors.append("apply must be a boolean")
    return errors
