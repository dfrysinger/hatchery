# API Upload Marker File

## Overview

The API upload marker file (`/etc/config-api-uploaded`) is created by the Hatchery API server when configuration is successfully uploaded via the `POST /config/upload` endpoint. It serves as a persistent indicator that config was uploaded via API rather than provisioned during droplet creation.

## Purpose

- **Status tracking:** Distinguishes API-uploaded configs from cloud-init provisioned configs
- **Troubleshooting:** Helps debug config application issues by tracking upload method
- **Auditing:** Provides upload timestamp for config management workflows

## Location

**File path:** `/etc/config-api-uploaded`

**Permissions:** `0o600` (owner read/write only) - protects timestamp data

## File Format

The file contains a single line: the Unix timestamp (float) of when the config was uploaded.

**Example content:**
```
1707442800.123456
```

This corresponds to: `2026-02-09 02:00:00.123456 UTC`

## API Endpoints

### Creating the Marker

The marker is created automatically when `POST /config/upload` successfully writes at least one config file:

```bash
curl -X POST http://localhost:8080/config/upload \
  -H "Content-Type: application/json" \
  -H "X-Timestamp: $(date +%s)" \
  -H "X-Signature: $SIGNATURE" \
  -d '{"habitat": {...}, "agents": {...}}'
```

If the upload succeeds, the marker is written with the current timestamp.

### Reading Upload Status

**Unauthenticated endpoint** (no HMAC required):

```bash
curl http://localhost:8080/config/status
```

**Response:**
```json
{
  "api_uploaded": true,
  "api_uploaded_at": 1707442800.123456
}
```

**Authenticated endpoint** (returns full config status):

```bash
curl http://localhost:8080/config \
  -H "X-Timestamp: $(date +%s)" \
  -H "X-Signature: $SIGNATURE"
```

**Response:**
```json
{
  "habitat_exists": true,
  "habitat_modified": 1707442800.5,
  "habitat_name": "Production-Habitat",
  "habitat_agent_count": 5,
  "agents_exists": true,
  "agents_modified": 1707442800.5,
  "agents_names": ["Claude", "ChatGPT", "Gemini", "EL", "Worker1"],
  "api_uploaded": true,
  "api_uploaded_at": 1707442800.123456
}
```

## Logging and Error Handling

As of TASK-21, the marker write operation includes:

### Structured Logging

All marker write operations log to `stderr` in structured JSON format:

**Success log:**
```json
{
  "event": "upload_marker_written",
  "path": "/etc/config-api-uploaded",
  "timestamp": 1707442800.123456,
  "success": true
}
```

**Error log:**
```json
{
  "event": "upload_marker_write_failed",
  "path": "/etc/config-api-uploaded",
  "timestamp": 1707442800.123456,
  "success": false,
  "error": "PermissionError",
  "details": "Permission denied: /etc/config-api-uploaded"
}
```

### Error Handling

Marker write failures are **non-fatal** - the API continues to function normally:

- **PermissionError:** Logged to stderr, config upload still succeeds
- **OSError:** Disk full or directory missing, logged to stderr
- **Unexpected errors:** Caught and logged with exception type

The upload endpoint can still return success even if marker write fails, since the actual config files were written. Clients can check marker status via `/config/status` to verify.

## Troubleshooting

### Marker Not Created

**Symptom:** `api_uploaded: false` even after successful upload

**Possible causes:**
1. Permission denied writing to `/etc/` (check api-server logs in stderr)
2. Disk full (check `df -h`)
3. Config upload endpoint returned error (check response body)

**Check logs:**
```bash
journalctl -u api-server -n 100 | grep upload_marker
```

### Stale Marker Timestamp

**Symptom:** `api_uploaded_at` doesn't match latest upload

**Cause:** Marker file write failed on latest upload, showing old timestamp

**Resolution:**
1. Check api-server stderr logs for write errors
2. Fix permissions: `sudo chmod 600 /etc/config-api-uploaded && sudo chown root:root /etc/config-api-uploaded`
3. Re-upload config to create fresh marker

### Manual Marker Creation

If needed for testing or recovery:

```bash
sudo bash -c 'echo $(date +%s.%N) > /etc/config-api-uploaded'
sudo chmod 600 /etc/config-api-uploaded
```

## Implementation Details

**Function:** `write_upload_marker()` in `scripts/api-server.py`

**Returns:** `{"ok": bool, "path": str, "error": str (optional)}`

**Behavior:**
- Creates file with current timestamp
- Sets restrictive permissions (0o600)
- Logs success/failure to stderr in JSON format
- Returns success/error dict without raising exceptions

**Tests:** `tests/test_upload_marker.py`
- Success case with logging
- Permission denied error
- OSError (disk full, directory missing)
- Unexpected errors
- Structured log format validation

## See Also

- [Architecture: API Config Upload + `api_uploaded` Marker](./architecture/api-config-upload.md)
- [Troubleshooting: API Config Upload](./troubleshooting/api-config-upload.md)
- [Task Spec: API Config Upload](./TASK-api-config-upload.md)
