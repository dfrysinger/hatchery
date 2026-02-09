# Hatchery Droplet HTTP API

This is a lightweight HTTP API exposed by the droplet’s `api-server` service (see `scripts/api-server.py`). It’s used by clients (e.g. iOS Shortcuts) to check health/status and to upload larger configuration after boot.

- Default port: `8080`
- Default bind: `127.0.0.1` (may be changed via `API_BIND_ADDRESS`)

## Endpoints

### Health / status

- `GET /health`
  - 200 if the bot is online
  - 503 otherwise

- `GET /status`
  - Full status JSON (phase/stage/services/safe_mode)

- `GET /stages`
  - Raw `init-stages.log` text

- `GET /log`
  - Last ~8KB of bootstrap/phase logs

### Config upload + apply

#### Authenticated (HMAC required)

- `POST /config/upload`
  - Uploads `habitat` and/or `agents` JSON
  - Writes (0600):
    - `/etc/habitat.json`
    - `/etc/agents.json`
  - If any config file is written, also writes the **API upload marker file** (0600):
    - `/etc/config-api-uploaded`
    - Contents: Unix timestamp (float)

- `POST /config/apply`
  - Applies uploaded config and restarts relevant services (async)

- `GET /config`
  - Returns config status/metadata (must not expose secrets)

#### Unauthenticated (safe, read-only)

- `GET /config/status`
  - Returns only upload status derived from the marker file:
    ```json
    {"api_uploaded": true, "api_uploaded_at": 1739060000.123}
    ```

## Marker file (`api_uploaded`)

The API reports upload status using the `api_uploaded` and `api_uploaded_at` fields. The source of truth is the marker file:

- Path: `/etc/config-api-uploaded`
- Created by: `write_upload_marker()` after successful `POST /config/upload` writes at least one config file
- Used by: `GET /config` and `GET /config/status`

Quick checks:

```bash
# On the droplet
test -f /etc/config-api-uploaded && echo "Uploaded" || echo "Not uploaded"

# Over HTTP (no auth)
curl -sS http://<droplet-ip>:8080/config/status
```

## References

- [Architecture: API config upload](./architecture/api-config-upload.md)
- [Troubleshooting: API config upload](./troubleshooting/api-config-upload.md)
- [API upload marker file](./api-upload-marker.md)
