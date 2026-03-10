#!/usr/bin/env python3
"""Focused tests for lib-env.sh helpers."""

import os
import subprocess
import tempfile


LIB_ENV = os.path.join(os.path.dirname(__file__), "..", "scripts", "lib-env.sh")


def run_lib_env(script_body: str) -> subprocess.CompletedProcess:
    script = f"""
set -euo pipefail
source "{LIB_ENV}"
{script_body}
"""
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True)


def test_env_load_file_safe_accepts_export_with_multiple_spaces():
    with tempfile.TemporaryDirectory() as tmpdir:
        env_file = os.path.join(tmpdir, "sample.env")
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("export   SAMPLE_KEY=sample-value\n")

        result = run_lib_env(f'env_load_file_safe "{env_file}"\nprintf "%s" "$SAMPLE_KEY"\n')

    assert result.returncode == 0, result.stderr
    assert result.stdout == "sample-value"


def test_env_load_file_safe_accepts_export_with_tabs():
    with tempfile.TemporaryDirectory() as tmpdir:
        env_file = os.path.join(tmpdir, "sample.env")
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("export\tTAB_KEY=tab-value\n")

        result = run_lib_env(f'env_load_file_safe "{env_file}"\nprintf "%s" "$TAB_KEY"\n')

    assert result.returncode == 0, result.stderr
    assert result.stdout == "tab-value"
