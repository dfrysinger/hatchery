"""Tests to verify BOOT.md doesn't have duplicate content (Issue #167).

Verifies that build-full-config.sh doesn't create duplicate NO_REPLY instructions
in the generated BOOT.md files for each agent.
"""

import os
import re
import pytest
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent
BUILD_CONFIG_SCRIPT = REPO_ROOT / "scripts" / "build-full-config.sh"


class TestBootMdNoDuplicates:
    """Test that BOOT.md generation doesn't create duplicate content."""
    
    def test_build_config_script_exists(self):
        """build-full-config.sh must exist."""
        assert BUILD_CONFIG_SCRIPT.is_file(), "scripts/build-full-config.sh not found"
    
    def test_no_duplicate_no_reply_in_script(self):
        """build-full-config.sh must not append NO_REPLY instructions twice to BOOT.md.
        
        Issue #167: The script had duplicate NO_REPLY instructions:
        - Once in the heredoc (correct)
        - Once in a printf block after custom instructions (duplicate, removed)
        """
        with open(BUILD_CONFIG_SCRIPT, 'r') as f:
            content = f.read()
        
        # Find all occurrences of the NO_REPLY instruction pattern
        no_reply_pattern = r"If BOOT\.md asks you to send a message.*?NO_REPLY"
        matches = list(re.finditer(no_reply_pattern, content, re.DOTALL))
        
        # Should appear exactly once (in the heredoc)
        assert len(matches) == 1, (
            f"Found {len(matches)} instances of NO_REPLY instructions in build-full-config.sh. "
            f"Expected exactly 1 (in the heredoc). Check for duplicate printf blocks."
        )
    
    def test_no_reply_instructions_in_heredoc(self):
        """Verify NO_REPLY instructions are present in the BOOT.md heredoc."""
        with open(BUILD_CONFIG_SCRIPT, 'r') as f:
            content = f.read()
        
        # Find the BOOT.md heredoc section
        heredoc_match = re.search(r"cat > .*/BOOT\.md.*?<<'BOOTMD'(.*?)BOOTMD", content, re.DOTALL)
        assert heredoc_match, "Could not find BOOT.md heredoc in build-full-config.sh"
        
        heredoc_content = heredoc_match.group(1)
        
        # Verify NO_REPLY instructions are in the heredoc
        assert "If BOOT.md asks you to send a message" in heredoc_content, (
            "NO_REPLY instructions missing from BOOT.md heredoc"
        )
        assert "reply with ONLY: NO_REPLY" in heredoc_content, (
            "NO_REPLY behavior not documented in BOOT.md heredoc"
        )
    
    def test_no_duplicate_printf_after_custom_instructions(self):
        """Verify there's no duplicate printf of NO_REPLY instructions after custom boot instructions.
        
        Issue #167: After the custom boot instructions block (GBO/ABOOT), there should NOT be
        a printf that re-adds the NO_REPLY instructions, as they're already in the heredoc.
        """
        with open(BUILD_CONFIG_SCRIPT, 'r') as f:
            lines = f.readlines()
        
        # Find the custom boot instructions block
        in_custom_boot = False
        custom_boot_end_line = -1
        
        for i, line in enumerate(lines):
            if 'if [ -n "$GBO" ] || [ -n "$ABOOT" ]' in line:
                in_custom_boot = True
            elif in_custom_boot and line.strip() == 'fi':
                custom_boot_end_line = i
                break
        
        assert custom_boot_end_line > 0, "Could not find custom boot instructions block"
        
        # Check the next 3 lines after the fi
        # Should NOT contain a printf with NO_REPLY instructions
        next_lines = lines[custom_boot_end_line + 1:custom_boot_end_line + 4]
        next_text = ''.join(next_lines)
        
        # Should NOT have a printf appending NO_REPLY instructions
        assert not (
            'printf' in next_text and 
            'NO_REPLY' in next_text and
            '>> "$AD/BOOT.md"' in next_text
        ), (
            "Duplicate printf of NO_REPLY instructions found after custom boot block. "
            "This creates duplicate content in BOOT.md (Issue #167)."
        )
    
    def test_boot_md_structure_documented(self):
        """Verify BOOT.md has clear structure without redundancy."""
        with open(BUILD_CONFIG_SCRIPT, 'r') as f:
            content = f.read()
        
        # The heredoc should contain:
        # 1. System health instructions
        # 2. Service checks
        # 3. NO_REPLY instructions
        # Custom instructions are added separately via conditional printf
        
        heredoc_match = re.search(r"cat > .*/BOOT\.md.*?<<'BOOTMD'(.*?)BOOTMD", content, re.DOTALL)
        assert heredoc_match, "Could not find BOOT.md heredoc"
        
        heredoc = heredoc_match.group(1)
        
        # Verify key sections are present
        assert "System Health" in heredoc
        assert "systemctl is-active" in heredoc
        assert "NO_REPLY" in heredoc
        
        # Count occurrences of "NO_REPLY" in heredoc (should appear ~3 times in context)
        no_reply_count = heredoc.count("NO_REPLY")
        assert 2 <= no_reply_count <= 4, (
            f"Expected 2-4 mentions of NO_REPLY in heredoc (in context of instructions), "
            f"got {no_reply_count}. Check for duplicates."
        )


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
