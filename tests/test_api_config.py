#!/usr/bin/env python3
"""Tests for API config upload endpoints.

Tests the /config/upload, /config/apply, and /config endpoints
added to api-server.py for receiving habitat and agent library
JSON files after boot.
"""
import json
import os
import tempfile
import unittest
from unittest.mock import patch, MagicMock, mock_open
import sys

# We'll test the handler logic directly by importing the module
# For now, we test the logic functions that will be extracted


class TestConfigUploadValidation(unittest.TestCase):
    """Test request validation for /config/upload."""

    def test_empty_body_is_valid(self):
        """Empty JSON body should be accepted (no-op)."""
        data = {}
        errors = validate_config_upload(data)
        self.assertEqual(errors, [])

    def test_habitat_must_be_dict(self):
        """habitat field must be a dictionary if present."""
        data = {"habitat": "not a dict"}
        errors = validate_config_upload(data)
        self.assertIn("habitat must be an object", errors)

    def test_agents_must_be_dict(self):
        """agents field must be a dictionary if present."""
        data = {"agents": ["list", "not", "dict"]}
        errors = validate_config_upload(data)
        self.assertIn("agents must be an object", errors)

    def test_apply_must_be_bool(self):
        """apply field must be a boolean if present."""
        data = {"apply": "yes"}
        errors = validate_config_upload(data)
        self.assertIn("apply must be a boolean", errors)

    def test_valid_habitat_only(self):
        """Valid habitat-only upload."""
        data = {"habitat": {"name": "TestHabitat", "agents": []}}
        errors = validate_config_upload(data)
        self.assertEqual(errors, [])

    def test_valid_agents_only(self):
        """Valid agents-only upload."""
        data = {"agents": {"agent1": {"model": "test", "identity": "..."}}}
        errors = validate_config_upload(data)
        self.assertEqual(errors, [])

    def test_valid_full_upload(self):
        """Valid upload with both habitat and agents."""
        data = {
            "habitat": {"name": "TestHabitat", "agents": []},
            "agents": {"agent1": {"model": "test"}},
            "apply": True
        }
        errors = validate_config_upload(data)
        self.assertEqual(errors, [])


class TestConfigFileWriting(unittest.TestCase):
    """Test file writing logic for config upload."""

    def setUp(self):
        """Create a temporary directory for test files."""
        self.temp_dir = tempfile.mkdtemp()
        self.habitat_path = os.path.join(self.temp_dir, "habitat.json")
        self.agents_path = os.path.join(self.temp_dir, "agents.json")

    def tearDown(self):
        """Clean up temporary files."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_write_habitat_creates_file(self):
        """Writing habitat config creates the file."""
        habitat = {"name": "Test", "agents": []}
        result = write_config_file(self.habitat_path, habitat)
        
        self.assertTrue(result["ok"])
        self.assertTrue(os.path.exists(self.habitat_path))

    def test_write_habitat_content_is_valid_json(self):
        """Written habitat file contains valid JSON."""
        habitat = {"name": "Test", "agents": [{"agent": "test1"}]}
        write_config_file(self.habitat_path, habitat)
        
        with open(self.habitat_path, 'r') as f:
            loaded = json.load(f)
        
        self.assertEqual(loaded["name"], "Test")
        self.assertEqual(len(loaded["agents"]), 1)

    def test_write_habitat_permissions(self):
        """Written file has 0600 permissions."""
        habitat = {"name": "Test"}
        write_config_file(self.habitat_path, habitat)
        
        mode = os.stat(self.habitat_path).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_write_agents_creates_file(self):
        """Writing agents library creates the file."""
        agents = {"agent1": {"model": "test", "identity": "You are..."}}
        result = write_config_file(self.agents_path, agents)
        
        self.assertTrue(result["ok"])
        self.assertTrue(os.path.exists(self.agents_path))

    def test_write_agents_preserves_content(self):
        """Written agents file preserves all content including markdown."""
        agents = {
            "resume-optimizer": {
                "model": "anthropic/claude-sonnet-4-5",
                "identity": "# Resume Optimizer\n\nYou are an expert...\n\n## Section\n- bullet"
            }
        }
        write_config_file(self.agents_path, agents)
        
        with open(self.agents_path, 'r') as f:
            loaded = json.load(f)
        
        self.assertIn("# Resume Optimizer", loaded["resume-optimizer"]["identity"])
        self.assertIn("- bullet", loaded["resume-optimizer"]["identity"])

    def test_write_error_returns_failure(self):
        """Write to invalid path returns error."""
        result = write_config_file("/nonexistent/path/file.json", {"test": 1})
        
        self.assertFalse(result["ok"])
        self.assertIn("error", result)


class TestConfigUploadResponse(unittest.TestCase):
    """Test response formatting for /config/upload."""

    def test_no_files_response(self):
        """Response when no files are uploaded."""
        result = format_upload_response(files_written=[], applied=False)
        
        self.assertTrue(result["ok"])
        self.assertEqual(result["files_written"], [])
        self.assertFalse(result["applied"])

    def test_habitat_only_response(self):
        """Response when only habitat is uploaded."""
        result = format_upload_response(
            files_written=["/etc/habitat.json"],
            applied=False
        )
        
        self.assertTrue(result["ok"])
        self.assertEqual(result["files_written"], ["/etc/habitat.json"])

    def test_both_files_response(self):
        """Response when both files are uploaded."""
        result = format_upload_response(
            files_written=["/etc/habitat.json", "/etc/agents.json"],
            applied=True
        )
        
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["files_written"]), 2)
        self.assertTrue(result["applied"])


class TestConfigApply(unittest.TestCase):
    """Test /config/apply endpoint logic."""

    @patch('subprocess.Popen')
    def test_apply_triggers_script(self, mock_popen):
        """Apply triggers the apply-config.sh script."""
        result = trigger_config_apply("/usr/local/bin/apply-config.sh")
        
        mock_popen.assert_called_once()
        call_args = mock_popen.call_args[0][0]
        self.assertIn("apply-config.sh", call_args[0])

    @patch('subprocess.Popen')
    def test_apply_returns_immediately(self, mock_popen):
        """Apply returns without waiting for script to complete."""
        mock_popen.return_value = MagicMock()
        
        result = trigger_config_apply("/usr/local/bin/apply-config.sh")
        
        self.assertTrue(result["ok"])
        self.assertTrue(result["restarting"])
        # Popen was called but not waited on
        mock_popen.return_value.wait.assert_not_called()

    @patch('subprocess.Popen', side_effect=Exception("Script not found"))
    def test_apply_error_handling(self, mock_popen):
        """Apply handles script errors gracefully."""
        result = trigger_config_apply("/nonexistent/script.sh")
        
        self.assertFalse(result["ok"])
        self.assertIn("error", result)


class TestGetConfig(unittest.TestCase):
    """Test GET /config endpoint logic."""

    def setUp(self):
        """Create a temporary directory for test files."""
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up temporary files."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_no_config_files(self):
        """Response when no config files exist."""
        result = get_config_status(
            habitat_path=os.path.join(self.temp_dir, "habitat.json"),
            agents_path=os.path.join(self.temp_dir, "agents.json")
        )
        
        self.assertFalse(result["habitat_exists"])
        self.assertFalse(result["agents_exists"])

    def test_habitat_exists(self):
        """Response when habitat file exists."""
        habitat_path = os.path.join(self.temp_dir, "habitat.json")
        with open(habitat_path, 'w') as f:
            json.dump({"name": "Test"}, f)
        
        result = get_config_status(
            habitat_path=habitat_path,
            agents_path=os.path.join(self.temp_dir, "agents.json")
        )
        
        self.assertTrue(result["habitat_exists"])
        self.assertIn("habitat_modified", result)

    def test_does_not_expose_tokens(self):
        """Config status does not expose sensitive data."""
        habitat_path = os.path.join(self.temp_dir, "habitat.json")
        with open(habitat_path, 'w') as f:
            json.dump({
                "name": "Test",
                "agents": [{"agent": "test", "discordBotToken": "SECRET123"}]
            }, f)
        
        result = get_config_status(
            habitat_path=habitat_path,
            agents_path=os.path.join(self.temp_dir, "agents.json")
        )
        
        # Should not contain any token values
        result_str = json.dumps(result)
        self.assertNotIn("SECRET123", result_str)
        self.assertNotIn("Token", result_str)


class TestApplyConfigScript(unittest.TestCase):
    """Test apply-config.sh script logic (as Python functions)."""

    def test_base64_encode_file(self):
        """File content is correctly base64 encoded."""
        import base64
        content = {"name": "Test", "agents": []}
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(content, f)
            temp_path = f.name
        
        try:
            with open(temp_path, 'rb') as f:
                encoded = base64.b64encode(f.read()).decode()
            
            # Decode and verify
            decoded = json.loads(base64.b64decode(encoded))
            self.assertEqual(decoded["name"], "Test")
        finally:
            os.unlink(temp_path)


class TestApiUploadedMarker(unittest.TestCase):
    """Test api_uploaded marker feature (issue #115).
    
    Tracks whether config was uploaded via API vs initial HABITAT_B64.
    """

    def setUp(self):
        """Create a temporary directory for test files."""
        self.temp_dir = tempfile.mkdtemp()
        self.habitat_path = os.path.join(self.temp_dir, "habitat.json")
        self.agents_path = os.path.join(self.temp_dir, "agents.json")
        self.marker_path = os.path.join(self.temp_dir, "config-api-uploaded")

    def tearDown(self):
        """Clean up temporary files."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_api_uploaded_false_when_no_marker(self):
        """AC4, AC7: api_uploaded is false when marker file doesn't exist."""
        result = get_config_status(
            habitat_path=self.habitat_path,
            agents_path=self.agents_path,
            marker_path=self.marker_path
        )
        
        self.assertFalse(result["api_uploaded"])
        self.assertNotIn("api_uploaded_at", result)

    def test_api_uploaded_true_after_marker_written(self):
        """AC1, AC3: api_uploaded is true when marker file exists."""
        # Write the marker
        write_upload_marker(self.marker_path)
        
        result = get_config_status(
            habitat_path=self.habitat_path,
            agents_path=self.agents_path,
            marker_path=self.marker_path
        )
        
        self.assertTrue(result["api_uploaded"])

    def test_api_uploaded_at_timestamp(self):
        """AC2, AC5: api_uploaded_at contains the upload timestamp."""
        import time
        before = time.time()
        
        write_upload_marker(self.marker_path)
        
        after = time.time()
        
        result = get_config_status(
            habitat_path=self.habitat_path,
            agents_path=self.agents_path,
            marker_path=self.marker_path
        )
        
        self.assertIn("api_uploaded_at", result)
        self.assertGreaterEqual(result["api_uploaded_at"], before)
        self.assertLessEqual(result["api_uploaded_at"], after)

    def test_marker_file_permissions(self):
        """AC6: Marker file has secure permissions (0600)."""
        write_upload_marker(self.marker_path)
        
        mode = os.stat(self.marker_path).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_marker_persists_across_requests(self):
        """Marker file persists and can be read multiple times."""
        write_upload_marker(self.marker_path)
        
        # Read config status twice
        result1 = get_config_status(
            habitat_path=self.habitat_path,
            agents_path=self.agents_path,
            marker_path=self.marker_path
        )
        result2 = get_config_status(
            habitat_path=self.habitat_path,
            agents_path=self.agents_path,
            marker_path=self.marker_path
        )
        
        self.assertTrue(result1["api_uploaded"])
        self.assertTrue(result2["api_uploaded"])
        self.assertEqual(result1["api_uploaded_at"], result2["api_uploaded_at"])


# =============================================================================
# Helper functions to be implemented in api-server.py
# =============================================================================

def validate_config_upload(data):
    """Validate config upload request data."""
    errors = []
    
    if "habitat" in data and not isinstance(data["habitat"], dict):
        errors.append("habitat must be an object")
    
    if "agents" in data and not isinstance(data["agents"], dict):
        errors.append("agents must be an object")
    
    if "apply" in data and not isinstance(data["apply"], bool):
        errors.append("apply must be a boolean")
    
    return errors


def write_config_file(path, data):
    """Write config data to file with secure permissions."""
    try:
        with open(path, 'w') as f:
            json.dump(data, f, indent=2)
        os.chmod(path, 0o600)
        return {"ok": True, "path": path}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def format_upload_response(files_written, applied):
    """Format the response for config upload."""
    return {
        "ok": True,
        "files_written": files_written,
        "applied": applied
    }


def trigger_config_apply(script_path):
    """Trigger config apply script asynchronously."""
    import subprocess
    try:
        subprocess.Popen([script_path])
        return {"ok": True, "restarting": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def get_config_status(habitat_path, agents_path, marker_path=None):
    """Get current config file status without exposing sensitive data."""
    result = {
        "habitat_exists": os.path.exists(habitat_path),
        "agents_exists": os.path.exists(agents_path)
    }
    
    if result["habitat_exists"]:
        stat = os.stat(habitat_path)
        result["habitat_modified"] = stat.st_mtime
    
    if result["agents_exists"]:
        stat = os.stat(agents_path)
        result["agents_modified"] = stat.st_mtime
    
    # Check for API upload marker (issue #115)
    if marker_path:
        if os.path.exists(marker_path):
            result["api_uploaded"] = True
            try:
                with open(marker_path, 'r') as f:
                    result["api_uploaded_at"] = float(f.read().strip())
            except (ValueError, IOError):
                pass
        else:
            result["api_uploaded"] = False
    
    return result


def write_upload_marker(marker_path):
    """Write API upload marker file with timestamp."""
    import time
    with open(marker_path, 'w') as f:
        f.write(str(time.time()))
    os.chmod(marker_path, 0o600)


if __name__ == '__main__':
    unittest.main()
