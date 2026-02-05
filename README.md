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

## TODO

- [ ] Publish and link iOS Shortcuts used in this project
  - Habitat provisioning shortcut (create droplet)
  - Habitat status checker
  - Habitat destroyer

## Version History

See [git log](https://github.com/dfrysinger/hatchery/commits/main) for full history. Current: **v4.3**
