# Live Test Habitats for Docker Isolation PR

Three habitats designed to validate the `feature/docker-isolation` branch before merge.

## Test Order

Run in this order — each validates prerequisites for the next:

| # | Habitat | Domain | Isolation | Purpose | Destruct |
|---|---------|--------|-----------|---------|----------|
| 2B | `test-2b-session-regression.json` | `bot1.frysinger.org` | session | Session-only regression test | 90 min |
| 2A | `test-2a-mixed-mode.json` | `bot2.frysinger.org` | mixed | Container + session together | 120 min |
| 2C | `test-2c-container-safemode.json` | `bot3.frysinger.org` | container | Safe mode trigger & recovery | 60 min |

## Tokens Used

| Bot Set | Platform | Habitat |
|---------|----------|---------|
| TetraFab* (1-4) | Telegram | 2B (session regression) |
| FlintSpark* (1-3) | Telegram | 2A (mixed mode) |
| CoralNova* (1-2) | Telegram | 2C (safe mode) |
| Claude, ChatGPT, Gemini | Discord | 2A (mixed mode) |
| worker-1, worker-2 | Discord | 2B (session regression) |
| safe-mode-bot | Discord | 2C (safe mode fallback) |

## Pre-Flight

1. All habitats set `hatcheryVersion: "feature/docker-isolation"`
2. API keys come from iOS Shortcut (`[[ANTHROPIC_KEY]]`, etc.)
3. Upload habitat JSON to `dropbox:droplets/Habitats/` before running Shortcut
4. No token collisions between habitats (different bot sets per test)

## Verification Script

After each droplet reaches Stage 11, SSH in and run:
```bash
# Quick health check
curl -s localhost:8080/status | jq '{stage: .stage, ready: .ready}'
jq . /etc/openclaw-groups.json
for svc in $(systemctl list-units 'openclaw-*' --no-legend | awk '{print $1}'); do
  echo "$svc: $(systemctl is-active $svc)"
done
```

## Test 2C Note

Test 2C requires breaking the Anthropic API key to trigger safe mode.
Option A: Use iOS Shortcut with a deliberately bad `[[ANTHROPIC_KEY]]` value.
Option B: SSH in after boot and corrupt the key in group.env, then restart the service.
