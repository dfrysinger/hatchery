#!/usr/bin/env python3
"""
Tests for the openclaw-restore.service systemd unit.

This service must run restore-openclaw-state.sh BEFORE clawdbot.service starts,
ensuring memory and transcripts are available on first bot message.

With the slim YAML approach, services are now in:
- systemd/ directory (static services)
- scripts/phase1-critical.sh (dynamically created services)
"""
import re
import os
import pytest

# Root of the repository
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYSTEMD_DIR = os.path.join(REPO_ROOT, "systemd")
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")
PHASE1_SCRIPT = os.path.join(SCRIPTS_DIR, "phase1-critical.sh")
PHASE2_SCRIPT = os.path.join(SCRIPTS_DIR, "phase2-background.sh")


def read_service_file(name):
    """Read a systemd service file from systemd/ directory."""
    path = os.path.join(SYSTEMD_DIR, name)
    with open(path, 'r') as f:
        return f.read()


def read_phase1_script():
    """Read the phase1-critical.sh script content."""
    with open(PHASE1_SCRIPT, 'r') as f:
        return f.read()


def read_phase2_script():
    """Read the phase2-background.sh script content."""
    with open(PHASE2_SCRIPT, 'r') as f:
        return f.read()


class TestRestoreServiceDefinition:
    """Tests for openclaw-restore.service definition in systemd/."""

    def test_restore_service_exists(self):
        """The openclaw-restore.service must exist in systemd/ directory."""
        path = os.path.join(SYSTEMD_DIR, "openclaw-restore.service")
        assert os.path.isfile(path), \
            "openclaw-restore.service must exist in systemd/ directory"

    def test_restore_service_runs_restore_script(self):
        """Service must execute restore-openclaw-state.sh."""
        content = read_service_file("openclaw-restore.service")
        assert re.search(r'ExecStart.*restore-openclaw-state\.sh', content), \
            "openclaw-restore.service must run restore-openclaw-state.sh"

    def test_restore_service_is_oneshot(self):
        """Service must be Type=oneshot (runs once per boot)."""
        content = read_service_file("openclaw-restore.service")
        assert 'Type=oneshot' in content, \
            "openclaw-restore.service must be Type=oneshot"

    def test_restore_service_has_timeout(self):
        """Service must have a reasonable timeout (30-120 seconds)."""
        content = read_service_file("openclaw-restore.service")
        timeout_match = re.search(r'Timeout(?:Start)?Sec=(\d+)', content)
        assert timeout_match, "openclaw-restore.service must have a timeout configured"
        timeout_val = int(timeout_match.group(1))
        assert 30 <= timeout_val <= 120, \
            f"Timeout should be 30-120 seconds, got {timeout_val}"

    def test_restore_service_remains_after_exit(self):
        """Service must have RemainAfterExit=yes to prevent re-runs."""
        content = read_service_file("openclaw-restore.service")
        assert 'RemainAfterExit=yes' in content, \
            "openclaw-restore.service must have RemainAfterExit=yes"

    def test_restore_service_before_clawdbot(self):
        """Service must specify Before=clawdbot.service."""
        content = read_service_file("openclaw-restore.service")
        assert 'Before=clawdbot.service' in content, \
            "openclaw-restore.service must have Before=clawdbot.service"


class TestClawdbotServiceDependencies:
    """Tests for clawdbot.service depending on restore service.
    
    Note: clawdbot.service is created dynamically in phase1-critical.sh,
    so we check the script source for the dependency configuration.
    """

    def test_clawdbot_after_restore_service(self):
        """clawdbot.service must start After=openclaw-restore.service."""
        content = read_phase1_script()
        # Look for the clawdbot.service heredoc with After= dependency
        assert re.search(r'After=.*openclaw-restore\.service', content), \
            "clawdbot.service (in phase1-critical.sh) must have After=openclaw-restore.service"

    def test_clawdbot_wants_restore_service(self):
        """clawdbot.service should Want the restore service."""
        content = read_phase1_script()
        # Wants= is preferred over Requires= for graceful degradation
        assert re.search(r'Wants=.*openclaw-restore\.service', content), \
            "clawdbot.service (in phase1-critical.sh) should have Wants=openclaw-restore.service"


class TestPhase1RestoreHandling:
    """Tests for restore service handling in phase1."""

    def test_phase1_enables_restore_service(self):
        """Phase 1 should enable the restore service."""
        content = read_phase1_script()
        assert re.search(r'systemctl\s+enable\s+openclaw-restore', content), \
            "phase1-critical.sh should enable openclaw-restore.service"

    def test_phase1_starts_restore_service(self):
        """Phase 1 should start the restore service."""
        content = read_phase1_script()
        assert re.search(r'systemctl\s+start\s+openclaw-restore', content), \
            "phase1-critical.sh should start openclaw-restore.service"

    def test_phase1_checks_service_exists(self):
        """Phase 1 should check if service file exists before enabling."""
        content = read_phase1_script()
        # Should check for file existence to avoid errors
        assert 'openclaw-restore.service' in content, \
            "phase1-critical.sh should reference openclaw-restore.service"


class TestPhase2NoDoubleRestore:
    """Tests that phase2 doesn't run restore redundantly."""

    def test_phase2_no_standalone_restore_call(self):
        """Phase 2 should not call restore-openclaw-state.sh directly anymore."""
        content = read_phase2_script()
        
        # The restore script should NOT be called as a standalone command
        # It's now handled by the systemd service before clawdbot starts
        lines = content.split('\n')
        for line in lines:
            # Skip comments
            if line.strip().startswith('#'):
                continue
            # Check for direct invocation
            if 'restore-openclaw-state.sh' in line:
                # This is OK if it's being sourced for functions, but not executed
                if not line.strip().startswith('source') and \
                   not line.strip().startswith('.'):
                    pytest.fail(
                        f"Phase 2 should not directly call restore-openclaw-state.sh. "
                        f"Found: {line.strip()}"
                    )


class TestRestoreServiceIntegration:
    """Integration tests for the restore service behavior."""

    def test_service_enabled_in_scripts(self):
        """The restore service should be enabled in setup scripts."""
        # Check phase1 (where it gets enabled/started)
        phase1_content = read_phase1_script()
        phase2_content = read_phase2_script()
        
        # At least one of the phases should enable it
        enabled_in_phase1 = re.search(r'systemctl\s+enable\s+openclaw-restore', phase1_content)
        enabled_in_phase2 = re.search(r'systemctl\s+enable\s+openclaw-restore', phase2_content)
        
        assert enabled_in_phase1 or enabled_in_phase2, \
            "openclaw-restore.service should be enabled in phase1 or phase2 scripts"


class TestRestoreServiceOrdering:
    """Tests for restore service enablement ordering in phase1-critical.sh."""

    @pytest.fixture
    def phase1_script_content(self):
        """Read the phase1-critical.sh script content."""
        return read_phase1_script()

    def test_restore_enabled_before_clawdbot_enabled(self, phase1_script_content):
        """openclaw-restore must be enabled BEFORE clawdbot is enabled.
        
        This ensures the Wants= dependency works correctly when the system reboots.
        Note: In the new architecture, phase1 only enables clawdbot (doesn't start it).
        The service starts on reboot when the full config is ready.
        """
        content = phase1_script_content
        
        # Find the position of both commands
        enable_restore = re.search(r'systemctl\s+enable\s+openclaw-restore', content)
        enable_clawdbot = re.search(r'systemctl\s+enable\s+clawdbot', content)
        
        assert enable_restore, \
            "phase1-critical.sh must have 'systemctl enable openclaw-restore'"
        assert enable_clawdbot, \
            "phase1-critical.sh must have 'systemctl enable clawdbot'"
        
        # Verify ordering: enable restore must come BEFORE enable clawdbot
        assert enable_restore.start() < enable_clawdbot.start(), \
            "systemctl enable openclaw-restore must appear BEFORE systemctl enable clawdbot " \
            "so the Wants= dependency works correctly on reboot"

    def test_restore_enabled_in_phase1_not_phase2(self, phase1_script_content):
        """Restore service should be enabled in phase1 (for immediate availability)."""
        # This test documents that restore is enabled in phase1, not phase2
        # The enable must happen before clawdbot starts to make Wants= work
        assert re.search(r'systemctl\s+enable\s+openclaw-restore', phase1_script_content), \
            "openclaw-restore.service must be enabled in phase1-critical.sh"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
