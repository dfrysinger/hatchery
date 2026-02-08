# Minimal Habitat Configuration

When using the two-phase config approach (minimal user_data + API upload), you need a small habitat JSON in `HABITAT_B64` to bootstrap the droplet.

## Why Two-Phase?

DigitalOcean's `user_data` limit is **64KB**. Complex habitats with multiple agents, SOUL.md files, and AGENTS.md can exceed this. The solution:

1. **Phase 1 (user_data)**: Minimal habitat JSON — just enough to boot and notify
2. **Phase 2 (API)**: Full agent configs uploaded via POST to `/config/upload`

## Schema Version

This documents the **v2 schema** (recommended). The v1 schema is deprecated but still supported for backward compatibility. See [issue #112](https://github.com/dfrysinger/hatchery/issues/112) for migration timeline.

## Minimal Required Fields

```json
{
  "name": "MyHabitat",
  "platform": "discord",
  "platforms": {
    "discord": {
      "ownerId": "YOUR_DISCORD_USER_ID"
    }
  },
  "agents": [
    {
      "agent": "claude",
      "tokens": {
        "discord": "YOUR_BOT_TOKEN"
      }
    }
  ]
}
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` | **Yes** | Habitat name (used in notifications, logs) |
| `platform` | **Yes** | `telegram`, `discord`, or `both` |
| `platforms.discord.ownerId` | If discord | Your Discord user ID for DM notifications |
| `platforms.telegram.ownerId` | If telegram | Your Telegram user ID for notifications |
| `agents` | **Yes (1+)** | At least one agent with bot token for notifications |
| `agents[].agent` | **Yes** | Agent name (becomes directory name) |
| `agents[].tokens.discord` | If discord | Bot token for Discord |
| `agents[].tokens.telegram` | If telegram | Bot token for Telegram |

### Optional Fields (have defaults)

| Field | Default | Description |
|-------|---------|-------------|
| `destructMinutes` | `0` | Auto-destruct timer (0 = disabled) |
| `bgColor` | `2D3748` | Desktop background color |
| `apiBindAddress` | `0.0.0.0` | API server bind address |
| `domain` | (empty) | Custom domain for the droplet |
| `globalIdentity` | (empty) | Shared IDENTITY.md content |
| `globalSoul` | (empty) | Shared SOUL.md content |
| `globalAgents` | (empty) | Shared AGENTS.md content |
| `globalUser` | (empty) | Shared USER.md content |
| `globalBoot` | (empty) | Shared boot task content |
| `globalTools` | (empty) | Shared TOOLS.md content |

## Platform Examples

### Discord-Only (Smallest)

```json
{
  "name": "QuickBot",
  "platform": "discord",
  "platforms": {
    "discord": { "ownerId": "795380005466800159" }
  },
  "agents": [{
    "agent": "bot",
    "tokens": { "discord": "MTIz..." }
  }]
}
```

### Telegram-Only

```json
{
  "name": "QuickBot",
  "platform": "telegram",
  "platforms": {
    "telegram": { "ownerId": "123456789" }
  },
  "agents": [{
    "agent": "bot",
    "tokens": { "telegram": "123:ABC..." }
  }]
}
```

### Both Platforms

```json
{
  "name": "DualBot",
  "platform": "both",
  "platforms": {
    "discord": { "ownerId": "795380005466800159" },
    "telegram": { "ownerId": "123456789" }
  },
  "agents": [{
    "agent": "bot",
    "tokens": {
      "discord": "MTIz...",
      "telegram": "123:ABC..."
    }
  }]
}
```

## iOS Shortcut Flow

```
1. Build minimal habitat JSON (above)
2. Base64 encode it
3. Include in user_data as HABITAT_B64
4. Create droplet
5. Wait for health check (GET /health)
6. POST full agent configs to /config/upload
7. Droplet applies config and restarts bots
```

## What Can Be Uploaded Later (Phase 2)

Everything not needed for boot notifications:

- Additional agents beyond the first
- Agent personality files (IDENTITY.md, SOUL.md, etc.)
- Global files content
- Council configuration
- Complex model settings

See [API Config Upload](./api-config-upload.md) for the upload endpoint spec.

---

## Legacy v1 Schema (Deprecated)

The old format with top-level `discord`/`telegram` and `discordBotToken`/`telegramBotToken` is still supported but deprecated:

```json
{
  "name": "MyHabitat",
  "platform": "discord",
  "discord": { "ownerId": "..." },
  "agents": [{ "agent": "bot", "discordBotToken": "..." }]
}
```

This will be removed in a future release. See [issue #112](https://github.com/dfrysinger/hatchery/issues/112).
