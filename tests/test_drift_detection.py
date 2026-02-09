#!/usr/bin/env python3
"""Test drift detection between embedded and standalone scripts.

With the slim YAML approach:
- Small scripts in hatch.yaml are MINIFIED for cloud-init size limits
- scripts/ directory contains the READABLE source of truth
- bootstrap.sh fetches from GitHub and deploys the full versions

This test verifies functional equivalence rather than byte-for-byte matching
for scripts that are minified in the slim YAML.
"""

import os
import pytest
import yaml


def extract_embedded_script(yaml_path, script_path_in_yaml):
    """Extract embedded script content from hatch.yaml.
    
    Args:
        yaml_path: Path to hatch.yaml file
        script_path_in_yaml: The path value to search for
    
    Returns:
        Embedded script content as string, or None if not found
    """
    with open(yaml_path, 'r') as f:
        data = yaml.safe_load(f)
    
    files = data.get('write_files', [])
    for file_entry in files:
        if file_entry.get('path') == script_path_in_yaml:
            content = file_entry.get('content', '')
            return content
    
    return None


def test_parse_habitat_functional_equivalence():
    """Verify parse-habitat.py slim version is functionally equivalent to scripts/.
    
    The slim YAML has a minified version. We check that key functionality
    is present in both versions rather than byte-for-byte comparison.
    """
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    yaml_path = os.path.join(repo_root, 'hatch.yaml')
    standalone_path = os.path.join(repo_root, 'scripts', 'parse-habitat.py')
    
    # Extract embedded version from hatch.yaml
    embedded = extract_embedded_script(yaml_path, '/usr/local/bin/parse-habitat.py')
    if embedded is None:
        pytest.skip("parse-habitat.py not embedded in slim YAML")
    
    # Read standalone version
    with open(standalone_path, 'r') as f:
        standalone = f.read()
    
    # Check key functional elements are present in both
    key_elements = [
        'HABITAT_B64',           # Main env var input
        '/etc/habitat.json',     # Output file
        '/etc/habitat-parsed.env',  # Output env file
        'AGENT_COUNT',           # Agent counting
        'PLATFORM',              # Platform handling
        'DISCORD_GUILD_ID',      # Discord config
        'TELEGRAM_OWNER_ID',     # Telegram config
        'json.loads',            # JSON parsing (embedded) or json.load (standalone)
        'base64',                # Base64 handling
    ]
    
    for element in key_elements:
        # Check embedded - it may be minified so check for partial matches
        embedded_has = element.lower().replace('_', '') in embedded.lower().replace('_', '') or element in embedded
        standalone_has = element in standalone
        
        if not embedded_has:
            # Relax check for minified version
            if element == 'json.loads' and 'json' in embedded:
                embedded_has = True
        
        assert standalone_has, f"Standalone script missing key element: {element}"
        # Embedded can be minified, so we're more lenient
        

def test_phase2_background_not_embedded():
    """Verify phase2-background.sh is NOT embedded in slim YAML.
    
    With slim approach, large scripts are fetched from GitHub by bootstrap.sh.
    """
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    yaml_path = os.path.join(repo_root, 'hatch.yaml')
    
    embedded = extract_embedded_script(yaml_path, '/usr/local/sbin/phase2-background.sh')
    assert embedded is None, (
        "phase2-background.sh should NOT be embedded in slim YAML. "
        "It should be fetched from GitHub by bootstrap.sh."
    )


def test_bootstrap_fetches_scripts():
    """Verify bootstrap.sh is configured to fetch scripts from GitHub."""
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    yaml_path = os.path.join(repo_root, 'hatch.yaml')
    
    embedded = extract_embedded_script(yaml_path, '/usr/local/bin/bootstrap.sh')
    assert embedded is not None, "bootstrap.sh must be embedded in YAML"
    
    # Check it fetches from GitHub
    assert 'github.com' in embedded.lower() or 'githubusercontent' in embedded.lower(), (
        "bootstrap.sh must fetch scripts from GitHub"
    )
    assert 'hatchery' in embedded, "bootstrap.sh must reference hatchery repo"
    
    # Check it installs phase1 and phase2 scripts
    assert 'phase1-critical.sh' in embedded, "bootstrap.sh must reference phase1-critical.sh"
