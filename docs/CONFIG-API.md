# Config API Documentation

This document describes the config upload API endpoints and the `api_uploaded` flag semantics.

## Endpoints Overview

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/config/status` | GET | No | Simple upload status (api_uploaded only) |
| `/config` | GET | Yes | Full config status (files, timestamps) |
| `/config/upload` | POST | Yes | Upload and optionally apply config |
| `/config/apply` | POST | Yes | Apply existing config |

## Config Provisioning Modes

Hatchery supports two config provisioning modes:

### 1. API-Uploaded Mode

Config is uploaded via the `/config/upload` endpoint, typically from iOS Shortcuts.

**Flow:**
```
iOS Shortcut → POST /config/upload → writes config files → apply (optional)
```

**Marker:**
- Creates `/etc/config-api-uploaded` with upload timestamp
- `api_uploaded: true` in status responses

**Use Case:**
- Dynamic config updates after droplet creation
- Remote management via iOS Shortcuts
- Config changes without droplet recreation

### 2. Apply-Only Mode

Config is placed via cloud-init or manual copy, then applied locally.

**Flow:**
```
cloud-init → writes config files → apply-config.sh
```

**Marker:**
- NO `/etc/config-api-uploaded` file
- `api_uploaded: false` in status responses

**Use Case:**
- Self-contained droplet provisioning
- Config baked into cloud-init YAML
- No external API dependency

## Status Response Interpretation

### GET /config/status (Unauthenticated)

```json
{
  "api_uploaded": false,
  "api_uploaded_at": null
}
```

**Important:** `api_uploaded: false` does NOT mean "unconfigured". It only means config was never uploaded via the API. For full state, use GET /config.

### GET /config (Authenticated)

```json
{
  "habitat_exists": true,
  "agents_exists": true,
  "habitat_modified": 1707676800.0,
  "agents_modified": 1707676800.0,
  "habitat_name": "MyHabitat",
  "habitat_agent_count": 3,
  "agents_names": ["Claude", "ChatGPT", "Gemini"],
  "api_uploaded": false,
  "api_uploaded_at": null
}
```

### State Matrix

| api_uploaded | habitat_exists | Meaning |
|--------------|----------------|---------|
| `false` | `false` | Fresh droplet, no config yet |
| `false` | `true` | **Apply-only mode** (cloud-init/manual) |
| `true` | `false` | Error state (marker but no config) |
| `true` | `true` | API-provisioned (normal flow) |

## Polling Best Practices

### For iOS Shortcuts

If you need to check if a droplet is "ready":

```
# Don't just check api_uploaded (misses apply-only mode)
GET /config/status → api_uploaded

# Better: check if config exists (requires auth)
GET /config → habitat_exists AND agents_exists
```

### For Health Checks

The `/health` endpoint is better for general readiness:

```
GET /health → {"status": "ok", ...}
```

## Upload Endpoint Details

### POST /config/upload

Uploads habitat and/or agents config, optionally applying immediately.

**Request:**
```json
{
  "habitat": { ... },  // Optional: habitat config
  "agents": { ... },   // Optional: agents library
  "apply": true        // Optional: apply after upload
}
```

**Response:**
```json
{
  "ok": true,
  "files_written": ["/etc/habitat.json", "/etc/agents.json"],
  "applied": true
}
```

**Side Effects:**
- Writes config files to `/etc/`
- Creates `/etc/config-api-uploaded` marker
- If `apply: true`, triggers config apply script

### POST /config/apply

Applies existing config without upload.

**Request:** Empty body or `{}`

**Response:**
```json
{
  "ok": true,
  "restarting": true
}
```

**Note:** This does NOT create the upload marker. Useful for re-applying config after manual edits.

## Security

- `/config/status` is unauthenticated (safe: only returns boolean)
- All other `/config/*` endpoints require HMAC authentication
- Config files are written with mode 0600 (owner-only)
- Marker file is written with mode 0600

## Related Issues

- Issue #115: Added api_uploaded flag
- Issue #119: Documented apply-only mode semantics
- Issue #130: Added unauthenticated /config/status endpoint
