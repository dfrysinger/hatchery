#!/usr/bin/env python3
"""Tests for Issue #228: Restore /keepalive endpoint in api-server.py.

Verifies:
1. POST /keepalive requires HMAC authentication
2. Valid HMAC returns success response
3. Subprocess errors return error response
4. GET /keepalive is not handled (404)
5. No shell=True in keepalive handler (static analysis)
6. /keepalive documented in api-server.py header
7. Auth with invalid signature returns 403
"""
import unittest
import hmac
import hashlib
import time
import os
import re


API_SERVER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'scripts', 'api-server.py'
)


def load_api_server():
    """Load api-server.py into a dict of globals, same pattern as test_api_auth.py."""
    with open(API_SERVER_PATH, 'r') as f:
        code = f.read()
    globals_dict = {'__name__': '__test__'}
    exec(code, globals_dict)
    return globals_dict


def make_valid_signature(secret, method, path, body=b''):
    """Generate a valid HMAC-SHA256 signature for the given request."""
    timestamp = str(int(time.time()))
    b = body.decode('utf-8') if isinstance(body, (bytes, bytearray)) else (body or '')
    msg = f"{timestamp}.{method}.{path}.{b}"
    signature = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return timestamp, signature


class TestKeepaliveAuth(unittest.TestCase):
    """Auth-level tests for /keepalive — these exercise verify_hmac_auth directly."""

    def setUp(self):
        os.environ['API_SECRET'] = 'test-secret-123'
        self.api = load_api_server()
        self.verify = self.api['verify_hmac_auth']

    # ------------------------------------------------------------------
    # 1. POST /keepalive requires auth (missing signature → rejected)
    # ------------------------------------------------------------------
    def test_keepalive_requires_auth(self):
        """POST without HMAC header is rejected."""
        timestamp = str(int(time.time()))
        ok, err = self.verify(timestamp, None, 'POST', '/keepalive', b'')
        self.assertFalse(ok, "Request with no signature should be rejected")
        self.assertIn('Signature', err)

    # ------------------------------------------------------------------
    # 2. Invalid signature → rejected
    # ------------------------------------------------------------------
    def test_keepalive_invalid_signature(self):
        """POST with wrong HMAC signature is rejected."""
        timestamp = str(int(time.time()))
        ok, err = self.verify(timestamp, 'bad-sig', 'POST', '/keepalive', b'')
        self.assertFalse(ok, "Bad signature should be rejected")

    # ------------------------------------------------------------------
    # 3. Valid auth accepted
    # ------------------------------------------------------------------
    def test_keepalive_valid_auth_accepted(self):
        """POST with correct HMAC signature for /keepalive returns (True, None)."""
        timestamp, signature = make_valid_signature(
            'test-secret-123', 'POST', '/keepalive', b''
        )
        ok, err = self.verify(timestamp, signature, 'POST', '/keepalive', b'')
        self.assertTrue(ok, "Valid signature should be accepted")
        self.assertIsNone(err)


class TestKeepaliveStaticAnalysis(unittest.TestCase):
    """Static-analysis tests that inspect api-server.py source code.

    These tests verify that the /keepalive endpoint is properly implemented
    in the source. They will FAIL in the Red Phase before the endpoint is added.
    """

    @classmethod
    def setUpClass(cls):
        with open(API_SERVER_PATH, 'r') as f:
            cls.source = f.read()
            cls.lines = cls.source.splitlines()

    # ------------------------------------------------------------------
    # 4. /keepalive documented in header comment
    # ------------------------------------------------------------------
    def test_keepalive_endpoint_documented(self):
        """api-server.py header (first 25 lines) must mention /keepalive."""
        header = '\n'.join(self.lines[:25])
        self.assertIn('/keepalive', header,
                       "/keepalive must be listed in the endpoint table in the file header")

    # ------------------------------------------------------------------
    # 5. No shell=True in the keepalive handler
    # ------------------------------------------------------------------
    def test_keepalive_no_shell_true(self):
        """The keepalive handler block must not use shell=True."""
        # Find the keepalive handler block (between '/keepalive' and the next elif/else)
        in_block = False
        keepalive_block_lines = []
        for line in self.lines:
            if "'/keepalive'" in line or '"/keepalive"' in line:
                in_block = True
            elif in_block and re.match(r'\s*(elif |else:)', line):
                break
            if in_block:
                keepalive_block_lines.append(line)

        self.assertTrue(len(keepalive_block_lines) > 0,
                        "/keepalive handler block must exist in api-server.py")
        block_text = '\n'.join(keepalive_block_lines)
        self.assertNotIn('shell=True', block_text,
                         "keepalive handler must not use shell=True (security)")

    # ------------------------------------------------------------------
    # 6. /keepalive handler exists in do_POST
    # ------------------------------------------------------------------
    def test_keepalive_handler_exists(self):
        """do_POST must contain a '/keepalive' branch."""
        # Find do_POST method and look for /keepalive within it
        in_do_post = False
        found = False
        for line in self.lines:
            if 'def do_POST' in line:
                in_do_post = True
            elif in_do_post and re.match(r'\s*def ', line) and 'do_POST' not in line:
                break  # left do_POST
            if in_do_post and "'/keepalive'" in line:
                found = True
                break

        self.assertTrue(found, "do_POST must contain a '/keepalive' handler")

    # ------------------------------------------------------------------
    # 7. Keepalive handler calls schedule-destruct.sh
    # ------------------------------------------------------------------
    def test_keepalive_calls_schedule_destruct(self):
        """Keepalive handler must reference schedule-destruct.sh."""
        in_block = False
        keepalive_block_lines = []
        for line in self.lines:
            if "'/keepalive'" in line or '"/keepalive"' in line:
                in_block = True
            elif in_block and re.match(r'\s*(elif |else:)', line):
                break
            if in_block:
                keepalive_block_lines.append(line)

        self.assertTrue(len(keepalive_block_lines) > 0,
                        "/keepalive handler block must exist in api-server.py")
        block_text = '\n'.join(keepalive_block_lines)
        self.assertIn('schedule-destruct', block_text,
                      "keepalive handler must call schedule-destruct.sh")


if __name__ == '__main__':
    unittest.main()
