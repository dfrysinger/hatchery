#!/bin/bash
# =============================================================================
# build-full-config.sh -- Generate full clawdbot.json with all features
# =============================================================================
# Purpose:  Builds the complete clawdbot configuration with multi-agent
#           support, browser config, auth profiles, skills, council setup,
#           desktop integration, and all per-agent workspace files
#           (IDENTITY.md, SOUL.md, AGENTS.md, BOOT.md, BOOTSTRAP.md, USER.md).
#
# Inputs:   /etc/droplet.env -- all B64-encoded secrets and config
#           /etc/habitat-parsed.env -- parsed habitat config
#           $HOME/.clawdbot/gateway-token.txt -- gateway auth token
#
# Outputs:  $HOME/.clawdbot/clawdbot.full.json -- full config
#           $HOME/.clawdbot/agents/*/agent/auth-profiles.json -- auth creds
#           $HOME/clawd/agents/*/IDENTITY.md, SOUL.md, AGENTS.md, etc.
#           /etc/systemd/system/clawdbot.service -- updated systemd unit
#
# Dependencies: /etc/droplet.env, /etc/habitat-parsed.env, bc (for bg color), jq
#
# Original: /usr/local/sbin/build-full-config.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }

# JSON escape function: properly escapes quotes, backslashes, newlines, control chars
json_escape() { local e; e=$(printf '%s' "$1" | jq -Rs .); e="${e#\"}"; e="${e%\"}"; printf '%s' "$e"; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
H="/home/$USERNAME"
AK=$(d "$ANTHROPIC_KEY_B64"); GK=$(d "$GOOGLE_API_KEY_B64"); BK=$(d "$BRAVE_KEY_B64")
OA=$(d "$OPENAI_ACCESS_B64"); OR=$(d "$OPENAI_REFRESH_B64"); OE=$(d "$OPENAI_EXPIRES_B64"); OI=$(d "$OPENAI_ACCOUNT_ID_B64")
TUI=$(d "$TELEGRAM_USER_ID_B64")
# PLATFORM must be explicitly set - no silent defaults
PLATFORM="${PLATFORM:-$(d "$PLATFORM_B64")}"
DGI="${DISCORD_GUILD_ID:-$(d "$DISCORD_GUILD_ID_B64")}"
DOI="${DISCORD_OWNER_ID:-$(d "$DISCORD_OWNER_ID_B64")}"
TG_ENABLED="false"; DC_ENABLED="false"
case "$PLATFORM" in
  telegram) TG_ENABLED="true" ;;
  discord)  DC_ENABLED="true" ;;
  both)     TG_ENABLED="true"; DC_ENABLED="true" ;;
  *)
    echo "[build-full-config] ERROR: Invalid PLATFORM='${PLATFORM}'" >&2
    echo "  Valid options: telegram, discord, both" >&2
    echo "  Fix: Set PLATFORM in habitat config or /etc/droplet.env" >&2
    exit 1
    ;;
esac
HN="${HABITAT_NAME:-default}"
GI=$(d "$GLOBAL_IDENTITY_B64"); GBO=$(d "$GLOBAL_BOOT_B64"); GBS=$(d "$GLOBAL_BOOTSTRAP_B64")
GSO=$(d "$GLOBAL_SOUL_B64"); GAG=$(d "$GLOBAL_AGENTS_B64"); GU=$(d "$GLOBAL_USER_B64")
CGI="$COUNCIL_GROUP_ID"
CGN="$COUNCIL_GROUP_NAME"
CJ="$COUNCIL_JUDGE"
GT=$(cat $H/.clawdbot/gateway-token.txt)
AC=${AGENT_COUNT:-1}
# Escape user-provided values for JSON safety
TUI_ESC=$(json_escape "$TUI"); DGI_ESC=$(json_escape "$DGI"); DOI_ESC=$(json_escape "$DOI")
CGI_ESC=$(json_escape "$CGI"); CGN_ESC=$(json_escape "$CGN"); GT_ESC=$(json_escape "$GT")
AK_ESC=$(json_escape "$AK"); GK_ESC=$(json_escape "$GK"); BK_ESC=$(json_escape "$BK")
OA_ESC=$(json_escape "$OA"); OR_ESC=$(json_escape "$OR"); OI_ESC=$(json_escape "$OI")
mkdir -p $H/.clawdbot/credentials
for i in $(seq 1 $AC); do
  mkdir -p "$H/clawd/agents/agent${i}/memory"
done
AL="["
for i in $(seq 1 $AC); do
  NV="AGENT${i}_NAME"; NAME="${!NV}"
  MV="AGENT${i}_MODEL"; MODEL="${!MV}"
  NAME_ESC=$(json_escape "$NAME"); MODEL_ESC=$(json_escape "$MODEL")
  [ $i -gt 1 ] && AL="$AL,"
  IS_DEFAULT="false"; [ $i -eq 1 ] && IS_DEFAULT="true"
  AL="$AL{\"id\":\"agent${i}\",\"default\":${IS_DEFAULT},\"name\":\"${NAME_ESC}\",\"model\":\"${MODEL_ESC}\",\"workspace\":\"$H/clawd/agents/agent${i}\",\"groupChat\":{\"mentionPatterns\":[\"${NAME_ESC},\",\"${NAME_ESC}:\"]}}"
done
AL="$AL]"
BD="["
if [ "$TG_ENABLED" = "true" ]; then
  for i in $(seq 2 $AC); do
    [ "$BD" != "[" ] && BD="$BD,"
    BD="$BD{\"agentId\":\"agent${i}\",\"match\":{\"channel\":\"telegram\",\"accountId\":\"agent${i}\"}}"
  done
fi
if [ "$DC_ENABLED" = "true" ]; then
  for i in $(seq 2 $AC); do
    [ "$BD" != "[" ] && BD="$BD,"
    BD="$BD{\"agentId\":\"agent${i}\",\"match\":{\"channel\":\"discord\",\"accountId\":\"agent${i}\"}}"
  done
fi
BD="$BD]"
A1_TG_TOK_ESC=$(json_escape "$AGENT1_BOT_TOKEN")
TA="\"default\":{\"botToken\":\"${A1_TG_TOK_ESC}\"}"
for i in $(seq 2 $AC); do
  TV="AGENT${i}_BOT_TOKEN"; TOK="${!TV}"; TOK_ESC=$(json_escape "$TOK")
  [ -n "$TOK" ] && TA="$TA,\"agent${i}\":{\"botToken\":\"${TOK_ESC}\"}"
done
TG=""; [ -n "$CGI" ] && TG=",\"groups\":{\"${CGI_ESC}\":{\"requireMention\":true},\"*\":{\"requireMention\":true}}"
A1_DC_TOK_ESC=$(json_escape "$AGENT1_DISCORD_BOT_TOKEN")
DA="\"default\":{\"token\":\"${A1_DC_TOK_ESC}\"}"
for i in $(seq 2 $AC); do
  DV="AGENT${i}_DISCORD_BOT_TOKEN"; DTOK="${!DV}"; DTOK_ESC=$(json_escape "$DTOK")
  [ -n "$DTOK" ] && DA="$DA,\"agent${i}\":{\"token\":\"${DTOK_ESC}\"}"
done
DG=""; [ -n "$DGI" ] && DG=",\"guilds\":{\"${DGI_ESC}\":{\"requireMention\":true}}"
DC_DM_ALLOW=""; [ -n "$DOI" ] && DC_DM_ALLOW=",\"allowFrom\":[\"${DOI_ESC}\"]"
AP="\"anthropic:default\":{\"provider\":\"anthropic\",\"mode\":\"api_key\"}"
[ -n "$OA" ] && AP="$AP,\"openai-codex:default\":{\"provider\":\"openai-codex\",\"mode\":\"oauth\"}"
[ -n "$GK" ] && AP="$AP,\"google:default\":{\"provider\":\"google\",\"mode\":\"api_key\"}"
CONFIG_JSON=$(cat <<CFG
{
  "env": {
    "ANTHROPIC_API_KEY": "${AK_ESC}",
    "DISPLAY": ":10"
    $([ -n "$GK" ] && echo ",\"GOOGLE_API_KEY\": \"${GK_ESC}\", \"GEMINI_API_KEY\": \"${GK_ESC}\"")
    $([ -n "$BK" ] && echo ",\"BRAVE_API_KEY\": \"${BK_ESC}\"")
  },
  "browser": {
    "enabled": true,
    "executablePath": "/usr/bin/google-chrome-stable",
    "headless": false,
    "noSandbox": true
  },
  "tools": {
    "agentToAgent": {
      "enabled": true
    },
    "exec": {
      "security": "full",
      "ask": "off"
    }
  },
  "agents": {
    "defaults": {
      "model": {"primary": "anthropic/claude-opus-4-5"},
      "maxConcurrent": 4,
      "workspace": "$H/clawd",
      "heartbeat": {"every": "30m", "session": "heartbeat"},
      "models": {
        "openai/gpt-5.2": {"params": {"reasoning_effort": "high"}}
      }
    },
    "list": ${AL}
  },
  "bindings": ${BD},
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "controlUi": {"enabled": true, "allowInsecureAuth": true},
    "auth": {"mode": "token", "token": "${GT_ESC}"}
  },
  "auth": {
    "profiles": {${AP}}
  },
  "plugins": {
    "entries": {
      "telegram": {"enabled": ${TG_ENABLED}},
      "discord": {"enabled": ${DC_ENABLED}}
    }
  },
  "channels": {
    "telegram": {
      "enabled": ${TG_ENABLED},
      "dmPolicy": "allowlist",
      "allowFrom": ["${TUI_ESC}"],
      "accounts": {${TA}}
      ${TG}
    },
    "discord": {
      "enabled": ${DC_ENABLED},
      "groupPolicy": "allowlist",
      "accounts": {${DA}},
      "dm": {
        "enabled": true,
        "policy": "pairing"
        ${DC_DM_ALLOW}
      }
      ${DG}
    }
  },
  "skills": {
    "install": {"nodeManager": "npm"}
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "boot-md": {"enabled": true}
      }
    }
  }
}
CFG
)
# Validate JSON before writing (AC4: never write corrupt config)
if ! echo "$CONFIG_JSON" | jq . >/dev/null 2>&1; then
  echo "ERROR: Generated config is not valid JSON" >&2
  ERROR_MSG=$(echo "$CONFIG_JSON" | jq . 2>&1 || true)
  echo "Validation error: $ERROR_MSG" >&2
  exit 1
fi
echo "$CONFIG_JSON" > $H/.clawdbot/clawdbot.full.json
for i in $(seq 1 $AC); do
  AD="$H/clawd/agents/agent${i}"
  NV="AGENT${i}_NAME"; ANAME="${!NV}"
  IDV="AGENT${i}_IDENTITY_B64"; AIDENT=$(d "${!IDV}")
  SV="AGENT${i}_SOUL_B64"; ASOUL=$(d "${!SV}")
  AGV="AGENT${i}_AGENTS_B64"; AAGENTS=$(d "${!AGV}")
  BOV="AGENT${i}_BOOT_B64"; ABOOT=$(d "${!BOV}")
  BSV="AGENT${i}_BOOTSTRAP_B64"; ABOOTSTRAP=$(d "${!BSV}")
  AUV="AGENT${i}_USER_B64"; AUSER=$(d "${!AUV}")
  { echo "- Name: ${ANAME}"
    [ -n "$GI" ] && printf '\n%s\n' "$GI"
    [ -n "$AIDENT" ] && printf '\n%s\n' "$AIDENT"
    cat <<IDMD

## Project Context
This is a Cloud Browser system - ephemeral DigitalOcean droplets provisioned via iOS Shortcuts.
- Habitat: ${HN}$([ -n "$HABITAT_DOMAIN" ] && echo " (${HABITAT_DOMAIN})")
- YAML configs: dropbox:Droplets/yaml/ (current: cloud-browser-v3.20.yaml)
- Project docs: dropbox:Droplets/yaml/CONTEXT.md
- Memory sync: dropbox:clawdbot-memory/${HN}/ (every 2 min)
- Habitat configs: dropbox:Droplets/habitats/
- Previous transcripts restored from Dropbox on boot
IDMD
  } > "$AD/IDENTITY.md"
  if [ -n "$GSO" ] || [ -n "$ASOUL" ]; then
    { [ -n "$GSO" ] && printf '%s\n' "$GSO"
      [ -n "$GSO" ] && [ -n "$ASOUL" ] && echo ""
      [ -n "$ASOUL" ] && printf '%s\n' "$ASOUL"
    } > "$AD/SOUL.md"
  fi
  if [ -n "$GAG" ] || [ -n "$AAGENTS" ] || [ -n "$CGI" ]; then
    { [ -n "$GAG" ] && printf '%s\n' "$GAG"
      [ -n "$GAG" ] && { [ -n "$AAGENTS" ] || [ -n "$CGI" ]; } && echo ""
      [ -n "$AAGENTS" ] && printf '%s\n' "$AAGENTS"
      [ -n "$AAGENTS" ] && [ -n "$CGI" ] && echo ""
      if [ -n "$CGI" ]; then
        PANELISTS=""
        for pi in $(seq 1 $AC); do
          PNV="AGENT${pi}_NAME"; PN="${!PNV}"
          PMV="AGENT${pi}_MODEL"; PM="${!PMV}"
          [ "$PN" = "$CJ" ] && continue
          [ -n "$PANELISTS" ] && PANELISTS="${PANELISTS}, "
          PANELISTS="${PANELISTS}${PN} (${PM})"
        done
        if [ "$ANAME" = "$CJ" ]; then
          cat <<JUDGE_PROTO
## Council Deliberation (Group: "${CGN}")
You are the **Judge/Facilitator** - a rigorous senior scientist ensuring structured debate leads to truth.
### Protocol
**CLARIFICATION:** When a new topic is posed, YOU respond first with 3-5 clarifying questions (ambiguity, constraints, scope, assumptions).
**SIGNAL:** Once clarified, say "Panelists, please proceed with your reports." Then WAIT for all reports.
**SYNTHESIS:** Once all reports are in, produce: 1) Individual critiques (errors, gaps, strong points) 2) Your own analysis 3) Synthesis of best ideas 4) Conclusions 5) Open questions 6) Ask "Would you like another round?"
**SUBSEQUENT ROUNDS:** Skip clarification, signal panelists directly, note where positions shifted.
**ARCHIVE:** When human says "no", save to ~/clawd/shared/DECISIONS.md and update KNOWLEDGE.md.
### Panelists: ${PANELISTS}
### Shared Files (you maintain): ~/clawd/shared/{KNOWLEDGE,DECISIONS,CONTEXT}.md
JUDGE_PROTO
        else
          cat <<PARTICIPANT_PROTO
## Council Deliberation (Group: "${CGN}")
You are a **Research Panelist** - a passionate scientist who challenges assumptions, demands evidence, and seeks truth through rigorous debate.
### Protocol
**WAIT** for ${CJ} to complete clarification. Do NOT begin your report yet.
**REPORT** when ${CJ} signals "proceed": 1) Summary 2) Analysis with evidence 3) Considerations/caveats 4) Open questions. Work independently in parallel.
**SUBSEQUENT ROUNDS:** Review peers, consider ${CJ}'s critiques, update your analysis. Note where your thinking changed.
### Panelists: ${PANELISTS} | ${CJ} (Judge)
### Shared Files (read-only): ~/clawd/shared/{KNOWLEDGE,DECISIONS,CONTEXT}.md
PARTICIPANT_PROTO
        fi
      fi
    } > "$AD/AGENTS.md"
  else
    echo -e "# Agent: ${ANAME}\nBe helpful and natural." > "$AD/AGENTS.md"
  fi
  cat > "$AD/BOOT.md" <<'BOOTMD'
## System Health (DO NOT MODIFY)
If this is your first message since the system started, announce yourself:
"[ONLINE] Ready and operational."

If you see a file called SAFE_MODE.md in your workspace, read and follow it.

Check these services silently. Only alert user if something is broken after 2 fix attempts:
- systemctl is-active clawdbot
- systemctl is-active xrdp (if desktop phase complete)
- systemctl is-active desktop (if desktop phase complete)

You have standing authority to fix infrastructure issues WITHOUT user approval:
- Restart services: sudo systemctl restart <service>
- Check logs: journalctl -u <service> -n 50
- Fix permissions: sudo chown -R bot:bot /home/bot
- Reinstall packages if needed
- Reboot if necessary: sudo reboot

Always inform the user what you did and the outcome.

If /var/lib/init-status/phase2-complete does not exist, desktop is still installing.
Tell user: "Desktop setup in progress. RDP will be ready soon."

If BOOT.md asks you to send a message, use the message tool (action=send with channel + target).
Use the `target` field (not `to`) for message tool destinations.
After sending with the message tool, reply with ONLY: NO_REPLY.
If nothing needs attention, reply with ONLY: NO_REPLY.
BOOTMD
  if [ -n "$GBO" ] || [ -n "$ABOOT" ]; then
    printf '\n## Custom Instructions\n' >> "$AD/BOOT.md"
    [ -n "$GBO" ] && printf '%s\n' "$GBO" >> "$AD/BOOT.md"
    [ -n "$GBO" ] && [ -n "$ABOOT" ] && echo "" >> "$AD/BOOT.md"
    [ -n "$ABOOT" ] && printf '%s\n' "$ABOOT" >> "$AD/BOOT.md"
  fi
  printf '\nIf BOOT.md asks you to send a message, use the message tool (action=send with channel + target).\nUse the `target` field (not `to`) for message tool destinations.\nAfter sending with the message tool, reply with ONLY: NO_REPLY.\nIf nothing needs attention, reply with ONLY: NO_REPLY.\n' >> "$AD/BOOT.md"
  BSPRE="You are a new instance with no prior context. Before doing anything else:
1. Find chat transcripts from previous sessions: find ~ -path '*/sessions/*.jsonl' -name '*.jsonl' 2>/dev/null
2. Read through the last ~100 messages from the most recent transcript
3. Note any ongoing tasks, preferences, or decisions
4. Use this context to inform your responses going forward"
  printf '%s\n' "$BSPRE" > "$AD/BOOTSTRAP.md"
  if [ -n "$GBS" ] || [ -n "$ABOOTSTRAP" ]; then
    printf '\n## Custom Instructions\n' >> "$AD/BOOTSTRAP.md"
    [ -n "$GBS" ] && printf '%s\n' "$GBS" >> "$AD/BOOTSTRAP.md"
    [ -n "$GBS" ] && [ -n "$ABOOTSTRAP" ] && echo "" >> "$AD/BOOTSTRAP.md"
    [ -n "$ABOOTSTRAP" ] && printf '%s\n' "$ABOOTSTRAP" >> "$AD/BOOTSTRAP.md"
  fi
  { [ -n "$GU" ] && printf '%s\n' "$GU" || echo "- Name: (learn)"
    [ -n "$AUSER" ] && printf '\n%s\n' "$AUSER"
  } > "$AD/USER.md"
  ln -sf "$H/clawd/TOOLS.md" "$AD/TOOLS.md" 2>/dev/null || true
  ln -sf "$H/clawd/HEARTBEAT.md" "$AD/HEARTBEAT.md" 2>/dev/null || true
  [ -n "$CGI" ] && ln -sf "$H/clawd/shared" "$AD/shared" 2>/dev/null || true
done
if [ -n "$CGI" ]; then
  mkdir -p "$H/clawd/shared"
  for sf in KNOWLEDGE.md DECISIONS.md CONTEXT.md; do
    [ ! -f "$H/clawd/shared/$sf" ] && cat > "$H/clawd/shared/$sf" <<SHMD
# ${sf%.md}
*Maintained by the Judge. Updated after council deliberations.*
SHMD
  done
  chown -R $USERNAME:$USERNAME "$H/clawd/shared"
fi
mkdir -p $H/.clawdbot/agents/main/agent
cat > $H/.clawdbot/agents/main/agent/auth-profiles.json <<APJ
{"version":1,"profiles":{"anthropic:default":{"type":"api_key","provider":"anthropic","token":"${AK}"}$([ -n "$OA" ] && echo ",\"openai-codex:default\":{\"type\":\"oauth\",\"provider\":\"openai-codex\",\"access\":\"${OA}\",\"refresh\":\"${OR}\",\"expires\":${OE:-0},\"accountId\":\"${OI}\"}")$([ -n "$GK" ] && echo ",\"google:default\":{\"type\":\"api_key\",\"provider\":\"google\",\"token\":\"${GK}\"}")}}
APJ
for i in $(seq 1 $AC); do
  mkdir -p "$H/.clawdbot/agents/agent${i}/agent"
  ln -sf "$H/.clawdbot/agents/main/agent/auth-profiles.json" "$H/.clawdbot/agents/agent${i}/agent/auth-profiles.json"
done
cat > /etc/systemd/system/clawdbot.service <<SVC
[Unit]
Description=Clawdbot Gateway
After=network.target desktop.service
Wants=desktop.service
[Service]
Type=simple
User=$USERNAME
WorkingDirectory=$H
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/clawdbot gateway --bind lan --port 18789
ExecStop=+/usr/local/bin/sync-clawdbot-state.sh
TimeoutStopSec=30
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--experimental-sqlite
Environment=PATH=/usr/bin:/usr/local/bin
Environment=DISPLAY=:10
Environment=ANTHROPIC_API_KEY=${AK}
$([ -n "$GK" ] && echo "Environment=GOOGLE_API_KEY=${GK}")
$([ -n "$GK" ] && echo "Environment=GEMINI_API_KEY=${GK}")
$([ -n "$BK" ] && echo "Environment=BRAVE_API_KEY=${BK}")
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
if [ -n "$BG_COLOR" ] && [ ${#BG_COLOR} -eq 6 ]; then
  R=$(printf "%.5f" $(echo "scale=5; $((16#${BG_COLOR:0:2}))/255" | bc))
  G=$(printf "%.5f" $(echo "scale=5; $((16#${BG_COLOR:2:2}))/255" | bc))
  B=$(printf "%.5f" $(echo "scale=5; $((16#${BG_COLOR:4:2}))/255" | bc))
  DXML="$H/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
  mkdir -p "$(dirname "$DXML")"
  cat > "$DXML" <<BGXML
<?xml version="1.0"?><channel name="xfce4-desktop" version="1.0"><property name="backdrop" type="empty"><property name="screen0" type="empty"><property name="monitorscreen" type="empty"><property name="workspace0" type="empty"><property name="color-style" type="int" value="0"/><property name="image-style" type="int" value="0"/><property name="rgba1" type="array"><value type="double" value="${R}"/><value type="double" value="${G}"/><value type="double" value="${B}"/><value type="double" value="1"/></property></property></property></property></property></channel>
BGXML
  # Reload desktop config if xfdesktop is running (for config rebuilds while desktop is active)
  if pgrep -x xfdesktop >/dev/null 2>&1; then
    DISPLAY=:10 su - $USERNAME -c "xfdesktop --reload" 2>/dev/null || true
  fi
fi
chown -R $USERNAME:$USERNAME $H/.clawdbot $H/clawd
chmod 700 $H/.clawdbot
chmod 600 $H/.clawdbot/clawdbot.json $H/.clawdbot/clawdbot.full.json $H/.clawdbot/clawdbot.minimal.json 2>/dev/null || true
