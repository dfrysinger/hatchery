"""Regression tests for recent gateway-health-check review fixes."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "gateway-health-check.sh"
LEGACY_COMPOSE_PATH_TEMPLATE = ".openclaw/compose/${GROUP:-default}/docker-compose.yaml"


def _read_script() -> str:
    return SCRIPT.read_text()


def _extract_function(name: str) -> str:
    lines = _read_script().splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f"{name}()"):
            start = i
            break
    assert start is not None, f"{name}() not found"

    depth = 0
    body = []
    for line in lines[start:]:
        body.append(line)
        depth += line.count("{")
        depth -= line.count("}")
        if depth == 0 and len(body) > 1:
            break
    return "\n".join(body)


def _extract_between_markers(start_text: str, end_text: str) -> str:
    script = _read_script()
    start = script.index(start_text)
    end = script.index(end_text, start)
    return script[start:end]


def test_config_path_block_reuses_hc_values():
    block = _extract_between_markers(
        "# Universal: Config path per isolation mode",
        "# Universal: Per-group state files",
    )
    assert 'CONFIG_PATH="$HC_CONFIG_PATH"' in block
    assert 'HC_HOME="${HC_HOME:-/home/${HC_USERNAME:-bot}}"' in block
    assert 'HC_HOME="/home/$HC_USERNAME"' not in block


def test_safe_mode_warning_requires_owner_ids():
    fn = _extract_function("send_entering_safe_mode_warning")
    assert '[ -n "$tg_token" ] && [ -n "$tg_owner" ]' in fn
    assert '[ -n "$dc_token" ] && [ -n "$dc_owner" ]' in fn


def test_container_paths_use_computed_compose_helper():
    helper = _extract_function("_hc_compose_file")
    restart = _extract_function("restart_gateway")
    enter = _extract_function("enter_safe_mode")

    assert 'COMPOSE_BASE:-${HC_HOME}/.openclaw/compose' in helper
    assert 'compose_file=$(_hc_compose_file "${GROUP:-default}")' in restart
    assert 'compose_file=$(_hc_compose_file "${GROUP:-default}")' in enter
    assert LEGACY_COMPOSE_PATH_TEMPLATE not in restart
    assert LEGACY_COMPOSE_PATH_TEMPLATE not in enter


def test_send_boot_notification_uses_state_dir_helper():
    fn = _extract_function("send_boot_notification")
    assert 'OPENCLAW_STATE_DIR=$(_hc_state_dir "$GROUP")' in fn
    assert '--reply-channel "$primary_platform"' in fn


def test_check_channel_connectivity_uses_array_iteration():
    fn = _extract_function("check_channel_connectivity")
    assert "IFS=',' read -r -a _platforms <<< \"$NOTIFY_PLATFORMS\"" in fn
    assert 'for ((_i=1; _i<=_count; _i++)); do' in fn
    assert 'for _platform in "${_platforms[@]}"; do' in fn
    assert 'for _platform in $_platforms; do' not in fn
    assert 'for _i in $(seq 1 "$_count"); do' not in fn


def test_state_dir_helper_has_safe_fallbacks():
    fn = _extract_function("_hc_state_dir")
    assert 'group="${1:-${GROUP:-default}}"' in fn
    assert 'echo "${HC_HOME}/.openclaw-sessions/${group}"' in fn


def test_hc_home_has_safe_fallback_expression():
    script = _read_script()
    assert 'HC_HOME="${HC_HOME:-/home/${HC_USERNAME:-bot}}"' in script
