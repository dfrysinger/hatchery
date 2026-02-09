#!/usr/bin/env python3
"""Test drift detection between embedded and standalone scripts.

This module ensures that embedded scripts in hatch.yaml stay synchronized
with their standalone counterparts in scripts/.
"""

import os
import re
import yaml


def extract_embedded_script(yaml_path, script_path_in_yaml):
    """Extract embedded script content from hatch.yaml.
    
    Args:
        yaml_path: Path to hatch.yaml file
        script_path_in_yaml: The path value to search for (e.g. "/usr/local/bin/parse-habitat.py")
    
    Returns:
        Embedded script content as string (with proper newlines)
    """
    with open(yaml_path, 'r') as f:
        data = yaml.safe_load(f)
    
    # Find the file entry in the write_files list (cloud-init format)
    files = data.get('write_files', [])
    for file_entry in files:
        if file_entry.get('path') == script_path_in_yaml:
            content = file_entry.get('content', '')
            # Content is already a string with newlines preserved by YAML
            return content
    
    raise ValueError(f"Script {script_path_in_yaml} not found in {yaml_path}")


def test_parse_habitat_drift():
    """Verify parse-habitat.py in hatch.yaml matches scripts/parse-habitat.py."""
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    yaml_path = os.path.join(repo_root, 'hatch.yaml')
    standalone_path = os.path.join(repo_root, 'scripts', 'parse-habitat.py')
    
    # Extract embedded version from hatch.yaml
    embedded = extract_embedded_script(yaml_path, '/usr/local/bin/parse-habitat.py')
    
    # Read standalone version
    with open(standalone_path, 'r') as f:
        standalone = f.read()
    
    # Compare byte-for-byte
    if embedded != standalone:
        # Show first difference for debugging
        lines_embedded = embedded.splitlines()
        lines_standalone = standalone.splitlines()
        
        diff_report = []
        max_lines = max(len(lines_embedded), len(lines_standalone))
        
        for i in range(max_lines):
            line_e = lines_embedded[i] if i < len(lines_embedded) else "[MISSING]"
            line_s = lines_standalone[i] if i < len(lines_standalone) else "[MISSING]"
            
            if line_e != line_s:
                diff_report.append(f"Line {i+1} differs:")
                diff_report.append(f"  Embedded:   {repr(line_e)}")
                diff_report.append(f"  Standalone: {repr(line_s)}")
                if len(diff_report) >= 20:  # Limit output
                    diff_report.append("... (additional differences omitted)")
                    break
        
        raise AssertionError(
            f"DRIFT DETECTED: parse-habitat.py differs between hatch.yaml and scripts/\n\n"
            + "\n".join(diff_report) + "\n\n"
            + "INSTRUCTIONS: Keep hatch.yaml and scripts/parse-habitat.py synchronized.\n"
            + "Update both files when making changes to parse-habitat logic."
        )
