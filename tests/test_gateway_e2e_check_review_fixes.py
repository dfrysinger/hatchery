"""Regression tests for gateway-e2e-check review fixes."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "gateway-e2e-check.sh"


def _read_script() -> str:
    return SCRIPT.read_text()


def _extract_function(name: str) -> str:
    lines = _read_script().splitlines()
    start = None
    for line_num, line in enumerate(lines):
        if line.startswith(f"{name}()"):
            start = line_num
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


def test_zero_output_tokens_reason_is_not_overwritten():
    fn = _extract_function("check_agents_e2e")
    assert 'if [ $rc -eq 0 ] && [ "$output_tokens" -eq 0 ]; then' in fn
    assert 'reason="LLM produced 0 output tokens (auth/API error)"' in fn
    assert 'elif [ $rc -eq 0 ]; then' in fn
    assert 'reason="missing HEALTH_CHECK_OK (LLM error?)"' in fn
    assert '[ $rc -eq 0 ] && ! echo "$output" | grep -qE "HEALTH_CHECK_OK|HEARTBEAT_OK" && reason=' not in fn
    zero_tokens_idx = fn.index('if [ $rc -eq 0 ] && [ "$output_tokens" -eq 0 ]; then')
    missing_magic_idx = fn.index('reason="missing HEALTH_CHECK_OK (LLM error?)"')
    assert zero_tokens_idx < missing_magic_idx
