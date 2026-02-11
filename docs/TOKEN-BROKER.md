# Token Broker for iOS Shortcuts

This document describes the architecture and implementation of a token brokerage system that runs entirely within iOS Shortcuts. It manages a pool of Discord and Telegram bot tokens, allocating them to ephemeral Hatchery habitats.

## Overview

### Problem
- Hatchery creates ephemeral droplets with AI agents
- Each agent needs Discord/Telegram bot tokens
- Tokens must be manually created via developer portals
- Users shouldn't need to host a separate API service

### Solution
A Shortcut-based broker that:
1. Stores token pool state in Dropbox (already used for memory sync)
2. Keeps actual tokens in Shortcut variables (secure, never in cloud)
3. Allocates tokens on habitat creation
4. Releases tokens on habitat destruction

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    iOS Shortcut                            │
│  ┌──────────────┐    ┌───────────────────────────────┐    │
│  │ Token Secrets│    │ Broker Logic (in Shortcut)    │    │
│  │ (Shortcut    │◄───│ 1. Read state from Dropbox    │    │
│  │  Variables)  │    │ 2. Find available token       │    │
│  └──────────────┘    │ 3. Mark as leased             │    │
│         │            │ 4. Inject into habitat.json   │    │
│         │            │ 5. Write state back           │    │
│         ▼            └───────────────────────────────┘    │
│  ┌──────────────┐                                         │
│  │ habitat.json │──────► DigitalOcean Droplet             │
│  │ (with tokens)│                                         │
│  └──────────────┘                                         │
└────────────────────────────────────────────────────────────┘
                               │
                         Dropbox API
                               │
                    ┌──────────▼──────────┐
                    │  token-state.json   │
                    │  (allocation state  │
                    │   only, no secrets) │
                    └─────────────────────┘
```

## Data Model

### Token State File (`Droplets/tokens/token-state.json`)

This file tracks which tokens are available or leased. **It does NOT contain actual tokens.**

```json
{
  "version": 1,
  "lastModified": "2026-02-11T03:00:00Z",
  "tokens": {
    "discord": [
      {
        "id": "discord-1",
        "botUsername": "HatcheryBot1",
        "botId": "1234567890",
        "status": "available"
      },
      {
        "id": "discord-2",
        "botUsername": "HatcheryBot2",
        "botId": "0987654321",
        "status": "leased",
        "habitatId": "Habitat-1",
        "habitatName": "MyHabitat",
        "agentName": "Claude",
        "leasedAt": "2026-02-11T02:30:00Z"
      }
    ],
    "telegram": [
      {
        "id": "telegram-1",
        "botUsername": "hatchery_bot_1",
        "status": "available"
      }
    ]
  }
}
```

### Shortcut Variables (Secure Storage)

Actual tokens are stored in Shortcut variables, never uploaded to cloud:

| Variable Name | Type | Example |
|--------------|------|---------|
| `DISCORD_TOKENS` | Dictionary | `{"discord-1": "Bot MTk...", "discord-2": "Bot NTg..."}` |
| `TELEGRAM_TOKENS` | Dictionary | `{"telegram-1": "123456:ABC...", "telegram-2": "789012:DEF..."}` |
| `DROPBOX_ACCESS_TOKEN` | Text | OAuth token for Dropbox API |

## Implementation

### Initial Setup

Before using the broker, set up your token pool:

#### Step 1: Create Bot Tokens

**Discord:**
1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Create Application → Bot → Reset Token → Copy
3. Enable required intents (Message Content, Server Members if needed)
4. Repeat for each bot in your pool

**Telegram:**
1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. `/newbot` → Follow prompts → Copy token
3. Repeat for each bot in your pool

#### Step 2: Store Tokens in Shortcut

Create a Shortcut called "Token Broker Setup":

```
┌─────────────────────────────────────────────────────────┐
│ 1. Dictionary                                           │
│    ┌─────────────┬────────────────────────────────┐    │
│    │ discord-1   │ Bot MTkxMjM0NTY3ODkw...        │    │
│    │ discord-2   │ Bot NTY3ODkwMTIzNDU2...        │    │
│    │ discord-3   │ Bot OTAxMjM0NTY3ODkw...        │    │
│    └─────────────┴────────────────────────────────┘    │
│    → Set Variable: DISCORD_TOKENS                       │
├─────────────────────────────────────────────────────────┤
│ 2. Dictionary                                           │
│    ┌─────────────┬────────────────────────────────┐    │
│    │ telegram-1  │ 1234567890:ABCdefGHI...        │    │
│    │ telegram-2  │ 0987654321:XYZabcDEF...        │    │
│    └─────────────┴────────────────────────────────┘    │
│    → Set Variable: TELEGRAM_TOKENS                      │
├─────────────────────────────────────────────────────────┤
│ 3. Show Alert: "Token variables saved!"                 │
└─────────────────────────────────────────────────────────┘
```

#### Step 3: Initialize State File

Create initial `token-state.json` in Dropbox:

```
┌─────────────────────────────────────────────────────────┐
│ 1. Text                                                 │
│    {                                                    │
│      "version": 1,                                      │
│      "lastModified": "[Current Date, ISO]",             │
│      "tokens": {                                        │
│        "discord": [                                     │
│          {"id": "discord-1", "botUsername": "Bot1",     │
│           "status": "available"},                       │
│          {"id": "discord-2", "botUsername": "Bot2",     │
│           "status": "available"}                        │
│        ],                                               │
│        "telegram": [                                    │
│          {"id": "telegram-1", "botUsername": "TgBot1",  │
│           "status": "available"}                        │
│        ]                                                │
│      }                                                  │
│    }                                                    │
├─────────────────────────────────────────────────────────┤
│ 2. Save File                                            │
│    Service: Dropbox                                     │
│    Path: /Droplets/tokens/token-state.json              │
│    Overwrite: Yes                                       │
└─────────────────────────────────────────────────────────┘
```

---

### Lease Token (Create Habitat)

Add these actions to your "Create Habitat" shortcut:

```
┌─────────────────────────────────────────────────────────┐
│ ═══════════════ TOKEN BROKER: LEASE ═══════════════    │
├─────────────────────────────────────────────────────────┤
│ 1. Get File from Dropbox                                │
│    Path: /Droplets/tokens/token-state.json              │
│    → Set Variable: StateFile                            │
├─────────────────────────────────────────────────────────┤
│ 2. Get Dictionary from Input: StateFile                 │
│    → Set Variable: State                                │
├─────────────────────────────────────────────────────────┤
│ 3. Get Value for "tokens" in State                      │
│    → Set Variable: AllTokens                            │
├─────────────────────────────────────────────────────────┤
│ ─────────────── DISCORD TOKEN ───────────────          │
├─────────────────────────────────────────────────────────┤
│ 4. Get Value for "discord" in AllTokens                 │
│    → Set Variable: DiscordTokens                        │
├─────────────────────────────────────────────────────────┤
│ 5. Repeat with Each item in DiscordTokens               │
│    │                                                    │
│    │  If: Get Value "status" = "available"              │
│    │    │                                               │
│    │    │  Get Value "id" in Repeat Item                │
│    │    │  → Set Variable: SelectedDiscordId            │
│    │    │                                               │
│    │    │  Stop Repeat (exit on first match)            │
│    │    │                                               │
│    │  End If                                            │
│    │                                                    │
│    End Repeat                                           │
├─────────────────────────────────────────────────────────┤
│ 6. If: SelectedDiscordId has no value                   │
│    │                                                    │
│    │  Show Alert: "No available Discord tokens!"        │
│    │  Stop Shortcut                                     │
│    │                                                    │
│    End If                                               │
├─────────────────────────────────────────────────────────┤
│ 7. Get Variable: DISCORD_TOKENS                         │
│    Get Dictionary Value for: SelectedDiscordId          │
│    → Set Variable: DiscordBotToken                      │
├─────────────────────────────────────────────────────────┤
│ ─────────────── TELEGRAM TOKEN ───────────────         │
├─────────────────────────────────────────────────────────┤
│ 8. Get Value for "telegram" in AllTokens                │
│    → Set Variable: TelegramTokens                       │
├─────────────────────────────────────────────────────────┤
│ 9. Repeat with Each item in TelegramTokens              │
│    │                                                    │
│    │  If: Get Value "status" = "available"              │
│    │    │                                               │
│    │    │  Get Value "id" in Repeat Item                │
│    │    │  → Set Variable: SelectedTelegramId           │
│    │    │                                               │
│    │    │  Stop Repeat                                  │
│    │    │                                               │
│    │  End If                                            │
│    │                                                    │
│    End Repeat                                           │
├─────────────────────────────────────────────────────────┤
│ 10. If: SelectedTelegramId has no value                 │
│     │                                                   │
│     │  Show Alert: "No available Telegram tokens!"      │
│     │  Stop Shortcut                                    │
│     │                                                   │
│     End If                                              │
├─────────────────────────────────────────────────────────┤
│ 11. Get Variable: TELEGRAM_TOKENS                       │
│     Get Dictionary Value for: SelectedTelegramId        │
│     → Set Variable: TelegramBotToken                    │
├─────────────────────────────────────────────────────────┤
│ ─────────────── UPDATE STATE ───────────────           │
├─────────────────────────────────────────────────────────┤
│ 12. Current Date (ISO 8601)                             │
│     → Set Variable: Now                                 │
├─────────────────────────────────────────────────────────┤
│ 13. Text (updated Discord entry)                        │
│     {                                                   │
│       "id": "[SelectedDiscordId]",                      │
│       "botUsername": "[original botUsername]",          │
│       "status": "leased",                               │
│       "habitatId": "[HABITAT_ID]",                      │
│       "habitatName": "[HABITAT_NAME]",                  │
│       "leasedAt": "[Now]"                               │
│     }                                                   │
│     → Update DiscordTokens array at matching index      │
├─────────────────────────────────────────────────────────┤
│ 14. Text (updated Telegram entry)                       │
│     {                                                   │
│       "id": "[SelectedTelegramId]",                     │
│       "botUsername": "[original botUsername]",          │
│       "status": "leased",                               │
│       "habitatId": "[HABITAT_ID]",                      │
│       "habitatName": "[HABITAT_NAME]",                  │
│       "leasedAt": "[Now]"                               │
│     }                                                   │
│     → Update TelegramTokens array at matching index     │
├─────────────────────────────────────────────────────────┤
│ 15. Text (complete updated state)                       │
│     {                                                   │
│       "version": [State.version + 1],                   │
│       "lastModified": "[Now]",                          │
│       "tokens": {                                       │
│         "discord": [DiscordTokens],                     │
│         "telegram": [TelegramTokens]                    │
│       }                                                 │
│     }                                                   │
├─────────────────────────────────────────────────────────┤
│ 16. Save File to Dropbox                                │
│     Path: /Droplets/tokens/token-state.json             │
│     Overwrite: Yes                                      │
├─────────────────────────────────────────────────────────┤
│ ─────────────── INJECT INTO HABITAT ───────────────    │
├─────────────────────────────────────────────────────────┤
│ 17. [Continue with habitat.json creation]               │
│     Use DiscordBotToken in platforms.discord.botToken   │
│     Use TelegramBotToken in platforms.telegram.botToken │
└─────────────────────────────────────────────────────────┘
```

---

### Release Token (Destroy Habitat)

Add these actions to your "Destroy Habitat" shortcut:

```
┌─────────────────────────────────────────────────────────┐
│ ═══════════════ TOKEN BROKER: RELEASE ═══════════════  │
├─────────────────────────────────────────────────────────┤
│ 1. Get File from Dropbox                                │
│    Path: /Droplets/tokens/token-state.json              │
│    → Set Variable: StateFile                            │
├─────────────────────────────────────────────────────────┤
│ 2. Get Dictionary from Input: StateFile                 │
│    → Set Variable: State                                │
├─────────────────────────────────────────────────────────┤
│ 3. Get Value for "tokens" in State                      │
│    → Set Variable: AllTokens                            │
├─────────────────────────────────────────────────────────┤
│ ─────────────── RELEASE DISCORD ───────────────        │
├─────────────────────────────────────────────────────────┤
│ 4. Get Value for "discord" in AllTokens                 │
│    → Set Variable: DiscordTokens                        │
├─────────────────────────────────────────────────────────┤
│ 5. Repeat with Each item in DiscordTokens               │
│    │                                                    │
│    │  If: Get Value "habitatId" = "[HABITAT_ID]"        │
│    │    │                                               │
│    │    │  Set Dictionary Value:                        │
│    │    │    "status" → "available"                     │
│    │    │  Remove Dictionary Value: "habitatId"         │
│    │    │  Remove Dictionary Value: "habitatName"       │
│    │    │  Remove Dictionary Value: "leasedAt"          │
│    │    │                                               │
│    │  End If                                            │
│    │                                                    │
│    End Repeat                                           │
├─────────────────────────────────────────────────────────┤
│ ─────────────── RELEASE TELEGRAM ───────────────       │
├─────────────────────────────────────────────────────────┤
│ 6. Get Value for "telegram" in AllTokens                │
│    → Set Variable: TelegramTokens                       │
├─────────────────────────────────────────────────────────┤
│ 7. Repeat with Each item in TelegramTokens              │
│    │                                                    │
│    │  If: Get Value "habitatId" = "[HABITAT_ID]"        │
│    │    │                                               │
│    │    │  Set Dictionary Value:                        │
│    │    │    "status" → "available"                     │
│    │    │  Remove Dictionary Value: "habitatId"         │
│    │    │  Remove Dictionary Value: "habitatName"       │
│    │    │  Remove Dictionary Value: "leasedAt"          │
│    │    │                                               │
│    │  End If                                            │
│    │                                                    │
│    End Repeat                                           │
├─────────────────────────────────────────────────────────┤
│ ─────────────── SAVE STATE ───────────────             │
├─────────────────────────────────────────────────────────┤
│ 8. Current Date (ISO 8601)                              │
│    → Set Variable: Now                                  │
├─────────────────────────────────────────────────────────┤
│ 9. Text (updated state)                                 │
│    {                                                    │
│      "version": [State.version + 1],                    │
│      "lastModified": "[Now]",                           │
│      "tokens": {                                        │
│        "discord": [DiscordTokens],                      │
│        "telegram": [TelegramTokens]                     │
│      }                                                  │
│    }                                                    │
├─────────────────────────────────────────────────────────┤
│ 10. Save File to Dropbox                                │
│     Path: /Droplets/tokens/token-state.json             │
│     Overwrite: Yes                                      │
├─────────────────────────────────────────────────────────┤
│ 11. Show Notification: "Released tokens for [HABITAT]"  │
└─────────────────────────────────────────────────────────┘
```

---

### Check Pool Status

Utility shortcut to see available tokens:

```
┌─────────────────────────────────────────────────────────┐
│ ═══════════════ TOKEN POOL STATUS ═══════════════      │
├─────────────────────────────────────────────────────────┤
│ 1. Get File from Dropbox                                │
│    Path: /Droplets/tokens/token-state.json              │
├─────────────────────────────────────────────────────────┤
│ 2. Get Dictionary from Input                            │
│    → Set Variable: State                                │
├─────────────────────────────────────────────────────────┤
│ 3. Count "available" Discord tokens                     │
│    → Set Variable: DiscordAvailable                     │
├─────────────────────────────────────────────────────────┤
│ 4. Count "leased" Discord tokens                        │
│    → Set Variable: DiscordLeased                        │
├─────────────────────────────────────────────────────────┤
│ 5. Count "available" Telegram tokens                    │
│    → Set Variable: TelegramAvailable                    │
├─────────────────────────────────────────────────────────┤
│ 6. Count "leased" Telegram tokens                       │
│    → Set Variable: TelegramLeased                       │
├─────────────────────────────────────────────────────────┤
│ 7. Show Alert:                                          │
│    "Token Pool Status                                   │
│                                                         │
│     Discord: [DiscordAvailable] available,              │
│              [DiscordLeased] leased                     │
│                                                         │
│     Telegram: [TelegramAvailable] available,            │
│               [TelegramLeased] leased"                  │
└─────────────────────────────────────────────────────────┘
```

## Race Condition Handling

If two habitats are created simultaneously, they might both try to lease the same token.

### Version Check Strategy

```
┌─────────────────────────────────────────────────────────┐
│ 1. Read state, note version number                      │
│ 2. Select tokens, prepare updates                       │
│ 3. Re-read state                                        │
│ 4. If version changed:                                  │
│    │  Show Alert: "Conflict detected, retrying..."      │
│    │  Wait 1 second                                     │
│    │  Go to step 1                                      │
│    Else:                                                │
│    │  Write updated state with version + 1              │
│    End If                                               │
└─────────────────────────────────────────────────────────┘
```

### Practical Note

For single-user scenarios, race conditions are rare. The version check provides protection without complexity.

## Maintenance

### Adding New Tokens

1. Create bot in Discord/Telegram developer portal
2. Add token to Shortcut variable (DISCORD_TOKENS or TELEGRAM_TOKENS)
3. Add entry to token-state.json with status "available"

### Revoking Tokens

If a token is compromised:

1. Revoke in platform's developer portal
2. Remove from Shortcut variables
3. Remove entry from token-state.json (or mark status: "revoked")

### Orphan Cleanup

If a droplet dies without releasing tokens:

1. Run "Check Pool Status" to see leased tokens
2. Manually edit token-state.json to set status: "available"
3. Or create a "Release All" utility shortcut

## Security Considerations

| Aspect | Implementation |
|--------|----------------|
| Token storage | Shortcut variables only (never in cloud) |
| State file | Contains IDs only, no secrets |
| Dropbox access | OAuth token in Shortcut |
| Audit trail | `leasedAt` timestamp in state |
| Token rotation | Manual process via platform portals |

## Limitations

1. **Manual token creation** — Tokens must be created manually in Discord/Telegram
2. **Single user** — Not designed for multi-tenant scenarios
3. **No auto-cleanup** — Orphaned leases require manual intervention
4. **Dropbox dependency** — Requires Dropbox account and API access

## Future Enhancements

- [ ] Automatic orphan detection (check droplet status via DO API)
- [ ] Token health verification (test API calls before leasing)
- [ ] Multiple pools per platform (production vs development)
- [ ] Lease expiration with auto-release
