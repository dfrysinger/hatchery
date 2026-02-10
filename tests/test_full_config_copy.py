#!/usr/bin/env python3
"""Test that build-full-config.sh copies full config to openclaw.json.

Bug: build-full-config.sh wrote to openclaw.full.json but OpenClaw reads
openclaw.json. Multi-agent configs weren't being used because the minimal
single-agent config from phase1 was never replaced.

Fix: Copy openclaw.full.json to openclaw.json after generating.
"""
import os
import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"


class TestFullConfigCopy:
    """Test that full config is copied to openclaw.json."""

    def test_build_full_config_copies_to_openclaw_json(self):
        """build-full-config.sh must copy openclaw.full.json to openclaw.json."""
        script_path = SCRIPTS_DIR / "build-full-config.sh"
        assert script_path.exists(), "build-full-config.sh not found"
        
        content = script_path.read_text()
        
        # Must have a cp command that copies full.json to openclaw.json
        # Pattern: cp $H/.openclaw/openclaw.full.json $H/.openclaw/openclaw.json
        # Or similar with quotes, different variable, etc.
        copy_patterns = [
            r'cp\s+.*openclaw\.full\.json.*openclaw\.json',
            r'cp\s+\$H/\.openclaw/openclaw\.full\.json\s+\$H/\.openclaw/openclaw\.json',
        ]
        
        found = any(re.search(pattern, content) for pattern in copy_patterns)
        
        assert found, (
            "build-full-config.sh must copy openclaw.full.json to openclaw.json "
            "after generating. OpenClaw reads openclaw.json, not openclaw.full.json."
        )

    def test_copy_happens_after_full_json_write(self):
        """The copy must happen AFTER writing openclaw.full.json."""
        script_path = SCRIPTS_DIR / "build-full-config.sh"
        content = script_path.read_text()
        
        # Find line numbers
        lines = content.split('\n')
        write_line = None
        copy_line = None
        
        for i, line in enumerate(lines, 1):
            # Look for: echo "$CONFIG_JSON" > ... openclaw.full.json
            # Avoid matching chmod lines that have 2>/dev/null
            if 'openclaw.full.json' in line and 'echo' in line and '>' in line:
                if 'cp' not in line and 'chmod' not in line:
                    write_line = i
            if 'cp' in line and 'openclaw.full.json' in line and 'openclaw.json' in line:
                copy_line = i
        
        assert write_line is not None, "Could not find write to openclaw.full.json"
        assert copy_line is not None, "Could not find copy to openclaw.json"
        assert copy_line > write_line, (
            f"Copy (line {copy_line}) must come after write (line {write_line})"
        )


if __name__ == '__main__':
    import pytest
    pytest.main([__file__, '-v'])
