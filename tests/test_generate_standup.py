#!/usr/bin/env python3
"""
Tests for generate-standup.py
Testing standup report generation from sprint-state.json
"""
import json
import os
import tempfile
from pathlib import Path
import pytest
import sys

# Add scripts directory to path
SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import generate_standup as gs


class TestSprintStateParser:
    """Test parsing of sprint-state.json"""
    
    def test_parse_valid_sprint_state(self):
        """AC1: Parse valid sprint-state.json"""
        state = {
            "sprint": {
                "release": "R3",
                "name": "Tooling & Observability",
                "startDate": "2026-02-07T20:44:00Z",
                "status": "in-progress"
            },
            "tasks": [
                {
                    "id": "TASK-10",
                    "title": "Implement secret redaction",
                    "status": "done",
                    "assignee": "worker-2"
                },
                {
                    "id": "TASK-11",
                    "title": "Add npm audit",
                    "status": "in-progress",
                    "assignee": "worker-1",
                    "notes": ["Working on CI integration"]
                },
                {
                    "id": "TASK-12",
                    "title": "Fix login bug",
                    "status": "blocked",
                    "assignee": "worker-3",
                    "blockers": ["Waiting for API keys"]
                },
                {
                    "id": "TASK-13",
                    "title": "Update docs",
                    "status": "not-started"
                }
            ]
        }
        
        parsed = gs.parse_sprint_state(state)
        
        assert parsed["release"] == "R3"
        assert parsed["release_name"] == "Tooling & Observability"
        assert len(parsed["completed"]) == 1
        assert len(parsed["in_progress"]) == 1
        assert len(parsed["blocked"]) == 1
        assert len(parsed["up_next"]) == 1
    
    def test_handle_missing_file(self):
        """AC1: Handle missing sprint-state.json gracefully"""
        with pytest.raises(FileNotFoundError) as exc:
            gs.load_sprint_state("/nonexistent/path.json")
        assert "sprint-state.json not found" in str(exc.value)
    
    def test_handle_malformed_json(self):
        """AC1: Handle malformed JSON gracefully"""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            f.write("{ invalid json }")
            temp_path = f.name
        
        try:
            with pytest.raises(ValueError) as exc:
                gs.load_sprint_state(temp_path)
            assert "Invalid JSON" in str(exc.value)
        finally:
            os.unlink(temp_path)
    
    def test_handle_missing_required_fields(self):
        """AC1: Handle missing required fields gracefully"""
        state = {"sprint": {}}  # Missing tasks
        
        with pytest.raises(ValueError) as exc:
            gs.parse_sprint_state(state)
        assert "Missing required field" in str(exc.value)


class TestStandupFormatter:
    """Test standup report formatting"""
    
    def test_format_task_with_blocker_dict(self):
        """BUG-003: Handle blocker objects (not just strings)"""
        task = {
            "id": "TASK-99",
            "title": "Test task",
            "status": "blocked",
            "assignee": "worker-1",
            "blockers": [
                {
                    "description": "Tech stack mismatch",
                    "resolution": "Updated task spec",
                    "resolvedAt": "2026-02-07T21:24:00Z"
                }
            ]
        }
        
        output = gs.format_task(task, show_details=True)
        
        # Should extract description from blocker object
        assert "Tech stack mismatch" in output
        assert "TASK-99" in output
        assert "worker-1" in output
    
    def test_format_task_with_blocker_string(self):
        """BUG-003: Still handle simple string blockers"""
        task = {
            "id": "TASK-98",
            "title": "Test task",
            "status": "blocked",
            "assignee": "worker-2",
            "blockers": ["Waiting for API keys"]
        }
        
        output = gs.format_task(task, show_details=True)
        
        # Should handle string blocker
        assert "Waiting for API keys" in output
        assert "TASK-98" in output
    
    def test_format_standup_basic(self):
        """AC2: Generate formatted standup with all sections"""
        data = {
            "release": "R3",
            "release_name": "Tooling & Observability",
            "completed": [
                {"id": "TASK-10", "title": "Secret redaction", "assignee": "worker-2"}
            ],
            "in_progress": [
                {"id": "TASK-11", "title": "npm audit", "assignee": "worker-1", 
                 "notes": ["Working on CI"]}
            ],
            "blocked": [
                {"id": "TASK-12", "title": "Login fix", "assignee": "worker-3",
                 "blockers": ["Waiting for keys"]}
            ],
            "up_next": [
                {"id": "TASK-13", "title": "Update docs"}
            ],
            "sprint_notes": []
        }
        
        output = gs.format_standup(data, date="2026-02-07")
        
        assert "## Daily Standup" in output
        assert "2026-02-07" in output
        assert "**Release:** R3" in output
        assert "Tooling & Observability" in output
        assert "### ✅ Completed Yesterday" in output or "### ✅ Completed" in output
        assert "TASK-10" in output
        assert "worker-2" in output
        assert "### 🏗️ In Progress" in output
        assert "TASK-11" in output
        assert "Working on CI" in output
        assert "### ⏸️ Blocked" in output
        assert "TASK-12" in output
        assert "Waiting for keys" in output
        assert "### 📋 Up Next" in output
        assert "TASK-13" in output
    
    def test_format_uses_emoji(self):
        """AC2: Use emoji for readability"""
        data = {
            "release": "R1",
            "release_name": "Test",
            "completed": [],
            "in_progress": [],
            "blocked": [],
            "up_next": [],
            "sprint_notes": []
        }
        
        output = gs.format_standup(data)
        
        # Check for emoji in section headers
        assert "✅" in output
        assert "🏗️" in output
        assert "⏸️" in output
        assert "📋" in output
    
    def test_format_length_limit(self):
        """AC2: Keep output ≤ 1000 chars (Discord-friendly)"""
        # Create data with many tasks
        data = {
            "release": "R99",
            "release_name": "Very Long Release Name for Testing",
            "completed": [
                {"id": f"TASK-{i}", "title": f"Long task title {i}" * 5, 
                 "assignee": f"worker-{i%5+1}"}
                for i in range(20)
            ],
            "in_progress": [],
            "blocked": [],
            "up_next": [],
            "sprint_notes": []
        }
        
        output = gs.format_standup(data)
        
        # Should truncate or summarize to stay under limit
        assert len(output) <= 1000
    
    def test_format_empty_sections(self):
        """AC2: Handle empty sections gracefully"""
        data = {
            "release": "R1",
            "release_name": "Test",
            "completed": [],
            "in_progress": [],
            "blocked": [],
            "up_next": [],
            "sprint_notes": []
        }
        
        output = gs.format_standup(data)
        
        # Should still have section headers but indicate nothing to report
        assert "## Daily Standup" in output
        assert "**Release:**" in output


class TestCLIInterface:
    """Test command-line interface"""
    
    def test_cli_default_usage(self, monkeypatch, capsys):
        """AC3: Default usage with no args"""
        # Create a mock sprint-state.json
        with tempfile.TemporaryDirectory() as tmpdir:
            state_file = Path(tmpdir) / "sprint-state.json"
            state_file.write_text(json.dumps({
                "sprint": {
                    "release": "R1",
                    "name": "Test Sprint",
                    "status": "in-progress"
                },
                "tasks": []
            }))
            
            monkeypatch.setattr(sys, 'argv', ['generate-standup.py'])
            monkeypatch.setenv('SPRINT_STATE_FILE', str(state_file))
            
            # Should run and output to stdout
            gs.main()
            captured = capsys.readouterr()
            assert "Daily Standup" in captured.out
    
    def test_cli_date_flag(self):
        """AC3: Support --date flag"""
        # This test will verify the date flag is parsed correctly
        args = gs.parse_args(['--date', '2026-02-15'])
        assert args.date == '2026-02-15'
    
    def test_cli_format_flag(self):
        """AC3: Support --format flag (md/json/slack)"""
        args = gs.parse_args(['--format', 'json'])
        assert args.format == 'json'
        
        args = gs.parse_args(['--format', 'slack'])
        assert args.format == 'slack'
        
        # Default should be markdown
        args = gs.parse_args([])
        assert args.format == 'md'
    
    def test_cli_output_flag(self, tmp_path):
        """AC3: Support --output flag to write to file"""
        output_file = tmp_path / "standup.md"
        args = gs.parse_args(['--output', str(output_file)])
        assert args.output == str(output_file)


class TestIntegration:
    """Integration tests with real-like data"""
    
    def test_full_workflow(self, tmp_path):
        """AC5: Integration test with mock sprint-state.json"""
        # Create a comprehensive mock sprint state
        state = {
            "sprint": {
                "release": "R3",
                "name": "Tooling & Observability",
                "startDate": "2026-02-07T20:44:00Z",
                "status": "in-progress"
            },
            "tasks": [
                {
                    "id": "TASK-10",
                    "title": "Implement secret redaction in logs",
                    "priority": "high",
                    "status": "done",
                    "assignee": "worker-2",
                    "notes": ["Merged PR #123"]
                },
                {
                    "id": "TASK-11",
                    "title": "Add npm audit to CI",
                    "priority": "high",
                    "status": "in-progress",
                    "assignee": "worker-1",
                    "notes": ["90% complete, testing"]
                },
                {
                    "id": "TASK-15",
                    "title": "Standup generator",
                    "priority": "medium",
                    "status": "in-progress",
                    "assignee": "worker-3",
                    "notes": ["Writing tests"]
                },
                {
                    "id": "TASK-16",
                    "title": "Gate brief generator",
                    "priority": "medium",
                    "status": "blocked",
                    "assignee": "worker-4",
                    "blockers": ["Waiting for standup generator"]
                },
                {
                    "id": "TASK-12",
                    "title": "Error reporting dashboard",
                    "priority": "low",
                    "status": "not-started"
                }
            ],
            "metadata": {
                "lastUpdated": "2026-02-07T21:00:00Z"
            }
        }
        
        state_file = tmp_path / "sprint-state.json"
        state_file.write_text(json.dumps(state, indent=2))
        
        # Load and parse
        loaded = gs.load_sprint_state(str(state_file))
        parsed = gs.parse_sprint_state(loaded)
        
        # Verify parsing
        assert parsed["release"] == "R3"
        assert len(parsed["completed"]) == 1
        assert len(parsed["in_progress"]) == 2
        assert len(parsed["blocked"]) == 1
        assert len(parsed["up_next"]) == 1
        
        # Generate standup
        output = gs.format_standup(parsed, date="2026-02-08")
        
        # Verify output format
        assert "## Daily Standup — 2026-02-08" in output
        assert "**Release:** R3 — Tooling & Observability" in output
        assert "TASK-10: Implement secret redaction" in output
        assert "TASK-11: Add npm audit" in output
        assert "TASK-15: Standup generator" in output
        assert "TASK-16: Gate brief generator" in output
        assert "TASK-12: Error reporting" in output
        assert "worker-2" in output
        assert "Waiting for standup generator" in output
        
        # Verify length constraint
        assert len(output) <= 1000
