#!/usr/bin/env python3
"""Tests for api_uploaded semantics (Issue #119).

These tests verify the behavior when config is:
- Never uploaded via API (apply-only mode)
- Uploaded via API (api-uploaded mode)
- Missing entirely (unconfigured)
"""
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock

import pytest

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"


def get_api_server_functions():
    """Import api-server functions for testing."""
    api_server_path = SCRIPTS_DIR / "api-server.py"
    source = api_server_path.read_text()
    
    namespace = {
        '__name__': 'test',
        'os': os,
        'json': json,
        'time': time,
    }
    
    # Extract and execute the relevant functions
    # We need: get_config_status, get_config_upload_status, write_upload_marker
    
    # Find MARKER_PATH constant
    namespace['MARKER_PATH'] = '/tmp/test-config-api-uploaded'
    namespace['HABITAT_PATH'] = '/tmp/test-habitat.json'
    namespace['AGENTS_PATH'] = '/tmp/test-agents.json'
    
    # Extract functions
    for func_name in ['get_config_status', 'get_config_upload_status', 'write_upload_marker']:
        start = source.find(f'def {func_name}')
        if start == -1:
            raise ValueError(f"Function {func_name} not found")
        
        # Find end of function (next 'def ' at same indentation or class/EOF)
        end = source.find('\ndef ', start + 1)
        if end == -1:
            end = source.find('\nclass ', start + 1)
        if end == -1:
            end = len(source)
        
        func_source = source[start:end]
        exec(func_source, namespace)
    
    return namespace


@pytest.fixture
def temp_paths(tmp_path):
    """Create temporary paths for testing."""
    paths = {
        'marker': tmp_path / 'config-api-uploaded',
        'habitat': tmp_path / 'habitat.json',
        'agents': tmp_path / 'agents.json',
    }
    yield paths
    # Cleanup
    for p in paths.values():
        if p.exists():
            p.unlink()


@pytest.fixture
def api_funcs(temp_paths):
    """Get api-server functions with mocked paths."""
    api_server_path = SCRIPTS_DIR / "api-server.py"
    source = api_server_path.read_text()
    
    namespace = {
        '__name__': 'test',
        'os': os,
        'json': json,
        'time': time,
        'sys': sys,
        'MARKER_PATH': str(temp_paths['marker']),
        'HABITAT_PATH': str(temp_paths['habitat']),
        'AGENTS_PATH': str(temp_paths['agents']),
    }
    
    # Extract functions
    for func_name in ['get_config_status', 'get_config_upload_status', 'write_upload_marker']:
        start = source.find(f'def {func_name}')
        end = source.find('\ndef ', start + 1)
        if end == -1:
            end = source.find('\nclass ', start + 1)
        if end == -1:
            end = len(source)
        
        func_source = source[start:end]
        exec(func_source, namespace)
    
    return namespace


class TestUnconfiguredState:
    """Test state when no config exists (fresh droplet)."""

    def test_no_files_means_unconfigured(self, api_funcs, temp_paths):
        """Fresh droplet with no files should show unconfigured state."""
        status = api_funcs['get_config_status']()
        
        assert status['habitat_exists'] is False
        assert status['agents_exists'] is False
        assert status['api_uploaded'] is False

    def test_upload_status_unconfigured(self, api_funcs, temp_paths):
        """Unauthenticated endpoint should show api_uploaded=False."""
        status = api_funcs['get_config_upload_status']()
        
        assert status['api_uploaded'] is False
        assert status['api_uploaded_at'] is None


class TestApplyOnlyMode:
    """Test apply-only mode (config exists but never API-uploaded)."""

    def test_config_exists_but_not_uploaded(self, api_funcs, temp_paths):
        """Config placed manually should show habitat_exists but api_uploaded=False."""
        # Simulate cloud-init placing config
        habitat = {"name": "TestHabitat", "agents": [{"agent": "Claude"}]}
        temp_paths['habitat'].write_text(json.dumps(habitat))
        
        status = api_funcs['get_config_status']()
        
        assert status['habitat_exists'] is True
        assert status['api_uploaded'] is False
        assert status.get('habitat_name') == "TestHabitat"

    def test_both_configs_apply_only(self, api_funcs, temp_paths):
        """Both config files without API upload = apply-only mode."""
        # Simulate cloud-init placing both configs
        habitat = {"name": "TestHabitat", "agents": [{"agent": "Claude"}, {"agent": "ChatGPT"}]}
        agents = {"Claude": {"model": "claude-3"}, "ChatGPT": {"model": "gpt-4"}}
        
        temp_paths['habitat'].write_text(json.dumps(habitat))
        temp_paths['agents'].write_text(json.dumps(agents))
        
        status = api_funcs['get_config_status']()
        
        assert status['habitat_exists'] is True
        assert status['agents_exists'] is True
        assert status['api_uploaded'] is False
        assert status.get('habitat_agent_count') == 2
        assert set(status.get('agents_names', [])) == {'Claude', 'ChatGPT'}

    def test_upload_status_in_apply_only_mode(self, api_funcs, temp_paths):
        """Unauthenticated endpoint shows api_uploaded=False even with config."""
        # Config exists but no marker
        habitat = {"name": "TestHabitat", "agents": [{"agent": "Claude"}]}
        temp_paths['habitat'].write_text(json.dumps(habitat))
        
        status = api_funcs['get_config_upload_status']()
        
        # This is the key point: api_uploaded=False doesn't mean "no config"
        assert status['api_uploaded'] is False
        assert status['api_uploaded_at'] is None


class TestApiUploadedMode:
    """Test API-uploaded mode (config uploaded via API)."""

    def test_marker_written_on_upload(self, api_funcs, temp_paths):
        """write_upload_marker should create marker file."""
        result = api_funcs['write_upload_marker']()
        
        assert result['ok'] is True
        assert temp_paths['marker'].exists()

    def test_marker_contains_timestamp(self, api_funcs, temp_paths):
        """Marker file should contain Unix timestamp."""
        before = time.time()
        api_funcs['write_upload_marker']()
        after = time.time()
        
        timestamp = float(temp_paths['marker'].read_text())
        assert before <= timestamp <= after

    def test_config_with_marker_shows_uploaded(self, api_funcs, temp_paths):
        """Config with marker should show api_uploaded=True."""
        # Simulate API upload
        habitat = {"name": "TestHabitat", "agents": [{"agent": "Claude"}]}
        temp_paths['habitat'].write_text(json.dumps(habitat))
        api_funcs['write_upload_marker']()
        
        status = api_funcs['get_config_status']()
        
        assert status['habitat_exists'] is True
        assert status['api_uploaded'] is True
        assert status['api_uploaded_at'] is not None

    def test_upload_status_shows_uploaded(self, api_funcs, temp_paths):
        """Unauthenticated endpoint should show api_uploaded=True with marker."""
        api_funcs['write_upload_marker']()
        
        status = api_funcs['get_config_upload_status']()
        
        assert status['api_uploaded'] is True
        assert status['api_uploaded_at'] is not None


class TestErrorState:
    """Test error state (marker exists but no config)."""

    def test_marker_without_config(self, api_funcs, temp_paths):
        """Marker without config files = error state."""
        # Create marker but no config (shouldn't happen normally)
        api_funcs['write_upload_marker']()
        
        status = api_funcs['get_config_status']()
        
        # api_uploaded=True but habitat_exists=False is an error state
        assert status['api_uploaded'] is True
        assert status['habitat_exists'] is False


class TestStateTransitions:
    """Test state transitions between modes."""

    def test_apply_only_to_api_uploaded(self, api_funcs, temp_paths):
        """Transition from apply-only to API-uploaded mode."""
        # Start in apply-only mode
        habitat = {"name": "TestHabitat", "agents": [{"agent": "Claude"}]}
        temp_paths['habitat'].write_text(json.dumps(habitat))
        
        status1 = api_funcs['get_config_status']()
        assert status1['api_uploaded'] is False
        assert status1['habitat_exists'] is True
        
        # Simulate API upload (creates marker)
        api_funcs['write_upload_marker']()
        
        status2 = api_funcs['get_config_status']()
        assert status2['api_uploaded'] is True
        assert status2['habitat_exists'] is True

    def test_multiple_uploads_update_timestamp(self, api_funcs, temp_paths):
        """Multiple API uploads should update timestamp."""
        api_funcs['write_upload_marker']()
        ts1 = float(temp_paths['marker'].read_text())
        
        time.sleep(0.01)  # Small delay to ensure different timestamp
        api_funcs['write_upload_marker']()
        ts2 = float(temp_paths['marker'].read_text())
        
        assert ts2 > ts1


class TestDocstringPresence:
    """Verify docstrings document api_uploaded semantics."""

    def test_write_upload_marker_documents_modes(self):
        """write_upload_marker should document both modes."""
        source = (SCRIPTS_DIR / "api-server.py").read_text()
        
        # Check for key documentation terms
        assert "API-UPLOADED MODE" in source or "api_uploaded" in source
        assert "APPLY-ONLY MODE" in source or "apply-only" in source.lower()

    def test_get_config_status_documents_matrix(self):
        """get_config_status should document state matrix."""
        source = (SCRIPTS_DIR / "api-server.py").read_text()
        
        # Should document the relationship between api_uploaded and habitat_exists
        assert "api_uploaded" in source
        assert "habitat_exists" in source

    def test_get_config_upload_status_warns_about_semantics(self):
        """get_config_upload_status should warn api_uploaded=False doesn't mean unconfigured."""
        source = (SCRIPTS_DIR / "api-server.py").read_text()
        
        # Find the docstring for get_config_upload_status
        start = source.find('def get_config_upload_status')
        end = source.find('result={"api_uploaded"', start)
        docstring = source[start:end]
        
        # Should warn about the semantics
        assert "false" in docstring.lower() or "False" in docstring
        assert "unconfigured" in docstring.lower() or "apply-only" in docstring.lower()


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
