# GitHub Issue: TASK-205 — Expand backward compatibility tests

**Title:** [R6] TASK-205: Expand backward compatibility tests for v3 schema parser

**Labels:** `tests`, `backward-compat`, `R6`

## Description

Ensure v2 and v1 habitat schemas (without isolation fields) continue to work unchanged when processed by the v3 parser. The existing `TestBackwardCompatibility` class had only 7 tests — expanded to 21 to cover all edge cases.

## Acceptance Criteria

- [x] v2 schemas parse without errors
- [x] Missing `isolation` defaults to `"none"`
- [x] Missing `sharedPaths` defaults to `[]`
- [x] Missing `isolationGroup` defaults to empty
- [x] Missing `network` defaults to empty
- [x] All tests in `TestBackwardCompatibility` pass
- [x] Existing habitat files in `examples/` still work
- [x] v1 legacy token formats (botToken, telegramBotToken, discordBotToken) work with deprecation warnings
- [x] Platform defaults to telegram
- [x] API bind address defaults to 127.0.0.1 (secure-by-default)
- [x] Global identity/soul/boot fields preserved
- [x] Council config preserved
- [x] String agent shorthand works

## Tests Added (14 new, 21 total)

| Test | What it verifies |
|------|-----------------|
| `test_v2_simple_single_agent` | Minimal v2 with all isolation defaults |
| `test_v2_multi_agent_no_isolation` | Multiple v2 agents, all v3 fields empty |
| `test_v1_telegram_legacy_botToken` | v1 `botToken` field + deprecation warning |
| `test_v1_discord_legacy_discordBotToken` | v1 `discordBotToken` + deprecation |
| `test_v1_telegramBotToken_legacy` | v1 `telegramBotToken` + deprecation |
| `test_destruct_minutes_default_zero` | destructMinutes defaults to 0 |
| `test_platform_defaults_telegram` | Platform defaults to telegram |
| `test_global_fields_preserved` | globalIdentity/Soul/Boot survive v3 |
| `test_api_bind_address_default` | Secure-by-default 127.0.0.1 |
| `test_api_bind_remote_enabled` | remoteApi: true → 0.0.0.0 |
| `test_both_platform_v1` | Dual-platform v1 habitat |
| `test_string_agent_shorthand` | String agent ref normalization |
| `test_domain_field_preserved` | domain → HABITAT_DOMAIN |
| `test_council_group_id_legacy` | Legacy councilGroupId field |

## Files Modified

- `tests/test_isolation_schema.py` — Added 14 tests to `TestBackwardCompatibility`

## Test Command

```bash
python3 -m pytest tests/test_isolation_schema.py::TestBackwardCompatibility -v
```

## Result

```
21 passed
```
