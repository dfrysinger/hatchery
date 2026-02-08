# Allowed Firewall Ports

This document defines the **only** ports that should be exposed on habitat droplets.
Both the iOS Shortcut firewall AND the hatch scripts must match this list.

> **Security Context:** See [SECURITY.md](SECURITY.md) for the full security model.
> The primary protection is the **DigitalOcean Cloud Firewall** which restricts access
> to your phone's IP only. The API server binding to `0.0.0.0` is safe because
> traffic is blocked at the cloud firewall level before reaching the droplet.

## Required Ports

| Port | Protocol | Service | Notes |
|------|----------|---------|-------|
| 22 | TCP | SSH | LIMIT rule (rate-limited) |
| 3389 | TCP | RDP | Authenticated remote desktop |
| 8080 | TCP | API Server | Status/health endpoints |
| 18789 | TCP | Clawdbot Gateway | Bot communication |

## Conditionally Allowed

| Port | Protocol | Service | Condition |
|------|----------|---------|-----------|
| 80 | TCP | HTTP | Only when HABITAT_DOMAIN is set (ACME challenges) |
| 443 | TCP | HTTPS | Only when HABITAT_DOMAIN is set |

## Forbidden Ports (NEVER expose)

| Port | Service | Reason |
|------|---------|--------|
| 5900 | VNC | No auth by default, use RDP tunnel instead |
| 5901 | VNC alt | Same as above |
| 6000-6010 | X11 | X11 forwarding is insecure |

## Verification

Run on a live droplet to verify firewall matches policy:
```bash
/usr/local/bin/verify-firewall.sh
```

## iOS Shortcut Sync

The "Create Habitat Firewall" Shortcut must be updated manually to match this list.
CI cannot test the Shortcut directly, but post-boot verification catches mismatches.
