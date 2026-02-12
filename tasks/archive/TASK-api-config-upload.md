# TASK: API Config Upload Endpoints

## Summary
Add endpoints to the droplet's HTTP API (`api-server.py`) to receive habitat and agent library JSON files after boot, enabling the iOS Shortcut to send configuration separately from the cloud-init YAML.

## Problem
- DigitalOcean's `user_data` limit is 64KB
- Current `hatch.yaml` is 77KB (already over limit)
- Agent libraries can be 50KB+ of markdown content
- Need a way to send large configs without hitting the limit

## Solution
Add API endpoints that accept JSON config uploads after the droplet boots, then apply the configuration and restart OpenClaw.

## Goals
1. Enable config upload via HTTP API after droplet boot
2. Support both habitat config and agent library uploads
3. Apply config changes without manual intervention
4. Keep the solution general-purpose (no Dropbox dependency)

## Acceptance Criteria

### AC1: POST /config/upload endpoint
- [ ] Accepts JSON body with optional `habitat` and `agents` fields
- [ ] Writes habitat to `/etc/habitat.json` with 0600 permissions
- [ ] Writes agents to `/etc/agents.json` with 0600 permissions
- [ ] Returns JSON response with `ok`, `files_written` fields
- [ ] Returns 400 for invalid JSON
- [ ] Returns 500 with error message on write failure

### AC2: POST /config/apply endpoint
- [ ] Triggers `/usr/local/bin/apply-config.sh` asynchronously
- [ ] Returns immediately with `{"ok": true, "restarting": true}`
- [ ] Does not block the HTTP response

### AC3: Combined upload + apply
- [ ] POST /config/upload with `apply: true` writes files AND triggers apply
- [ ] Returns `{"ok": true, "files_written": [...], "applied": true}`

### AC4: apply-config.sh script
- [ ] Reads `/etc/habitat.json` and exports as `HABITAT_B64`
- [ ] Reads `/etc/agents.json` and exports as `AGENT_LIB_B64`
- [ ] Runs `parse-habitat.py` to regenerate `/etc/habitat-parsed.env`
- [ ] Runs `build-full-config.sh` to regenerate OpenClaw config
- [ ] Restarts `clawdbot` service
- [ ] Logs all actions to `/var/log/apply-config.log`

### AC5: GET /config endpoint
- [ ] Returns current config status (files exist, last modified times)
- [ ] Does NOT expose sensitive data (tokens, keys)

### AC6: GET /config/status endpoint (unauthenticated)
- [ ] Returns only `api_uploaded` and `api_uploaded_at`
- [ ] Safe for polling (no secrets)

### AC7: Tests
- [ ] Unit tests for JSON parsing and validation
- [ ] Unit tests for file writing logic
- [ ] Unit tests for response formatting
- [ ] Integration test for full upload → apply flow (mocked)

## Out of Scope
- Authentication (API is only accessible on local network)
- Config validation (OpenClaw validates on startup)
- Rollback on failure

## Files to Create/Modify
1. `scripts/api-server.py` - Add new endpoints
2. `scripts/apply-config.sh` - New script
3. `hatch.yaml` - Include apply-config.sh in write_files
4. `tests/test_api_config.py` - Unit tests

## Upload Marker (`api_uploaded`)

After a successful `POST /config/upload` that writes at least one file, the API server writes a marker file:

- Path: **`/etc/config-api-uploaded`**
- Permissions: `0600`
- Contents: Unix timestamp (float)

This enables safe, unauthenticated polling via:

- `GET /config/status` → `{"api_uploaded": <bool>, "api_uploaded_at": <float|null>}`

## Usage Example

```bash
# After droplet boots and /health returns healthy:

# Upload config
curl -X POST http://droplet-ip:8080/config/upload \
  -H "Content-Type: application/json" \
  -d '{
    "habitat": {"name": "JobHunt", "agents": [...]},
    "agents": {"resume-optimizer": {...}},
    "apply": true
  }'

# Response:
# {"ok": true, "files_written": ["/etc/habitat.json", "/etc/agents.json"], "applied": true}

# Check status
curl http://droplet-ip:8080/config
# {"habitat_exists": true, "agents_exists": true, "last_applied": "2024-..."}
```
