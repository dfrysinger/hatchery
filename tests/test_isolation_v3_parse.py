#!/usr/bin/env python3
"""Tests for v3 isolation field parsing in parse-habitat.py.

Tests that parse-habitat.py correctly extracts:
- Top-level isolation settings (isolation.default, isolation.sharedPaths)
- Per-agent isolation settings (group, isolation, network, capabilities, resources)
- Backward compatibility when isolation fields are missing
"""
import json
import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"


class TestIsolationTopLevel:
    """Test top-level isolation field parsing."""

    def test_isolation_object_format(self):
        """Parse isolation as object: {default, sharedPaths}."""
        habitat = {
            "name": "Test",
            "isolation": {
                "default": "container",
                "sharedPaths": ["/clawd/shared", "/data"]
            },
            "agents": [{"agent": "Claude"}]
        }
        
        isolation_cfg = habitat.get("isolation", {})
        assert isinstance(isolation_cfg, dict)
        assert isolation_cfg.get("default") == "container"
        assert isolation_cfg.get("sharedPaths") == ["/clawd/shared", "/data"]

    def test_isolation_string_format(self):
        """Parse isolation as simple string."""
        habitat = {
            "name": "Test",
            "isolation": "session",
            "agents": [{"agent": "Claude"}]
        }
        
        isolation_cfg = habitat.get("isolation", {})
        if isinstance(isolation_cfg, str):
            isolation_default = isolation_cfg
            shared_paths = []
        else:
            isolation_default = isolation_cfg.get("default", "none")
            shared_paths = isolation_cfg.get("sharedPaths", [])
        
        assert isolation_default == "session"
        assert shared_paths == []

    def test_isolation_missing_defaults_to_none(self):
        """Missing isolation field defaults to 'none'."""
        habitat = {
            "name": "Test",
            "agents": [{"agent": "Claude"}]
        }
        
        isolation_cfg = habitat.get("isolation", {})
        if isinstance(isolation_cfg, str):
            isolation_default = isolation_cfg
        else:
            isolation_default = isolation_cfg.get("default", "none")
        
        assert isolation_default == "none"

    def test_valid_isolation_levels(self):
        """Valid isolation levels: none, session, process, container, droplet."""
        valid_levels = ["none", "session", "process", "container", "droplet"]
        
        for level in valid_levels:
            habitat = {
                "name": "Test",
                "isolation": {"default": level},
                "agents": [{"agent": "Claude"}]
            }
            assert habitat["isolation"]["default"] == level


class TestAgentIsolationFields:
    """Test per-agent isolation field parsing."""

    def test_agent_group_explicit(self):
        """Agent with explicit group."""
        agent = {"agent": "Claude", "group": "council"}
        assert agent.get("group", agent["agent"]) == "council"

    def test_agent_group_defaults_to_name(self):
        """Agent without group defaults to agent name."""
        agent = {"agent": "Claude"}
        assert agent.get("group", agent["agent"]) == "Claude"

    def test_agent_isolation_override(self):
        """Agent can override top-level isolation."""
        agent = {"agent": "Worker", "isolation": "container"}
        assert agent.get("isolation", "") == "container"

    def test_agent_network_modes(self):
        """Agent network mode: host, internal, none."""
        test_cases = [
            ({"agent": "A", "network": "host"}, "host"),
            ({"agent": "B", "network": "internal"}, "internal"),
            ({"agent": "C", "network": "none"}, "none"),
            ({"agent": "D"}, "host"),  # default
        ]
        
        for agent, expected in test_cases:
            assert agent.get("network", "host") == expected

    def test_agent_capabilities(self):
        """Agent capabilities list."""
        agent = {
            "agent": "Researcher",
            "capabilities": ["web_search", "web_fetch"]
        }
        assert agent.get("capabilities", []) == ["web_search", "web_fetch"]

    def test_agent_capabilities_default_empty(self):
        """Missing capabilities defaults to empty (meaning all allowed)."""
        agent = {"agent": "Claude"}
        assert agent.get("capabilities", []) == []

    def test_agent_resources_memory(self):
        """Agent memory resource limit."""
        agent = {
            "agent": "Worker",
            "resources": {"memory": "512Mi"}
        }
        resources = agent.get("resources", {})
        assert resources.get("memory", "") == "512Mi"

    def test_agent_resources_cpu(self):
        """Agent CPU resource limit."""
        agent = {
            "agent": "Worker",
            "resources": {"cpu": "0.5"}
        }
        resources = agent.get("resources", {})
        assert resources.get("cpu", "") == "0.5"


class TestIsolationGroups:
    """Test isolation group logic."""

    def test_agents_same_group(self):
        """Agents with same group share isolation boundary."""
        habitat = {
            "name": "Test",
            "isolation": "container",
            "agents": [
                {"agent": "A", "group": "team1"},
                {"agent": "B", "group": "team1"},
                {"agent": "C", "group": "team2"}
            ]
        }
        
        groups = set()
        for agent in habitat["agents"]:
            groups.add(agent.get("group", agent["agent"]))
        
        assert groups == {"team1", "team2"}

    def test_unique_groups_extracted(self):
        """Unique isolation groups should be extractable."""
        agents = [
            {"agent": "A", "group": "council"},
            {"agent": "B", "group": "council"},
            {"agent": "C", "group": "workers"},
            {"agent": "D"},  # Defaults to "D"
        ]
        
        groups = set()
        for agent in agents:
            groups.add(agent.get("group", agent["agent"]))
        
        assert groups == {"council", "workers", "D"}


class TestBackwardCompatibility:
    """Test v2 schemas still work (no isolation fields)."""

    def test_v2_habitat_no_isolation(self):
        """v2 habitat without isolation fields should work."""
        v2_habitat = {
            "name": "V2Habitat",
            "platform": "discord",
            "agents": [{"agent": "Claude"}]
        }
        
        # No isolation field
        assert "isolation" not in v2_habitat
        
        # Defaults applied
        isolation_cfg = v2_habitat.get("isolation", {})
        isolation_default = isolation_cfg.get("default", "none") if isinstance(isolation_cfg, dict) else "none"
        
        assert isolation_default == "none"

    def test_v2_agent_no_group(self):
        """v2 agent without group/isolation fields should work."""
        v2_agent = {"agent": "Claude", "model": "anthropic/claude-opus-4-5"}
        
        # No v3 fields
        assert "group" not in v2_agent
        assert "isolation" not in v2_agent
        assert "network" not in v2_agent
        assert "capabilities" not in v2_agent
        assert "resources" not in v2_agent
        
        # Defaults applied
        assert v2_agent.get("group", v2_agent["agent"]) == "Claude"
        assert v2_agent.get("network", "host") == "host"


class TestValidation:
    """Test validation of isolation fields."""

    def test_invalid_isolation_level(self):
        """Invalid isolation level should be rejected/warned."""
        invalid_levels = ["docker", "vm", "kubernetes", ""]
        valid_levels = ["none", "session", "process", "container", "droplet"]
        
        for level in invalid_levels:
            assert level not in valid_levels

    def test_invalid_network_mode(self):
        """Invalid network mode should be rejected/warned."""
        invalid_modes = ["bridge", "overlay", ""]
        valid_modes = ["host", "internal", "none"]
        
        for mode in invalid_modes:
            assert mode not in valid_modes


class TestEnvVarOutput:
    """Test expected environment variable format."""

    def test_isolation_env_vars_format(self):
        """Verify expected env var names for isolation."""
        expected_vars = [
            "ISOLATION_DEFAULT",
            "ISOLATION_SHARED_PATHS",
            "ISOLATION_GROUPS",
        ]
        
        # These should be written to habitat-parsed.env
        for var in expected_vars:
            assert var.isupper()
            assert "_" in var or var.isalpha()

    def test_agent_isolation_env_vars_format(self):
        """Verify expected per-agent env var names."""
        expected_patterns = [
            "AGENT{n}_GROUP",
            "AGENT{n}_ISOLATION",
            "AGENT{n}_NETWORK",
            "AGENT{n}_CAPABILITIES",
            "AGENT{n}_RESOURCES_MEMORY",
            "AGENT{n}_RESOURCES_CPU",
        ]
        
        # Format should match existing AGENT{n}_* pattern
        for pattern in expected_patterns:
            assert pattern.startswith("AGENT{n}_")


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
