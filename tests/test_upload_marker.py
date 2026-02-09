#!/usr/bin/env python3
"""Tests for write_upload_marker() in api-server.py (TASK-21).

Tests the logging and error handling added to write_upload_marker():
- Success case with structured logging
- Permission denied error handling
- Directory doesn't exist error handling
- Disk full simulation (OSError)
- All failures log to stderr with structured format
"""
import os
import sys
import tempfile
import json
import unittest
from unittest.mock import patch, mock_open, MagicMock
from pathlib import Path


# Import and patch the api-server module (requires source manipulation since it uses hyphens)
# For testing, we'll exec the script and extract the function
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


class TestUploadMarker(unittest.TestCase):
    """Test write_upload_marker() logging and error handling."""
    
    @classmethod
    def setUpClass(cls):
        """Load api-server module once for all tests."""
        cls.api_module = load_api_server_module()
    
    def test_success_case_with_logging(self):
        """AC1: Success case writes file, sets permissions, logs to stderr."""
        with tempfile.TemporaryDirectory() as tmpdir:
            marker_path = os.path.join(tmpdir, "test-marker")
            
            # Patch MARKER_PATH to use temp dir
            with patch.object(self.api_module, 'MARKER_PATH', marker_path):
                # Capture stderr to verify logging
                with patch('sys.stderr', new_callable=MagicMock) as mock_stderr:
                    result = self.api_module.write_upload_marker()
                    
                    # Verify success
                    self.assertTrue(result["ok"])
                    self.assertEqual(result["path"], marker_path)
                    
                    # Verify file was created
                    self.assertTrue(os.path.exists(marker_path))
                    
                    # Verify permissions (0o600 = owner read/write only)
                    mode = os.stat(marker_path).st_mode & 0o777
                    self.assertEqual(mode, 0o600)
                    
                    # Verify file contains timestamp
                    with open(marker_path, 'r') as f:
                        content = f.read()
                        timestamp = float(content)
                        self.assertGreater(timestamp, 0)
                    
                    # Verify structured logging to stderr
                    stderr_calls = [call[0][0] for call in mock_stderr.write.call_args_list if call[0]]
                    # Join all write calls (print() may do multiple writes)
                    stderr_output = ''.join(str(c) for c in stderr_calls if c)
                    
                    # Structured log should be JSON
                    # Find JSON lines in output
                    json_logs = []
                    for line in stderr_output.split('\n'):
                        line = line.strip()
                        if line.startswith('{') and line.endswith('}'):
                            try:
                                json_logs.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                    
                    # Should have at least one structured log entry
                    self.assertGreater(len(json_logs), 0, "Expected structured JSON log in stderr")
                    
                    # Verify log entry content
                    log_entry = json_logs[0]
                    self.assertEqual(log_entry["event"], "upload_marker_written")
                    self.assertEqual(log_entry["path"], marker_path)
                    self.assertTrue(log_entry["success"])
                    self.assertIn("timestamp", log_entry)
    
    def test_permission_denied_error(self):
        """AC2: Permission denied is logged with structured error."""
        marker_path = "/root/test-marker-permission-denied"
        
        with patch.object(self.api_module, 'MARKER_PATH', marker_path):
            # Mock open() to raise PermissionError
            with patch('builtins.open', side_effect=PermissionError("Permission denied: /root/test-marker")):
                with patch('sys.stderr', new_callable=MagicMock) as mock_stderr:
                    result = self.api_module.write_upload_marker()
                    
                    # Verify failure is non-fatal (returns error dict, doesn't raise)
                    self.assertFalse(result["ok"])
                    self.assertIn("Permission denied", result["error"])
                    
                    # Verify structured error log
                    stderr_calls = [call[0][0] for call in mock_stderr.write.call_args_list if call[0]]
                    stderr_output = ''.join(str(c) for c in stderr_calls if c)
                    
                    json_logs = []
                    for line in stderr_output.split('\n'):
                        line = line.strip()
                        if line.startswith('{') and line.endswith('}'):
                            try:
                                json_logs.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                    
                    self.assertGreater(len(json_logs), 0, "Expected error log in stderr")
                    
                    log_entry = json_logs[0]
                    self.assertEqual(log_entry["event"], "upload_marker_write_failed")
                    self.assertFalse(log_entry["success"])
                    self.assertEqual(log_entry["error"], "PermissionError")
    
    def test_os_error_handling(self):
        """AC3: OSError (disk full, directory missing) is logged."""
        marker_path = "/nonexistent/directory/marker"
        
        with patch.object(self.api_module, 'MARKER_PATH', marker_path):
            # Mock open() to raise OSError (simulates disk full or directory missing)
            with patch('builtins.open', side_effect=OSError(28, "No space left on device")):
                with patch('sys.stderr', new_callable=MagicMock) as mock_stderr:
                    result = self.api_module.write_upload_marker()
                    
                    # Verify failure is non-fatal
                    self.assertFalse(result["ok"])
                    self.assertIn("OS error", result["error"])
                    
                    # Verify structured error log
                    stderr_calls = [call[0][0] for call in mock_stderr.write.call_args_list if call[0]]
                    stderr_output = ''.join(str(c) for c in stderr_calls if c)
                    
                    json_logs = []
                    for line in stderr_output.split('\n'):
                        line = line.strip()
                        if line.startswith('{') and line.endswith('}'):
                            try:
                                json_logs.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                    
                    self.assertGreater(len(json_logs), 0, "Expected error log in stderr")
                    
                    log_entry = json_logs[0]
                    self.assertEqual(log_entry["event"], "upload_marker_write_failed")
                    self.assertFalse(log_entry["success"])
                    self.assertEqual(log_entry["error"], "OSError")
    
    def test_unexpected_error_handling(self):
        """AC4: Unexpected errors are logged with exception type."""
        marker_path = "/tmp/test-marker"
        
        with patch.object(self.api_module, 'MARKER_PATH', marker_path):
            # Mock open() to raise unexpected exception
            with patch('builtins.open', side_effect=ValueError("Unexpected error")):
                with patch('sys.stderr', new_callable=MagicMock) as mock_stderr:
                    result = self.api_module.write_upload_marker()
                    
                    # Verify failure is non-fatal
                    self.assertFalse(result["ok"])
                    self.assertIn("Unexpected error", result["error"])
                    
                    # Verify structured error log with exception type
                    stderr_calls = [call[0][0] for call in mock_stderr.write.call_args_list if call[0]]
                    stderr_output = ''.join(str(c) for c in stderr_calls if c)
                    
                    json_logs = []
                    for line in stderr_output.split('\n'):
                        line = line.strip()
                        if line.startswith('{') and line.endswith('}'):
                            try:
                                json_logs.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass
                    
                    self.assertGreater(len(json_logs), 0, "Expected error log in stderr")
                    
                    log_entry = json_logs[0]
                    self.assertEqual(log_entry["event"], "upload_marker_write_failed")
                    self.assertFalse(log_entry["success"])
                    self.assertEqual(log_entry["error"], "ValueError")
    
    def test_structured_log_format(self):
        """AC5: Verify structured log format is valid JSON with required fields."""
        with tempfile.TemporaryDirectory() as tmpdir:
            marker_path = os.path.join(tmpdir, "test-marker")
            
            with patch.object(self.api_module, 'MARKER_PATH', marker_path):
                with patch('sys.stderr', new_callable=MagicMock) as mock_stderr:
                    self.api_module.write_upload_marker()
                    
                    # Extract stderr output
                    stderr_calls = [call[0][0] for call in mock_stderr.write.call_args_list if call[0]]
                    stderr_output = ''.join(str(c) for c in stderr_calls if c)
                    
                    # Find JSON log entry
                    json_logs = []
                    for line in stderr_output.split('\n'):
                        line = line.strip()
                        if line.startswith('{') and line.endswith('}'):
                            try:
                                log = json.loads(line)
                                json_logs.append(log)
                                
                                # Verify required fields exist
                                self.assertIn("event", log)
                                self.assertIn("path", log)
                                self.assertIn("timestamp", log)
                                self.assertIn("success", log)
                                
                                # Verify event name convention
                                self.assertIn("upload_marker", log["event"])
                                
                            except json.JSONDecodeError as e:
                                self.fail(f"Invalid JSON in log: {line}\nError: {e}")
                    
                    self.assertGreater(len(json_logs), 0, "Expected at least one JSON log entry")


if __name__ == '__main__':
    unittest.main()
