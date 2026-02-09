"""
Test for Issue #166: Stage 9 duplicate in phase2-background.sh

Verifies that stage 9 is only set once during phase 2 provisioning.
"""

import os
import re
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHASE2_SCRIPT = os.path.join(REPO_ROOT, "scripts", "phase2-background.sh")


class TestPhase2StageProgression:
    """Test that phase2-background.sh sets stages in correct order without duplicates."""

    def test_phase2_script_exists(self):
        """phase2-background.sh must exist."""
        assert os.path.isfile(PHASE2_SCRIPT), "phase2-background.sh not found"

    def test_stage_9_set_only_once(self):
        """Stage 9 must be set exactly once (no duplicates)."""
        if not os.path.isfile(PHASE2_SCRIPT):
            pytest.skip("phase2-background.sh does not exist")

        with open(PHASE2_SCRIPT, "r") as f:
            content = f.read()

        # Find all set-stage.sh calls with stage 9
        # Pattern matches: $S 9 "..." or set-stage.sh 9 "..."
        pattern = r'(?:\$S|/usr/local/bin/set-stage\.sh)\s+9\s+'
        matches = re.findall(pattern, content)

        assert len(matches) == 1, (
            f"Stage 9 should be set exactly once, but found {len(matches)} occurrences"
        )

    def test_stages_progress_monotonically(self):
        """Stages should progress in order: 4 → 5 → 6 → 7 → 8 → 9 → 10."""
        if not os.path.isfile(PHASE2_SCRIPT):
            pytest.skip("phase2-background.sh does not exist")

        with open(PHASE2_SCRIPT, "r") as f:
            lines = f.readlines()

        # Extract all set-stage calls with line numbers
        stage_calls = []
        pattern = re.compile(r'(?:\$S|/usr/local/bin/set-stage\.sh)\s+(\d+)\s+')

        for i, line in enumerate(lines, 1):
            match = pattern.search(line)
            if match:
                stage_num = int(match.group(1))
                stage_calls.append((i, stage_num))

        assert len(stage_calls) > 0, "No stage calls found in phase2-background.sh"

        # Verify stages progress monotonically (no going backwards)
        prev_stage = 3  # Phase 2 starts at stage 4
        for line_num, stage_num in stage_calls:
            assert stage_num > prev_stage, (
                f"Stage {stage_num} on line {line_num} goes backwards "
                f"(previous stage was {prev_stage})"
            )
            prev_stage = stage_num

    def test_expected_stage_order(self):
        """Phase 2 should set stages in the documented order."""
        if not os.path.isfile(PHASE2_SCRIPT):
            pytest.skip("phase2-background.sh does not exist")

        with open(PHASE2_SCRIPT, "r") as f:
            content = f.read()

        # Expected stage progression for phase 2
        expected_stages = [4, 5, 6, 7, 8, 9, 10]
        pattern = re.compile(r'(?:\$S|/usr/local/bin/set-stage\.sh)\s+(\d+)\s+')
        
        found_stages = [int(m.group(1)) for m in pattern.finditer(content)]

        assert found_stages == expected_stages, (
            f"Phase 2 stages should be {expected_stages}, but found {found_stages}"
        )

    def test_stage_9_is_remote_access(self):
        """Stage 9 should be labeled 'remote-access' (not 'starting-desktop')."""
        if not os.path.isfile(PHASE2_SCRIPT):
            pytest.skip("phase2-background.sh does not exist")

        with open(PHASE2_SCRIPT, "r") as f:
            content = f.read()

        # Find the stage 9 call and verify its description
        pattern = r'(?:\$S|/usr/local/bin/set-stage\.sh)\s+9\s+"([^"]+)"'
        matches = re.findall(pattern, content)

        assert len(matches) >= 1, "Stage 9 call not found"
        assert matches[0] == "remote-access", (
            f"Stage 9 should be 'remote-access', but found '{matches[0]}'"
        )

        # Verify there's no duplicate with different description
        if len(matches) > 1:
            pytest.fail(
                f"Stage 9 set multiple times with descriptions: {matches}. "
                "Should only be set once as 'remote-access'."
            )
