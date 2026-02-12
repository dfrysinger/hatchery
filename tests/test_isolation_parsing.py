#!/usr/bin/env python3
"""Integration tests for v3 isolation schema parsing.

These tests verify that parse-habitat.py correctly:
- Extracts isolation fields and exports them as env vars
- Validates isolation and network modes
- Handles backward compatibility with v2 schemas
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


def run_parse_habitat(habitat_json: dict, agent_lib: dict = None) -> tuple[dict, str, int]:
    """Run parse-habitat.py and return (env_vars, stderr, returncode).
    
    Uses mock filesystem to avoid needing root permissions.
    """
    habitat_b64 = base64.b64encode(json.dumps(habitat_json).encode()).decode()
    
    env = os.environ.copy()
    env['HABITAT_B64'] = habitat_b64
    if agent_lib:
        env['AGENT_LIB_B64'] = base64.b64encode(json.dumps(agent_lib).encode()).decode()
    
    # Create temp files to capture output
    with tempfile.TemporaryDirectory() as tmpdir:
        # Patch the output paths in a wrapper script
        wrapper = f'''
import sys
sys.path.insert(0, "{SCRIPTS_DIR}")

# Mock file writes to temp directory
original_open = open
def mock_open(path, *args, **kwargs):
    if path == '/etc/habitat.json':
        path = "{tmpdir}/habitat.json"
    elif path == '/etc/habitat-parsed.env':
        path = "{tmpdir}/habitat-parsed.env"
    return original_open(path, *args, **kwargs)

import builtins
builtins.open = mock_open

# Mock chmod
import os
original_chmod = os.chmod
def mock_chmod(path, mode):
    if path.startswith('/etc/'):
        path = path.replace('/etc/', '{tmpdir}/')
    return original_chmod(path, mode)
os.chmod = mock_chmod

# Now run the actual script
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


class TestIsolationDefaultParsing:
    """Test top-level isolation field parsing."""

    def test_missing_isolation_defaults_to_none(self):
        """When isolation is not specified, default to 'none'."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "none"

    def test_isolation_none_explicit(self):
        """Explicit isolation: none."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "none",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "none"

    def test_isolation_session(self):
        """isolation: session."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "session",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "session"

    def test_isolation_container(self):
        """isolation: container."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "container"

    def test_isolation_droplet(self):
        """isolation: droplet."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "droplet",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "droplet"

    def test_invalid_isolation_warns_and_defaults(self):
        """Invalid isolation level should warn and default to 'none'."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "kubernetes",  # Invalid
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "none"
        assert "Invalid isolation level" in stderr


class TestSharedPathsParsing:
    """Test sharedPaths field parsing."""

    def test_missing_shared_paths_defaults_empty(self):
        """When sharedPaths is not specified, default to empty."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_SHARED_PATHS") == ""

    def test_shared_paths_single(self):
        """Single shared path."""
        habitat = {
            "name": "TestHabitat",
            "sharedPaths": ["/clawd/shared"],
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_SHARED_PATHS") == "/clawd/shared"

    def test_shared_paths_multiple(self):
        """Multiple shared paths (comma-separated)."""
        habitat = {
            "name": "TestHabitat",
            "sharedPaths": ["/clawd/shared", "/clawd/reports", "/data"],
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_SHARED_PATHS") == "/clawd/shared,/clawd/reports,/data"


class TestAgentIsolationGroupParsing:
    """Test per-agent isolationGroup field."""

    def test_missing_isolation_group_defaults_to_name(self):
        """When isolationGroup not specified, default to agent name."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_ISOLATION_GROUP") == "Claude"

    def test_explicit_isolation_group(self):
        """Explicit isolationGroup."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude", "isolationGroup": "council"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_ISOLATION_GROUP") == "council"

    def test_multiple_agents_same_group(self):
        """Multiple agents in same isolationGroup."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [
                {"agent": "Opus", "isolationGroup": "council"},
                {"agent": "Claude", "isolationGroup": "council"},
                {"agent": "Worker", "isolationGroup": "workers"}
            ]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_ISOLATION_GROUP") == "council"
        assert env_vars.get("AGENT2_ISOLATION_GROUP") == "council"
        assert env_vars.get("AGENT3_ISOLATION_GROUP") == "workers"
        # ISOLATION_GROUPS should list unique groups
        groups = env_vars.get("ISOLATION_GROUPS", "").split(",")
        assert set(groups) == {"council", "workers"}


class TestAgentIsolationParsing:
    """Test per-agent isolation override field."""

    def test_missing_agent_isolation_empty(self):
        """When agent isolation not specified, empty (inherits global)."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_ISOLATION") == ""

    def test_agent_isolation_override(self):
        """Agent overrides global isolation."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Orchestrator", "isolation": "session"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_ISOLATION") == "session"

    def test_invalid_agent_isolation_warns(self):
        """Invalid agent isolation should warn and be ignored."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude", "isolation": "vm"}]  # Invalid
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_ISOLATION") == ""
        assert "invalid isolation" in stderr.lower()


class TestAgentNetworkParsing:
    """Test per-agent network field."""

    def test_missing_network_defaults_to_host(self):
        """When network not specified, default to 'host'."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_NETWORK") == "host"

    def test_network_internal(self):
        """network: internal."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude", "network": "internal"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_NETWORK") == "internal"

    def test_network_none(self):
        """network: none (air-gapped)."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Sandbox", "network": "none"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_NETWORK") == "none"

    def test_invalid_network_warns_and_defaults(self):
        """Invalid network should warn and default to 'host'."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude", "network": "bridge"}]  # Invalid
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_NETWORK") == "host"
        assert "invalid network" in stderr.lower()

    def test_network_on_non_container_warns(self):
        """Setting network on non-container isolation should warn."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "session",
            "agents": [{"agent": "Claude", "network": "none"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        # Should still set the value but warn
        assert env_vars.get("AGENT1_NETWORK") == "none"
        assert "network only applies to container/droplet" in stderr.lower()


class TestAgentCapabilitiesParsing:
    """Test per-agent capabilities field."""

    def test_missing_capabilities_empty(self):
        """When capabilities not specified, default to empty (all tools)."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_CAPABILITIES") == ""

    def test_capabilities_single(self):
        """Single capability."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Executor", "capabilities": ["exec"]}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_CAPABILITIES") == "exec"

    def test_capabilities_multiple(self):
        """Multiple capabilities (comma-separated)."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Researcher", "capabilities": ["web_search", "web_fetch", "read"]}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_CAPABILITIES") == "web_search,web_fetch,read"


class TestAgentResourcesParsing:
    """Test per-agent resources field."""

    def test_missing_resources_empty(self):
        """When resources not specified, fields are empty."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_RESOURCES_MEMORY") == ""
        assert env_vars.get("AGENT1_RESOURCES_CPU") == ""

    def test_resources_memory(self):
        """resources.memory."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude", "resources": {"memory": "512Mi"}}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_RESOURCES_MEMORY") == "512Mi"
        assert env_vars.get("AGENT1_RESOURCES_CPU") == ""

    def test_resources_cpu(self):
        """resources.cpu."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude", "resources": {"cpu": "0.5"}}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_RESOURCES_CPU") == "0.5"

    def test_resources_both(self):
        """resources.memory and resources.cpu."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [{"agent": "Claude", "resources": {"memory": "1Gi", "cpu": "2"}}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_RESOURCES_MEMORY") == "1Gi"
        assert env_vars.get("AGENT1_RESOURCES_CPU") == "2"


class TestIsolationGroupsOutput:
    """Test ISOLATION_GROUPS aggregate output."""

    def test_single_agent_single_group(self):
        """Single agent = single implicit group."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_GROUPS") == "Claude"

    def test_multiple_agents_unique_groups(self):
        """Multiple agents, each in own group."""
        habitat = {
            "name": "TestHabitat",
            "agents": [
                {"agent": "A"},
                {"agent": "B"},
                {"agent": "C"}
            ]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        groups = set(env_vars.get("ISOLATION_GROUPS", "").split(","))
        assert groups == {"A", "B", "C"}

    def test_multiple_agents_shared_groups(self):
        """Multiple agents sharing groups."""
        habitat = {
            "name": "TestHabitat",
            "agents": [
                {"agent": "A", "isolationGroup": "team1"},
                {"agent": "B", "isolationGroup": "team1"},
                {"agent": "C", "isolationGroup": "team2"},
                {"agent": "D", "isolationGroup": "team2"},
                {"agent": "E"}  # Own group "E"
            ]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        groups = set(env_vars.get("ISOLATION_GROUPS", "").split(","))
        assert groups == {"team1", "team2", "E"}


class TestBackwardCompatibility:
    """Test that v2 schemas continue to work."""

    def test_v2_minimal_habitat(self):
        """Minimal v2 habitat should work with sensible defaults."""
        habitat = {
            "name": "SimpleBot",
            "agents": [{"agent": "Claude"}]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("HABITAT_NAME") == "SimpleBot"
        assert env_vars.get("AGENT_COUNT") == "1"
        assert env_vars.get("AGENT1_NAME") == "Claude"
        # v3 defaults
        assert env_vars.get("ISOLATION_DEFAULT") == "none"
        assert env_vars.get("ISOLATION_SHARED_PATHS") == ""
        assert env_vars.get("AGENT1_ISOLATION_GROUP") == "Claude"
        assert env_vars.get("AGENT1_ISOLATION") == ""
        assert env_vars.get("AGENT1_NETWORK") == "host"
        assert env_vars.get("AGENT1_CAPABILITIES") == ""

    def test_v2_string_shorthand_agent(self):
        """v2 string shorthand for agent should work."""
        habitat = {
            "name": "SimpleBot",
            "agents": ["Claude"]  # String shorthand
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("AGENT1_NAME") == "Claude"
        assert env_vars.get("AGENT1_ISOLATION_GROUP") == "Claude"


class TestComplexScenarios:
    """Test complex real-world scenarios end-to-end."""

    def test_council_with_isolated_workers(self):
        """Full council setup with containerized workers."""
        habitat = {
            "name": "Council",
            "platform": "discord",
            "isolation": "session",
            "sharedPaths": ["/clawd/shared", "/clawd/reports"],
            "agents": [
                {"agent": "Opus", "isolationGroup": "council"},
                {"agent": "Claude", "isolationGroup": "council"},
                {"agent": "ChatGPT", "isolationGroup": "council"},
                {
                    "agent": "Worker-1",
                    "isolation": "container",
                    "isolationGroup": "workers",
                    "network": "internal",
                    "capabilities": ["exec", "read", "write"],
                    "resources": {"memory": "512Mi", "cpu": "0.5"}
                },
                {
                    "agent": "Worker-2",
                    "isolation": "container",
                    "isolationGroup": "workers",
                    "network": "internal",
                    "capabilities": ["exec", "read", "write"],
                    "resources": {"memory": "512Mi", "cpu": "0.5"}
                }
            ]
        }
        env_vars, stderr, rc = run_parse_habitat(habitat)
        
        assert rc == 0
        assert env_vars.get("ISOLATION_DEFAULT") == "session"
        assert env_vars.get("ISOLATION_SHARED_PATHS") == "/clawd/shared,/clawd/reports"
        
        # Council agents
        assert env_vars.get("AGENT1_ISOLATION_GROUP") == "council"
        assert env_vars.get("AGENT2_ISOLATION_GROUP") == "council"
        assert env_vars.get("AGENT3_ISOLATION_GROUP") == "council"
        assert env_vars.get("AGENT1_ISOLATION") == ""  # Inherits session
        
        # Worker agents
        assert env_vars.get("AGENT4_ISOLATION_GROUP") == "workers"
        assert env_vars.get("AGENT5_ISOLATION_GROUP") == "workers"
        assert env_vars.get("AGENT4_ISOLATION") == "container"
        assert env_vars.get("AGENT4_NETWORK") == "internal"
        assert env_vars.get("AGENT4_CAPABILITIES") == "exec,read,write"
        assert env_vars.get("AGENT4_RESOURCES_MEMORY") == "512Mi"
        assert env_vars.get("AGENT4_RESOURCES_CPU") == "0.5"
        
        # Unique groups
        groups = set(env_vars.get("ISOLATION_GROUPS", "").split(","))
        assert groups == {"council", "workers"}


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
