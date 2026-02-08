# Hatchery Roadmap

## Vision

Make provisioning AI-powered cloud desktops as easy as tapping a button on your phone. Users configure their habitat once through a wizard, save the config, and launch droplets instantly.

---

## Current State (v4.x)

- ✅ Cloud-init YAML template (`hatch.yaml`)
- ✅ Multi-agent support (up to 10 agents)
- ✅ Discord and Telegram platforms
- ✅ Habitat JSON configs in Dropbox
- ✅ iOS Shortcuts for lifecycle management
- ✅ Droplet status API (`/status`, `/health`)

---

## Phase 1: Config Upload API *(In Progress — PR #93)*

**Goal:** Solve the 64KB user_data limit by uploading large configs via HTTP after boot.

- [x] `POST /config/upload` — Upload habitat + agents JSON
- [x] `POST /config/apply` — Apply config and restart
- [x] `GET /config` — View config status
- [x] `apply-config.sh` — Script to apply uploaded config
- [x] Unit tests (23 tests)
- [ ] Integration with hatch-slim.yaml

**New Flow:**
```
Shortcut → Create droplet (slim YAML) → Poll /health → POST /config/upload
```

---

## Phase 2: Shortcut Wizard *(Planned)*

**Goal:** Let users configure habitats through an interactive Shortcut wizard instead of editing JSON manually.

### Features

1. **Configuration Wizard**
   - Step-by-step habitat setup
   - Platform selection (Telegram/Discord/Both)
   - Agent selection from library
   - Bot token input with validation
   - Auto-destruct timer setting

2. **Config Storage Options**
   - iCloud Drive (default, private)
   - Dropbox (for cross-device access)
   - Local on device (offline-capable)

3. **Config Management**
   - List saved configs
   - Edit existing configs via wizard
   - Duplicate and modify configs
   - Delete configs

4. **Launch Flow**
   - Select saved config → Create droplet
   - Config automatically uploaded via `/config/upload`
   - Progress tracking with notifications

### User Stories

```
As a user, I want to:
- Configure a new habitat through guided prompts
- Save my config for reuse
- Edit my saved configs when I need changes
- Launch a droplet from any saved config with one tap
- Store configs in my preferred location (iCloud/Dropbox/local)
```

### Technical Approach

```
┌─────────────────────────────────────────────────────────────┐
│                    SHORTCUT WIZARD                          │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐     │
│  │ Platform│ → │ Agents  │ → │ Tokens  │ → │  Save   │     │
│  │ Select  │   │ Select  │   │  Input  │   │ Config  │     │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    CONFIG STORAGE                           │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐                │
│  │  iCloud  │   │ Dropbox  │   │  Local   │                │
│  │  Drive   │   │          │   │  Files   │                │
│  └──────────┘   └──────────┘   └──────────┘                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   LAUNCH DROPLET                            │
│  1. Read saved config from storage                          │
│  2. Create droplet with hatch-slim.yaml                     │
│  3. Poll /health until ready                                │
│  4. POST /config/upload with saved config                   │
│  5. Notify user: "Habitat ready!"                           │
└─────────────────────────────────────────────────────────────┘
```

### Config File Format

Saved configs combine habitat + agents in one file:

```json
{
  "_meta": {
    "version": 1,
    "created": "2024-02-08T00:00:00Z",
    "modified": "2024-02-08T00:00:00Z",
    "wizard_version": "1.0"
  },
  "habitat": {
    "name": "MyHabitat",
    "platform": "telegram",
    "telegram": { "ownerId": "123456789" },
    "agents": [
      { "agent": "resume-optimizer", "telegramBotToken": "..." }
    ]
  },
  "agents": {
    "resume-optimizer": {
      "model": "anthropic/claude-sonnet-4-5",
      "identity": "..."
    }
  }
}
```

---

## Phase 3: Agent Library *(Future)*

**Goal:** Curated library of pre-built agents users can add to their habitats.

- Agent marketplace/catalog
- One-tap agent installation
- Community-contributed agents
- Agent versioning and updates

---

## Phase 4: Multi-Habitat Management *(Future)*

**Goal:** Manage multiple habitats from a single interface.

- Dashboard showing all active habitats
- Quick switch between habitats
- Batch operations (shutdown all, etc.)
- Cost tracking and alerts

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. PRs welcome!

---

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| v4.3 | 2024-02 | Config upload API, agent library support |
| v4.2 | 2024-02 | x11vnc fix, memory restore before boot |
| v4.1 | 2024-01 | Discord multi-bot support |
| v4.0 | 2024-01 | Dual platform (Telegram + Discord) |
| v3.x | 2023 | Initial release, Telegram-only |
