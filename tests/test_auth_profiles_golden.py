#!/usr/bin/env python3
"""Tests for auth-profiles golden copy and safe-mode recovery resilience.

Validates that:
1. build-full-config.sh creates a golden auth-profiles.provisioned.json
2. safe-mode-recovery.sh prefers the golden copy when searching for OAuth tokens
3. safe-mode-handler.sh restores auth-profiles from golden copy before starting gateway
4. lib-health-check.sh provides hc_stop_modify_start() for safe file modification

Background: The gateway persists in-memory state (including auth-profiles.json)
to disk on SIGTERM. During safe mode recovery, the restart cycle can clobber
OAuth tokens that weren't loaded by the safe-mode config. The golden copy
pattern ensures provisioned credentials survive any number of gateway restarts.
"""

import os
import re

import pytest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")
SCRIPTS = os.path.join(REPO_ROOT, "scripts")


def _load(name):
    with open(os.path.join(SCRIPTS, name)) as f:
        return f.read()


class TestGoldenCopyProvisioning:
    """build-full-config.sh must create a golden auth-profiles copy."""

    def test_golden_copy_created(self):
        """build-full-config.sh must write auth-profiles.provisioned.json."""
        content = _load("build-full-config.sh")
        assert "auth-profiles.provisioned.json" in content, (
            "build-full-config.sh must create golden copy "
            "auth-profiles.provisioned.json alongside live copy"
        )

    def test_golden_copy_is_copy_of_live(self):
        """Golden copy must be created from the live auth-profiles.json."""
        content = _load("build-full-config.sh")
        # Must copy from auth-profiles.json to auth-profiles.provisioned.json
        # (cp command may span multiple lines with line continuation)
        assert re.search(
            r"cp.*auth-profiles\.json.*auth-profiles\.provisioned\.json",
            content,
            re.DOTALL,
        ), "Golden copy must be a cp of the live auth-profiles.json"

    def test_golden_copy_permissions(self):
        """Golden copy must have restricted permissions (600)."""
        content = _load("build-full-config.sh")
        assert re.search(
            r"(chmod 600|ensure_bot_file).*provisioned", content
        ), "Golden copy must have 600 permissions"


class TestRecoveryReadsGolden:
    """safe-mode-recovery.sh must prefer the golden copy for OAuth lookups."""

    def test_provisioned_searched_first(self):
        """check_oauth_profile must search provisioned copy before live."""
        content = _load("safe-mode-recovery.sh")
        provisioned_pos = content.find("auth-profiles.provisioned.json")
        live_pos = content.find(
            "auth-profiles.json",
            provisioned_pos + 1 if provisioned_pos >= 0 else 0,
        )
        assert provisioned_pos >= 0, (
            "safe-mode-recovery.sh must reference auth-profiles.provisioned.json"
        )
        assert provisioned_pos < live_pos, (
            "Provisioned golden copy must be searched BEFORE live copy "
            "in check_oauth_profile()"
        )


class TestHandlerRestoresAuth:
    """safe-mode-handler.sh must restore auth from golden copy on restart."""

    def test_handler_restores_auth_profiles(self):
        """Handler must restore auth-profiles from provisioned copy."""
        content = _load("safe-mode-handler.sh")
        assert "auth-profiles.provisioned.json" in content, (
            "safe-mode-handler.sh must reference golden auth-profiles copy"
        )

    def test_handler_uses_stop_modify_start(self):
        """Handler must use hc_stop_modify_start instead of hc_restart_and_wait."""
        content = _load("safe-mode-handler.sh")
        # restart_and_verify should use stop_modify_start, not restart_and_wait
        # Find the restart_and_verify function
        func_match = re.search(
            r"restart_and_verify\(\).*?^}", content, re.MULTILINE | re.DOTALL
        )
        assert func_match, "Cannot find restart_and_verify function"
        func_body = func_match.group()
        assert "hc_stop_modify_start" in func_body, (
            "restart_and_verify must use hc_stop_modify_start "
            "(not hc_restart_and_wait) to prevent auth-profiles clobber"
        )
        assert "hc_restart_and_wait" not in func_body, (
            "restart_and_verify must NOT use hc_restart_and_wait "
            "(gateway SIGTERM clobbers auth-profiles)"
        )


class TestStopModifyStart:
    """lib-health-check.sh must provide hc_stop_modify_start()."""

    def test_function_exists(self):
        """hc_stop_modify_start must be defined."""
        content = _load("lib-health-check.sh")
        assert re.search(
            r"^hc_stop_modify_start\(\)", content, re.MULTILINE
        ), "lib-health-check.sh must define hc_stop_modify_start()"

    def test_calls_stop_then_start(self):
        """hc_stop_modify_start must call stop, then callback, then start."""
        content = _load("lib-health-check.sh")
        func_match = re.search(
            r"hc_stop_modify_start\(\).*?^}",
            content,
            re.MULTILINE | re.DOTALL,
        )
        assert func_match, "Cannot find hc_stop_modify_start function"
        func_body = func_match.group()
        stop_pos = func_body.find("hc_stop_service")
        callback_pos = func_body.find('"$callback"')
        start_pos = func_body.find("hc_start_service")
        assert stop_pos >= 0, "Must call hc_stop_service"
        assert callback_pos >= 0, "Must call callback"
        assert start_pos >= 0, "Must call hc_start_service"
        assert stop_pos < callback_pos < start_pos, (
            "Order must be: stop → callback → start"
        )

    def test_start_service_exists(self):
        """hc_start_service must be defined (complement of hc_stop_service)."""
        content = _load("lib-health-check.sh")
        assert re.search(
            r"^hc_start_service\(\)", content, re.MULTILINE
        ), "lib-health-check.sh must define hc_start_service()"
