#!/usr/bin/env python3
"""Test that apply-config.sh calls rename-bots.sh.

Bug: When config is uploaded via API, Telegram bot display names don't update
because apply-config.sh didn't call rename-bots.sh after rebuilding config.
"""
import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"


class TestApplyConfigRename:
    """Test that apply-config.sh calls rename-bots.sh."""

    def test_apply_config_calls_rename_bots(self):
        """apply-config.sh must call rename-bots.sh after build-full-config.sh."""
        script_path = SCRIPTS_DIR / "apply-config.sh"
        assert script_path.exists(), "apply-config.sh not found"
        
        content = script_path.read_text()
        
        # Must call rename-bots.sh
        assert "rename-bots.sh" in content, (
            "apply-config.sh must call rename-bots.sh to update Telegram bot names"
        )

    def test_rename_after_build_config(self):
        """rename-bots.sh must be called AFTER build-full-config.sh."""
        script_path = SCRIPTS_DIR / "apply-config.sh"
        content = script_path.read_text()
        
        lines = content.split('\n')
        build_line = None
        rename_line = None
        
        for i, line in enumerate(lines, 1):
            # Find the actual execution line (not just echo statements about it)
            # build-full-config.sh execution starts with /
            if '/build-full-config.sh' in line:
                build_line = i
            # rename-bots.sh execution starts with /
            if '/rename-bots.sh' in line:
                rename_line = i
        
        assert build_line is not None, "Could not find build-full-config.sh call"
        assert rename_line is not None, "Could not find rename-bots.sh call"
        assert rename_line > build_line, (
            f"rename-bots.sh (line {rename_line}) must come after "
            f"build-full-config.sh (line {build_line})"
        )


if __name__ == '__main__':
    import pytest
    pytest.main([__file__, '-v'])
