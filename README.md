# Hatchery

Ephemeral cloud habitats — self-configuring DigitalOcean droplets with AI agents, remote desktop, and browser automation. Provisioned in minutes from an iOS Shortcut.

> 📋 **[See the Roadmap](ROADMAP.md)** for upcoming features including the Shortcut Configuration Wizard.

## What It Does

A single tap on your phone spins up a fully configured cloud desktop with:
- **AI Agent** (ClawdBot/OpenClaw) with Telegram integration
- **Remote Desktop** (XFCE4 via RDP/VNC)
- **Chrome** with remote debugging
- **Dev tools** — git, gh, ffmpeg, LibreOffice, and more
- **Optional self-destruct timer** — habitats are ephemeral by design

## Files

| File | Description |
|---|---|
| `hatch.yaml` | Cloud-init template — the habitat blueprint |
| `gmail-api.py` | Gmail API script (externalized from YAML) |
| `set-council-group.sh` | Council group setup (externalized from YAML) |
| `version.json` | Current version metadata |

## Usage

Your shortcut fetches the template, fills in credentials, and sends it to the DigitalOcean API:

```
GET https://raw.githubusercontent.com/dfrysinger/hatchery/main/hatch.yaml
```

Version check:
```
GET https://raw.githubusercontent.com/dfrysinger/hatchery/main/version.json
```

## iOS Shortcuts

> **TODO:** Publish and link shortcuts below

### Lifecycle
| Shortcut | Description |
|---|---|
| Create Habitat | Provision a new habitat from `hatch.yaml` |
| Open Habitat | Open a habitat — connects if running, creates if not |
| Shutdown Habitat | Graceful shutdown with state sync |
| Destroy Habitat | Tear down a habitat |
| Destroy All Droplets | Nuclear option — destroy everything |

### Monitoring
| Shortcut | Description |
|---|---|
| Get Habitat Status | Poll the status API (`/status`) |
| Get Habitat Installation Status | Track boot progress through phases |
| Keepalive Habitat | Prevent idle destruction |
| Test Habitat RDP | Verify remote desktop connectivity |

### Networking
| Shortcut | Description |
|---|---|
| Create Habitat Firewall | Set up DO firewall rules |
| Repair Habitat Firewall | Refresh firewall rules (e.g. when your IP changes) |
| Test Habitat Firewall | Verify firewall rules |
| Update Habitat DDNS | Update dynamic DNS records |
| Test Habitat DNS | Verify DNS resolution |
| Destroy Habitat Firewall | Remove firewall rules |

### Helpers
| Shortcut | Description |
|---|---|
| Get Habitat Info | Fetch droplet metadata from DO API |
| Get Habitat Variable | Read a specific habitat config value |
| Get Habitat Filename | Resolve the habitat JSON config file path |
| Get Habitat Status Filename | Resolve status log filename |
| Get Habitat Name | Get the habitat's display name |
| Get Habitat Selection Filename | Resolve the stored habitat selection (user's chosen habitat) |
| Get Elapsed Time | Calculate provisioning duration |
| Get Token | Retrieve API authentication token |
| Creating Droplet | Droplet creation sub-routine |

## Droplet API

Each droplet runs a lightweight HTTP API on port 8080:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/status` | GET | Full provisioning status |
| `/health` | GET | Health check (200 if bot online) |
| `/stages` | GET | Raw init-stages.log |
| `/config` | GET | Config file status (no secrets) |
| `/config/upload` | POST | Upload habitat + agents JSON |
| `/config/apply` | POST | Apply config and restart |
| `/sync` | POST | Trigger state sync to Dropbox |
| `/prepare-shutdown` | POST | Sync and stop for shutdown |

### Config Upload Flow

For large configs that exceed DO's 64KB user_data limit:

```bash
# 1. Create droplet with slim YAML
# 2. Wait for boot
curl http://$DROPLET_IP:8080/health

# 3. Upload config
curl -X POST http://$DROPLET_IP:8080/config/upload \
  -H "Content-Type: application/json" \
  -d '{
    "habitat": {"name": "MyHabitat", ...},
    "agents": {"agent-name": {"identity": "..."}},
    "apply": true
  }'
```

## Shortcut Configuration Wizard *(Coming Soon)*

Configure habitats through an interactive iOS Shortcut wizard:

1. **Configure** — Step-by-step habitat setup (platform, agents, tokens)
2. **Save** — Store config to iCloud, Dropbox, or local device
3. **Launch** — One-tap droplet creation from saved config
4. **Edit** — Modify saved configs anytime via the wizard

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Wizard    │ ──► │   Config    │ ──► │   Launch    │
│   Setup     │     │   Storage   │     │   Droplet   │
└─────────────┘     └─────────────┘     └─────────────┘
                         │
                    ┌────┴────┐
                    │ iCloud  │
                    │ Dropbox │
                    │  Local  │
                    └─────────┘
```

See [ROADMAP.md](ROADMAP.md) for details.

## Version History

See [git log](https://github.com/dfrysinger/hatchery/commits/main) for full history. Current: **v4.3**

## Security

> **📖 See [docs/SECURITY.md](docs/SECURITY.md) for the full security architecture.**

### Network Security Model

Hatchery uses **defense-in-depth** with multiple layers:

1. **DigitalOcean Cloud Firewall** — Primary protection. Only your phone's IP can reach the droplet.
2. **HMAC Authentication** — Sensitive API endpoints require signed requests.
3. **UFW** (optional) — Host-level backup firewall.

**API Bind Address (Secure-by-Default):**

The API server defaults to **127.0.0.1** (localhost-only) for security.

- **Default:** `API_BIND_ADDRESS=127.0.0.1` — not reachable from the internet
- **Opt-in for iOS Shortcuts:** Set `apiBindAddress: "0.0.0.0"` in your habitat config
- **When enabled:** DO Firewall blocks all traffic except from your allowlisted IP
- **Authentication:** HMAC protects sensitive endpoints (`/sync`, `/prepare-shutdown`, `/config/*`)

See `docs/REMOTE-ACCESS.md` for remote access setup and security hardening.

**Dynamic IP Handling:**
Your phone's IP changes often. The "Repair Habitat Firewall" Shortcut updates DO Firewall rules instantly when your IP changes.

### Dependency Scanning

Hatchery uses `pip-audit` to automatically scan Python dependencies for known security vulnerabilities. This runs on every PR and push to main.

**Run security scan locally:**
```bash
pip install pip-audit
pip-audit
```

**Handling audit failures:**

If CI fails due to vulnerabilities:

1. **Check severity**: High/critical vulnerabilities block merge
2. **Upgrade affected package**: 
   ```bash
   pip install --upgrade <package-name>
   pip freeze | grep <package-name> >> requirements.txt
   ```
3. **Test after upgrade**: Run `pytest tests/ -v` to verify compatibility
4. **If no fix available**: Document in GitHub issue, tag maintainers

**Exception process:**

If a vulnerability cannot be fixed (e.g., no patch available, false positive):

1. Create GitHub issue documenting:
   - CVE/vulnerability ID
   - Why it cannot be fixed
   - Risk assessment
   - Mitigation steps (if any)
2. Temporarily allow via `pip-audit --ignore-vuln <CVE-ID>` in CI
3. Add expiry reminder: "Re-evaluate by YYYY-MM-DD"
4. Requires approval from EL or Judge

## Contributing Rules

### ⚠️ ASCII Only in Cloud-Init Files
**All `.yaml`, `.sh`, and `.py` files must contain only ASCII characters (bytes 0-127).**

DigitalOcean's cloud-init parser silently fails on Unicode. Common offenders:
- `—` (em dash) → use `--`
- `→` (arrow) → use `->`
- `…` (ellipsis) → use `...`
- `'` `'` (curly quotes) → use `'`

CI enforces this automatically via `tests/test_ascii.py`.
