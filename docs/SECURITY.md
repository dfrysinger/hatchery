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
│  │  • API Server (0.0.0.0:8080)                    │   │
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

**This means:**
- API server can safely bind to `0.0.0.0` (all interfaces)
- Only your phone can reach the droplet
- No SSH tunnels or VPNs required

### Why This Is Secure

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
TIMESTAMP=$(date +%s)
SIGNATURE=$(echo -n "${TIMESTAMP}${BODY}" | openssl dgst -sha256 -hmac "${API_SECRET}" | cut -d' ' -f2)

# Include in request
curl -X POST http://$HOST:8080/sync \
  -H "X-Timestamp: ${TIMESTAMP}" \
  -H "X-Signature: ${SIGNATURE}"
```

**Purpose:** Defense-in-depth. If firewall is misconfigured, HMAC still protects.

## API Endpoints by Sensitivity

| Endpoint | Auth Required | Notes |
|----------|---------------|-------|
| `/status` | No | Read-only status (safe to expose) |
| `/health` | No | Simple health check |
| `/stages` | No | Boot progress log |
| `/config` | No | Config status (no secrets) |
| `/sync` | **Yes (HMAC)** | Triggers Dropbox sync |
| `/prepare-shutdown` | **Yes (HMAC)** | Graceful shutdown |
| `/config/upload` | **Yes (HMAC)** | Upload configuration |
| `/config/apply` | **Yes (HMAC)** | Apply config (restart) |

## Binding to 0.0.0.0

The API server binds to all interfaces (`0.0.0.0:8080`) rather than localhost only.

**Why this is acceptable:**
1. DO Firewall blocks all traffic except from your IP
2. HMAC protects sensitive endpoints
3. iOS Shortcuts need direct access (can't use localhost)
4. `/status` and `/health` leak minimal info even if exposed

**If you're paranoid:** Use the Cloudflare Tunnel alternative (see below).

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
