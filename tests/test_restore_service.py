#!/usr/bin/env python3
"""
Tests for the openclaw-restore.service systemd unit.

This service must run restore-openclaw-state.sh BEFORE clawdbot.service starts,
ensuring memory and transcripts are available on first bot message.
"""
import re
import os
import pytest

# Path to the hatch.yaml file
HATCH_YAML = os.path.join(os.path.dirname(__file__), '..', 'hatch.yaml')
PHASE2_SCRIPT = os.path.join(os.path.dirname(__file__), '..', 'scripts', 'phase2-background.sh')


def read_hatch_yaml():
    """Read the hatch.yaml file content."""
    with open(HATCH_YAML, 'r') as f:
        return f.read()


def read_phase2_script():
    """Read the phase2-background.sh script content."""
    with open(PHASE2_SCRIPT, 'r') as f:
        return f.read()


class TestRestoreServiceDefinition:
    """Tests for openclaw-restore.service definition in hatch.yaml."""

    def test_restore_service_exists(self):
        """The openclaw-restore.service must be defined in hatch.yaml."""
        content = read_hatch_yaml()
        assert 'openclaw-restore.service' in content, \
            "openclaw-restore.service must be defined in hatch.yaml"

    def test_restore_service_runs_restore_script(self):
        """Service must execute restore-openclaw-state.sh."""
        content = read_hatch_yaml()
        # Look for ExecStart with the restore script
        assert re.search(r'ExecStart.*restore-openclaw-state\.sh', content), \
            "openclaw-restore.service must run restore-openclaw-state.sh"

    def test_restore_service_is_oneshot(self):
        """Service must be Type=oneshot (runs once per boot)."""
        content = read_hatch_yaml()
        # Find the service definition block (starts with - path: ...service)
        service_match = re.search(
            r'-\s+path:\s+/etc/systemd/system/openclaw-restore\.service.*?(?=\n  -\s+path:|\Z)',
            content,
            re.DOTALL
        )
        assert service_match, "Could not find openclaw-restore.service definition"
        service_block = service_match.group(0)
        assert 'Type=oneshot' in service_block, \
            "openclaw-restore.service must be Type=oneshot"

    def test_restore_service_has_timeout(self):
        """Service must have a reasonable timeout (30-120 seconds)."""
        content = read_hatch_yaml()
        service_match = re.search(
            r'-\s+path:\s+/etc/systemd/system/openclaw-restore\.service.*?(?=\n  -\s+path:|\Z)',
            content,
            re.DOTALL
        )
        assert service_match, "Could not find openclaw-restore.service definition"
        service_block = service_match.group(0)
        
        # Look for TimeoutStartSec or TimeoutSec
        timeout_match = re.search(r'Timeout(?:Start)?Sec=(\d+)', service_block)
        assert timeout_match, "openclaw-restore.service must have a timeout configured"
        
        timeout_val = int(timeout_match.group(1))
        assert 30 <= timeout_val <= 120, \
            f"Timeout should be 30-120 seconds, got {timeout_val}"

    def test_restore_service_remains_after_exit(self):
        """Service must have RemainAfterExit=yes to prevent re-runs."""
        content = read_hatch_yaml()
        service_match = re.search(
            r'-\s+path:\s+/etc/systemd/system/openclaw-restore\.service.*?(?=\n  -\s+path:|\Z)',
            content,
            re.DOTALL
        )
        assert service_match, "Could not find openclaw-restore.service definition"
        service_block = service_match.group(0)
        assert 'RemainAfterExit=yes' in service_block, \
            "openclaw-restore.service must have RemainAfterExit=yes"


class TestClawdbotServiceDependencies:
    """Tests for clawdbot.service depending on restore service."""

    def test_clawdbot_after_restore_service(self):
        """clawdbot.service must start After=openclaw-restore.service."""
        content = read_hatch_yaml()
        # Find clawdbot.service definitions (there are two in hatch.yaml)
        # Both should have the dependency
        
        # Look for After= lines that include openclaw-restore.service
        after_matches = re.findall(r'After=.*openclaw-restore\.service', content)
        assert len(after_matches) >= 1, \
            "clawdbot.service must have After=openclaw-restore.service"

    def test_clawdbot_wants_restore_service(self):
        """clawdbot.service should Want the restore service."""
        content = read_hatch_yaml()
        # Wants= is preferred over Requires= for graceful degradation
        wants_matches = re.findall(r'Wants=.*openclaw-restore\.service', content)
        assert len(wants_matches) >= 1, \
            "clawdbot.service should have Wants=openclaw-restore.service"


class TestPhase2NoDoubleRestore:
    """Tests that phase2 doesn't run restore redundantly."""

    def test_phase2_no_standalone_restore_call(self):
        """Phase 2 should not call restore-openclaw-state.sh directly anymore."""
        content = read_phase2_script()
        
        # The restore script should NOT be called as a standalone command
        # It's now handled by the systemd service before clawdbot starts
        # 
        # We're looking for lines like:
        #   /usr/local/bin/restore-openclaw-state.sh
        #   restore-openclaw-state.sh
        # 
        # But NOT in comments
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

    def test_service_enabled_in_phase2(self):
        """The restore service should be enabled during phase2 setup."""
        content = read_hatch_yaml()
        # Look for systemctl enable openclaw-restore
        assert re.search(r'systemctl\s+enable\s+openclaw-restore', content), \
            "openclaw-restore.service should be enabled during setup"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
