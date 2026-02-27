#!/usr/bin/env python3
"""Tests for runcmd / power_state boot architecture.

Validates that:
1. provision.sh does NOT call reboot (cloud-init power_state owns the reboot)
2. hatch.yaml uses power_state to reboot after all runcmd entries complete
3. runcmd entries are modular and safe (network/systemd guaranteed operational)

Background: cloud-init runcmd entries run sequentially. If any entry triggers
a reboot, subsequent entries race the shutdown. The fix is to let cloud-init's
power_state module handle the reboot AFTER all runcmd entries complete. This
eliminates the race condition as a class, not just for specific scripts.
"""

import os
import re

import pytest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")


def _load_yaml():
    with open(os.path.join(REPO_ROOT, "hatch.yaml")) as f:
        return f.read()


def _load_provision():
    with open(os.path.join(REPO_ROOT, "scripts", "provision.sh")) as f:
        return f.read()


def _get_runcmd_entries(content):
    """Extract command entries (not comments) from runcmd section."""
    runcmd_match = re.search(
        r"^runcmd:.*?(?=^\w|\Z)", content, re.MULTILINE | re.DOTALL
    )
    assert runcmd_match, "No runcmd section found in hatch.yaml"
    return [
        line.strip()
        for line in runcmd_match.group().split("\n")
        if line.strip().startswith("- ")
    ]


class TestPowerStateArchitecture:
    """cloud-init power_state must own the reboot, not provision.sh."""

    def test_power_state_present(self):
        """hatch.yaml must have a power_state section."""
        content = _load_yaml()
        assert re.search(
            r"^power_state:", content, re.MULTILINE
        ), "hatch.yaml missing power_state section. Cloud-init must own the reboot."

    def test_power_state_mode_reboot(self):
        """power_state must specify mode: reboot."""
        content = _load_yaml()
        ps_match = re.search(
            r"^power_state:.*?(?=^\w|\Z)", content, re.MULTILINE | re.DOTALL
        )
        assert ps_match, "No power_state section"
        assert re.search(
            r"mode:\s*reboot", ps_match.group()
        ), "power_state.mode must be 'reboot'"

    def test_power_state_has_condition(self):
        """power_state must be gated on provision-complete marker."""
        content = _load_yaml()
        ps_match = re.search(
            r"^power_state:.*?(?=^\w|\Z)", content, re.MULTILINE | re.DOTALL
        )
        assert ps_match, "No power_state section"
        assert "provision-complete" in ps_match.group(), (
            "power_state must be conditioned on provision-complete marker "
            "to avoid rebooting on failed provisions"
        )

    def test_provision_does_not_reboot(self):
        """provision.sh must NOT call reboot directly."""
        content = _load_provision()
        # Look for bare 'reboot' command (not in comments)
        for i, line in enumerate(content.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if re.match(r"^(sudo\s+)?reboot(\s|$)", stripped):
                pytest.fail(
                    f"provision.sh line {i}: calls reboot directly. "
                    "Cloud-init power_state must own the reboot."
                )

    def test_provision_does_not_shutdown(self):
        """provision.sh must NOT call shutdown -r directly."""
        content = _load_provision()
        for i, line in enumerate(content.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if re.match(r"^(sudo\s+)?shutdown\s+-r", stripped):
                pytest.fail(
                    f"provision.sh line {i}: calls shutdown -r. "
                    "Cloud-init power_state must own the reboot."
                )


class TestRuncmdModular:
    """runcmd entries should be modular post-provision tasks."""

    def test_bootstrap_is_first_entry(self):
        """bootstrap.sh must be the first runcmd entry."""
        entries = _get_runcmd_entries(_load_yaml())
        assert len(entries) >= 1, "No runcmd entries found"
        assert "bootstrap.sh" in entries[0], (
            f"First runcmd entry must be bootstrap.sh, got: {entries[0]}"
        )

    def test_no_systemctl_enable_now_in_runcmd(self):
        """systemctl enable --now is redundant (already in provision.sh)."""
        entries = _get_runcmd_entries(_load_yaml())
        for entry in entries:
            assert "enable --now" not in entry, (
                "systemctl enable --now in runcmd is redundant with provision.sh. "
                "Remove it."
            )

    def test_rename_bots_in_runcmd(self):
        """rename-bots.sh should be a modular runcmd entry (safe with power_state)."""
        entries = _get_runcmd_entries(_load_yaml())
        has_rename = any("rename-bots" in e for e in entries)
        assert has_rename, (
            "rename-bots.sh should be in runcmd (safe because power_state owns reboot)"
        )

    def test_schedule_destruct_in_runcmd(self):
        """schedule-destruct.sh should be a modular runcmd entry."""
        entries = _get_runcmd_entries(_load_yaml())
        has_destruct = any("schedule-destruct" in e for e in entries)
        assert has_destruct, (
            "schedule-destruct.sh should be in runcmd (safe because power_state owns reboot)"
        )


class TestProvisionCompletionGate:
    """provision-complete marker must only be set on success."""

    def test_build_failed_skips_completion_marker(self):
        """If build-failed exists, provision-complete must NOT be touched."""
        content = _load_provision()
        # Find the build-failed check and verify it prevents provision-complete
        assert "build-failed" in content
        # The provision-complete touch must be AFTER the build-failed gate
        lines = content.split("\n")
        build_failed_check_line = None
        provision_complete_line = None
        for i, line in enumerate(lines):
            if "build-failed" in line and "if" in line and not line.strip().startswith("#"):
                build_failed_check_line = i
            if "provision-complete" in line and "touch" in line and not line.strip().startswith("#"):
                provision_complete_line = i
        assert build_failed_check_line is not None, (
            "provision.sh must check for build-failed before setting provision-complete"
        )
        assert provision_complete_line is not None
        assert build_failed_check_line < provision_complete_line, (
            "build-failed check must come BEFORE provision-complete marker"
        )

    def test_build_failed_exits_nonzero(self):
        """provision.sh must exit non-zero when build-failed is detected."""
        content = _load_provision()
        # Find the build-failed block and verify it exits
        in_block = False
        found_exit = False
        for line in content.split("\n"):
            stripped = line.strip()
            if "build-failed" in stripped and "if" in stripped and not stripped.startswith("#"):
                in_block = True
            if in_block and "exit 1" in stripped:
                found_exit = True
                break
            if in_block and stripped == "fi":
                break
        assert found_exit, (
            "provision.sh must exit 1 when build-failed is detected, "
            "preventing provision-complete from being set"
        )


class TestCriticalStageGating:
    """Critical stages (1-3, 7) must gate the provision-complete marker."""

    def _stage_section(self, start_num, end_num):
        """Extract section between two stage markers."""
        content = _load_provision()
        pattern = rf"# Stage {start_num}:.*?# Stage {end_num}:"
        match = re.search(pattern, content, re.DOTALL)
        assert match, f"Cannot find Stage {start_num} section"
        return match.group()

    def test_stage1_verifies_node(self):
        """Stage 1 must verify node binary and set build-failed if missing."""
        section = self._stage_section(1, 2)
        assert "command -v node" in section, (
            "Stage 1 must check for node binary after installation"
        )
        assert "build-failed" in section, (
            "Stage 1 must set build-failed if Node.js installation fails"
        )

    def test_stage2_verifies_openclaw(self):
        """Stage 2 must verify openclaw binary and set build-failed if missing."""
        section = self._stage_section(2, 3)
        assert "command -v openclaw" in section, (
            "Stage 2 must check for openclaw binary after installation"
        )
        assert "build-failed" in section, (
            "Stage 2 must set build-failed if OpenClaw installation fails"
        )

    def test_stage3_verifies_user(self):
        """Stage 3 must verify bot user exists and set build-failed if missing."""
        section = self._stage_section(3, 4)
        assert "build-failed" in section, (
            "Stage 3 must set build-failed if user creation fails"
        )
        # Check for user existence verification (id command)
        assert re.search(r'id\s.*USERNAME', section), (
            "Stage 3 must verify bot user exists with id command"
        )

    def test_stage7_already_gates(self):
        """Stage 7 (build-full-config.sh) already sets build-failed on failure."""
        content = _load_provision()
        # Find build-full-config.sh call and verify it has || build-failed
        assert re.search(
            r'build-full-config\.sh.*build-failed', content, re.DOTALL
        ), "Stage 7 must set build-failed if build-full-config.sh fails"

    def test_header_documents_critical_stages(self):
        """Header must document which stages are critical."""
        content = _load_provision()
        header = content[:1500]  # First ~30 lines
        assert "CRITICAL" in header, (
            "Header must mark critical stages (stages that gate provision-complete)"
        )

    def test_completion_gate_documents_all_critical_stages(self):
        """The completion gate comment must list all critical stages."""
        content = _load_provision()
        # Find the gate section
        gate_match = re.search(
            r'# Gate the provision-complete.*?if \[', content, re.DOTALL
        )
        assert gate_match, "Cannot find completion gate section"
        gate_comment = gate_match.group()
        for keyword in ["Node", "OpenClaw", "Bot user", "build-full-config"]:
            assert keyword in gate_comment, (
                f"Completion gate comment must mention {keyword}"
            )


class TestProvisionClean:
    """provision.sh should NOT contain tasks that belong in runcmd."""

    def test_no_rename_bots_call(self):
        """provision.sh should not call rename-bots.sh (it's a runcmd entry)."""
        content = _load_provision()
        for i, line in enumerate(content.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if "rename-bots.sh" in stripped:
                pytest.fail(
                    f"provision.sh line {i}: calls rename-bots.sh. "
                    "This is a modular runcmd task, not a provisioning step."
                )

    def test_no_schedule_destruct_call(self):
        """provision.sh should not call schedule-destruct.sh (it's a runcmd entry)."""
        content = _load_provision()
        for i, line in enumerate(content.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if "schedule-destruct.sh" in stripped:
                pytest.fail(
                    f"provision.sh line {i}: calls schedule-destruct.sh. "
                    "This is a modular runcmd task, not a provisioning step."
                )
