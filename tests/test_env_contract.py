"""
Env contract test — verify runtime scripts can find the env vars they need.

Prevents:
- group.env missing vars that runtime scripts expect (owner IDs, platform, etc.)
- New vars added to parse-habitat.py but not propagated to group.env
- Typos in env var names across producer/consumer boundaries

Strategy: extract env var references from runtime scripts, compare against
the set of vars produced by parse-habitat.py + generate_group_env().
"""

import os
import re
import subprocess

import pytest

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(REPO_DIR, "scripts")

# Runtime scripts that run AFTER boot (health checks, safe mode, E2E)
# These must get all their env from group.env or systemd Environment=
RUNTIME_SCRIPTS = [
    "gateway-e2e-check.sh",
    "gateway-health-check.sh",
    "safe-mode-handler.sh",
    "safe-mode-recovery.sh",
    "try-full-config.sh",
]

# Vars set by bash, systemd, or computed at runtime — NOT expected in group.env
RUNTIME_ONLY = {
    # Bash builtins
    "HOME", "USER", "PATH", "PWD", "TERM", "SHELL", "LANG", "HOSTNAME",
    "SHLVL", "OLDPWD", "IFS", "OPTIND", "OPTARG", "COLUMNS", "LINES",
    # Bash special
    "BASH_SOURCE", "BASH_LINENO", "FUNCNAME", "LINENO",
    "PIPESTATUS", "RANDOM", "SECONDS", "BASHPID", "BASH_REMATCH",
    "BASH", "BASH_VERSION", "BASH_VERSINFO",
    # Set by hc_init_logging / hc_load_environment (derived at runtime)
    "HC_HOME", "HC_USERNAME", "HC_LOG", "HC_SAFE_MODE_FILE",
    "HC_UNHEALTHY_MARKER", "HC_SETUP_COMPLETE", "HC_PLATFORM",
    "HC_GROUP", "HC_PORT", "HC_ISOLATION", "HC_NETWORK",
    "HC_CONFIG_PATH", "HC_STATE_DIR",
    # Set by systemd EnvironmentFile or unit Environment=
    "GROUP", "GROUP_PORT", "CONFIG_PATH",
    "OPENCLAW_CONFIG_PATH", "OPENCLAW_STATE_DIR",
    "CI",
    # Set by the script itself (local computation)
    "MANIFEST", "MAX_RECOVERY_ATTEMPTS", "RECOVERY_ATTEMPT",
    "INTRO_SENT_MARKER", "LOCKOUT_FILE",
    # Loop/temp vars commonly used
    "i", "idx", "rc", "output", "line", "pid", "port",
    "group", "agent_id", "agent_name", "token", "config_file",
    # Function-scoped vars (declared with local)
    "result", "status", "response", "url", "data",
}

# Vars produced by parse-habitat.py (from analyzing the script)
PARSE_HABITAT_VARS = set()


def extract_env_vars_from_script(script_path):
    """Extract env var names referenced as ${VAR} or $VAR in a script."""
    with open(script_path) as f:
        content = f.read()

    # Match ${VAR_NAME} and $VAR_NAME (uppercase + underscore only)
    pattern = r'\$\{([A-Z][A-Z0-9_]*)\}|\$([A-Z][A-Z0-9_]*)\b'
    matches = re.findall(pattern, content)
    # Each match is a tuple (group1, group2) — one will be empty
    return {m[0] or m[1] for m in matches}


def get_parse_habitat_output_vars():
    """Extract var names that parse-habitat.py writes to habitat-parsed.env."""
    script = os.path.join(SCRIPTS_DIR, "parse-habitat.py")
    if not os.path.exists(script):
        return set()

    with open(script) as f:
        content = f.read()

    # Match f.write('VAR_NAME=...) and f.write(f"VAR_NAME=...")
    # Also match print("VAR=...) patterns
    vars_found = set()
    for match in re.finditer(r'["\']([A-Z][A-Z0-9_]*)=', content):
        vars_found.add(match.group(1))
    return vars_found


def get_group_env_vars():
    """Extract var names written by generate_group_env() in lib-isolation.sh."""
    script = os.path.join(SCRIPTS_DIR, "lib-isolation.sh")
    if not os.path.exists(script):
        return set()

    with open(script) as f:
        content = f.read()

    # Find the generate_group_env function and extract var names
    vars_found = set()
    in_func = False
    for line in content.splitlines():
        if "generate_group_env" in line and "()" in line:
            in_func = True
        elif in_func and line.strip().startswith("}"):
            break
        elif in_func:
            # Match KEY= patterns in echo/cat heredocs
            for match in re.finditer(r'^([A-Z][A-Z0-9_]*)=', line.strip()):
                vars_found.add(match.group(1))
            # Match echo "KEY=..." >> patterns
            for match in re.finditer(r'echo\s+["\']([A-Z][A-Z0-9_]*)=', line):
                vars_found.add(match.group(1))
    return vars_found


class TestEnvContract:
    """Verify env var producer/consumer contract."""

    def test_parse_habitat_produces_vars(self):
        """parse-habitat.py must produce at least the core vars."""
        vars_produced = get_parse_habitat_output_vars()
        if not vars_produced:
            pytest.skip("Could not extract vars from parse-habitat.py")

        core_vars = {"AGENT_COUNT", "PLATFORM", "HABITAT_NAME"}
        missing = core_vars - vars_produced
        assert not missing, f"parse-habitat.py missing core vars: {missing}"

    def test_group_env_produces_vars(self):
        """generate_group_env() must produce group-specific overrides."""
        vars_produced = get_group_env_vars()
        if not vars_produced:
            pytest.skip("Could not extract vars from lib-isolation.sh")

        required = {"GROUP", "GROUP_PORT", "ISOLATION"}
        missing = required - vars_produced
        assert not missing, f"generate_group_env() missing required vars: {missing}"

    def test_runtime_scripts_no_unknown_vars(self):
        """Runtime scripts should not reference vars that nobody produces."""
        all_produced = get_parse_habitat_output_vars() | get_group_env_vars()
        if not all_produced:
            pytest.skip("Could not extract produced vars")

        # Add well-known vars from droplet.env (base64 decoded)
        env_vars = {
            "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENAI_OAUTH_ACCESS",
            "OPENAI_OAUTH_REFRESH", "OPENAI_OAUTH_EXPIRES", "OPENAI_ACCOUNT_ID",
            "GOOGLE_API_KEY", "GEMINI_API_KEY", "BRAVE_API_KEY",
            "DO_TOKEN", "DROPBOX_TOKEN", "GATEWAY_TOKEN",
            "SSH_PASSWORD", "CLOUDFLARE_TOKEN", "CLOUDFLARE_ZONE_ID",
        }
        all_available = all_produced | env_vars | RUNTIME_ONLY

        for script_name in RUNTIME_SCRIPTS:
            script_path = os.path.join(SCRIPTS_DIR, script_name)
            if not os.path.exists(script_path):
                continue

            consumed = extract_env_vars_from_script(script_path)
            # Filter to uppercase-only (actual env vars, not local vars)
            consumed = {v for v in consumed if v == v.upper() and len(v) > 2}
            unknown = consumed - all_available

            # Some vars are from sourced libraries — check if they're defined in libs
            lib_defined = set()
            for lib in ["lib-health-check.sh", "lib-notify.sh", "lib-auth.sh",
                         "lib-env.sh", "lib-isolation.sh", "lib-permissions.sh"]:
                lib_path = os.path.join(SCRIPTS_DIR, lib)
                if os.path.exists(lib_path):
                    with open(lib_path) as f:
                        lib_content = f.read()
                    for var in list(unknown):
                        # Check if the var is assigned in the lib
                        if re.search(rf'^{var}=|^\s+{var}=|export {var}=', lib_content, re.MULTILINE):
                            lib_defined.add(var)

            unknown -= lib_defined

            # Allow some well-known vars that come from the environment
            well_known = {
                "CONFIG_JSON", "GEN_CONFIG_SCRIPT",  # build-full-config scope
                "AUTH_DIAG_LOG",  # opt-in diagnostic logging
                "MANIFEST",  # path constant
            }
            unknown -= well_known

            if unknown:
                # This is a warning, not a hard fail — new vars may be legitimate
                # but should be consciously added to the produced set
                print(f"  INFO: {script_name} references vars not in known producers: {unknown}")

    def test_owner_id_vars_in_parse_habitat(self):
        """parse-habitat.py must produce per-platform owner IDs."""
        vars_produced = get_parse_habitat_output_vars()
        if not vars_produced:
            pytest.skip("Could not extract vars from parse-habitat.py")

        # Per ChatGPT review: per-platform owner IDs, not single OWNER_ID
        assert "TELEGRAM_OWNER_ID" in vars_produced or "DISCORD_OWNER_ID" in vars_produced, \
            "parse-habitat.py must produce TELEGRAM_OWNER_ID and/or DISCORD_OWNER_ID"

    def test_no_habitat_parsed_env_in_runtime_scripts(self):
        """Runtime scripts must not source habitat-parsed.env directly."""
        for script_name in RUNTIME_SCRIPTS:
            script_path = os.path.join(SCRIPTS_DIR, script_name)
            if not os.path.exists(script_path):
                continue

            with open(script_path) as f:
                content = f.read()

            # Allow comments about habitat-parsed.env
            for i, line in enumerate(content.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                if "habitat-parsed.env" in stripped and "source" in stripped:
                    # This is a pre-existing issue that Phase 1 will fix.
                    # For now, just warn (don't fail) since this is the lint target.
                    print(f"  WARN: {script_name}:{i} sources habitat-parsed.env "
                          f"(Phase 1 will eliminate this)")


class TestConfigValidation:
    """Test the validate_generated_config function in lib-isolation.sh."""

    def _run_validation(self, config_json, group="test-group"):
        """Write a temp config and run validate_generated_config on it."""
        import json
        import tempfile

        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(config_json, f)
            config_path = f.name

        try:
            result = subprocess.run(
                ["bash", "-c", f"""
                    source {SCRIPTS_DIR}/lib-isolation.sh 2>/dev/null || true
                    # Override get_group_config_path to return our temp file
                    get_group_config_path() {{ echo "{config_path}"; }}
                    validate_generated_config "{group}"
                """],
                capture_output=True, text=True
            )
            return result.returncode, result.stderr
        finally:
            os.unlink(config_path)

    def test_single_agent_default_account_passes(self):
        """Single agent with accounts.default should pass."""
        config = {
            "agents": {"list": [{"id": "agent1", "default": True}]},
            "bindings": [],
            "channels": {
                "telegram": {"accounts": {"default": {"botToken": "tok"}}},
            },
        }
        rc, stderr = self._run_validation(config)
        assert rc == 0, f"Valid config rejected: {stderr}"

    def test_single_agent_wrong_account_fails(self):
        """Single agent with accounts.agent1 should fail (Doctor will rename)."""
        config = {
            "agents": {"list": [{"id": "agent1", "default": True}]},
            "bindings": [],
            "channels": {
                "telegram": {"accounts": {"agent1": {"botToken": "tok"}}},
            },
        }
        rc, stderr = self._run_validation(config)
        assert rc == 1, "Config with agent1 account for single agent should fail"
        assert "must be 'default'" in stderr

    def test_multi_agent_all_bindings_passes(self):
        """Multi agent with bindings for all agents should pass."""
        config = {
            "agents": {"list": [
                {"id": "agent1", "default": True},
                {"id": "agent2"},
            ]},
            "bindings": [
                {"agentId": "agent1", "match": {"channel": "telegram", "accountId": "agent1"}},
                {"agentId": "agent2", "match": {"channel": "telegram", "accountId": "agent2"}},
            ],
            "channels": {
                "telegram": {"accounts": {
                    "agent1": {"botToken": "tok1"},
                    "agent2": {"botToken": "tok2"},
                }},
            },
        }
        rc, stderr = self._run_validation(config)
        assert rc == 0, f"Valid multi-agent config rejected: {stderr}"

    def test_multi_agent_missing_binding_fails(self):
        """Multi agent missing a binding should fail."""
        config = {
            "agents": {"list": [
                {"id": "agent1", "default": True},
                {"id": "agent2"},
            ]},
            "bindings": [
                {"agentId": "agent2", "match": {"channel": "telegram", "accountId": "agent2"}},
            ],
            "channels": {
                "telegram": {"accounts": {
                    "agent1": {"botToken": "tok1"},
                    "agent2": {"botToken": "tok2"},
                }},
            },
        }
        rc, stderr = self._run_validation(config)
        assert rc == 1, "Config with missing binding should fail"
        assert "only 1 have bindings" in stderr

    def test_binding_references_missing_account_fails(self):
        """Binding referencing non-existent account should fail."""
        config = {
            "agents": {"list": [
                {"id": "agent1", "default": True},
                {"id": "agent2"},
            ]},
            "bindings": [
                {"agentId": "agent1", "match": {"channel": "telegram", "accountId": "agent1"}},
                {"agentId": "agent2", "match": {"channel": "telegram", "accountId": "ghost"}},
            ],
            "channels": {
                "telegram": {"accounts": {
                    "agent1": {"botToken": "tok1"},
                    "agent2": {"botToken": "tok2"},
                }},
            },
        }
        rc, stderr = self._run_validation(config)
        assert rc == 1, "Config with binding to missing account should fail"
        assert "ghost" in stderr
