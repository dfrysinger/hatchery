#!/usr/bin/env python3
"""Tests for schedule-destruct.sh persistent timer creation.

Validates that schedule-destruct.sh creates persistent systemd timer/service
unit files instead of transient systemd-run timers. Persistent timers survive
reboots, fixing the race condition where runcmd entries execute during shutdown.
"""

import os
import subprocess
import tempfile

import pytest


def extract_script():
    """Read schedule-destruct.sh from scripts/ directory."""
    script_path = os.path.join(
        os.path.dirname(__file__), "..", "scripts", "schedule-destruct.sh"
    )
    with open(script_path) as f:
        return f.read()


def make_test_script(tmp_dir, destruct_mins="180", extra_env=None):
    """Create a test-friendly version of schedule-destruct.sh.

    Stubs out systemctl and sources a fake env instead of /etc/droplet.env.
    """
    script = extract_script()

    # Create fake droplet.env
    env_file = os.path.join(tmp_dir, "droplet.env")
    with open(env_file, "w") as f:
        f.write("")

    # Create fake habitat-parsed.env
    parsed_env = os.path.join(tmp_dir, "habitat-parsed.env")
    with open(parsed_env, "w") as f:
        f.write(f'DESTRUCT_MINS="{destruct_mins}"\n')
        if extra_env:
            f.write(extra_env)

    # Create fake lib-env.sh
    lib_env = os.path.join(tmp_dir, "lib-env.sh")
    with open(lib_env, "w") as f:
        f.write(
            """#!/bin/bash
d() { echo "$1" | base64 -d 2>/dev/null; }
env_load() { true; }
"""
        )

    # Create systemd output directory
    systemd_dir = os.path.join(tmp_dir, "systemd")
    os.makedirs(systemd_dir, exist_ok=True)

    # Create fake systemctl
    systemctl_log = os.path.join(tmp_dir, "systemctl.log")
    systemctl_bin = os.path.join(tmp_dir, "systemctl")
    with open(systemctl_bin, "w") as f:
        f.write(
            f"""#!/bin/bash
echo "$@" >> {systemctl_log}
"""
        )
    os.chmod(systemctl_bin, 0o755)

    # Patch the script
    patched = script
    # Replace /etc paths with tmp paths
    patched = patched.replace("/etc/droplet.env", env_file)
    patched = patched.replace("/etc/habitat-parsed.env", parsed_env)
    patched = patched.replace("/etc/systemd/system/", f"{systemd_dir}/")
    # Replace lib-env.sh sourcing
    patched = patched.replace(
        'for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do\n'
        '  [ -f "$_lib_path/lib-env.sh" ] && { source "$_lib_path/lib-env.sh"; break; }\n'
        "done",
        f'source "{lib_env}"',
    )
    # Replace systemctl with fake
    patched = patched.replace("systemctl ", f"{systemctl_bin} ")
    # Remove python3 parse-habitat.py call
    patched = patched.replace(
        "python3 /usr/local/bin/parse-habitat.py", "true"
    )

    test_script = os.path.join(tmp_dir, "schedule-destruct.sh")
    with open(test_script, "w") as f:
        f.write(patched)
    os.chmod(test_script, 0o755)

    return test_script, systemctl_log, systemd_dir


class TestScheduleDestructPersistentTimer:
    """schedule-destruct.sh must create persistent systemd unit files."""

    def test_creates_service_unit(self):
        """Service unit file created for kill-droplet.sh."""
        with tempfile.TemporaryDirectory() as tmp:
            script, _, systemd_dir = make_test_script(tmp, "180")
            result = subprocess.run(
                ["bash", script], capture_output=True, text=True
            )
            assert result.returncode == 0, f"stderr: {result.stderr}"
            service_path = os.path.join(systemd_dir, "self-destruct.service")
            assert os.path.exists(service_path), "self-destruct.service not created"
            content = open(service_path).read()
            assert "kill-droplet.sh" in content
            assert "Type=oneshot" in content

    def test_creates_timer_unit(self):
        """Timer unit file created with correct OnBootSec."""
        with tempfile.TemporaryDirectory() as tmp:
            script, _, systemd_dir = make_test_script(tmp, "180")
            result = subprocess.run(
                ["bash", script], capture_output=True, text=True
            )
            assert result.returncode == 0, f"stderr: {result.stderr}"
            timer_path = os.path.join(systemd_dir, "self-destruct.timer")
            assert os.path.exists(timer_path), "self-destruct.timer not created"
            content = open(timer_path).read()
            assert "OnBootSec=180m" in content
            assert "WantedBy=timers.target" in content

    def test_enables_timer(self):
        """Timer is enabled via systemctl (survives reboot)."""
        with tempfile.TemporaryDirectory() as tmp:
            script, systemctl_log, _ = make_test_script(tmp, "120")
            subprocess.run(["bash", script], capture_output=True, text=True)
            log = open(systemctl_log).read()
            assert "enable self-destruct.timer" in log

    def test_daemon_reload_called(self):
        """systemctl daemon-reload called after creating unit files."""
        with tempfile.TemporaryDirectory() as tmp:
            script, systemctl_log, _ = make_test_script(tmp, "60")
            subprocess.run(["bash", script], capture_output=True, text=True)
            log = open(systemctl_log).read()
            assert "daemon-reload" in log

    def test_custom_minutes(self):
        """Timer uses the configured DESTRUCT_MINS value."""
        with tempfile.TemporaryDirectory() as tmp:
            script, _, systemd_dir = make_test_script(tmp, "45")
            subprocess.run(["bash", script], capture_output=True, text=True)
            timer_path = os.path.join(systemd_dir, "self-destruct.timer")
            content = open(timer_path).read()
            assert "OnBootSec=45m" in content


class TestScheduleDestructSkipConditions:
    """schedule-destruct.sh should skip when no valid timer configured."""

    def test_skip_when_zero(self):
        """No units created when DESTRUCT_MINS=0."""
        with tempfile.TemporaryDirectory() as tmp:
            script, _, systemd_dir = make_test_script(tmp, "0")
            result = subprocess.run(
                ["bash", script], capture_output=True, text=True
            )
            assert result.returncode == 0
            assert not os.path.exists(
                os.path.join(systemd_dir, "self-destruct.timer")
            )
            assert "No destruct timer" in result.stdout

    def test_skip_when_empty(self):
        """No units created when DESTRUCT_MINS is empty."""
        with tempfile.TemporaryDirectory() as tmp:
            script, _, systemd_dir = make_test_script(tmp, "")
            result = subprocess.run(
                ["bash", script], capture_output=True, text=True
            )
            assert result.returncode == 0
            assert not os.path.exists(
                os.path.join(systemd_dir, "self-destruct.timer")
            )

    def test_skip_when_negative(self):
        """No units created when DESTRUCT_MINS is negative."""
        with tempfile.TemporaryDirectory() as tmp:
            script, _, systemd_dir = make_test_script(tmp, "-5")
            result = subprocess.run(
                ["bash", script], capture_output=True, text=True
            )
            assert result.returncode == 0
            assert not os.path.exists(
                os.path.join(systemd_dir, "self-destruct.timer")
            )


class TestNoTransientTimers:
    """schedule-destruct.sh must NOT use systemd-run (transient timers)."""

    def test_no_systemd_run(self):
        """Script must not contain systemd-run (transient timers don't survive reboot)."""
        script = extract_script()
        assert "systemd-run" not in script, (
            "schedule-destruct.sh still uses systemd-run. "
            "Transient timers are lost on reboot. Use persistent unit files."
        )
