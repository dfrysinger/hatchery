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
FIXTURES_DIR="$TESTS_DIR/fixtures"

PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=$((FAILED + 1)); }

GEN_CONFIG="$REPO_DIR/scripts/generate-config.sh"

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
# Helper: set up mock environment for config generation
# =============================================================================
setup_mock_env() {
  local mode="${1:-single}"  # single, multi, discord
  
  export TEST_MODE=1
  export USERNAME="bot"
  export HABITAT_NAME="TestHabitat"
  export HABITAT_DOMAIN=""
  export PLATFORM="telegram"
  export AGENT_COUNT=1
  export ISOLATION_DEFAULT="none"
  export ISOLATION_GROUPS=""
  
  # Mock tokens (base64)
  export ANTHROPIC_KEY_B64=$(echo -n "sk-ant-test-key-123" | base64)
  export GOOGLE_API_KEY_B64=$(echo -n "AIza-google-test" | base64)
  export BRAVE_KEY_B64=$(echo -n "BSA-brave-test" | base64)
  export OPENAI_ACCESS_B64=""
  export OPENAI_REFRESH_B64=""
  export OPENAI_EXPIRES_B64=""
  export OPENAI_ACCOUNT_ID_B64=""
  export TELEGRAM_USER_ID_B64=$(echo -n "123456789" | base64)
  export TELEGRAM_OWNER_ID="123456789"
  export DISCORD_GUILD_ID_B64=""
  export DISCORD_OWNER_ID_B64=""
  export PLATFORM_B64=$(echo -n "telegram" | base64)
  
  # Agent 1
  export AGENT1_NAME="TestBot"
  export AGENT1_MODEL="anthropic/claude-sonnet-4"
  export AGENT1_BOT_TOKEN="BOT_TOKEN_1"
  export AGENT1_DISCORD_BOT_TOKEN=""
  export AGENT1_IDENTITY_B64=""
  export AGENT1_SOUL_B64=""
  export AGENT1_AGENTS_B64=""
  export AGENT1_BOOT_B64=""
  export AGENT1_BOOTSTRAP_B64=""
  export AGENT1_USER_B64=""
  
  # Council (empty)
  export COUNCIL_GROUP_ID=""
  export COUNCIL_GROUP_NAME=""
  export COUNCIL_JUDGE=""
  
  # Global workspace content (empty)
  export GLOBAL_IDENTITY_B64=""
  export GLOBAL_BOOT_B64=""
  export GLOBAL_BOOTSTRAP_B64=""
  export GLOBAL_SOUL_B64=""
  export GLOBAL_AGENTS_B64=""
  export GLOBAL_USER_B64=""
  export GLOBAL_TOOLS_B64=""
  
  # Mock gateway token
  export MOCK_GATEWAY_TOKEN="test-gateway-token-abc123"
  
  case "$mode" in
    multi)
      export AGENT_COUNT=3
      export AGENT2_NAME="Agent2"
      export AGENT2_MODEL="anthropic/claude-opus-4-5"
      export AGENT2_BOT_TOKEN="BOT_TOKEN_2"
      export AGENT2_DISCORD_BOT_TOKEN=""
      export AGENT2_IDENTITY_B64=""
      export AGENT2_SOUL_B64=""
      export AGENT2_AGENTS_B64=""
      export AGENT2_BOOT_B64=""
      export AGENT2_BOOTSTRAP_B64=""
      export AGENT2_USER_B64=""
      export AGENT3_NAME="Agent3"
      export AGENT3_MODEL="anthropic/claude-opus-4-5"
      export AGENT3_BOT_TOKEN="BOT_TOKEN_3"
      export AGENT3_DISCORD_BOT_TOKEN=""
      export AGENT3_IDENTITY_B64=""
      export AGENT3_SOUL_B64=""
      export AGENT3_AGENTS_B64=""
      export AGENT3_BOOT_B64=""
      export AGENT3_BOOTSTRAP_B64=""
      export AGENT3_USER_B64=""
      ;;
    discord)
      export PLATFORM="discord"
      export PLATFORM_B64=$(echo -n "discord" | base64)
      export AGENT1_DISCORD_BOT_TOKEN="DISCORD_TOKEN_1"
      export DISCORD_GUILD_ID_B64=$(echo -n "guild123" | base64)
      export DISCORD_OWNER_ID_B64=$(echo -n "987654321" | base64)
      export DISCORD_OWNER_ID="987654321"
      ;;
    both)
      export PLATFORM="both"
      export PLATFORM_B64=$(echo -n "both" | base64)
      export AGENT1_DISCORD_BOT_TOKEN="DISCORD_TOKEN_1"
      export DISCORD_GUILD_ID_B64=$(echo -n "guild123" | base64)
      export DISCORD_OWNER_ID_B64=$(echo -n "987654321" | base64)
      export DISCORD_OWNER_ID="987654321"
      ;;
    session)
      export AGENT_COUNT=3
      export ISOLATION_DEFAULT="session"
      export ISOLATION_GROUPS="group-a:agent1,agent2:18790 group-b:agent3:18791"
      export AGENT2_NAME="Agent2"
      export AGENT2_MODEL="anthropic/claude-opus-4-5"
      export AGENT2_BOT_TOKEN="BOT_TOKEN_2"
      export AGENT2_DISCORD_BOT_TOKEN=""
      export AGENT3_NAME="Agent3"
      export AGENT3_MODEL="anthropic/claude-opus-4-5"
      export AGENT3_BOT_TOKEN="BOT_TOKEN_3"
      export AGENT3_DISCORD_BOT_TOKEN=""
      ;;
  esac
}

# =============================================================================
echo ""
echo "=== PR3: --mode full produces valid JSON ==="
# =============================================================================

(
  setup_mock_env single
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  if echo "$output" | jq . >/dev/null 2>&1; then
    echo "PASS: full mode produces valid JSON"
  else
    echo "FAIL: full mode produces invalid JSON"
    echo "$output" | head -5 >&2
    exit 1
  fi
  
  # Check required top-level keys
  for key in gateway agents channels env; do
    if echo "$output" | jq -e ".$key" >/dev/null 2>&1; then
      echo "PASS: full config has .$key"
    else
      echo "FAIL: full config missing .$key"
    fi
  done
  
  # Check gateway bind is loopback
  bind=$(echo "$output" | jq -r '.gateway.bind')
  [ "$bind" = "loopback" ] && echo "PASS: gateway.bind is loopback" || echo "FAIL: gateway.bind='$bind'"
  
  # Check gateway port
  port=$(echo "$output" | jq -r '.gateway.port')
  [ "$port" = "18789" ] && echo "PASS: gateway.port is 18789" || echo "FAIL: gateway.port='$port'"
  
  # Check gateway token
  token=$(echo "$output" | jq -r '.gateway.auth.token')
  [ "$token" = "$MOCK_GATEWAY_TOKEN" ] && echo "PASS: gateway token set correctly" || echo "FAIL: gateway token='$token'"
  
) > /tmp/test-gen-config-full.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-full.txt

# =============================================================================
echo ""
echo "=== PR3: Account names match agent IDs (never 'default') ==="
# =============================================================================

(
  setup_mock_env single
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  # Telegram accounts should be keyed by agent ID
  tg_keys=$(echo "$output" | jq -r '.channels.telegram.accounts | keys[]' 2>/dev/null)
  if echo "$tg_keys" | grep -q "^agent1$"; then
    echo "PASS: telegram account keyed as 'agent1'"
  else
    echo "FAIL: telegram account not keyed as 'agent1' (keys: $tg_keys)"
  fi
  
  if echo "$tg_keys" | grep -q "^default$"; then
    echo "FAIL: telegram has 'default' account key"
  else
    echo "PASS: no 'default' account key in telegram"
  fi
  
) > /tmp/test-gen-config-accounts.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-accounts.txt

# =============================================================================
echo ""
echo "=== PR3: Multi-agent produces correct accounts + bindings ==="
# =============================================================================

(
  setup_mock_env multi
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  # Should have 3 agents
  agent_count=$(echo "$output" | jq '.agents.list | length')
  [ "$agent_count" = "3" ] && echo "PASS: 3 agents in list" || echo "FAIL: agent count=$agent_count"
  
  # Agent IDs should be agent1, agent2, agent3
  for i in 1 2 3; do
    aid=$(echo "$output" | jq -r ".agents.list[$((i-1))].id")
    [ "$aid" = "agent$i" ] && echo "PASS: agent $i id is 'agent$i'" || echo "FAIL: agent $i id='$aid'"
  done
  
  # Only agent1 should be default
  is_default_1=$(echo "$output" | jq -r '.agents.list[0].default')
  is_default_2=$(echo "$output" | jq -r '.agents.list[1].default')
  [ "$is_default_1" = "true" ] && echo "PASS: agent1 is default" || echo "FAIL: agent1 default=$is_default_1"
  [ "$is_default_2" = "false" ] && echo "PASS: agent2 is not default" || echo "FAIL: agent2 default=$is_default_2"
  
  # Telegram accounts for all 3
  for i in 1 2 3; do
    tok=$(echo "$output" | jq -r ".channels.telegram.accounts.agent${i}.botToken // empty")
    [ -n "$tok" ] && echo "PASS: telegram account agent${i} exists" || echo "FAIL: telegram account agent${i} missing"
  done
  
  # Bindings for agent2, agent3 (agent1 is default, doesn't need binding)
  binding_count=$(echo "$output" | jq '.bindings | length')
  [ "$binding_count" -ge 2 ] && echo "PASS: at least 2 bindings" || echo "FAIL: bindings count=$binding_count"
  
) > /tmp/test-gen-config-multi.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-multi.txt

# =============================================================================
echo ""
echo "=== PR3: Telegram-only disables Discord ==="
# =============================================================================

(
  setup_mock_env single
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  tg_enabled=$(echo "$output" | jq -r '.channels.telegram.enabled // .plugins.entries.telegram.enabled // empty')
  dc_enabled=$(echo "$output" | jq -r '.channels.discord.enabled // .plugins.entries.discord.enabled // empty')
  
  [ "$tg_enabled" = "true" ] && echo "PASS: telegram enabled" || echo "FAIL: telegram enabled=$tg_enabled"
  [ "$dc_enabled" = "false" ] && echo "PASS: discord disabled" || echo "FAIL: discord enabled=$dc_enabled"
  
) > /tmp/test-gen-config-tg.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-tg.txt

# =============================================================================
echo ""
echo "=== PR3: Discord-only disables Telegram ==="
# =============================================================================

(
  setup_mock_env discord
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  tg_enabled=$(echo "$output" | jq -r '.plugins.entries.telegram.enabled // .channels.telegram.enabled // empty')
  dc_enabled=$(echo "$output" | jq -r '.plugins.entries.discord.enabled // .channels.discord.enabled // empty')
  
  [ "$tg_enabled" = "false" ] && echo "PASS: telegram disabled" || echo "FAIL: telegram enabled=$tg_enabled"
  [ "$dc_enabled" = "true" ] && echo "PASS: discord enabled" || echo "FAIL: discord enabled=$dc_enabled"
  
) > /tmp/test-gen-config-dc.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-dc.txt

# =============================================================================
echo ""
echo "=== PR3: Both platforms enabled ==="
# =============================================================================

(
  setup_mock_env both
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  tg_enabled=$(echo "$output" | jq -r '.plugins.entries.telegram.enabled // .channels.telegram.enabled // empty')
  dc_enabled=$(echo "$output" | jq -r '.plugins.entries.discord.enabled // .channels.discord.enabled // empty')
  
  [ "$tg_enabled" = "true" ] && echo "PASS: telegram enabled" || echo "FAIL: telegram enabled=$tg_enabled"
  [ "$dc_enabled" = "true" ] && echo "PASS: discord enabled" || echo "FAIL: discord enabled=$dc_enabled"
  
) > /tmp/test-gen-config-both.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-both.txt

# =============================================================================
echo ""
echo "=== PR3: Session mode filters agents by group ==="
# =============================================================================

(
  setup_mock_env session
  # Generate config for group-a (agent1, agent2) on port 18790
  output=$("$GEN_CONFIG" --mode session --group "group-a" --agents "agent1,agent2" --port 18790 --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  if echo "$output" | jq . >/dev/null 2>&1; then
    echo "PASS: session mode produces valid JSON"
  else
    echo "FAIL: session mode produces invalid JSON"
    exit 1
  fi
  
  # Port should be 18790
  port=$(echo "$output" | jq -r '.gateway.port')
  [ "$port" = "18790" ] && echo "PASS: session port is 18790" || echo "FAIL: session port='$port'"
  
  # Should only have agent1 and agent2, not agent3
  agent_count=$(echo "$output" | jq '.agents.list | length')
  [ "$agent_count" = "2" ] && echo "PASS: 2 agents in group-a" || echo "FAIL: group-a agent count=$agent_count"
  
  # Agent3 should NOT be present
  has_agent3=$(echo "$output" | jq -r '.agents.list[] | select(.id == "agent3") | .id // empty')
  [ -z "$has_agent3" ] && echo "PASS: agent3 not in group-a config" || echo "FAIL: agent3 found in group-a"
  
  # Telegram should only have tokens for agent1 and agent2
  tg_keys=$(echo "$output" | jq -r '.channels.telegram.accounts | keys[]' 2>/dev/null || echo "")
  if echo "$tg_keys" | grep -q "agent3"; then
    echo "FAIL: telegram has agent3 account in group-a config"
  else
    echo "PASS: telegram only has group-a agents"
  fi
  
) > /tmp/test-gen-config-session.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-session.txt

# =============================================================================
echo ""
echo "=== PR3: Safe-mode config uses provided token ==="
# =============================================================================

(
  setup_mock_env single
  output=$("$GEN_CONFIG" --mode safe-mode \
    --token "sk-ant-safe-mode-token" \
    --provider "anthropic" \
    --platform "telegram" \
    --bot-token "SAFE_MODE_BOT_TOKEN" \
    --owner-id "123456789" \
    --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  if echo "$output" | jq . >/dev/null 2>&1; then
    echo "PASS: safe-mode produces valid JSON"
  else
    echo "FAIL: safe-mode produces invalid JSON"
    exit 1
  fi
  
  # Should have safe-mode agent
  agent_id=$(echo "$output" | jq -r '.agents.list[0].id // empty')
  [ "$agent_id" = "safe-mode" ] && echo "PASS: safe-mode agent id" || echo "FAIL: agent id='$agent_id'"
  
  # API key should be set
  api_key=$(echo "$output" | jq -r '.env.ANTHROPIC_API_KEY // empty')
  [ "$api_key" = "sk-ant-safe-mode-token" ] && echo "PASS: API key set" || echo "FAIL: API key='$api_key'"
  
  # Bot token account should be "safe-mode"
  sm_token=$(echo "$output" | jq -r '.channels.telegram.accounts["safe-mode"].botToken // empty')
  [ "$sm_token" = "SAFE_MODE_BOT_TOKEN" ] && echo "PASS: safe-mode account token set" || echo "FAIL: safe-mode token='$sm_token'"
  
) > /tmp/test-gen-config-safemode.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-safemode.txt

# =============================================================================
echo ""
echo "=== PR3: Idempotent — running twice produces same output ==="
# =============================================================================

(
  setup_mock_env single
  output1=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  output2=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  if [ "$output1" = "$output2" ]; then
    echo "PASS: idempotent output"
  else
    echo "FAIL: outputs differ between runs"
    diff <(echo "$output1") <(echo "$output2") | head -10 >&2
  fi
  
) > /tmp/test-gen-config-idempotent.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-idempotent.txt

# =============================================================================
echo ""
echo "=== PR3: JSON escaping handles special characters ==="
# =============================================================================

(
  setup_mock_env single
  export AGENT1_NAME='Test "Bot" with $pecial & chars'
  output=$("$GEN_CONFIG" --mode full --gateway-token "$MOCK_GATEWAY_TOKEN" 2>/dev/null)
  
  if echo "$output" | jq . >/dev/null 2>&1; then
    echo "PASS: special characters produce valid JSON"
  else
    echo "FAIL: special characters break JSON"
  fi
  
  # The name should be preserved
  name=$(echo "$output" | jq -r '.agents.list[0].name')
  if [ "$name" = 'Test "Bot" with $pecial & chars' ]; then
    echo "PASS: special characters round-trip correctly"
  else
    echo "FAIL: name='$name'"
  fi
  
) > /tmp/test-gen-config-escape.txt 2>&1

while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done < /tmp/test-gen-config-escape.txt

# =============================================================================
echo ""
echo "=== PR3: No more heredoc config patterns in non-legacy scripts ==="
# =============================================================================

# After PR3, only legacy scripts (phase1, phase2) and the old build-full-config 
# should have heredoc config patterns. The new scripts should not.
for script in generate-session-services.sh safe-mode-recovery.sh; do
  path="$REPO_DIR/scripts/$script"
  [ -f "$path" ] || continue
  
  # Check for heredoc JSON config generation patterns
  if grep -q '<<CFG\|<<CONFIG\|<<EOF_CONFIG\|<<OPENCLAW_CONFIG' "$path"; then
    fail "$script still has heredoc config pattern — should use generate-config.sh"
  else
    pass "$script has no heredoc config patterns"
  fi
done

# build-full-config.sh should call generate-config.sh instead of heredoc
BFC="$REPO_DIR/scripts/build-full-config.sh"
if grep -q 'generate-config.sh' "$BFC"; then
  pass "build-full-config.sh calls generate-config.sh"
else
  fail "build-full-config.sh should call generate-config.sh"
fi

# =============================================================================
echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}$PASSED${NC}  Failed: ${RED}$FAILED${NC}"
exit $FAILED
