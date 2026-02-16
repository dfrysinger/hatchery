#!/bin/bash
# =============================================================================
# phase1-critical.sh -- Early boot: get bot online ASAP
# =============================================================================
# Purpose:  Critical first phase of droplet provisioning. Installs Node.js,
#           openclaw, creates user account, generates minimal openclaw.json
#           config, starts the openclaw gateway service, and notifies owner.
#           Launches phase2-background.sh when complete.
#
# Inputs:   /etc/droplet.env -- all B64-encoded secrets and config
#           /etc/habitat-parsed.env -- parsed habitat config (generated here)
#
# Outputs:  /home/$USERNAME/.openclaw/openclaw.json -- minimal bot config
#           /etc/systemd/system/clawdbot.service -- systemd unit
#           /var/lib/init-status/phase1-complete -- completion marker
#
# Dependencies: parse-habitat.py, tg-notify.sh, set-stage.sh, npm, curl
#
# Original: /usr/local/sbin/phase1-critical.sh (in hatch.yaml write_files)
# =============================================================================
set -e
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
if ! python3 /usr/local/bin/parse-habitat.py; then
  # Fallback: extract minimal config directly from HABITAT_B64 for safe-mode
  # Handles both v1 (botToken, discordBotToken) and v2 (tokens.telegram, tokens.discord) schemas
  python3 << 'FALLBACK_PY' >> /etc/habitat-parsed.env 2>/dev/null || true
import base64, json, os, sys
try:
    h = json.loads(base64.b64decode(os.environ.get('HABITAT_B64', '')).decode())
except:
    h = {}
print('HABITAT_NAME="broken"')
print('AGENT_COUNT=1')

# Agent 1 config
a = h.get('agents', [{}])[0] if h.get('agents') else {}
name = a.get('name', 'Claude')
print(f'AGENT1_NAME="{name}"')

# Platform detection (v2: platforms.X, v1: discord/telegram presence)
plat = h.get('platform', '')
if not plat:
    if h.get('platforms', {}).get('discord') or h.get('discord'):
        plat = 'discord'
    elif h.get('platforms', {}).get('telegram') or a.get('botToken') or a.get('tokens', {}).get('telegram'):
        plat = 'telegram'
    else:
        plat = 'telegram'  # default
print(f'PLATFORM="{plat}"')

# Telegram token: v2 (tokens.telegram) > v1 (botToken)
tg_tok = a.get('tokens', {}).get('telegram', '') or a.get('botToken', '')
print(f'AGENT1_BOT_TOKEN="{tg_tok}"')

# Discord token: v2 (tokens.discord) > v1 (discordBotToken)
dc_tok = a.get('tokens', {}).get('discord', '') or a.get('discordBotToken', '')
print(f'AGENT1_DISCORD_BOT_TOKEN="{dc_tok}"')

# Owner IDs - v2: platforms.X.ownerId, v1: discord{OwnerId,GuildId}
dc_owner = h.get('platforms', {}).get('discord', {}).get('ownerId', '') or h.get('discordOwnerId', '') or h.get('discord', {}).get('ownerId', '')
dc_guild = h.get('platforms', {}).get('discord', {}).get('guildId', '') or h.get('discordGuildId', '') or h.get('discord', {}).get('guildId', '')
tg_owner = h.get('platforms', {}).get('telegram', {}).get('ownerId', '') or h.get('telegram', {}).get('ownerId', '')
print(f'DISCORD_OWNER_ID="{dc_owner}"')
print(f'DISCORD_GUILD_ID="{dc_guild}"')
if tg_owner:
    print(f'TELEGRAM_USER_ID="{tg_owner}"')
FALLBACK_PY
fi
source /etc/habitat-parsed.env
S="/usr/local/bin/set-stage.sh"
TG="/usr/local/bin/tg-notify.sh"
LOG="/var/log/phase1.log"
START=$(date +%s)
# Boot messages removed - status API provides progress, first message will be final outcome
$S 1 "preparing"
NODE_PID=$(cat /tmp/downloads/node.pid 2>/dev/null)
[ -n "$NODE_PID" ] && wait $NODE_PID 2>/dev/null || true
if [ -f /tmp/downloads/node.tar.xz ]; then
  tar -xJf /tmp/downloads/node.tar.xz -C /usr/local --strip-components=1 >> "$LOG" 2>&1
  rm -f /tmp/downloads/node.tar.xz
else
  apt-get update -qq && apt-get install -y nodejs npm >> "$LOG" 2>&1
fi
# Install jq early - needed by build-full-config.sh which may run via API before phase2
apt-get install -y jq >> "$LOG" 2>&1 || true
$S 2 "installing-bot"
npm install -g openclaw@latest >> "$LOG" 2>&1
PW=$(d "$PASSWORD_B64")
id "$USERNAME" &>/dev/null || useradd -m -s /bin/bash -G sudo "$USERNAME"
echo "$USERNAME:$PW" | chpasswd
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
H="/home/$USERNAME"
chown $USERNAME:$USERNAME $H
AK=$(d "$ANTHROPIC_KEY_B64")
TBT="$AGENT1_BOT_TOKEN"
DBT="$AGENT1_DISCORD_BOT_TOKEN"
TUI=$(d "$TELEGRAM_USER_ID_B64")
DOI="${DISCORD_OWNER_ID:-$(d "$DISCORD_OWNER_ID_B64")}"
DGI="${DISCORD_GUILD_ID:-$(d "$DISCORD_GUILD_ID_B64")}"
GK=$(d "$GOOGLE_API_KEY_B64")
A1N="$AGENT1_NAME"
# PLATFORM must be explicitly set - no silent defaults
PLATFORM="${PLATFORM:-$(d "$PLATFORM_B64")}"
GT=$(openssl rand -hex 24)
mkdir -p $H/.openclaw $H/clawd/agents/agent1/memory
echo "$GT" > $H/.openclaw/gateway-token.txt
ln -sf "$H/clawd/HEARTBEAT.md" "$H/clawd/agents/agent1/HEARTBEAT.md"
# Determine platform flags
TG_ENABLED="false"; DC_ENABLED="false"
case "$PLATFORM" in
  telegram) TG_ENABLED="true" ;;
  discord)  DC_ENABLED="true" ;;
  both)     TG_ENABLED="true"; DC_ENABLED="true" ;;
  *)
    echo "[build-minimal-config] ERROR: Invalid PLATFORM='${PLATFORM}'" >&2
    echo "  Valid options: telegram, discord, both" >&2
    echo "  Fix: Set PLATFORM in habitat config or /etc/droplet.env" >&2
    exit 1
    ;;
esac
# Build plugins entries
PLUGINS_JSON="\"telegram\":{\"enabled\":${TG_ENABLED}},\"discord\":{\"enabled\":${DC_ENABLED}}"
# Build telegram channel config
TG_CHANNEL=""
if [ "$TG_ENABLED" = "true" ]; then
  TG_CHANNEL="\"telegram\":{\"enabled\":true,\"dmPolicy\":\"allowlist\",\"allowFrom\":[\"${TUI}\"],\"accounts\":{\"default\":{\"botToken\":\"${TBT}\"}}}"
else
  TG_CHANNEL="\"telegram\":{\"enabled\":false}"
fi
# Build discord channel config
DC_CHANNEL=""
if [ "$DC_ENABLED" = "true" ]; then
  DC_DM_ALLOW=""
  [ -n "$DOI" ] && DC_DM_ALLOW=",\"allowFrom\":[\"${DOI}\"]"
  DC_GUILD=""
  [ -n "$DGI" ] && DC_GUILD=",\"guilds\":{\"${DGI}\":{\"requireMention\":true}}"
  DC_CHANNEL="\"discord\":{\"enabled\":true,\"groupPolicy\":\"allowlist\",\"accounts\":{\"default\":{\"token\":\"${DBT}\"}},\"dm\":{\"enabled\":true,\"policy\":\"pairing\"${DC_DM_ALLOW}}${DC_GUILD}}"
else
  DC_CHANNEL="\"discord\":{\"enabled\":false}"
fi
cat > $H/.openclaw/openclaw.json <<CFG
{
  "env": {
    "ANTHROPIC_API_KEY": "${AK}"
  },
  "agents": {
    "defaults": {
      "model": {"primary": "anthropic/claude-opus-4-5"},
      "workspace": "$H/clawd"
    },
    "list": [
      {
        "id": "agent1",
        "default": true,
        "name": "${A1N}",
        "workspace": "$H/clawd/agents/agent1"
      }
    ]
  },
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${GT}"
    }
  },
  "plugins": {
    "entries": {
      ${PLUGINS_JSON}
    }
  },
  "channels": {
    ${TG_CHANNEL},
    ${DC_CHANNEL}
  }
}
CFG
# Save as emergency config for safe mode fallback
cp $H/.openclaw/openclaw.json $H/.openclaw/openclaw.emergency.json
echo "ANTHROPIC_API_KEY=${AK}" > $H/.openclaw/.env
[ -n "$GK" ] && echo -e "GOOGLE_API_KEY=${GK}\nGEMINI_API_KEY=${GK}" >> $H/.openclaw/.env
GCID=$(d "$GMAIL_CLIENT_ID_B64"); GSEC=$(d "$GMAIL_CLIENT_SECRET_B64"); GRTK=$(d "$GMAIL_REFRESH_TOKEN_B64")
[ -n "$GCID" ] && echo -e "GMAIL_CLIENT_ID=${GCID}\nGMAIL_CLIENT_SECRET=${GSEC}\nGMAIL_REFRESH_TOKEN=${GRTK}" >> $H/.openclaw/.env
echo -e "# Agent: ${A1N}\nModel: Claude Sonnet\nBe helpful. Desktop setup in progress..." > $H/clawd/agents/agent1/AGENTS.md
cat > $H/clawd/agents/agent1/BOOT.md <<'BOOTMD'
Desktop setup in progress. RDP will be ready soon.
If nothing needs attention, reply with ONLY: NO_REPLY.
BOOTMD
chown -R $USERNAME:$USERNAME $H/.openclaw $H/clawd
chmod 700 $H/.openclaw
chmod 600 $H/.openclaw/openclaw.json
cat > /etc/systemd/system/clawdbot.service <<SVC
[Unit]
Description=Clawdbot Gateway
After=network.target openclaw-restore.service
Wants=openclaw-restore.service
[Service]
Type=simple
User=$USERNAME
WorkingDirectory=$H
ExecStart=/usr/local/bin/openclaw gateway --bind lan --port 18789
ExecStartPost=+/usr/local/bin/gateway-health-check.sh
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=2
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--experimental-sqlite
Environment=RUN_MODE=execstartpost
Environment=ANTHROPIC_API_KEY=${AK}
$([ -n "$GK" ] && echo "Environment=GOOGLE_API_KEY=${GK}")
$([ -n "$GK" ] && echo "Environment=GEMINI_API_KEY=${GK}")
[Install]
WantedBy=multi-user.target
SVC

# Create api-server.service if it doesn't exist (PR #146 removed it from write_files)
if [ ! -f /etc/systemd/system/api-server.service ]; then
cat > /etc/systemd/system/api-server.service <<'APISVC'
[Unit]
Description=Droplet Status API
After=network.target

[Service]
EnvironmentFile=-/etc/api-server.env
EnvironmentFile=-/etc/habitat-parsed.env
ExecStart=/usr/local/bin/api-server.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
APISVC
fi

systemctl daemon-reload

# Create API_SECRET if not already set (moved from runcmd which runs before service file exists)
if [ ! -f /etc/api-server.env ]; then
  source /etc/droplet.env 2>/dev/null || true
  if [ -n "$API_SECRET_B64" ] && [ "$API_SECRET_B64" != "[[API_SECRET_B64]]" ]; then
    API_SECRET=$(echo "$API_SECRET_B64" | base64 -d)
    echo "[api-server] Using provided API_SECRET"
  else
    API_SECRET=$(openssl rand -hex 32)
    echo "[api-server] Generated random API_SECRET"
  fi
  umask 077
  printf 'API_SECRET=%s\n' "$API_SECRET" > /etc/api-server.env
  chmod 600 /etc/api-server.env
fi

# Enable and start api-server (created above if it didn't exist)
systemctl enable api-server
systemctl start api-server || true
ufw allow 8080/tcp

# Enable and START restore service BEFORE clawdbot (if service file exists)
# clawdbot has After=openclaw-restore.service, so it waits for restore to complete
if [ -f /etc/systemd/system/openclaw-restore.service ]; then
    systemctl enable openclaw-restore.service
    systemctl start openclaw-restore.service || true  # Don't fail if restore has issues
fi
# Enable clawdbot but DON'T start - reboot will start it with full config
# ExecStartPost health check will validate and send notifications
systemctl enable clawdbot
ufw allow 18789/tcp
$S 3 "phase1-complete"
touch /var/lib/init-status/phase1-complete
echo "$START" > /var/lib/init-status/phase1-time
/usr/local/bin/set-phase.sh 2 "background-setup"
nohup /usr/local/sbin/phase2-background.sh >> /var/log/phase2.log 2>&1 &
disown
