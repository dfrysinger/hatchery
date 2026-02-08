#!/usr/bin/env python3
"""Tests for XFCE theme configuration.

Ensures that when a theme is specified in xfwm4 config, the corresponding
package is included in the apt install list.
"""
import re
import os
import pytest


def read_hatch_yaml():
    """Read hatch.yaml content."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    yaml_path = os.path.join(script_dir, "..", "hatch.yaml")
    with open(yaml_path, "r") as f:
        return f.read()


class TestXfceTheme:
    """Test that XFCE theme configuration matches installed packages."""

    def test_yaru_theme_package_installed_when_yaru_theme_specified(self):
        """If xfwm4 config specifies Yaru theme, yaru-theme-gtk must be installed."""
        content = read_hatch_yaml()
        
        # Check if any Yaru theme variant is specified in xfwm4 config
        xfwm4_theme_match = re.search(r'xfwm4.*theme.*type="string"\s+value="(Yaru[^"]*)"', content)
        
        if xfwm4_theme_match:
            theme_name = xfwm4_theme_match.group(1)
            # If Yaru theme is used, yaru-theme-gtk must be in package list
            assert "yaru-theme-gtk" in content, \
                f"Theme '{theme_name}' requires yaru-theme-gtk package but it's not in apt install list"

    def test_theme_package_in_desktop_environment_section(self):
        """yaru-theme-gtk should be installed with desktop environment packages."""
        content = read_hatch_yaml()
        
        # Find the desktop-environment apt-get install block
        # Look for the section between "desktop-environment" and the next section
        de_match = re.search(
            r'\$S\s+\d+\s+"desktop-environment".*?apt-get install.*?xfce4.*?>>',
            content,
            re.DOTALL
        )
        
        assert de_match, "Could not find desktop-environment apt install block"
        de_block = de_match.group(0)
        
        # Check yaru-theme-gtk is in this block
        assert "yaru-theme-gtk" in de_block, \
            "yaru-theme-gtk should be installed in desktop-environment section"

    def test_xfwm4_theme_config_exists(self):
        """Verify xfwm4 theme configuration is present."""
        content = read_hatch_yaml()
        
        # Should have xfwm4 config with a theme property
        assert 'channel name="xfwm4"' in content, "xfwm4 config channel missing"
        assert 'property name="theme"' in content, "xfwm4 theme property missing"

    def test_icon_theme_package_installed(self):
        """Verify icon theme package is installed."""
        content = read_hatch_yaml()
        
        # elementary-xfce-icon-theme should be installed
        assert "elementary-xfce-icon-theme" in content, \
            "elementary-xfce-icon-theme package should be installed"
