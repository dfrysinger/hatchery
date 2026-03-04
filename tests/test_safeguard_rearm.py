"""Tests for safeguard .path unit re-arming and failure notification.

Bug discovered 2026-03-04: The .path unit deactivated after its first trigger
and was never restarted. When the service entered a crash loop 10 days later,
the unhealthy marker was written but nobody was listening.

These tests verify:
1. safe-mode-handler.sh has an EXIT trap that re-arms the .path unit
2. safe-mode-handler.sh sends a notification on non-zero exit
3. gateway-health-check.sh re-arms the .path unit on successful check
"""

import re

import pytest


HANDLER_PATH = "scripts/safe-mode-handler.sh"
HEALTH_CHECK_PATH = "scripts/gateway-health-check.sh"


@pytest.fixture
def handler_source():
    with open(HANDLER_PATH) as f:
        return f.read()


@pytest.fixture
def health_check_source():
    with open(HEALTH_CHECK_PATH) as f:
        return f.read()


class TestHandlerExitTrap:
    """safe-mode-handler.sh must have an EXIT trap that re-arms the .path unit."""

    def test_has_exit_trap(self, handler_source):
        """Handler must register a trap on EXIT."""
        assert "trap " in handler_source
        assert "EXIT" in handler_source

    def test_trap_restarts_path_unit(self, handler_source):
        """EXIT trap must restart the safeguard .path unit."""
        assert "openclaw-safeguard" in handler_source
        assert "systemctl restart" in handler_source or "systemctl start" in handler_source

    def test_trap_handles_group_suffix(self, handler_source):
        """Path unit name must include GROUP suffix when set."""
        assert "openclaw-safeguard${GROUP:+-$GROUP}.path" in handler_source

    def test_trap_is_rearm_only(self, handler_source):
        """EXIT trap should ONLY re-arm — notifications belong in failure paths."""
        trap_match = re.search(
            r"_handler_exit\(\)\s*\{(.+?)\n\}",
            handler_source,
            re.DOTALL,
        )
        assert trap_match, "Could not find _handler_exit function"
        trap_body = trap_match.group(1)
        assert "notify_send_message" not in trap_body, \
            "Trap should not send notifications — failure paths handle that"
        assert "systemctl" in trap_body, \
            "Trap must re-arm the .path unit"


class TestFailureNotification:
    """All failure paths must notify with journal errors and lockout."""

    def test_has_shared_notify_function(self, handler_source):
        """Handler should have a single notification function for all failure paths."""
        assert "_notify_critical_failure" in handler_source

    def test_notify_includes_journal_errors(self, handler_source):
        """Notification must include actual error lines from the journal."""
        assert "hc_service_logs" in handler_source

    def test_notify_includes_ssh_command(self, handler_source):
        """Notification must include SSH command for manual recovery."""
        assert "ssh bot@" in handler_source or "ssh " in handler_source

    def test_exhausted_attempts_notifies(self, handler_source):
        """Exhausted-attempts path (exit 2 early) must call notification."""
        # Find the exhausted-attempts section
        exhausted_idx = handler_source.index("exhausted")
        # The notification call should be nearby (within ~30 lines)
        nearby = handler_source[exhausted_idx:exhausted_idx + 900]
        assert "_notify_critical_failure" in nearby

    def test_restart_failure_notifies(self, handler_source):
        """restart_and_verify failure path must call notification."""
        failure_idx = handler_source.index("SERVICE WON'T START")
        nearby = handler_source[failure_idx:failure_idx + 600]
        assert "_notify_critical_failure" in nearby

    def test_lockout_on_all_failure_paths(self, handler_source):
        """All notification paths must use lockout marker."""
        # Count lockout checks — should be at least 2 (exhausted + restart failure)
        lockout_count = handler_source.count("critical-notified")
        assert lockout_count >= 2, \
            f"Expected lockout checks on at least 2 failure paths, found {lockout_count}"


class TestHealthCheckRearm:
    """gateway-health-check.sh must re-arm .path unit on successful check."""

    def test_rearms_on_success(self, health_check_source):
        """Health check must restart safeguard .path after HTTP passes."""
        # Must appear in the success path (near "HTTP CHECK PASSED")
        success_section = health_check_source[
            health_check_source.index("HTTP responding"):
            health_check_source.index("HTTP CHECK PASSED")
        ]
        assert "openclaw-safeguard" in success_section
        assert "systemctl" in success_section

    def test_rearm_is_best_effort(self, health_check_source):
        """Re-arm must not fail the health check if systemctl fails."""
        success_section = health_check_source[
            health_check_source.index("HTTP responding"):
            health_check_source.index("HTTP CHECK PASSED")
        ]
        # The re-arm block (variable assignment + systemctl calls) must be
        # guarded so failures don't abort the health check under set -e.
        # Look for the guarding pattern in the overall block, not per-line.
        assert "openclaw-safeguard" in success_section, \
            "Safeguard re-arm must appear in the success path"
        # Every systemctl line in this section must be guarded
        systemctl_lines = [
            line.strip() for line in success_section.split("\n")
            if "systemctl" in line and line.strip() and not line.strip().startswith("#")
        ]
        assert systemctl_lines, "No systemctl calls in success path"
        for line in systemctl_lines:
            assert "2>/dev/null" in line or "|| true" in line, \
                f"Re-arm systemctl must be guarded: {line}"


class TestMarkerCleanupBeforeRearm:
    """Unhealthy marker must be removed BEFORE the EXIT trap re-arms the .path unit.

    If the marker still exists when the .path unit restarts, it would
    immediately re-trigger the handler → infinite loop.
    """

    def test_marker_cleanup_in_handler_body(self, handler_source):
        """All exit paths must clean up HC_UNHEALTHY_MARKER before exiting."""
        # Every 'exit 0' and 'exit 2' should have a preceding rm -f of the marker
        # (either directly or via restart_and_verify which also cleans it)
        cleanup_count = handler_source.count("rm -f \"$HC_UNHEALTHY_MARKER\"")
        assert cleanup_count >= 2, \
            f"Expected at least 2 marker cleanups (success + failure paths), found {cleanup_count}"

    def test_trap_does_not_delete_marker(self, handler_source):
        """The EXIT trap itself must NOT delete the marker — handler body does that."""
        # Find the trap function
        trap_match = re.search(
            r"_handler_exit\(\)\s*\{(.+?)\n\}",
            handler_source,
            re.DOTALL,
        )
        assert trap_match, "Could not find _handler_exit function"
        trap_body = trap_match.group(1)
        assert "HC_UNHEALTHY_MARKER" not in trap_body, \
            "EXIT trap must not touch the unhealthy marker — handler body handles it"
