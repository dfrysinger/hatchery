# Architecture: API Config Upload + `api_uploaded` Marker

This document explains the **two-phase configuration** flow used by Hatchery droplets when `user_data` is too large for DigitalOcean’s 64KB limit.

## Overview

1. Droplet boots with a **minimal habitat** embedded in `user_data`.
2. After `/health` is healthy, the iOS Shortcut (or other client) **uploads full config** over HTTP.
3. The droplet writes the uploaded JSON to disk and (optionally) triggers a config apply/restart.

## Endpoints

### Authenticated (HMAC required)

#### `POST /config/upload`
Uploads JSON config.

**Request body** (example):
```json
{
  "habitat": {"name": "MyHabitat", "agents": []},
  "agents": {"some-agent": {"description": "..."}},
  "apply": true
}
```

**Behavior**
- Writes:
  - Habitat → `/etc/habitat.json` (0600)
  - Agent library → `/etc/agents.json` (0600)
- If **any** file is written, writes the upload marker:
  - Marker path: **`/etc/config-api-uploaded`** (0600)
  - Marker contents: Unix timestamp (seconds, float)
- If `apply: true`, triggers `/usr/local/bin/apply-config.sh` asynchronously.

**Response** (example):
```json
{"ok": true, "files_written": ["/etc/habitat.json", "/etc/agents.json"], "applied": true}
```

#### `POST /config/apply`
Triggers config apply/restart.

#### `GET /config`
Returns config status. May include limited metadata about the uploaded habitat/agents (but must not expose secrets).

### Unauthenticated (public, read-only)

#### `GET /config/status`
Returns only upload-marker status (safe for unauthenticated polling):
```json
{"api_uploaded": true, "api_uploaded_at": 1739060000.123}
```

## The `api_uploaded` Marker

### Purpose
The marker is a **cheap, durable signal** that the droplet has successfully received uploaded config over the API (regardless of whether apply/restart has completed).

### Source of truth
- The API server checks for marker existence and parses the timestamp.
- The marker is written by `write_upload_marker()` after successful `POST /config/upload` writes at least one file.

### Common checks
```bash
# Exists?
test -f /etc/config-api-uploaded && echo "Config uploaded" || echo "Config not uploaded"

# Show timestamp (if present)
cat /etc/config-api-uploaded

# Query via HTTP (no auth):
curl -s http://<droplet-ip>:8080/config/status
```

## Logging and Error Handling

The marker write operation (as of TASK-21) uses structured JSON logging to stderr:

**Success:**
```json
{"event": "upload_marker_written", "path": "/etc/config-api-uploaded", "timestamp": 1707442800.123, "success": true}
```

**Failure:**
```json
{"event": "upload_marker_write_failed", "path": "/etc/config-api-uploaded", "timestamp": 1707442800.123, "success": false, "error": "PermissionError", "details": "Permission denied"}
```

Marker write failures are **non-fatal** — the config upload still succeeds. Clients can check marker status via `/config/status` to verify.

## Implementation Reference
- Marker path constant: `MARKER_PATH='/etc/config-api-uploaded'`
- Marker write: `write_upload_marker()` in `scripts/api-server.py`
- Status endpoints: `/config` and `/config/status`
- Tests: `tests/test_upload_marker.py`

## See Also
- [Troubleshooting: Config Upload](../troubleshooting/api-config-upload.md)
- [Security: HMAC Authentication](../security/SECURITY.md)
