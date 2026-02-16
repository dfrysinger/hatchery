# Safe Mode Testing Instructions

## Test 1: Bad Anthropic API Key (Recommended)

This test triggers safe mode by providing an invalid Anthropic API key.
The bot will connect to Telegram but fail health checks, triggering recovery.

### Setup
1. In your iOS Shortcut, when prompted for ANTHROPIC_API_KEY, enter: `invalid-key-for-testing`
2. Keep your OPENAI OAuth token valid (in 1Password)
3. Use the normal JobHunt habitat

### Expected Behavior
1. Bot comes online in Phase 1 (minimal config)
2. Full config applies after reboot
3. Health check fails (Anthropic key invalid)
4. **Safe Mode Recovery:**
   - Finds working Telegram token ✓
   - Tries Anthropic API → fails
   - Falls back to OpenAI OAuth → succeeds ✓
   - Generates emergency config with OpenAI
5. Bot comes back online using OpenAI

### Verification
- Check `/log` API for `safe-mode-recovery.log`
- Look for: "Falls back to openai" or "Using API provider: openai"
- SAFE_MODE.md should appear in agent workspace

---

## Test 2: Bad Primary Token

Use the test habitat with Agent1 having an invalid token.

### Setup
1. Copy `habitat-safemode-bad-primary-token.json` to your Dropbox habitats folder
2. Run shortcut and select this habitat
3. Use valid API keys

### Expected Behavior
1. Phase 1 tries Agent1 token → fails to connect
2. Safe Mode Recovery:
   - Tries Agent1 token → fails
   - Tries Agent2 token → succeeds ✓
3. Bot comes online using Agent2's identity

---

## Test 3: Force Safe Mode After Boot (Requires SSH/Bot Command)

If you want to test safe mode on a running droplet:

```bash
# Corrupt the full config
echo '{"invalid": json}' | sudo tee /home/bot/.openclaw/openclaw.full.json

# Trigger post-boot-check
sudo systemctl restart post-boot-check
```

---

## Logs to Check

After any test, check these via `/log` API:

1. `/var/log/post-boot-check.log` - Shows safe mode trigger
2. `/var/log/safe-mode-recovery.log` - Detailed recovery steps
3. `SAFE_MODE.md` in agent workspace - Recovery summary

## Shortcut Modifications

| Test | Modification |
|------|--------------|
| Bad API Key | Set ANTHROPIC_API_KEY to `invalid-key-test` |
| Bad Token | Use `habitat-safemode-bad-primary-token.json` |
| Normal | No changes, just testing recovery resilience |
