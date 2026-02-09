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


def test_phase2_background_drift():
    """Verify phase2-background.sh in hatch.yaml matches scripts/phase2-background.sh.
    
    Note: Standalone script has a documentation header (13 lines) that is not present
    in the embedded version. We strip this header before comparison since it's purely
    for developer reference and not needed in the cloud-init embedded version.
    """
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    yaml_path = os.path.join(repo_root, 'hatch.yaml')
    standalone_path = os.path.join(repo_root, 'scripts', 'phase2-background.sh')
    
    # Extract embedded version from hatch.yaml
    embedded = extract_embedded_script(yaml_path, '/usr/local/sbin/phase2-background.sh')
    
    # Read standalone version
    with open(standalone_path, 'r') as f:
        standalone_raw = f.read()
    
    # Strip documentation header from standalone (lines 2-14: comments between shebang and actual code)
    # Header pattern: starts with "# ========" after shebang, ends before "set -a; source"
    lines = standalone_raw.splitlines(keepends=True)
    if len(lines) > 14 and lines[1].startswith('# ====='):
        # Find where header ends (first line that's not a comment or blank after shebang)
        header_end = 1
        for i in range(1, len(lines)):
            line = lines[i].strip()
            if line and not line.startswith('#'):
                header_end = i
                break
        # Reconstruct: shebang + code (without header)
        standalone = lines[0] + ''.join(lines[header_end:])
    else:
        # No header found, use as-is
        standalone = standalone_raw
    
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
            f"DRIFT DETECTED: phase2-background.sh differs between hatch.yaml and scripts/\n\n"
            + "\n".join(diff_report) + "\n\n"
            + "INSTRUCTIONS: Keep hatch.yaml and scripts/phase2-background.sh synchronized.\n"
            + "Update both files when making changes to phase2 provisioning logic.\n"
            + "Note: Documentation header in standalone script is automatically stripped during comparison."
        )
