#!/usr/bin/env bash
# bootstrap.sh -- fetch hatchery release tarball from GitHub and hand off to phase1
set -euo pipefail

# Source env vars so helpers (notify, etc.) and VERSION can resolve
set -a; source /etc/droplet.env; source /etc/habitat-parsed.env 2>/dev/null || true; set +a

REPO="dfrysinger/hatchery"
INSTALL_DIR="/opt/hatchery"
VERSION="${HATCHERY_VERSION:-}"
[ -z "$VERSION" ] && [ -f /etc/hatchery-version ] && VERSION=$(cat /etc/hatchery-version)
VERSION="${VERSION:-main}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
notify() {
  local msg="$1"
  [ -x "$INSTALL_DIR/scripts/tg-notify.sh" ] && \
    "$INSTALL_DIR/scripts/tg-notify.sh" "$msg" 2>/dev/null || true
}

log() { echo "[bootstrap] $*"; }

# ---------------------------------------------------------------------------
# fetch URL DEST -- download with 3 retries & exponential backoff
# ---------------------------------------------------------------------------
fetch() {
  local url="$1" dest="$2"
  local delays=(5 15 30)
  local attempt=0
  while [ $attempt -lt 3 ]; do
    if curl -fSL --max-time 60 -o "$dest" "$url"; then
      return 0
    fi
    log "Attempt $((attempt+1)) failed; retrying in ${delays[$attempt]}s..."
    sleep "${delays[$attempt]}"
    attempt=$((attempt + 1))
  done
  notify "bootstrap: fetch failed after 3 retries -- $url"
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"

if [ "$VERSION" = "main" ]; then
  # Dev mode -- pull HEAD archive
  log "Dev mode: fetching main branch archive"
  TARBALL=$(mktemp)
  fetch "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" "$TARBALL"
  tar -xzf "$TARBALL" --strip-components=1 -C "$INSTALL_DIR"
  rm -f "$TARBALL"
else
  # Release mode -- fetch versioned tarball + checksum
  log "Release mode: fetching v${VERSION}"
  TARBALL=$(mktemp)
  SUMFILE=$(mktemp)
  BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"
  fetch "${BASE_URL}/hatchery-${VERSION}.tar.gz" "$TARBALL"
  fetch "${BASE_URL}/sha256sums.txt" "$SUMFILE"

  # Verify SHA256
  EXPECTED=$(grep "hatchery-${VERSION}.tar.gz" "$SUMFILE" | awk '{print $1}')
  ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    notify "bootstrap: SHA256 mismatch (expected $EXPECTED, got $ACTUAL)"
    log "SHA256 verification failed!"; exit 1
  fi
  log "SHA256 verified OK"

  tar -xzf "$TARBALL" -C "$INSTALL_DIR"
  rm -f "$TARBALL" "$SUMFILE"
fi

chmod +x "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true

# ---------------------------------------------------------------------------
# Install scripts to system paths
# ---------------------------------------------------------------------------
for f in "$INSTALL_DIR"/scripts/*.sh; do
  [ -f "$f" ] || continue
  bn=$(basename "$f")
  case "$bn" in
    bootstrap.sh)
      ;; # skip -- do not overwrite ourselves mid-execution
    phase1-critical.sh|phase2-background.sh|build-full-config.sh|generate-session-services.sh|generate-docker-compose.sh|lib-permissions.sh|lib-auth.sh)
      cp "$f" /usr/local/sbin/
      ;;
    *)
      cp "$f" /usr/local/bin/
      ;;
  esac
done

for f in "$INSTALL_DIR"/scripts/*.py; do
  [ -f "$f" ] && cp "$f" /usr/local/bin/ && chmod 755 "/usr/local/bin/$(basename "$f")"
done

# ---------------------------------------------------------------------------
# Install systemd service files (fixes #139: service/script mismatch)
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/systemd" ]; then
  for f in "$INSTALL_DIR"/systemd/*.service; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    cp "$f" /etc/systemd/system/
    log "Updated systemd service: $bn"
  done
  systemctl daemon-reload
  # Restart api-server if its service file was updated
  [ -f "$INSTALL_DIR/systemd/api-server.service" ] && systemctl restart api-server || true
fi

[ -f "$INSTALL_DIR/gmail-api.py" ] && cp "$INSTALL_DIR/gmail-api.py" /usr/local/bin/gmail-api.py && chmod 755 /usr/local/bin/gmail-api.py
[ -f "$INSTALL_DIR/set-council-group.sh" ] && cp "$INSTALL_DIR/set-council-group.sh" /usr/local/bin/set-council-group.telegram.sh && chmod 755 /usr/local/bin/set-council-group.telegram.sh

chmod +x /usr/local/sbin/*.sh /usr/local/bin/*.sh 2>/dev/null || true

log "Handing off to phase1-critical.sh"
/usr/local/sbin/phase1-critical.sh
