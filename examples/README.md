# Example Habitat Configuration Files

This directory contains example habitat JSON files for configuring a Hatchery deployment. These files use **placeholder tokens** — you must replace them with your own values before use.

## What is a Habitat JSON File?

A habitat JSON file defines the configuration for a Hatchery instance: which platform(s) to connect to, which AI agents to run, bot tokens, owner IDs, and shared personality/identity settings. Hatchery reads this file at startup to provision your agents.

## Platform Modes

Hatchery supports three platform modes, set via the `"platform"` field:

| Mode | File | Description |
|------|------|-------------|
| `"discord"` | [habitat-discord.json](habitat-discord.json) | Agents run only on Discord |
| `"telegram"` | [habitat-telegram.json](habitat-telegram.json) | Agents run only on Telegram |
| `"both"` | [habitat-both.json](habitat-both.json) | Agents run on both Discord and Telegram simultaneously |

## Filling in Placeholders

Every value prefixed with `YOUR_` must be replaced with your actual credentials:

### Discord

| Placeholder | Where to Find It |
|---|---|
| `YOUR_DISCORD_SERVER_ID` | Right-click your server name → **Copy Server ID** (enable Developer Mode in Discord Settings → Advanced) |
| `YOUR_DISCORD_USER_ID` | Right-click your username → **Copy User ID** (requires Developer Mode) |
| `YOUR_*_DISCORD_BOT_TOKEN` | [Discord Developer Portal](https://discord.com/developers/applications) → your application → **Bot** → **Reset Token** |

**Creating a Discord bot:**
1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **New Application**, give it a name
3. Go to the **Bot** tab, click **Reset Token**, and copy it
4. Under **Privileged Gateway Intents**, enable **Message Content Intent**
5. Go to **OAuth2 → URL Generator**, select `bot` scope with appropriate permissions
6. Use the generated URL to invite the bot to your server

### Telegram

| Placeholder | Where to Find It |
|---|---|
| `YOUR_TELEGRAM_USER_ID` | Message [@userinfobot](https://t.me/userinfobot) on Telegram — it replies with your numeric user ID |
| `YOUR_*_TELEGRAM_BOT_TOKEN` | Message [@BotFather](https://t.me/BotFather) on Telegram → `/newbot` → follow prompts → copy the token |
| `YOUR_TELEGRAM_GROUP_ID` | Add [@raw_data_bot](https://t.me/raw_data_bot) to your group and it will show the group's numeric ID |

**Creating a Telegram bot:**
1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts to choose a name and username
3. Copy the bot token provided
4. Send `/setprivacy` → select your bot → **Disable** (so the bot can read group messages)
5. Add the bot to your group

## Configuration Fields

| Field | Description |
|---|---|
| `name` | Display name for your habitat |
| `domain` | Domain where Hatchery is hosted |
| `destructMinutes` | Auto-delete messages after N minutes (0 = disabled) |
| `bgColor` | Background color hex code for the web UI |
| `platform` | `"discord"`, `"telegram"`, or `"both"` |
| `council` | Council/judge settings for multi-agent deliberation |
| `globalIdentity` | System identity prompt shared by all agents |
| `globalBoot` | Boot-time instructions for all agents |
| `globalBootstrap` | Bootstrap instructions for all agents |
| `globalSoul` | Personality/soul prompt shared by all agents |
| `globalAgents` | Instructions about other agents (shared context) |
| `globalUser` | Information about the owner/user |
| `agents` | Array of agent configurations with platform-specific bot tokens |

## ⚠️ Security: Keep Real Configs Private

**Never commit real habitat files with actual tokens to a git repository.**

Your real habitat JSON file contains sensitive bot tokens that grant full control over your bots. Store it securely:

- **Dropbox / Google Drive / iCloud** — synced and backed up, not in version control
- **Encrypted local storage** — use tools like `age` or `gpg` to encrypt at rest
- **Environment variables** — reference tokens from env vars instead of hardcoding
- **Secret managers** — AWS Secrets Manager, Vault, etc.

Add `*.habitat.json` or similar patterns to your `.gitignore` to prevent accidental commits.
