#!/usr/bin/env python3
"""Tests for runcmd race condition prevention.

Validates that hatch.yaml runcmd contains ONLY bootstrap.sh, and that
provision.sh handles all pre-reboot tasks (rename-bots, schedule-destruct,
post-boot-check) before triggering the reboot.

Background: cloud-init runcmd entries after bootstrap.sh race against the
reboot triggered by provision.sh. systemd is already shutting down when
they execute, causing network operations (curl) and service management
(systemctl start) to fail silently.
"""

import os
import re

import pytest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")


class TestHatchYamlRuncmd:
    """hatch.yaml runcmd must not have entries that race the reboot."""

    def _load_hatch_yaml(self):
        path = os.path.join(REPO_ROOT, "hatch.yaml")
        with open(path) as f:
            return f.read()

    def _get_runcmd_entries(self):
        """Extract only command entries (not comments) from runcmd section."""
        content = self._load_hatch_yaml()
        runcmd_match = re.search(r"^runcmd:.*?(?=^\w|\Z)", content, re.MULTILINE | re.DOTALL)
        assert runcmd_match, "No runcmd section found in hatch.yaml"
        runcmd = runcmd_match.group()
        # Only check actual command entries (lines starting with '  -'), not comments
        entries = [
            line.strip()
            for line in runcmd.split("\n")
            if line.strip().startswith("- ")
        ]
        return entries

    def test_no_rename_bots_in_runcmd(self):
        """rename-bots.sh must not be a runcmd entry (runs in provision.sh instead)."""
        entries = self._get_runcmd_entries()
        for entry in entries:
            assert "rename-bots" not in entry, (
                "rename-bots.sh is in runcmd and will race the reboot. "
                "Move to provision.sh pre-reboot section."
            )

    def test_no_schedule_destruct_in_runcmd(self):
        """schedule-destruct.sh must not be a runcmd entry (runs in provision.sh instead)."""
        entries = self._get_runcmd_entries()
        for entry in entries:
            assert "schedule-destruct" not in entry, (
                "schedule-destruct.sh is in runcmd and will race the reboot. "
                "Move to provision.sh pre-reboot section."
            )

    def test_no_systemctl_enable_now_in_runcmd(self):
        """systemctl enable --now must not be a runcmd entry (fails during shutdown)."""
        entries = self._get_runcmd_entries()
        for entry in entries:
            assert "enable --now" not in entry, (
                "systemctl enable --now in runcmd fails during shutdown. "
                "Move to provision.sh."
            )

    def test_runcmd_only_bootstrap(self):
        """runcmd should only contain bootstrap.sh (everything else is in provision.sh)."""
        content = self._load_hatch_yaml()
        runcmd_match = re.search(r"^runcmd:.*?(?=^\w|\Z)", content, re.MULTILINE | re.DOTALL)
        runcmd = runcmd_match.group()
        # Count actual command entries (lines starting with '  -')
        entries = [
            line.strip()
            for line in runcmd.split("\n")
            if line.strip().startswith("- ")
        ]
        assert len(entries) == 1, (
            f"runcmd has {len(entries)} entries, expected 1 (bootstrap.sh only). "
            f"Entries: {entries}"
        )
        assert "bootstrap.sh" in entries[0]


class TestProvisionPreReboot:
    """provision.sh must call pre-reboot tasks before the reboot."""

    def _load_provision(self):
        path = os.path.join(REPO_ROOT, "scripts", "provision.sh")
        with open(path) as f:
            return f.read()

    def test_rename_bots_before_reboot(self):
        """rename-bots.sh called before the reboot command."""
        content = self._load_provision()
        rename_pos = content.find("rename-bots.sh")
        reboot_pos = content.rfind("\nreboot")
        assert rename_pos > 0, "rename-bots.sh not found in provision.sh"
        assert reboot_pos > 0, "reboot not found in provision.sh"
        assert rename_pos < reboot_pos, (
            "rename-bots.sh must be called BEFORE reboot in provision.sh"
        )

    def test_schedule_destruct_before_reboot(self):
        """schedule-destruct.sh called before the reboot command."""
        content = self._load_provision()
        destruct_pos = content.find("schedule-destruct.sh")
        reboot_pos = content.rfind("\nreboot")
        assert destruct_pos > 0, "schedule-destruct.sh not found in provision.sh"
        assert reboot_pos > 0, "reboot not found in provision.sh"
        assert destruct_pos < reboot_pos, (
            "schedule-destruct.sh must be called BEFORE reboot in provision.sh"
        )

    def test_post_boot_check_enabled_before_reboot(self):
        """post-boot-check.service enabled before the reboot command."""
        content = self._load_provision()
        enable_pos = content.find("post-boot-check.service")
        reboot_pos = content.rfind("\nreboot")
        assert enable_pos > 0, "post-boot-check.service not found in provision.sh"
        assert reboot_pos > 0
        assert enable_pos < reboot_pos, (
            "post-boot-check.service must be enabled BEFORE reboot in provision.sh"
        )
