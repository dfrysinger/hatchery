# Hatchery

Ephemeral cloud habitats — self-configuring DigitalOcean droplets with AI agents, remote desktop, and browser automation. Provisioned in minutes from an iOS Shortcut.

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

## Version History

See [git log](https://github.com/dfrysinger/hatchery/commits/main) for full history. Current: **v4.3**
