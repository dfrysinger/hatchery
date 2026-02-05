#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$0")")"

VERSION=$(python3 -c "import json; print(json.load(open('version.json'))['version'])")
TARBALL="hatchery-${VERSION}.tar.gz"

tar czf "${TARBALL}" \
  --transform "s,^,hatchery/," \
  scripts/ tests/ examples/ version.json README.md

sha256sum "${TARBALL}" > "${TARBALL}.sha256"

echo "Built ${TARBALL}"
echo "SHA256: $(cat "${TARBALL}.sha256")"
