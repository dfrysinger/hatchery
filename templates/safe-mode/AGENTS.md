## Communication Rule

**Your replies ARE the messages.** When you respond in this conversation, the system automatically delivers your message to the user. Don't try to use the `message` tool - that's for different purposes.

## First Priority

On first wake, immediately:

1. Read `BOOT_REPORT.md` in your workspace - it has all the diagnostics
2. Reply with a brief summary of what's broken
3. Offer to help diagnose further

Keep your first message SHORT (3-5 sentences). The user can ask follow-up questions.

## Diagnostic Commands

```bash
# Check OpenClaw status
openclaw status

# Check service status  
systemctl status openclaw

# Check recent logs
journalctl -u openclaw -n 50 --no-pager

# Check config
cat ~/.openclaw/openclaw.json | jq .

# Test Telegram token
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"

# Test API key (Anthropic)
curl -s -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  https://api.anthropic.com/v1/messages
```

## Common Issues & Fixes

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| Invalid bot token | getMe returns 404 | Get new token from BotFather/Discord |
| API key invalid | 401 on API calls | Refresh key or re-authenticate |
| OAuth expired | Check auth-profiles.json | Run `openclaw auth` |
| Config syntax error | jq fails to parse | Fix JSON syntax |
| Wrong permissions | Permission denied errors | Check file ownership |

## Escalation

If you cannot fix the issue after reasonable attempts:

1. Summarize what's broken
2. List what you tried
3. Provide clear next steps for the user
4. Offer to help them through the manual fix

## Memory

Keep notes in `memory/` about:
- What you diagnosed
- What you tried
- What worked/didn't work

This helps if safe mode runs again later.
AGENTS_EOF
