#!/usr/bin/env python3
"""Tests for defensive type-checking in parse-habitat.py.

Issue #118: Add runtime type validation to catch malformed schema before processing.

These tests verify that parse-habitat.py:
- Validates all required fields
- Returns clear error messages identifying which field failed
- Handles missing keys, wrong types, null values
- All errors are caught before processing begins
"""
import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
PARSE_HABITAT = SCRIPTS_DIR / "parse-habitat.py"


def run_parse_habitat(habitat_json, agent_lib=None) -> tuple[int, str, str]:
    """Run parse-habitat.py and return (returncode, stdout, stderr)."""
    habitat_b64 = base64.b64encode(json.dumps(habitat_json).encode()).decode()
    
    env = os.environ.copy()
    env['HABITAT_B64'] = habitat_b64
    if agent_lib:
        env['AGENT_LIB_B64'] = base64.b64encode(json.dumps(agent_lib).encode()).decode()
    
    with tempfile.TemporaryDirectory() as tmpdir:
        wrapper = f'''
import sys
sys.path.insert(0, "{SCRIPTS_DIR}")

original_open = open
def mock_open(path, *args, **kwargs):
    if path == '/etc/habitat.json':
        path = "{tmpdir}/habitat.json"
    elif path == '/etc/habitat-parsed.env':
        path = "{tmpdir}/habitat-parsed.env"
    return original_open(path, *args, **kwargs)

import builtins
builtins.open = mock_open

import os
original_chmod = os.chmod
def mock_chmod(path, mode):
    if path.startswith('/etc/'):
        path = path.replace('/etc/', '{tmpdir}/')
    return original_chmod(path, mode)
os.chmod = mock_chmod

exec(open("{PARSE_HABITAT}").read())
'''
        result = subprocess.run(
            ['python3', '-c', wrapper],
            env=env,
            capture_output=True,
            text=True
        )
        return result.returncode, result.stdout, result.stderr


def run_parse_habitat_with_env(habitat_json, agent_lib=None) -> tuple[dict, str, int]:
    """Run parse-habitat.py and return (env_vars, stderr, returncode).
    
    Use this when you need to inspect the generated env vars.
    """
    habitat_b64 = base64.b64encode(json.dumps(habitat_json).encode()).decode()
    
    env = os.environ.copy()
    env['HABITAT_B64'] = habitat_b64
    if agent_lib:
        env['AGENT_LIB_B64'] = base64.b64encode(json.dumps(agent_lib).encode()).decode()
    
    with tempfile.TemporaryDirectory() as tmpdir:
        wrapper = f'''
import sys
sys.path.insert(0, "{SCRIPTS_DIR}")

original_open = open
def mock_open(path, *args, **kwargs):
    if path == '/etc/habitat.json':
        path = "{tmpdir}/habitat.json"
    elif path == '/etc/habitat-parsed.env':
        path = "{tmpdir}/habitat-parsed.env"
    return original_open(path, *args, **kwargs)

import builtins
builtins.open = mock_open

import os
original_chmod = os.chmod
def mock_chmod(path, mode):
    if path.startswith('/etc/'):
        path = path.replace('/etc/', '{tmpdir}/')
    return original_chmod(path, mode)
os.chmod = mock_chmod

exec(open("{PARSE_HABITAT}").read())
'''
        result = subprocess.run(
            ['python3', '-c', wrapper],
            env=env,
            capture_output=True,
            text=True
        )
        
        # Parse the env file if it was created
        env_vars = {}
        env_file = Path(tmpdir) / "habitat-parsed.env"
        if env_file.exists():
            for line in env_file.read_text().split('\n'):
                if '=' in line and not line.startswith('#'):
                    key, _, value = line.partition('=')
                    # Strip quotes from value
                    env_vars[key] = value.strip('"\'')
        
        return env_vars, result.stderr, result.returncode


class TestRootValidation:
    """Test validation of root habitat object."""

    def test_valid_minimal_habitat(self):
        """Valid minimal habitat should pass."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Should pass: {stderr}"

    def test_root_must_be_object(self):
        """Root must be a JSON object, not array."""
        rc, stdout, stderr = run_parse_habitat([{"name": "Test"}])
        assert rc == 1
        assert "must be a JSON object" in stderr

    def test_root_cannot_be_string(self):
        """Root cannot be a string."""
        # Need to encode manually to avoid json.dumps wrapping
        habitat_b64 = base64.b64encode(b'"just a string"').decode()
        env = os.environ.copy()
        env['HABITAT_B64'] = habitat_b64
        result = subprocess.run(
            ['python3', str(PARSE_HABITAT)],
            env=env,
            capture_output=True,
            text=True
        )
        assert result.returncode == 1
        assert "must be a JSON object" in result.stderr

    def test_root_cannot_be_null(self):
        """Root cannot be null."""
        habitat_b64 = base64.b64encode(b'null').decode()
        env = os.environ.copy()
        env['HABITAT_B64'] = habitat_b64
        result = subprocess.run(
            ['python3', str(PARSE_HABITAT)],
            env=env,
            capture_output=True,
            text=True
        )
        assert result.returncode == 1
        assert "must be a JSON object" in result.stderr


class TestNameValidation:
    """Test validation of 'name' field."""

    def test_name_is_required(self):
        """'name' field is required."""
        habitat = {"agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' is required" in stderr

    def test_name_must_be_string(self):
        """'name' must be a string."""
        habitat = {"name": 123, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' must be string" in stderr

    def test_name_cannot_be_null(self):
        """'name' cannot be null."""
        habitat = {"name": None, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' must be string" in stderr

    def test_name_cannot_be_empty(self):
        """'name' cannot be empty string."""
        habitat = {"name": "", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' cannot be empty" in stderr

    def test_name_cannot_be_whitespace(self):
        """'name' cannot be only whitespace."""
        habitat = {"name": "   ", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' cannot be empty" in stderr

    def test_name_array_is_invalid(self):
        """'name' cannot be an array."""
        habitat = {"name": ["Test"], "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' must be string" in stderr


class TestPlatformValidation:
    """Test validation of 'platform' field."""

    def test_platform_valid_values(self):
        """Valid platform values: telegram, discord, both."""
        for platform in ["telegram", "discord", "both"]:
            habitat = {"name": "Test", "platform": platform, "agents": [{"agent": "Claude"}]}
            rc, stdout, stderr = run_parse_habitat(habitat)
            assert rc == 0, f"platform '{platform}' should be valid: {stderr}"

    def test_platform_must_be_string(self):
        """'platform' must be a string."""
        habitat = {"name": "Test", "platform": 123, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'platform' must be string" in stderr

    def test_platform_invalid_value(self):
        """Invalid platform value should error."""
        habitat = {"name": "Test", "platform": "slack", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'platform' must be 'telegram', 'discord', or 'both'" in stderr


class TestPlatformsValidation:
    """Test validation of 'platforms' field."""

    def test_platforms_must_be_object(self):
        """'platforms' must be an object."""
        habitat = {"name": "Test", "platforms": "discord", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'platforms' must be object" in stderr

    def test_platforms_entries_must_be_objects(self):
        """Each platform config must be an object."""
        habitat = {
            "name": "Test",
            "platforms": {"discord": "invalid"},
            "agents": [{"agent": "Claude"}]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'platforms.discord' must be object" in stderr


class TestAgentsValidation:
    """Test validation of 'agents' field."""

    def test_agents_cannot_be_null(self):
        """'agents' cannot be null."""
        habitat = {"name": "Test", "agents": None}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'agents' cannot be null" in stderr

    def test_agents_must_be_array(self):
        """'agents' must be an array."""
        habitat = {"name": "Test", "agents": {"agent": "Claude"}}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'agents' must be array" in stderr

    def test_agents_can_be_empty(self):
        """Empty agents array is allowed."""
        habitat = {"name": "Test", "agents": []}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Empty agents should be valid: {stderr}"

    def test_agents_string_must_be_object_or_string(self):
        """Agent entries must be string or object."""
        habitat = {"name": "Test", "agents": [123]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0]" in stderr
        assert "must be string or object" in stderr

    def test_agents_null_entry(self):
        """Null agent entry should error."""
        habitat = {"name": "Test", "agents": [None]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0]" in stderr
        assert "cannot be null" in stderr


class TestAgentObjectValidation:
    """Test validation of agent object fields."""

    def test_agent_name_required(self):
        """'agent' field is required in agent object."""
        habitat = {"name": "Test", "agents": [{"model": "gpt-4"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].agent" in stderr
        assert "required" in stderr

    def test_agent_name_must_be_string(self):
        """'agent' field must be string."""
        habitat = {"name": "Test", "agents": [{"agent": 123}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].agent" in stderr
        assert "must be string" in stderr

    def test_agent_name_cannot_be_empty(self):
        """'agent' field cannot be empty."""
        habitat = {"name": "Test", "agents": [{"agent": ""}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].agent" in stderr
        assert "cannot be empty" in stderr

    def test_agent_string_shorthand_valid(self):
        """String shorthand for agent is valid."""
        habitat = {"name": "Test", "agents": ["Claude"]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"String shorthand should be valid: {stderr}"

    def test_agent_string_shorthand_empty(self):
        """Empty string shorthand is invalid."""
        habitat = {"name": "Test", "agents": [""]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0]" in stderr
        assert "cannot be empty" in stderr


class TestAgentTokensValidation:
    """Test validation of agent tokens field."""

    def test_tokens_must_be_object(self):
        """'tokens' must be an object."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "tokens": "invalid"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].tokens" in stderr
        assert "must be object" in stderr

    def test_token_values_must_be_strings(self):
        """Token values must be strings."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "tokens": {"discord": 12345}}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].tokens.discord" in stderr
        assert "must be string" in stderr

    def test_token_values_can_be_null(self):
        """Null token values are allowed (missing token)."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "tokens": {"discord": None}}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Null token should be valid: {stderr}"


class TestAgentIsolationValidation:
    """Test validation of agent isolation fields."""

    def test_isolation_group_must_be_string(self):
        """'isolationGroup' must be string."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "isolationGroup": 123}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].isolationGroup" in stderr
        assert "must be string" in stderr

    def test_isolation_must_be_string(self):
        """'isolation' must be string."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "isolation": True}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].isolation" in stderr
        assert "must be string" in stderr

    def test_network_must_be_string(self):
        """'network' must be string."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "network": ["host"]}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].network" in stderr
        assert "must be string" in stderr


class TestAgentCapabilitiesValidation:
    """Test validation of agent capabilities field."""

    def test_capabilities_must_be_array(self):
        """'capabilities' must be an array."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "capabilities": "exec"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].capabilities" in stderr
        assert "must be array" in stderr

    def test_capability_entries_must_be_strings(self):
        """Each capability must be a string."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "capabilities": ["exec", 123]}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].capabilities[1]" in stderr
        assert "must be string" in stderr


class TestAgentResourcesValidation:
    """Test validation of agent resources field."""

    def test_resources_must_be_object(self):
        """'resources' must be an object."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "resources": "512Mi"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].resources" in stderr
        assert "must be object" in stderr

    def test_resources_memory_must_be_string_or_number(self):
        """'resources.memory' must be string or number."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "resources": {"memory": ["512Mi"]}}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0].resources.memory" in stderr
        assert "must be string or number" in stderr

    def test_resources_memory_string_valid(self):
        """String resources.memory is valid."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "resources": {"memory": "512Mi"}}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"String memory should be valid: {stderr}"

    def test_resources_memory_number_valid(self):
        """Numeric resources.memory is valid."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude", "resources": {"memory": 512}}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Numeric memory should be valid: {stderr}"


class TestOtherFieldsValidation:
    """Test validation of other optional fields."""

    def test_destruct_minutes_must_be_number(self):
        """'destructMinutes' must be a number."""
        habitat = {"name": "Test", "destructMinutes": "30", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'destructMinutes' must be number" in stderr

    def test_destruct_minutes_number_valid(self):
        """Numeric destructMinutes is valid."""
        habitat = {"name": "Test", "destructMinutes": 30, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Numeric destructMinutes should be valid: {stderr}"

    def test_remote_api_must_be_bool(self):
        """'remoteApi' must be boolean."""
        habitat = {"name": "Test", "remoteApi": "true", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'remoteApi' must be bool" in stderr

    def test_api_bind_address_must_be_string(self):
        """'apiBindAddress' must be string."""
        habitat = {"name": "Test", "apiBindAddress": 0, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'apiBindAddress' must be string" in stderr

    def test_council_must_be_object(self):
        """'council' must be object."""
        habitat = {"name": "Test", "council": "council-name", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'council' must be object" in stderr

    def test_shared_paths_must_be_array(self):
        """'sharedPaths' must be array."""
        habitat = {"name": "Test", "sharedPaths": "/clawd/shared", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'sharedPaths' must be array" in stderr

    def test_shared_paths_entries_must_be_strings(self):
        """'sharedPaths' entries must be strings."""
        habitat = {"name": "Test", "sharedPaths": ["/clawd/shared", 123], "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'sharedPaths[1]' must be string" in stderr


class TestMultipleErrors:
    """Test that multiple errors are reported together."""

    def test_multiple_errors_reported(self):
        """Multiple validation errors should all be reported."""
        habitat = {
            "name": 123,
            "platform": "invalid",
            "agents": "not-an-array"
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'name' must be string" in stderr
        assert "'platform' must be" in stderr
        assert "'agents' must be array" in stderr

    def test_multiple_agent_errors(self):
        """Errors across multiple agents should all be reported."""
        habitat = {
            "name": "Test",
            "agents": [
                {"agent": ""},
                {"model": "gpt-4"},  # Missing agent
                {"agent": 123}
            ]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "agents[0]" in stderr
        assert "agents[1]" in stderr
        assert "agents[2]" in stderr


class TestAgentLibraryValidation:
    """Test validation of AGENT_LIB_B64."""

    def test_agent_lib_must_be_object(self):
        """Agent library must be a JSON object."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat, agent_lib=["not", "an", "object"])
        # Should warn but not fail
        assert rc == 0
        assert "must be object" in stderr.lower()

    def test_agent_lib_invalid_json_warns(self):
        """Invalid agent library JSON should warn, not fail."""
        habitat = {"name": "Test", "agents": [{"agent": "Claude"}]}
        # Passing malformed data that will fail to parse
        env = os.environ.copy()
        env['HABITAT_B64'] = base64.b64encode(json.dumps(habitat).encode()).decode()
        env['AGENT_LIB_B64'] = base64.b64encode(b'not json').decode()
        
        with tempfile.TemporaryDirectory() as tmpdir:
            wrapper = f'''
import sys
sys.path.insert(0, "{SCRIPTS_DIR}")
original_open = open
def mock_open(path, *args, **kwargs):
    if path == '/etc/habitat.json': path = "{tmpdir}/habitat.json"
    elif path == '/etc/habitat-parsed.env': path = "{tmpdir}/habitat-parsed.env"
    return original_open(path, *args, **kwargs)
import builtins
builtins.open = mock_open
import os
original_chmod = os.chmod
def mock_chmod(path, mode):
    if path.startswith('/etc/'): path = path.replace('/etc/', '{tmpdir}/')
    return original_chmod(path, mode)
os.chmod = mock_chmod
exec(open("{PARSE_HABITAT}").read())
'''
            result = subprocess.run(
                ['python3', '-c', wrapper],
                env=env,
                capture_output=True,
                text=True
            )
            # Should succeed but warn
            assert result.returncode == 0
            assert "WARN" in result.stderr


class TestEdgeCases:
    """Test edge cases and unusual inputs."""

    def test_extra_fields_ignored(self):
        """Unknown fields should be ignored (forward compatibility)."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude"}],
            "unknownField": "should be ignored",
            "anotherUnknown": {"nested": True}
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Unknown fields should be ignored: {stderr}"

    def test_unicode_name_valid(self):
        """Unicode in name should be valid."""
        habitat = {"name": "Тест 🤖", "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Unicode name should be valid: {stderr}"

    def test_very_long_name(self):
        """Very long name should still be valid (no length limit)."""
        habitat = {"name": "A" * 10000, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Long name should be valid: {stderr}"

    def test_deeply_nested_platforms(self):
        """Deeply nested platform config should work."""
        habitat = {
            "name": "Test",
            "platforms": {
                "discord": {
                    "serverId": "123",
                    "ownerId": "456",
                    "nested": {"deeply": {"values": True}}
                }
            },
            "agents": [{"agent": "Claude"}]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Nested platform config should be valid: {stderr}"


class TestBoolAsIntBypass:
    """Test BUG-213-A: bool-as-int bypass (Python bool is subclass of int)."""

    def test_destruct_minutes_bool_rejected(self):
        """destructMinutes: true should be rejected (not treated as 1)."""
        habitat = {"name": "Test", "destructMinutes": True, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'destructMinutes' must be number, got bool" in stderr

    def test_destruct_minutes_false_rejected(self):
        """destructMinutes: false should be rejected (not treated as 0)."""
        habitat = {"name": "Test", "destructMinutes": False, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "'destructMinutes' must be number, got bool" in stderr

    def test_destruct_minutes_int_accepted(self):
        """destructMinutes: 30 should be accepted."""
        habitat = {"name": "Test", "destructMinutes": 30, "agents": [{"agent": "Claude"}]}
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Integer destructMinutes should be valid: {stderr}"

    def test_resources_cpu_bool_rejected(self):
        """resources.cpu: true should be rejected."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "resources": {"cpu": True}}]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "resources.cpu" in stderr
        assert "got bool" in stderr

    def test_resources_memory_bool_rejected(self):
        """resources.memory: true should be rejected."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "resources": {"memory": False}}]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 1
        assert "resources.memory" in stderr
        assert "got bool" in stderr

    def test_resources_cpu_number_accepted(self):
        """resources.cpu: 0.5 should be accepted."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "resources": {"cpu": 0.5}}]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"Numeric cpu should be valid: {stderr}"

    def test_resources_memory_string_accepted(self):
        """resources.memory: '512Mi' should be accepted."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "resources": {"memory": "512Mi"}}]
        }
        rc, stdout, stderr = run_parse_habitat(habitat)
        assert rc == 0, f"String memory should be valid: {stderr}"


class TestNullTokenNormalization:
    """Test BUG-213-B: null token propagation."""

    def test_null_token_normalized_to_empty(self):
        """tokens.discord: null should become empty string, not 'None'."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "tokens": {"discord": None}}]
        }
        env_vars, stderr, rc = run_parse_habitat_with_env(habitat)
        
        assert rc == 0, f"Null token should be valid: {stderr}"
        # Token should be empty string, not "None"
        token = env_vars.get("AGENT1_DISCORD_BOT_TOKEN", "MISSING")
        assert token == "", f"Expected empty string, got '{token}'"
        assert token != "None", "Token should not be literal 'None' string"

    def test_missing_token_is_empty(self):
        """Missing token should be empty string."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "tokens": {"telegram": "tok123"}}]  # No discord
        }
        env_vars, stderr, rc = run_parse_habitat_with_env(habitat)
        
        assert rc == 0
        # Discord token not specified, should be empty
        token = env_vars.get("AGENT1_DISCORD_BOT_TOKEN", "MISSING")
        assert token == "", f"Expected empty string for missing token, got '{token}'"

    def test_valid_token_preserved(self):
        """Valid token string should be preserved."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "tokens": {"discord": "my-secret-token"}}]
        }
        env_vars, stderr, rc = run_parse_habitat_with_env(habitat)
        
        assert rc == 0
        token = env_vars.get("AGENT1_DISCORD_BOT_TOKEN", "MISSING")
        assert token == "my-secret-token"

    def test_empty_string_token_preserved(self):
        """Empty string token should remain empty string."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude", "tokens": {"discord": ""}}]
        }
        env_vars, stderr, rc = run_parse_habitat_with_env(habitat)
        
        assert rc == 0
        token = env_vars.get("AGENT1_DISCORD_BOT_TOKEN", "MISSING")
        assert token == ""


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
