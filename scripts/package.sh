#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$0")")"

VERSION=$(python3 -c "import json; print(json.load(open('version.json'))['version'])")
TARBALL="hatchery-${VERSION}.tar.gz"

# Create temp staging with symlink for portable tar prefix
STAGING=$(mktemp -d)
ln -s "$PWD" "$STAGING/hatchery"
tar czf "${TARBALL}" -C "$STAGING" \
  hatchery/scripts/ hatchery/tests/ hatchery/examples/ \
  hatchery/version.json hatchery/README.md
rm -rf "$STAGING"

# Portable checksum (sha256sum on Linux, shasum on macOS)
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${TARBALL}" > "${TARBALL}.sha256"
else
  shasum -a 256 "${TARBALL}" > "${TARBALL}.sha256"
fi

echo "Built ${TARBALL}"
echo "SHA256: $(cat "${TARBALL}.sha256")"
