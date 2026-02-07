#!/usr/bin/env python3
"""
Tests for x11vnc.service systemd unit configuration.

Validates that x11vnc.service:
- AC1/AC3: Has ConditionPathExists for phase2-complete marker (won't start during provisioning)
- AC2: Has WantedBy=desktop.service (starts automatically after reboot)
- AC5: Has correct dependencies (After/Requires desktop.service)

Issue #80: x11vnc fails to start after reboot (dependency chain broken)
"""
import os
import re
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_hatch_yaml():
    """Read hatch.yaml content."""
    path = os.path.join(REPO_ROOT, "hatch.yaml")
    with open(path, 'r') as f:
        return f.read()


def extract_x11vnc_service_unit(content: str) -> str:
    """Extract the x11vnc.service unit file content from hatch.yaml.
    
    Looks for the heredoc pattern:
        cat > /etc/systemd/system/x11vnc.service <<SVC
        ... unit content ...
        SVC
    """
    # Match the heredoc for x11vnc.service
    pattern = r'cat\s*>\s*/etc/systemd/system/x11vnc\.service\s*<<\s*SVC\s*\n(.*?)\n\s*SVC'
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        pytest.fail("Could not find x11vnc.service heredoc in hatch.yaml")
    return match.group(1)


class TestX11VNCServiceDependencies:
    """Validate x11vnc.service unit file dependencies."""

    def test_requires_desktop_service(self):
        """x11vnc must require desktop.service to ensure display is ready."""
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        assert "Requires=desktop.service" in unit, (
            "x11vnc.service must have Requires=desktop.service in [Unit] section"
        )

    def test_after_desktop_service(self):
        """x11vnc must start after desktop.service."""
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        assert "After=desktop.service" in unit, (
            "x11vnc.service must have After=desktop.service in [Unit] section"
        )


class TestX11VNCServicePhase2Guard:
    """Validate x11vnc won't start during phase2 provisioning (AC1, AC3)."""

    def test_condition_path_exists(self):
        """x11vnc must have ConditionPathExists for phase2-complete marker.
        
        This is defense-in-depth: even if x11vnc is somehow triggered during
        phase2, the condition prevents it from starting until the marker exists.
        """
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        # Look for ConditionPathExists with the phase2-complete marker
        assert "ConditionPathExists=/var/lib/init-status/phase2-complete" in unit, (
            "x11vnc.service must have ConditionPathExists=/var/lib/init-status/phase2-complete\n"
            "This prevents VNC from starting during initial provisioning (security)."
        )


class TestX11VNCServiceAutostart:
    """Validate x11vnc starts automatically after reboot (AC2)."""

    def test_wanted_by_desktop_service(self):
        """x11vnc must be wanted by desktop.service to start after reboot.
        
        This ensures x11vnc is pulled in when desktop.service starts,
        which happens automatically after the post-provisioning reboot.
        """
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        # Check [Install] section has WantedBy
        # The unit should have WantedBy=desktop.service (not multi-user.target)
        assert "WantedBy=desktop.service" in unit, (
            "x11vnc.service must have WantedBy=desktop.service in [Install] section\n"
            "This makes x11vnc start when desktop starts (after reboot)."
        )

    def test_not_wanted_by_multi_user_target(self):
        """x11vnc must NOT be WantedBy multi-user.target (security regression).
        
        PR #79 removed WantedBy=multi-user.target to prevent VNC from starting
        during provisioning. We must not reintroduce this.
        """
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        # Ensure WantedBy=multi-user.target is NOT present
        if "WantedBy=multi-user.target" in unit:
            pytest.fail(
                "SECURITY REGRESSION: x11vnc.service must NOT have WantedBy=multi-user.target\n"
                "This would expose unencrypted VNC during the provisioning window.\n"
                "Use WantedBy=desktop.service instead."
            )


class TestX11VNCServiceComplete:
    """End-to-end validation of x11vnc.service unit file."""

    def test_unit_file_structure(self):
        """Validate complete unit file has all required sections."""
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        # Must have all three sections
        assert "[Unit]" in unit, "Missing [Unit] section"
        assert "[Service]" in unit, "Missing [Service] section"
        assert "[Install]" in unit, "Missing [Install] section"

    def test_service_type(self):
        """Validate service is Type=simple (x11vnc runs in foreground)."""
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        assert "Type=simple" in unit, "x11vnc.service should be Type=simple"

    def test_restart_policy(self):
        """Validate service has restart policy for resilience."""
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        assert "Restart=always" in unit, "x11vnc.service should have Restart=always"

    def test_display_environment(self):
        """Validate DISPLAY is set to match xvfb/desktop."""
        content = read_hatch_yaml()
        unit = extract_x11vnc_service_unit(content)
        
        # Should use :10 to match xvfb configuration
        assert "Environment=DISPLAY=:10" in unit, (
            "x11vnc.service must set DISPLAY=:10 to match xvfb configuration"
        )
