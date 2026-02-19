# Troubleshooting: API Config Upload

This guide helps diagnose issues with the **two-phase config** workflow (minimal `user_data` + API upload).

## Quick triage checklist

1. **Is the API server reachable?**
   ```bash
   curl -sS http://<droplet-ip>:8080/health
   ```
   If this fails, fix networking / security group / bind address first.

2. **Did the config upload happen at all?** (marker)
   - Over HTTP (no auth):
     ```bash
     curl -sS http://<droplet-ip>:8080/config/status
     ```
   - On the droplet:
     ```bash
     test -f /etc/config-api-uploaded && echo "Uploaded" || echo "Not uploaded"
     ```

3. **Were the expected files written?**
   ```bash
   ls -l /etc/habitat.json /etc/agents.json
   ```

4. **Did apply/restart run?**
   - `openclaw` service status
   - `/var/log/apply-config.log` (if present)

## Understanding the marker file

- Path: **`/etc/config-api-uploaded`**
- Written when: `POST /config/upload` successfully writes *any* config file(s)
- Contents: Unix timestamp (float)

### Interpretations
- Marker missing → upload never succeeded, or wrote nothing.
- Marker exists but bots not updated → upload succeeded, but apply/restart failed or was never requested (`apply: true`).

## Common failure modes

### 1) Upload returns 403 Forbidden
Cause: Missing/invalid HMAC headers.

Fix: Ensure client sends `X-Timestamp` and `X-Signature` for authenticated endpoints.

### 2) Upload returns 400 with `errors`
Cause: Schema/validation issue in payload.

Fix: Correct JSON schema; retry upload.

### 3) Marker exists but config not applied
Cause: `apply: true` not set, or apply failed.

Fix:
- Re-run upload with `apply: true`, or call `POST /config/apply`.
- Check `/var/log/apply-config.log`.

### 4) `/config/status` says uploaded=false, but files exist
Cause: Marker was deleted or written to a different path in older builds.

Fix: Re-upload (writes marker), or check code constant `MARKER_PATH`.
