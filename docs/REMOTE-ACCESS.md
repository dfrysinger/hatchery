# Remote Access to API Server

## Security Notice

**By default, the API server binds to `127.0.0.1` (localhost only) for security.** This prevents unauthorized access from the public internet.

To enable remote access (e.g., for iOS Shortcuts), you must explicitly opt in by setting `apiBindAddress` in your habitat configuration.

## Default Behavior (Secure)

Without configuration, the API server is only accessible from the droplet itself:

- **Bind Address:** `127.0.0.1:8080`
- **Accessible from:** Localhost only (SSH tunnel required for remote access)
- **Security:** API endpoints are not exposed to the internet

## Opt-In: Remote Access

To access the API server remotely (e.g., from iOS Shortcuts):

### 1. Update Habitat Configuration

Add `apiBindAddress` to your `habitat.json`:

```json
{
  "apiBindAddress": "0.0.0.0",
  "apiSecret": "your-secure-secret-here",
  ...
}
```

**Required:**
- `apiBindAddress: "0.0.0.0"` — Binds to all interfaces (enables remote access)
- `apiSecret: "..."` — Mandatory HMAC-SHA256 authentication secret

### 2. Firewall Configuration

**Security Notice:** Only allow access from trusted IP addresses. Do NOT open port 8080 to the entire internet.

```bash
# Check current firewall rules
sudo ufw status

# Allow port 8080 from your trusted IP (RECOMMENDED)
sudo ufw allow from YOUR_IP_ADDRESS/32 to any port 8080 proto tcp

# Or, for iOS Shortcut from cellular/roaming (less secure)
# Use IP allowlist or VPN (Tailscale/WireGuard) instead
```

**Alternatives to public exposure:**
- **DigitalOcean Cloud Firewall:** Create allowlist of trusted IPs
- **VPN:** Use Tailscale or WireGuard for secure roaming access
- **SSH Tunnel:** See "SSH Tunnel (Secure Alternative)" section below

### 3. DNS/IP Configuration

Configure your client (e.g., iOS Shortcut) to connect to:

```
http://YOUR_DROPLET_IP:8080/status
```

Or use a domain name if configured:

```
http://habitat.yourdomain.com:8080/status
```

## Authentication

All API endpoints require HMAC-SHA256 authentication when `API_SECRET` is set.

> **Full details:** See [Security: HMAC Authentication](security/SECURITY.md) for the complete signature format, replay protection, endpoint sensitivity table, and code examples (Python, iOS Shortcut).

**Quick reference:**

| Header | Value |
|--------|-------|
| `X-Timestamp` | Unix seconds |
| `X-Signature` | `HMAC-SHA256("{timestamp}.{method}.{path}.{body}", API_SECRET)` |

Replay window: 5 minutes (300 seconds).

## SSH Tunnel (Secure Alternative)

If you don't want to expose the API server publicly, use an SSH tunnel:

```bash
# On your local machine
ssh -L 8080:127.0.0.1:8080 root@YOUR_DROPLET_IP

# Access API locally
curl http://localhost:8080/status
```

This keeps the API server bound to `127.0.0.1` while allowing secure remote access via SSH.

## Security Best Practices

1. **Always set `API_SECRET`** when using `apiBindAddress: "0.0.0.0"`
2. **Use strong secrets** (32+ random characters)
3. **Rotate secrets** periodically
4. **Monitor access logs** in `/var/log/api-server.log` (if logging enabled)
5. **Restrict firewall rules** to known IP addresses when possible
6. **Use HTTPS** via reverse proxy (nginx/caddy) for production

## Troubleshooting

### API Not Accessible Remotely

1. **Check bind address:**
   ```bash
   grep API_BIND_ADDRESS /etc/droplet.env
   # Should show: API_BIND_ADDRESS="0.0.0.0"
   ```

2. **Check service is running:**
   ```bash
   systemctl status openclaw-api
   ```

3. **Check listening port:**
   ```bash
   netstat -tuln | grep 8080
   # Should show: 0.0.0.0:8080 (not 127.0.0.1:8080)
   ```

4. **Check firewall:**
   ```bash
   sudo ufw status | grep 8080
   # Should show: 8080/tcp ALLOW Anywhere
   ```

5. **Test from droplet:**
   ```bash
   curl http://0.0.0.0:8080/health
   ```

6. **Test from remote:**
   ```bash
   curl http://YOUR_DROPLET_IP:8080/health
   ```

### Authentication Failures

- **Verify API_SECRET matches** between habitat config and client
- **Check timestamp skew** (must be within 5 minutes)
- **Ensure body content matches** signature calculation (empty string for GET)

## References

- API Endpoints: See `scripts/api-server.py` docstring
- HMAC Authentication: [RFC 2104](https://tools.ietf.org/html/rfc2104)
- Security Model: [docs/security/SECURITY.md](security/SECURITY.md)
