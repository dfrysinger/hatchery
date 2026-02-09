# Security Architecture

This document explains the security model for Hatchery habitats.

## Overview

Hatchery uses **defense-in-depth** with multiple layers:

1. **DigitalOcean Cloud Firewall** (primary) — IP allowlisting at the infrastructure level
2. **HMAC Authentication** — Request signing for API endpoints
3. **UFW** (optional) — Host-level firewall as backup

## DigitalOcean Firewall

The primary security layer is a **cloud firewall managed via iOS Shortcut**.

### How It Works

```
┌─────────────────────────────────────────────────────────┐
│                    DigitalOcean                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │           Cloud Firewall (DO API)                │   │
│  │  ┌─────────────────────────────────────────┐    │   │
│  │  │ ALLOW from: [Your Phone IP]             │    │   │
│  │  │ ALLOW ports: 22, 3389, 8080, 18789      │    │   │
│  │  │ DENY all other inbound                  │    │   │
│  │  └─────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────┘   │
│                         │                               │
│                         ▼                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Habitat Droplet                     │   │
│  │  • API Server (127.0.0.1:8080 default)          │   │
│  │  • Clawdbot Gateway (:18789)                    │   │
│  │  • RDP (:3389), SSH (:22)                       │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Dynamic IP Handling

Your phone's IP changes frequently (cellular, WiFi, travel). The "Repair Habitat Firewall" Shortcut handles this:

1. Shortcut detects current public IP
2. Calls DO API to update firewall rules
3. New IP is immediately allowed

**When remote API access is enabled (`remoteApi: true`):**
- API server binds to `0.0.0.0` (all interfaces) for iOS Shortcut access
- DO Firewall ensures only your phone can reach the droplet
- No SSH tunnels or VPNs required for remote management

### Why This Is Secure

**Note:** By default, the API server binds to `127.0.0.1` (localhost-only), preventing any external access. Remote API access via `0.0.0.0` binding is opt-in only (see "API Bind Address" section below).

When remote API access is enabled with DO Firewall protection:

| Attack Vector | Mitigation |
|---------------|------------|
| Port scanning | DO firewall blocks all non-allowlisted IPs |
| Endpoint enumeration | Blocked at cloud level before reaching droplet |
| Brute force | Can't even connect without allowlisted IP |
| IP spoofing | TCP handshake required; spoofing doesn't work |

## HMAC Authentication

Even with the firewall, API endpoints use HMAC request signing:

```bash
# Generate signature
# Message format: "{timestamp}.{method}.{path}.{body}"
TIMESTAMP=$(date +%s)
METHOD="POST"
PATH="/sync"
BODY="{}"  # Empty JSON for sync
MESSAGE="${TIMESTAMP}.${METHOD}.${PATH}.${BODY}"
SIGNATURE=$(echo -n "${MESSAGE}" | openssl dgst -sha256 -hmac "${API_SECRET}" | cut -d' ' -f2)

# Include in request
curl -X POST http://$HOST:8080/sync \
  -H "X-Timestamp: ${TIMESTAMP}" \
  -H "X-Signature: ${SIGNATURE}" \
  -H "Content-Type: application/json" \
  -d "${BODY}"
```

**Message format:** `{timestamp}.{method}.{path}.{body}` — all four components dot-separated.

**Purpose:** Defense-in-depth. If firewall is misconfigured, HMAC still protects.

## API Endpoints by Sensitivity

| Endpoint | Auth Required | Notes |
|----------|---------------|-------|
| `/status` | No | Read-only status (safe to expose) |
| `/health` | No | Simple health check |
| `/config/status` | No | Upload status only (no secrets) |
| `/stages` | **Yes (HMAC)** | Boot progress log (may contain sensitive info) |
| `/log` | **Yes (HMAC)** | Boot logs (may contain sensitive info) |
| `/config` | **Yes (HMAC)** | Config file status (may leak structure) |
| `/sync` | **Yes (HMAC)** | Triggers Dropbox sync |
| `/prepare-shutdown` | **Yes (HMAC)** | Graceful shutdown |
| `/config/upload` | **Yes (HMAC)** | Upload configuration |
| `/config/apply` | **Yes (HMAC)** | Apply config (restart) |

## API Bind Address (Secure-by-Default)

The API server defaults to **127.0.0.1:8080** (localhost-only) for security.

**Default behavior:**
- API is **not** exposed to the internet
- Only local processes can access it
- Suitable for SSH tunnel or reverse proxy access

**Opt-in for iOS Shortcut remote access:**

**Option 1: Simple (recommended)**
```json
{
  "name": "MyHabitat",
  "remoteApi": true,
  ...
}
```

**Option 2: Advanced override**
```json
{
  "apiBindAddress": "0.0.0.0"
}
```

After enabling remote access:
1. Configure DO Firewall to allowlist your IP (see `docs/REMOTE-ACCESS.md`)
2. HMAC authentication protects sensitive endpoints

**Priority:** `apiBindAddress` (if set) > `remoteApi` (if true) > default (127.0.0.1)

**Why remote binding (`0.0.0.0`) is acceptable when opted-in and properly configured:**
- DO Firewall blocks all traffic except from your allowlisted IP
- HMAC protects sensitive endpoints (`/sync`, `/config`, `/stages`, etc.)
- iOS Shortcuts need direct HTTP access (can't use localhost)
- Only `/status`, `/health`, and `/config/status` are unauthenticated (minimal info)

**Important:** Remote binding is **opt-in only**. The API defaults to localhost-only (`127.0.0.1`) for security. Enable remote access only when using iOS Shortcuts or similar remote management tools.

**For zero-port-exposure:** Use SSH tunnels or Cloudflare Tunnel (see below).

## Alternative: Cloudflare Tunnel

For zero-port-exposure setup:

```bash
# Install cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared

# Create tunnel
cloudflared tunnel create hatchery
cloudflared tunnel route dns hatchery hatchery.yourdomain.com

# Run (add to systemd for persistence)
cloudflared tunnel run hatchery
```

Then access via `https://hatchery.yourdomain.com/status` — no firewall rules needed.

## Security Checklist

- [ ] DO Firewall created with correct ports
- [ ] Firewall attached to droplet
- [ ] API_SECRET generated and stored in iOS Shortcut
- [ ] HMAC auth enabled on sensitive endpoints
- [ ] "Repair Habitat Firewall" Shortcut tested

## Incident Response

If you suspect compromise:

1. **Immediately:** Run "Destroy Habitat" Shortcut
2. **Rotate:** Generate new API_SECRET
3. **Audit:** Check DO access logs
4. **Rebuild:** Create fresh habitat with new secrets
