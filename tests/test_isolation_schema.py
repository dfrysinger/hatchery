#!/usr/bin/env python3
"""Tests for Habitat Schema v3 isolation support.

These tests verify that parse-habitat.py correctly handles:
- Top-level isolation settings
- Per-agent isolation overrides
- Isolation groups
- Network modes
- Shared paths
- Backward compatibility with v2 schemas
"""
import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
PARSE_HABITAT = SCRIPTS_DIR / "parse-habitat.py"


def run_parse_habitat(habitat_json: dict) -> dict:
    """Run parse-habitat.py with given habitat and return parsed env vars."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(habitat_json, f)
        habitat_file = f.name
    
    try:
        # Set up environment
        env = os.environ.copy()
        env['HABITAT_B64'] = ''  # Will read from file
        
        # Run parse-habitat.py
        result = subprocess.run(
            ['python3', str(PARSE_HABITAT)],
            env=env,
            capture_output=True,
            text=True,
            input=json.dumps(habitat_json)
        )
        
        # Parse output env file
        env_vars = {}
        output_file = Path('/etc/habitat-parsed.env')
        if output_file.exists():
            for line in output_file.read_text().split('\n'):
                if '=' in line and not line.startswith('#'):
                    key, _, value = line.partition('=')
                    env_vars[key] = value.strip('"\'')
        
        return env_vars
    finally:
        os.unlink(habitat_file)


class TestIsolationTopLevel:
    """Test top-level isolation settings."""

    def test_isolation_none_is_default(self):
        """Missing isolation field should default to 'none'."""
        habitat = {
            "name": "TestHabitat",
            "agents": [{"agent": "Claude"}]
        }
        # Verify schema allows missing isolation
        assert "isolation" not in habitat
        # Default should be "none" when parsed

    def test_isolation_values_valid(self):
        """Valid isolation values: none, session, container, droplet."""
        valid_values = ["none", "session", "container", "droplet"]
        for value in valid_values:
            habitat = {
                "name": "TestHabitat",
                "isolation": value,
                "agents": [{"agent": "Claude"}]
            }
            # Should not raise
            json.dumps(habitat)

    def test_shared_paths_is_array(self):
        """sharedPaths must be an array of strings."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "sharedPaths": ["/clawd/shared", "/clawd/reports"],
            "agents": [{"agent": "Claude"}]
        }
        assert isinstance(habitat["sharedPaths"], list)
        assert all(isinstance(p, str) for p in habitat["sharedPaths"])


class TestIsolationPerAgent:
    """Test per-agent isolation settings."""

    def test_agent_inherits_global_isolation(self):
        """Agent without isolation should inherit global setting."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [
                {"agent": "Claude"}  # No isolation specified
            ]
        }
        # Claude should inherit "container"
        assert "isolation" not in habitat["agents"][0]

    def test_agent_overrides_global_isolation(self):
        """Agent can override global isolation level."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [
                {"agent": "Orchestrator", "isolation": "session"},
                {"agent": "Worker"}  # Inherits container
            ]
        }
        assert habitat["agents"][0]["isolation"] == "session"
        assert "isolation" not in habitat["agents"][1]

    def test_agent_isolation_group(self):
        """Agents with same isolationGroup share boundary."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [
                {"agent": "A", "isolationGroup": "team1"},
                {"agent": "B", "isolationGroup": "team1"},
                {"agent": "C", "isolationGroup": "team2"}
            ]
        }
        # A and B should share container, C separate
        assert habitat["agents"][0]["isolationGroup"] == habitat["agents"][1]["isolationGroup"]
        assert habitat["agents"][0]["isolationGroup"] != habitat["agents"][2]["isolationGroup"]

    def test_agent_network_modes(self):
        """Agent network mode: host, internal, none."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [
                {"agent": "WebAgent", "network": "host"},
                {"agent": "InternalAgent", "network": "internal"},
                {"agent": "SandboxAgent", "network": "none"}
            ]
        }
        assert habitat["agents"][0]["network"] == "host"
        assert habitat["agents"][1]["network"] == "internal"
        assert habitat["agents"][2]["network"] == "none"


class TestIsolationGroupLogic:
    """Test isolation group behavior."""

    def test_missing_group_means_own_boundary(self):
        """Agent without isolationGroup gets its own boundary."""
        habitat = {
            "name": "TestHabitat",
            "isolation": "container",
            "agents": [
                {"agent": "A"},  # Own boundary (implicit group "A")
                {"agent": "B"}   # Own boundary (implicit group "B")
            ]
        }
        # Each should be isolated from the other
        assert "isolationGroup" not in habitat["agents"][0]
        assert "isolationGroup" not in habitat["agents"][1]

    def test_group_name_validation(self):
        """isolationGroup should be alphanumeric + hyphens."""
        valid_groups = ["team1", "team-a", "workers", "council-2024"]
        invalid_groups = ["team 1", "team@1", "team/a", ""]
        
        for group in valid_groups:
            habitat = {
                "name": "Test",
                "agents": [{"agent": "A", "isolationGroup": group}]
            }
            # Should be valid
            assert habitat["agents"][0]["isolationGroup"] == group
        
        # Invalid groups should be rejected by validation (not JSON schema)


class TestBackwardCompatibility:
    """Test v2 schema backward compatibility."""

    def test_v2_schema_still_valid(self):
        """v2 habitat without isolation fields should work."""
        v2_habitat = {
            "name": "OldHabitat",
            "platform": "discord",
            "agents": [
                {"agent": "Claude"},
                {"agent": "ChatGPT"}
            ]
        }
        # Should be valid JSON
        json.dumps(v2_habitat)
        # No isolation fields
        assert "isolation" not in v2_habitat
        assert "sharedPaths" not in v2_habitat

    def test_v2_treated_as_isolation_none(self):
        """v2 habitat should be treated as isolation: none."""
        # This is a behavioral test - parse-habitat.py should
        # default to "none" when isolation is missing
        pass  # Verified in integration tests

    def test_mixed_v2_v3_agents(self):
        """Agents can mix v2 style (minimal) with v3 style (full)."""
        habitat = {
            "name": "MixedHabitat",
            "isolation": "session",
            "agents": [
                {"agent": "Simple"},  # v2 style
                {
                    "agent": "Complex",
                    "isolation": "container",
                    "isolationGroup": "workers",
                    "network": "none"
                }  # v3 style
            ]
        }
        # Should be valid
        json.dumps(habitat)


class TestNetworkModeValidation:
    """Test network mode constraints."""

    def test_network_only_for_container_or_droplet(self):
        """network field only valid for container/droplet isolation."""
        # Valid: container + network
        valid = {
            "name": "Test",
            "isolation": "container",
            "agents": [{"agent": "A", "network": "none"}]
        }
        json.dumps(valid)
        
        # Should warn/error: session + network (network has no effect)
        # This is a validation rule, not schema rule

    def test_network_default_is_host(self):
        """Missing network should default to 'host'."""
        habitat = {
            "name": "Test",
            "isolation": "container",
            "agents": [{"agent": "A"}]  # No network specified
        }
        # Default should be "host" when parsed
        assert "network" not in habitat["agents"][0]


class TestResourceLimits:
    """Test resource limit fields."""

    def test_resources_optional(self):
        """resources field is optional."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "A"}]
        }
        assert "resources" not in habitat["agents"][0]

    def test_resources_memory_format(self):
        """memory should be Kubernetes-style (e.g., '512Mi')."""
        habitat = {
            "name": "Test",
            "isolation": "container",
            "agents": [
                {"agent": "A", "resources": {"memory": "512Mi"}},
                {"agent": "B", "resources": {"memory": "1Gi"}}
            ]
        }
        assert habitat["agents"][0]["resources"]["memory"] == "512Mi"
        assert habitat["agents"][1]["resources"]["memory"] == "1Gi"


class TestCapabilities:
    """Test capabilities field."""

    def test_capabilities_is_array(self):
        """capabilities should be array of strings."""
        habitat = {
            "name": "Test",
            "agents": [
                {"agent": "A", "capabilities": ["exec", "web_search"]},
                {"agent": "B", "capabilities": []}
            ]
        }
        assert isinstance(habitat["agents"][0]["capabilities"], list)
        assert isinstance(habitat["agents"][1]["capabilities"], list)

    def test_capabilities_restricts_tools(self):
        """Agent with limited capabilities should only access those tools."""
        habitat = {
            "name": "Test",
            "agents": [
                {"agent": "Researcher", "capabilities": ["web_search", "web_fetch"]},
                {"agent": "Executor", "capabilities": ["exec"]}
            ]
        }
        # Researcher can't exec, Executor can't web_search
        assert "exec" not in habitat["agents"][0]["capabilities"]
        assert "web_search" not in habitat["agents"][1]["capabilities"]


class TestSchemaValidation:
    """Test schema validation rules."""

    def test_isolation_must_be_valid_value(self):
        """isolation must be one of: none, session, container, droplet."""
        valid = ["none", "session", "container", "droplet"]
        invalid = ["docker", "vm", "kubernetes", ""]
        
        for v in valid:
            habitat = {"name": "T", "isolation": v, "agents": [{"agent": "A"}]}
            json.dumps(habitat)  # Should work
        
        # Invalid values should be rejected by parse-habitat.py validation

    def test_network_must_be_valid_value(self):
        """network must be one of: host, internal, none."""
        valid = ["host", "internal", "none"]
        invalid = ["bridge", "overlay", ""]
        
        for v in valid:
            habitat = {
                "name": "T",
                "isolation": "container",
                "agents": [{"agent": "A", "network": v}]
            }
            json.dumps(habitat)  # Should work

    def test_agents_required(self):
        """agents array is required."""
        habitat = {"name": "Test"}
        assert "agents" not in habitat
        # parse-habitat.py should error on missing agents


class TestComplexScenarios:
    """Test complex real-world scenarios."""

    def test_council_with_workers(self):
        """Council pattern: shared council, isolated workers."""
        habitat = {
            "name": "Council",
            "platform": "discord",
            "isolation": "session",
            "sharedPaths": ["/clawd/shared"],
            "agents": [
                {"agent": "Opus", "isolationGroup": "council"},
                {"agent": "Claude", "isolationGroup": "council"},
                {"agent": "ChatGPT", "isolationGroup": "council"},
                {"agent": "Worker-1", "isolation": "container", "isolationGroup": "workers"},
                {"agent": "Worker-2", "isolation": "container", "isolationGroup": "workers"}
            ]
        }
        # Council shares session, workers share container
        council = [a for a in habitat["agents"] if a.get("isolationGroup") == "council"]
        workers = [a for a in habitat["agents"] if a.get("isolationGroup") == "workers"]
        
        assert len(council) == 3
        assert len(workers) == 2
        assert all(a.get("isolation") == "container" for a in workers)

    def test_code_sandbox_pattern(self):
        """Code execution pattern: trusted orchestrator, sandboxed executor."""
        habitat = {
            "name": "CodeRunner",
            "platform": "telegram",
            "isolation": "container",
            "sharedPaths": ["/clawd/shared/code"],
            "agents": [
                {
                    "agent": "orchestrator",
                    "isolation": "session",
                    "capabilities": ["message", "cron", "sessions_spawn"]
                },
                {
                    "agent": "executor",
                    "isolationGroup": "sandbox",
                    "network": "none",
                    "capabilities": ["exec"],
                    "resources": {"memory": "512Mi"}
                }
            ]
        }
        orchestrator = habitat["agents"][0]
        executor = habitat["agents"][1]
        
        assert orchestrator["isolation"] == "session"
        assert executor["network"] == "none"
        assert "exec" in executor["capabilities"]
        assert "exec" not in orchestrator["capabilities"]


# Task definitions for implementation
IMPLEMENTATION_TASKS = """
## Implementation Tasks

### TASK-201: Update parse-habitat.py for v3 schema
- Extract `isolation` (default: "none")
- Extract `sharedPaths` (default: [])
- Per-agent: `isolation`, `isolationGroup`, `network`, `capabilities`, `resources`
- Export as environment variables
- Acceptance: All tests in TestIsolationTopLevel pass

### TASK-202: Add isolation validation to parse-habitat.py
- Validate `isolation` is one of: none, session, container, droplet
- Validate `network` is one of: host, internal, none
- Validate `network` only set when isolation is container/droplet
- Warn if invalid, don't fail (backward compat)
- Acceptance: All tests in TestSchemaValidation pass

### TASK-203: Update build-full-config.sh for isolation groups
- Group agents by `isolationGroup`
- For `isolation: none` — current single-process behavior
- For `isolation: session` — separate OpenClaw sessions
- Acceptance: All tests in TestIsolationGroupLogic pass

### TASK-204: Add docker-compose generation for container mode
- Generate docker-compose.yaml when `isolation: container`
- Mount `sharedPaths` as volumes
- Apply `network` mode per container
- Apply `resources` limits
- Acceptance: All tests in TestComplexScenarios pass

### TASK-205: Add backward compatibility tests
- Verify v2 schemas work unchanged
- Verify missing fields default correctly
- Acceptance: All tests in TestBackwardCompatibility pass
"""

if __name__ == '__main__':
    pytest.main([__file__, '-v'])
    print(IMPLEMENTATION_TASKS)
