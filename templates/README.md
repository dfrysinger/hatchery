# Habitat Templates

Ready-to-use habitat configuration templates.

## Minimal Templates (for two-phase config)

These contain the minimum fields needed to bootstrap a droplet. Use with the API config upload for full agent configurations.

| Template | Use Case |
|----------|----------|
| `minimal-habitat-discord.json` | Discord-only habitat |
| `minimal-habitat-telegram.json` | Telegram-only habitat |

### Usage in iOS Shortcut

1. Copy the template content
2. Replace placeholder values:
   - `YOUR_DISCORD_USER_ID` → Your Discord user ID
   - `YOUR_TELEGRAM_USER_ID` → Your Telegram user ID  
   - `YOUR_BOT_TOKEN` → Bot token from Discord/Telegram
   - `MyHabitat` → Your habitat name
3. Base64 encode the JSON
4. Pass as `HABITAT_B64` in droplet user_data

See [Minimal Habitat Docs](../docs/minimal-habitat.md) for full details.
