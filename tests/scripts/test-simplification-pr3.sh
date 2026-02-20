#!/bin/bash
# =============================================================================
# test-simplification-pr3.sh -- PR 3: Unified config generator (generate-config.sh)
# =============================================================================
# TDD tests for the single source of truth config generator using jq.
# This is the HIGHEST VALUE change — kills the #1 bug source.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$TESTS_DIR")"

PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=$((FAILED + 1)); }

GEN_CONFIG="$REPO_DIR/scripts/generate-config.sh"
TMPOUT="/tmp/test-gen-config-output.json"

# =============================================================================
echo ""
echo "=== PR3: generate-config.sh exists and is executable ==="
# =============================================================================

if [ -f "$GEN_CONFIG" ]; then
  pass "generate-config.sh exists"
else
  fail "generate-config.sh does not exist"
  echo ""
  echo "=== Summary ==="
  echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
  exit $FAILED
fi

if [ -x "$GEN_CONFIG" ]; then
  pass "generate-config.sh is executable"
else
  fail "generate-config.sh is not executable"
fi

# =============================================================================
# Helper: generate config with mock env
# =============================================================================
gen() {
  local mode="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" \
    TEST_MODE=1 \
    USERNAME="bot" \
    HABITAT_NAME="TestHabitat" \
    PLATFORM="${GEN_PLATFORM:-telegram}" \
    AGENT_COUNT="${GEN_AGENT_COUNT:-1}" \
    AGENT1_NAME="${GEN_AGENT1_NAME:-TestBot}" \
    AGENT1_MODEL="${GEN_AGENT1_MODEL:-anthropic/claude-sonnet-4}" \
    AGENT1_BOT_TOKEN="${GEN_AGENT1_BOT_TOKEN:-BOT_TOKEN_1}" \
    AGENT1_DISCORD_BOT_TOKEN="${GEN_AGENT1_DC_TOKEN:-}" \
    AGENT2_NAME="${GEN_AGENT2_NAME:-}" \
    AGENT2_MODEL="${GEN_AGENT2_MODEL:-}" \
    AGENT2_BOT_TOKEN="${GEN_AGENT2_BOT_TOKEN:-}" \
    AGENT2_DISCORD_BOT_TOKEN="${GEN_AGENT2_DC_TOKEN:-}" \
    AGENT3_NAME="${GEN_AGENT3_NAME:-}" \
    AGENT3_MODEL="${GEN_AGENT3_MODEL:-}" \
    AGENT3_BOT_TOKEN="${GEN_AGENT3_BOT_TOKEN:-}" \
    AGENT3_DISCORD_BOT_TOKEN="${GEN_AGENT3_DC_TOKEN:-}" \
    TELEGRAM_OWNER_ID="${GEN_TG_OWNER:-123456789}" \
    DISCORD_OWNER_ID="${GEN_DC_OWNER:-}" \
    DISCORD_GUILD_ID="${GEN_DC_GUILD:-}" \
    COUNCIL_GROUP_ID="" \
    ANTHROPIC_API_KEY="${GEN_AK:-sk-ant-test-key}" \
    GOOGLE_API_KEY="${GEN_GK:-}" \
    BRAVE_API_KEY="${GEN_BK:-}" \
    OPENAI_ACCESS_B64="" \
    ISOLATION_DEFAULT="${GEN_ISOLATION:-none}" \
    bash "$GEN_CONFIG" --mode "$mode" --gateway-token "test-gw-token" "$@" 2>/dev/null
}

# =============================================================================
echo ""
echo "=== PR3: --mode full produces valid JSON ==="
# =============================================================================

gen full > "$TMPOUT"

if jq . "$TMPOUT" >/dev/null 2>&1; then
  pass "full mode produces valid JSON"
else
  fail "full mode produces invalid JSON"
fi

for key in gateway agents channels env; do
  if jq -e ".$key" "$TMPOUT" >/dev/null 2>&1; then
    pass "full config has .$key"
  else
    fail "full config missing .$key"
  fi
done

bind=$(jq -r '.gateway.bind' "$TMPOUT")
[ "$bind" = "loopback" ] && pass "gateway.bind is loopback" || fail "gateway.bind='$bind'"

port=$(jq -r '.gateway.port' "$TMPOUT")
[ "$port" = "18789" ] && pass "gateway.port is 18789" || fail "gateway.port='$port'"

token=$(jq -r '.gateway.auth.token' "$TMPOUT")
[ "$token" = "test-gw-token" ] && pass "gateway token set correctly" || fail "gateway token='$token'"

# =============================================================================
echo ""
echo "=== PR3: Account names match agent IDs (never 'default') ==="
# =============================================================================

tg_keys=$(jq -r '.channels.telegram.accounts | keys[]' "$TMPOUT" 2>/dev/null)
echo "$tg_keys" | grep -q "^agent1$" && pass "telegram account keyed as 'agent1'" || fail "telegram account not keyed as 'agent1' (keys: $tg_keys)"
echo "$tg_keys" | grep -q "^default$" && fail "telegram has 'default' account key" || pass "no 'default' account key in telegram"

# =============================================================================
echo ""
echo "=== PR3: Multi-agent produces correct accounts + bindings ==="
# =============================================================================

GEN_AGENT_COUNT=3 \
GEN_AGENT2_NAME="Agent2" GEN_AGENT2_MODEL="anthropic/claude-opus-4-5" GEN_AGENT2_BOT_TOKEN="BOT_TOKEN_2" \
GEN_AGENT3_NAME="Agent3" GEN_AGENT3_MODEL="anthropic/claude-opus-4-5" GEN_AGENT3_BOT_TOKEN="BOT_TOKEN_3" \
  gen full > "$TMPOUT"

agent_count=$(jq '.agents.list | length' "$TMPOUT")
[ "$agent_count" = "3" ] && pass "3 agents in list" || fail "agent count=$agent_count"

for i in 1 2 3; do
  aid=$(jq -r ".agents.list[$((i-1))].id" "$TMPOUT")
  [ "$aid" = "agent$i" ] && pass "agent $i id is 'agent$i'" || fail "agent $i id='$aid'"
done

is_default_1=$(jq -r '.agents.list[0].default' "$TMPOUT")
is_default_2=$(jq -r '.agents.list[1].default' "$TMPOUT")
[ "$is_default_1" = "true" ] && pass "agent1 is default" || fail "agent1 default=$is_default_1"
[ "$is_default_2" = "false" ] && pass "agent2 is not default" || fail "agent2 default=$is_default_2"

for i in 1 2 3; do
  tok=$(jq -r ".channels.telegram.accounts.agent${i}.botToken // empty" "$TMPOUT")
  [ -n "$tok" ] && pass "telegram account agent${i} exists" || fail "telegram account agent${i} missing"
done

binding_count=$(jq '.bindings | length' "$TMPOUT")
[ "$binding_count" -ge 2 ] && pass "at least 2 bindings" || fail "bindings count=$binding_count"

# =============================================================================
echo ""
echo "=== PR3: Telegram-only disables Discord ==="
# =============================================================================

GEN_PLATFORM=telegram gen full > "$TMPOUT"

tg_en=$(jq -r '.plugins.entries.telegram.enabled' "$TMPOUT")
dc_en=$(jq -r '.plugins.entries.discord.enabled' "$TMPOUT")
[ "$tg_en" = "true" ] && pass "telegram enabled" || fail "telegram enabled=$tg_en"
[ "$dc_en" = "false" ] && pass "discord disabled" || fail "discord enabled=$dc_en"

# =============================================================================
echo ""
echo "=== PR3: Discord-only disables Telegram ==="
# =============================================================================

GEN_PLATFORM=discord GEN_AGENT1_DC_TOKEN="DISCORD_TOKEN_1" GEN_DC_OWNER="987654321" GEN_DC_GUILD="guild123" \
  gen full > "$TMPOUT"

tg_en=$(jq -r '.plugins.entries.telegram.enabled' "$TMPOUT")
dc_en=$(jq -r '.plugins.entries.discord.enabled' "$TMPOUT")
[ "$tg_en" = "false" ] && pass "telegram disabled" || fail "telegram enabled=$tg_en"
[ "$dc_en" = "true" ] && pass "discord enabled" || fail "discord enabled=$dc_en"

# =============================================================================
echo ""
echo "=== PR3: Both platforms enabled ==="
# =============================================================================

GEN_PLATFORM=both GEN_AGENT1_DC_TOKEN="DISCORD_TOKEN_1" GEN_DC_OWNER="987654321" GEN_DC_GUILD="guild123" \
  gen full > "$TMPOUT"

tg_en=$(jq -r '.plugins.entries.telegram.enabled' "$TMPOUT")
dc_en=$(jq -r '.plugins.entries.discord.enabled' "$TMPOUT")
[ "$tg_en" = "true" ] && pass "telegram enabled" || fail "telegram enabled=$tg_en"
[ "$dc_en" = "true" ] && pass "discord enabled" || fail "discord enabled=$dc_en"

# =============================================================================
echo ""
echo "=== PR3: Session mode filters agents by group ==="
# =============================================================================

GEN_AGENT_COUNT=3 \
GEN_AGENT2_NAME="Agent2" GEN_AGENT2_MODEL="anthropic/claude-opus-4-5" GEN_AGENT2_BOT_TOKEN="BOT_TOKEN_2" \
GEN_AGENT3_NAME="Agent3" GEN_AGENT3_MODEL="anthropic/claude-opus-4-5" GEN_AGENT3_BOT_TOKEN="BOT_TOKEN_3" \
  gen session --group "group-a" --agents "agent1,agent2" --port 18790 > "$TMPOUT"

if jq . "$TMPOUT" >/dev/null 2>&1; then
  pass "session mode produces valid JSON"
else
  fail "session mode produces invalid JSON"
fi

port=$(jq -r '.gateway.port' "$TMPOUT")
[ "$port" = "18790" ] && pass "session port is 18790" || fail "session port='$port'"

agent_count=$(jq '.agents.list | length' "$TMPOUT")
[ "$agent_count" = "2" ] && pass "2 agents in group-a" || fail "group-a agent count=$agent_count"

has_agent3=$(jq -r '.agents.list[] | select(.id == "agent3") | .id // empty' "$TMPOUT")
[ -z "$has_agent3" ] && pass "agent3 not in group-a config" || fail "agent3 found in group-a"

tg_keys=$(jq -r '.channels.telegram.accounts | keys[]' "$TMPOUT" 2>/dev/null || echo "")
echo "$tg_keys" | grep -q "agent3" && fail "telegram has agent3 in group-a" || pass "telegram only has group-a agents"

# =============================================================================
echo ""
echo "=== PR3: Safe-mode config ==="
# =============================================================================

gen safe-mode --token "sk-ant-safe" --provider "anthropic" --platform "telegram" \
  --bot-token "SAFE_BOT_TOKEN" --owner-id "123456789" > "$TMPOUT"

if jq . "$TMPOUT" >/dev/null 2>&1; then
  pass "safe-mode produces valid JSON"
else
  fail "safe-mode produces invalid JSON"
fi

agent_id=$(jq -r '.agents.list[0].id // empty' "$TMPOUT")
[ "$agent_id" = "safe-mode" ] && pass "safe-mode agent id" || fail "agent id='$agent_id'"

api_key=$(jq -r '.env.ANTHROPIC_API_KEY // empty' "$TMPOUT")
[ "$api_key" = "sk-ant-safe" ] && pass "API key set" || fail "API key='$api_key'"

sm_token=$(jq -r '.channels.telegram.accounts["safe-mode"].botToken // empty' "$TMPOUT")
[ "$sm_token" = "SAFE_BOT_TOKEN" ] && pass "safe-mode account token set" || fail "safe-mode token='$sm_token'"

# =============================================================================
echo ""
echo "=== PR3: Idempotent ==="
# =============================================================================

gen full > /tmp/test-gen-idem1.json
gen full > /tmp/test-gen-idem2.json
if diff -q /tmp/test-gen-idem1.json /tmp/test-gen-idem2.json >/dev/null 2>&1; then
  pass "idempotent output"
else
  fail "outputs differ between runs"
fi

# =============================================================================
echo ""
echo "=== PR3: JSON escaping handles special characters ==="
# =============================================================================

GEN_AGENT1_NAME='Test "Bot" with $pecial & chars' gen full > "$TMPOUT"

if jq . "$TMPOUT" >/dev/null 2>&1; then
  pass "special characters produce valid JSON"
else
  fail "special characters break JSON"
fi

name=$(jq -r '.agents.list[0].name' "$TMPOUT")
if [ "$name" = 'Test "Bot" with $pecial & chars' ]; then
  pass "special characters round-trip correctly"
else
  fail "name='$name'"
fi

# =============================================================================
echo ""
echo "=== PR3: No more heredoc config patterns in non-legacy scripts ==="
# =============================================================================

for script in generate-session-services.sh safe-mode-recovery.sh; do
  path="$REPO_DIR/scripts/$script"
  [ -f "$path" ] || continue
  if grep -q '<<CFG\|<<CONFIG\|<<EOF_CONFIG\|<<OPENCLAW_CONFIG\|<<SESSIONCFG' "$path"; then
    fail "$script still has heredoc config pattern — should use generate-config.sh"
  else
    pass "$script has no heredoc config patterns"
  fi
done

BFC="$REPO_DIR/scripts/build-full-config.sh"
if grep -q 'generate-config.sh' "$BFC"; then
  pass "build-full-config.sh calls generate-config.sh"
else
  fail "build-full-config.sh should call generate-config.sh"
fi

# Cleanup
rm -f "$TMPOUT" /tmp/test-gen-idem{1,2}.json

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
