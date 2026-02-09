#!/usr/bin/env python3
"""Tests for subprocess security in api-server.py (TASK-171).

Verifies that subprocess calls do NOT use shell=True to prevent shell injection
vulnerabilities.
"""
import os
import sys
import re
import unittest
from pathlib import Path


class TestSubprocessSecurity(unittest.TestCase):
    """Test that subprocess calls in api-server.py do NOT use shell=True."""
    
    @classmethod
    def setUpClass(cls):
        """Load api-server.py source code."""
        repo_root = Path(__file__).parent.parent
        api_server_path = repo_root / "scripts" / "api-server.py"
        
        with open(api_server_path, 'r') as f:
            cls.source_code = f.read()
    
    def test_no_shell_true_in_subprocess_calls(self):
        """TASK-171 AC1: No subprocess calls should use shell=True."""
        # Find all subprocess.run and subprocess.Popen calls with shell=True
        pattern = r'subprocess\.(run|Popen|call|check_call|check_output)\([^)]*shell\s*=\s*True'
        matches = re.findall(pattern, self.source_code)
        
        self.assertEqual(len(matches), 0,
                        f"Found {len(matches)} subprocess calls with shell=True. "
                        f"All should use list-based arguments instead.")
    
    def test_sync_endpoint_uses_list_args(self):
        """TASK-171 AC2: /sync endpoint should use list-based subprocess args."""
        # Find the /sync endpoint code
        sync_pattern = r"self\.path\s*==\s*'/sync'(.*?)(?=elif|else:)"
        match = re.search(sync_pattern, self.source_code, re.DOTALL)
        
        self.assertIsNotNone(match, "/sync endpoint should exist")
        
        sync_code = match.group(1)
        
        # Check for subprocess calls
        subprocess_calls = re.findall(r'subprocess\.(run|Popen)', sync_code)
        self.assertGreater(len(subprocess_calls), 0, 
                          "/sync should contain subprocess calls")
        
        # Verify shell=True is not used
        shell_true = re.search(r'shell\s*=\s*True', sync_code)
        self.assertIsNone(shell_true, 
                         "/sync endpoint must not use shell=True")
        
        # Verify list-based arguments are used (look for [ brackets)
        list_args = re.search(r'subprocess\.\w+\(\s*\[', sync_code)
        self.assertIsNotNone(list_args,
                            "/sync should use list-based subprocess arguments")
    
    def test_prepare_shutdown_uses_list_args(self):
        """TASK-171 AC3: /prepare-shutdown endpoint should use list-based subprocess args."""
        # Find the /prepare-shutdown endpoint code
        shutdown_pattern = r"self\.path\s*==\s*'/prepare-shutdown'(.*?)(?=elif|else:)"
        match = re.search(shutdown_pattern, self.source_code, re.DOTALL)
        
        self.assertIsNotNone(match, "/prepare-shutdown endpoint should exist")
        
        shutdown_code = match.group(1)
        
        # Check for subprocess calls
        subprocess_calls = re.findall(r'subprocess\.(run|Popen)', shutdown_code)
        self.assertGreater(len(subprocess_calls), 0,
                          "/prepare-shutdown should contain subprocess calls")
        
        # Verify shell=True is not used
        shell_true = re.search(r'shell\s*=\s*True', shutdown_code)
        self.assertIsNone(shell_true,
                         "/prepare-shutdown endpoint must not use shell=True")
        
        # Verify list-based arguments are used
        list_args = re.search(r'subprocess\.\w+\(\s*\[', shutdown_code)
        self.assertIsNotNone(list_args,
                            "/prepare-shutdown should use list-based subprocess arguments")
    
    def test_all_subprocess_calls_examined(self):
        """TASK-171 AC4: Document all subprocess call locations for security audit."""
        # Find all subprocess calls
        subprocess_pattern = r'subprocess\.(run|Popen|call|check_call|check_output)\('
        matches = list(re.finditer(subprocess_pattern, self.source_code))
        
        # Get line numbers
        lines = self.source_code.split('\n')
        call_locations = []
        
        for match in matches:
            # Find line number
            line_num = self.source_code[:match.start()].count('\n') + 1
            line_content = lines[line_num - 1].strip()
            call_locations.append((line_num, line_content))
        
        # Expected locations (update after fixing):
        # - check_service function (line ~38) - already safe
        # - /sync endpoint (line ~177) - needs fix
        # - /prepare-shutdown endpoint (lines ~188) - needs fix (2 calls)
        
        self.assertGreaterEqual(len(call_locations), 3,
                               f"Should find at least 3 subprocess calls. Found: {call_locations}")
        
        # Verify all calls are documented here
        for line_num, line_content in call_locations:
            # This test documents all subprocess calls for security review
            # After fix, all should use list-based args with no shell=True
            print(f"Line {line_num}: {line_content}")


class TestSubprocessFunctionality(unittest.TestCase):
    """Test that correct commands are called after removing shell=True."""
    
    @classmethod
    def setUpClass(cls):
        """Load api-server.py source code."""
        repo_root = Path(__file__).parent.parent
        api_server_path = repo_root / "scripts" / "api-server.py"
        
        with open(api_server_path, 'r') as f:
            cls.source_code = f.read()
    
    def test_sync_endpoint_calls_correct_script(self):
        """TASK-171 AC5: /sync endpoint calls sync-openclaw-state.sh script."""
        # Find /sync endpoint
        sync_pattern = r"self\.path\s*==\s*'/sync'(.*?)(?=elif|else:)"
        match = re.search(sync_pattern, self.source_code, re.DOTALL)
        
        self.assertIsNotNone(match, "/sync endpoint should exist")
        sync_code = match.group(1)
        
        # Verify sync-openclaw-state.sh is called
        self.assertIn('sync-openclaw-state.sh', sync_code,
                     "/sync should call sync-openclaw-state.sh")
    
    def test_prepare_shutdown_calls_sync_script(self):
        """TASK-171 AC6: /prepare-shutdown calls sync-openclaw-state.sh script."""
        shutdown_pattern = r"self\.path\s*==\s*'/prepare-shutdown'(.*?)(?=elif|else:)"
        match = re.search(shutdown_pattern, self.source_code, re.DOTALL)
        
        self.assertIsNotNone(match, "/prepare-shutdown endpoint should exist")
        shutdown_code = match.group(1)
        
        # Verify sync script is called
        self.assertIn('sync-openclaw-state.sh', shutdown_code,
                     "/prepare-shutdown should call sync-openclaw-state.sh")
    
    def test_prepare_shutdown_stops_clawdbot(self):
        """TASK-171 AC7: /prepare-shutdown calls systemctl stop clawdbot."""
        shutdown_pattern = r"self\.path\s*==\s*'/prepare-shutdown'(.*?)(?=elif|else:)"
        match = re.search(shutdown_pattern, self.source_code, re.DOTALL)
        
        self.assertIsNotNone(match, "/prepare-shutdown endpoint should exist")
        shutdown_code = match.group(1)
        
        # Verify systemctl stop is called
        self.assertIn('systemctl', shutdown_code,
                     "/prepare-shutdown should call systemctl")
        self.assertIn('stop', shutdown_code,
                     "/prepare-shutdown should stop service")
        self.assertIn('clawdbot', shutdown_code,
                     "/prepare-shutdown should stop clawdbot")


if __name__ == '__main__':
    unittest.main()
