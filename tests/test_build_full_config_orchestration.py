"""Tests for build-full-config.sh orchestration of lib-isolation.sh.

Validates that build-full-config.sh:
1. Sources lib-isolation.sh and calls generate_groups_manifest
2. Validates group consistency before proceeding
3. Runs per-group setup (dirs, env, config, auth, safeguard, e2e units)
4. Dispatches to mode-specific generators (session or container only)
5. Session generator receives only session groups
6. Container generator receives only container groups
"""
import subprocess
import json
import os
import tempfile
import pytest
import shutil

SCRIPT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts')


def make_minimal_env(tmpdir, groups="browser,documents", agent_count=2):
    """Create minimal env for testing build-full-config.sh orchestration.
    
    Returns env dict and paths dict.
    """
    home = os.path.join(tmpdir, 'home', 'bot')
    os.makedirs(home, exist_ok=True)
    os.makedirs(os.path.join(home, '.openclaw', 'agents', 'main', 'agent'), exist_ok=True)
    os.makedirs(os.path.join(home, 'clawd', 'agents'), exist_ok=True)

    # Create a minimal gateway token
    token_file = os.path.join(home, '.openclaw', 'gateway-token.txt')
    with open(token_file, 'w') as f:
        f.write('test-gateway-token')

    # Create stub generate-config.sh that produces valid JSON
    gen_config = os.path.join(tmpdir, 'generate-config.sh')
    with open(gen_config, 'w') as f:
        f.write('#!/bin/bash\necho \'{"gateway":{"port":18789}}\'\n')
    os.chmod(gen_config, 0o755)

    env = {
        'PATH': f'{tmpdir}:{os.environ.get("PATH", "/usr/bin:/bin")}',
        'HOME': home,
        'HOME_DIR': home,
        'USERNAME': 'bot',
        'SVC_USER': 'bot',
        'AGENT_COUNT': str(agent_count),
        'ISOLATION_GROUPS': groups,
        'ISOLATION_DEFAULT': 'session',
        'HABITAT_NAME': 'test-habitat',
        'PLATFORM': 'telegram',
        'MANIFEST': os.path.join(tmpdir, 'openclaw-groups.json'),
        'CONFIG_BASE': os.path.join(home, '.openclaw', 'configs'),
        'STATE_BASE': os.path.join(home, '.openclaw-sessions'),
        'COMPOSE_BASE': os.path.join(home, '.openclaw', 'compose'),
        # Agent definitions
        'AGENT1_NAME': 'Claude',
        'AGENT1_ISOLATION_GROUP': 'browser',
        'AGENT1_ISOLATION': 'session',
        'AGENT1_MODEL': 'anthropic/claude-opus-4-5',
        'AGENT1_NETWORK': 'host',
        'AGENT2_NAME': 'Gemini',
        'AGENT2_ISOLATION_GROUP': 'documents',
        'AGENT2_ISOLATION': 'session',
        'AGENT2_MODEL': 'google/gemini-2.5-pro',
        'AGENT2_NETWORK': 'host',
        # Prevent real file operations
        'DRY_RUN': '1',
    }

    return env, {'home': home, 'tmpdir': tmpdir, 'gen_config': gen_config}


def run_orchestration_snippet(code, env, check=True):
    """Run a bash snippet that sources lib-isolation.sh and executes orchestration code."""
    lib_path = os.path.join(SCRIPT_DIR, 'lib-isolation.sh')
    script = f"""
set -euo pipefail
source "{lib_path}"
{code}
"""
    result = subprocess.run(
        ['bash', '-c', script],
        capture_output=True, text=True, env=env,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"bash exited {result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


class TestOrchestratorManifest:
    """Orchestrator generates the runtime manifest before dispatching."""

    def test_manifest_generated_before_group_setup(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        code = """
generate_groups_manifest
[ -f "$MANIFEST" ] && echo "MANIFEST_EXISTS" || echo "MANIFEST_MISSING"
cat "$MANIFEST" | jq -r '.groups | keys[]' | sort
"""
        result = run_orchestration_snippet(code, env)
        assert "MANIFEST_EXISTS" in result.stdout
        assert "browser" in result.stdout
        assert "documents" in result.stdout

    def test_manifest_has_correct_ports(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        code = r"""
generate_groups_manifest
cat "$MANIFEST" | jq -r '.groups | to_entries[] | "\(.key):\(.value.port)"' | sort
"""
        result = run_orchestration_snippet(code, env)
        lines = sorted(result.stdout.strip().split('\n'))
        # Alphabetical: browser=18790, documents=18791
        assert lines[0] == "browser:18790"
        assert lines[1] == "documents:18791"


class TestOrchestratorValidation:
    """Orchestrator validates group consistency before proceeding."""

    def test_mixed_isolation_rejected(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path), groups="mixed", agent_count=2)
        env['AGENT1_ISOLATION_GROUP'] = 'mixed'
        env['AGENT1_ISOLATION'] = 'session'
        env['AGENT2_ISOLATION_GROUP'] = 'mixed'
        env['AGENT2_ISOLATION'] = 'container'
        code = """
validate_group_consistency "mixed"
"""
        result = run_orchestration_snippet(code, env, check=False)
        assert result.returncode != 0
        assert "mixed isolation" in result.stderr.lower() or "FATAL" in result.stderr

    def test_consistent_group_passes(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        code = """
validate_group_consistency "browser"
echo "VALID"
"""
        result = run_orchestration_snippet(code, env)
        assert "VALID" in result.stdout


class TestOrchestratorGroupSetup:
    """Orchestrator sets up dirs, env, config, auth, tokens per group."""

    def test_directories_created(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        code = """
generate_groups_manifest
setup_group_directories "browser"
[ -d "${CONFIG_BASE}/browser" ] && echo "CONFIG_DIR_OK"
[ -d "${STATE_BASE}/browser" ] && echo "STATE_DIR_OK"
[ -d "${STATE_BASE}/browser/agents/agent1/agent" ] && echo "AGENT_DIR_OK"
"""
        result = run_orchestration_snippet(code, env)
        assert "CONFIG_DIR_OK" in result.stdout
        assert "STATE_DIR_OK" in result.stdout
        assert "AGENT_DIR_OK" in result.stdout

    def test_group_env_file_created(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        env['ANTHROPIC_API_KEY'] = 'test-key-123'
        code = """
generate_groups_manifest
setup_group_directories "browser"
generate_group_env "browser"
cat "${CONFIG_BASE}/browser/group.env"
"""
        result = run_orchestration_snippet(code, env)
        assert "GROUP=browser" in result.stdout
        assert "GROUP_PORT=18790" in result.stdout
        assert "ANTHROPIC_API_KEY=test-key-123" in result.stdout

    def test_group_token_generated(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        code = """
generate_groups_manifest
setup_group_directories "browser"
token=$(generate_group_token "browser")
[ -n "$token" ] && echo "TOKEN_OK"
# Idempotent — same token on second call
token2=$(generate_group_token "browser")
[ "$token" = "$token2" ] && echo "IDEMPOTENT_OK"
"""
        result = run_orchestration_snippet(code, env)
        assert "TOKEN_OK" in result.stdout
        assert "IDEMPOTENT_OK" in result.stdout

    def test_safeguard_units_use_envfile(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        output_dir = os.path.join(str(tmp_path), 'systemd')
        os.makedirs(output_dir, exist_ok=True)
        code = f"""
generate_groups_manifest
port=$(get_group_port "browser")
iso=$(get_group_isolation "browser")
generate_safeguard_units "browser" "{output_dir}"
cat "{output_dir}/openclaw-safeguard-browser.service"
"""
        result = run_orchestration_snippet(code, env)
        assert "EnvironmentFile=" in result.stdout
        assert "group.env" in result.stdout

    def test_e2e_unit_generated(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        output_dir = os.path.join(str(tmp_path), 'systemd')
        os.makedirs(output_dir, exist_ok=True)
        code = f"""
generate_groups_manifest
port=$(get_group_port "browser")
iso=$(get_group_isolation "browser")
generate_e2e_unit "browser" "{output_dir}"
cat "{output_dir}/openclaw-e2e-browser.service"
"""
        result = run_orchestration_snippet(code, env)
        assert "EnvironmentFile=" in result.stdout
        assert "gateway-e2e-check.sh" in result.stdout


class TestOrchestratorDispatch:
    """Orchestrator dispatches to correct mode-specific generators."""

    def test_session_groups_filtered(self, tmp_path):
        env, paths = make_minimal_env(str(tmp_path))
        code = r"""
session_groups=$(get_groups_by_type "session")
echo "SESSION: $session_groups"
container_groups=$(get_groups_by_type "container")
echo "CONTAINER: $container_groups"
"""
        result = run_orchestration_snippet(code, env)
        assert "browser" in result.stdout.split("SESSION:")[1].split("\n")[0]
        assert "documents" in result.stdout.split("SESSION:")[1].split("\n")[0]
        container_line = result.stdout.split("CONTAINER:")[1].split("\n")[0]
        assert container_line.strip() == ""

    def test_mixed_mode_dispatch(self, tmp_path):
        """Groups with different isolation types dispatch to different generators."""
        env, paths = make_minimal_env(str(tmp_path), groups="browser,docker-worker", agent_count=2)
        env['AGENT1_ISOLATION_GROUP'] = 'browser'
        env['AGENT1_ISOLATION'] = 'session'
        env['AGENT2_ISOLATION_GROUP'] = 'docker-worker'
        env['AGENT2_ISOLATION'] = 'container'
        code = r"""
session_groups=$(get_groups_by_type "session")
container_groups=$(get_groups_by_type "container")
echo "SESSION: $session_groups"
echo "CONTAINER: $container_groups"
"""
        result = run_orchestration_snippet(code, env)
        session_line = result.stdout.split("SESSION:")[1].split("\n")[0]
        container_line = result.stdout.split("CONTAINER:")[1].split("\n")[0]
        assert "browser" in session_line
        assert "docker-worker" not in session_line
        assert "docker-worker" in container_line
        assert "browser" not in container_line


class TestSlimSessionGenerator:
    """After refactoring, generate-session-services.sh should NOT contain duplicated logic."""

    def test_no_generate_config_call(self):
        """Session generator must not call generate-config.sh (orchestrator does it)."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        with open(script_path) as f:
            content = f.read()
        # After refactoring, there should be no call to generate-config.sh
        # The orchestrator handles config generation
        assert 'generate-config.sh' not in content, \
            "generate-session-services.sh should not call generate-config.sh (orchestrator handles it)"

    def test_no_auth_profiles_copy(self):
        """Session generator must not copy auth-profiles (orchestrator does it)."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        with open(script_path) as f:
            content = f.read()
        assert 'auth-profiles' not in content, \
            "generate-session-services.sh should not handle auth-profiles (orchestrator does it)"

    def test_no_safeguard_unit_generation(self):
        """Session generator must not generate safeguard units (orchestrator does it)."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        with open(script_path) as f:
            content = f.read()
        assert 'openclaw-safeguard' not in content, \
            "generate-session-services.sh should not generate safeguard units"

    def test_no_e2e_unit_generation(self):
        """Session generator must not generate E2E units (orchestrator does it)."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        with open(script_path) as f:
            content = f.read()
        assert 'openclaw-e2e' not in content, \
            "generate-session-services.sh should not generate E2E units"

    def test_reads_port_from_manifest(self):
        """Session generator must read ports from manifest (not compute them)."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        with open(script_path) as f:
            content = f.read()
        assert 'BASE_PORT' not in content, \
            "generate-session-services.sh should not define BASE_PORT (read from manifest)"

    def test_no_directory_creation(self):
        """Session generator must not create config/state dirs (orchestrator does it)."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        with open(script_path) as f:
            content = f.read()
        assert 'ensure_bot_dir' not in content, \
            "generate-session-services.sh should not create directories"
        assert 'mkdir' not in content, \
            "generate-session-services.sh should not create directories"

    def test_bash_syntax_valid(self):
        """Session generator must pass bash -n."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        result = subprocess.run(
            ['bash', '-n', script_path],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"bash -n failed: {result.stderr}"

    def test_generates_systemd_service(self, tmp_path):
        """Session generator creates the main .service file per group."""
        script_path = os.path.join(SCRIPT_DIR, 'generate-session-services.sh')
        output_dir = str(tmp_path / 'systemd')
        os.makedirs(output_dir, exist_ok=True)

        # Create manifest that the slim generator will read
        manifest = {
            "generated": "2026-02-24T00:00:00Z",
            "groups": {
                "browser": {
                    "isolation": "session",
                    "port": 18790,
                    "network": "host",
                    "agents": ["agent1"],
                    "configPath": str(tmp_path / "configs/browser/openclaw.session.json"),
                    "statePath": str(tmp_path / "state/browser"),
                    "envFile": str(tmp_path / "configs/browser/group.env"),
                    "serviceName": "openclaw-browser",
                    "composePath": None
                }
            }
        }
        manifest_path = str(tmp_path / 'openclaw-groups.json')
        with open(manifest_path, 'w') as f:
            json.dump(manifest, f)

        env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': str(tmp_path / 'home'),
            'HOME_DIR': str(tmp_path / 'home'),
            'MANIFEST': manifest_path,
            'USERNAME': 'bot',
            'SVC_USER': 'bot',
            'ISOLATION_DEFAULT': 'session',
            'ISOLATION_GROUPS': 'browser',
            'HABITAT_NAME': 'test',
            'SESSION_OUTPUT_DIR': output_dir,
            'DRY_RUN': '1',
        }

        result = subprocess.run(
            ['bash', script_path],
            capture_output=True, text=True, env=env,
        )
        # After refactoring, the slim generator should succeed
        assert result.returncode == 0, f"generator failed: {result.stderr}"
        service_file = os.path.join(output_dir, 'openclaw-browser.service')
        assert os.path.exists(service_file), f"service file not created: {os.listdir(output_dir)}"
        with open(service_file) as f:
            content = f.read()
        assert 'ExecStart=/usr/local/bin/openclaw gateway' in content
        assert '18790' in content
