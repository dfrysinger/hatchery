"""Ensure all cloud-init YAML and scripts contain only ASCII characters.

DigitalOcean's cloud-init parser rejects non-ASCII (em dashes, arrows,
curly quotes, etc.). This test catches them before they reach production.
"""
import pathlib, pytest

REPO = pathlib.Path(__file__).resolve().parent.parent

# Files that MUST be pure ASCII (only YAML files that go through iOS Shortcut pipeline)
# Scripts are fetched directly from GitHub and can contain emoji/Unicode
ASCII_REQUIRED = [
    "hatch.yaml",
    "hatch-slim.yaml",
]


@pytest.mark.parametrize("relpath", ASCII_REQUIRED)
def test_no_non_ascii(relpath):
    """Reject any byte > 127 in cloud-init files."""
    fp = REPO / relpath
    if not fp.exists():
        pytest.skip(f"{relpath} not found")
    content = fp.read_bytes()
    bad = []
    for i, b in enumerate(content):
        if b > 127:
            line = content[:i].count(b"\n") + 1
            col = i - content[:i].rfind(b"\n")
            snippet = content[max(0, i - 15) : i + 15]
            bad.append(f"  line {line}, col {col}: byte 0x{b:02x} near: {snippet}")
    assert not bad, (
        f"Non-ASCII characters in {relpath} will break cloud-init:\n"
        + "\n".join(bad[:10])
        + ("\n  ... and more" if len(bad) > 10 else "")
        + "\n\nReplace with ASCII equivalents: -- instead of em-dash, -> instead of arrow, etc."
    )
