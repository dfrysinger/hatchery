# v1 Habitat Schema (Deprecated)

**Status:** Deprecated as of PR #113 (Feb 2026)  
**Support:** Backward compatibility maintained  
**Removal:** See issue #112 for deprecation timeline

## Overview

The v1 schema was the original habitat configuration format used before the introduction of the v2 generic platform schema. While v1 is deprecated, backward compatibility is maintained to support existing habitats.

## Key Differences from v2

| Feature | v1 Schema | v2 Schema |
|---------|-----------|-----------|
| Platform config | Top-level `discord`, `telegram` | Nested under `platforms.discord`, `platforms.telegram` |
| Agent tokens | `discordBotToken`, `telegramBotToken` | Nested under `tokens.discord`, `tokens.telegram` |
| Platform detection | `platform` field + top-level objects | `platform` field + `platforms` object |

## v1 Schema Example

```json
{
  "name": "Production-Habitat",
  "domain": "bot.example.org",
  "destructMinutes": 120,
  "bgColor": "1A202C",
  "platform": "discord",
  "discord": {
    "serverId": "1111111111111111111",
    "ownerId": "2222222222222222222"
  },
  "telegram": {
    "ownerId": "333333333"
  },
  "council": {
    "groupName": "Executive Council",
    "judge": "OpusBot",
    "discord": {
      "serverId": "4444444444444444444",
      "judgeChan": "5555555555555555555"
    },
    "telegram": {
      "groupId": "666666666"
    }
  },
  "globalIdentity": "You are a helpful AI assistant.",
  "agents": [
    {
      "agent": "MainBot",
      "discordBotToken": "MTEx...EXAMPLE_TOKEN_DO_NOT_USE...BBB",
      "telegramBotToken": "1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ1234567"
    }
  ]
}
```

## v1 → v2 Migration

The v1 schema is automatically migrated to v2 format by `parse-habitat.py`. No manual migration is required. The parse script supports both formats and produces identical environment variables.

### Migration Mapping

**Platform Configuration:**
- v1: `discord.serverId` → v2: `platforms.discord.serverId`
- v1: `discord.ownerId` → v2: `platforms.discord.ownerId`
- v1: `telegram.ownerId` → v2: `platforms.telegram.ownerId`

**Agent Tokens:**
- v1: `agents[].discordBotToken` → v2: `agents[].tokens.discord`
- v1: `agents[].telegramBotToken` → v2: `agents[].tokens.telegram`

## Backward Compatibility

The following v1 features remain fully supported:

- ✅ Top-level `discord` and `telegram` objects
- ✅ Agent tokens as `discordBotToken`, `telegramBotToken`
- ✅ Legacy `botToken` field (fallback for Telegram)
- ✅ Council platform-specific configuration
- ✅ All environment variables generated identically to v2

## Testing

v1 backward compatibility is verified by comprehensive test coverage in `tests/test_parse_habitat.py`:

- `TestV1Schema::test_v1_comprehensive_backward_compatibility` — End-to-end v1 config validation
- `TestV1Schema::test_v1_v2_produce_same_output` — Ensures v1 and v2 produce identical output
- Individual field tests for platform config, tokens, council, etc.

Run v1 tests:
```bash
pytest tests/test_parse_habitat.py::TestV1Schema -v
```

## Deprecation Timeline

See issue #112 for the v1 deprecation and removal timeline. Users are encouraged to migrate to v2 schema for:

- Better iOS Shortcut compatibility
- Cleaner multi-platform support
- Future-proof configuration

## See Also

- [v2 Schema Documentation](./minimal-habitat.md)
- [Migration Guide](#) (to be created)
- [Issue #112](https://github.com/dfrysinger/hatchery/issues/112) — v1 deprecation tracking
