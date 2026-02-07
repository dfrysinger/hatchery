#!/usr/bin/env python3
# =============================================================================
# parse-habitat.py -- Parse HABITAT_B64 JSON into /etc/habitat-parsed.env
# =============================================================================
# Purpose:  Decodes the base64-encoded habitat JSON from the environment,
#           writes /etc/habitat.json and /etc/habitat-parsed.env with all
#           agent configs, platform settings, council config, and global
#           identity/soul/boot fields as shell-sourceable env vars.
#
# Inputs:   HABITAT_B64 (required) -- base64-encoded habitat JSON
#           AGENT_LIB_B64 (optional) -- base64-encoded agent library JSON
#
# Outputs:  /etc/habitat.json -- raw habitat JSON
#           /etc/habitat-parsed.env -- shell-sourceable env vars
#
# Original: /usr/local/bin/parse-habitat.py (in hatch.yaml write_files)
# =============================================================================
import json, base64, os, sys
def d(val):
    try: return base64.b64decode(val).decode()
    except: return ""
def b64(s):
    return base64.b64encode((s or "").encode()).decode()
hab_raw = os.environ.get('HABITAT_B64', '')
lib_raw = os.environ.get('AGENT_LIB_B64', '')
if not hab_raw:
    print("ERROR: HABITAT_B64 not set", file=sys.stderr)
    sys.exit(1)
try:
    hab = json.loads(d(hab_raw))
except (json.JSONDecodeError, Exception) as e:
    print("ERROR: Failed to parse HABITAT_B64: {}".format(e), file=sys.stderr)
    sys.exit(1)
lib = {}
if lib_raw:
    try:
        lib = json.loads(d(lib_raw))
    except (json.JSONDecodeError, Exception):
        print("WARN: Failed to parse AGENT_LIB_B64, using empty library", file=sys.stderr)
with open('/etc/habitat.json', 'w') as f:
    json.dump(hab, f, indent=2)
os.chmod('/etc/habitat.json', 0o600)
with open('/etc/habitat-parsed.env', 'w') as f:
    f.write('HABITAT_NAME="{}"\n'.format(hab["name"]))
    f.write('HABITAT_NAME_B64="{}"\n'.format(b64(hab["name"])))
    f.write('DESTRUCT_MINS="{}"\n'.format(hab.get("destructMinutes", 0)))
    f.write('DESTRUCT_MINS_B64="{}"\n'.format(b64(str(hab.get("destructMinutes", 0)))))
    f.write('BG_COLOR="{}"\n'.format(hab.get("bgColor", "2D3748")))
    # Platform (default: "telegram" for backward compat)
    platform = hab.get("platform", "telegram")
    f.write('PLATFORM="{}"\n'.format(platform))
    f.write('PLATFORM_B64="{}"\n'.format(b64(platform)))
    # Discord config
    discord_cfg = hab.get("discord", {})
    f.write('DISCORD_GUILD_ID="{}"\n'.format(discord_cfg.get("serverId", "")))
    f.write('DISCORD_GUILD_ID_B64="{}"\n'.format(b64(discord_cfg.get("serverId", ""))))
    f.write('DISCORD_OWNER_ID="{}"\n'.format(discord_cfg.get("ownerId", "")))
    f.write('DISCORD_OWNER_ID_B64="{}"\n'.format(b64(discord_cfg.get("ownerId", ""))))
    # Telegram config
    telegram_cfg = hab.get("telegram", {})
    telegram_owner_id = telegram_cfg.get("ownerId", "")
    f.write('TELEGRAM_OWNER_ID="{}"\n'.format(telegram_owner_id))
    f.write('TELEGRAM_OWNER_ID_B64="{}"\n'.format(b64(telegram_owner_id)))
    # Backward compat: keep TELEGRAM_USER_ID_B64 as alias
    f.write('TELEGRAM_USER_ID_B64="{}"\n'.format(b64(telegram_owner_id)))
    # Council config (supports nested telegram.groupId and legacy groupId)
    council = hab.get("council", {})
    council_tg = council.get("telegram", {})
    council_group_id = council_tg.get("groupId", council.get("groupId", hab.get("councilGroupId", "")))
    f.write('COUNCIL_GROUP_ID="{}"\n'.format(council_group_id))
    f.write('COUNCIL_GROUP_NAME="{}"\n'.format(council.get("groupName", "")))
    f.write('COUNCIL_JUDGE="{}"\n'.format(council.get("judge", "")))
    f.write('HABITAT_DOMAIN="{}"\n'.format(hab.get("domain", "")))
    f.write('GLOBAL_IDENTITY_B64="{}"\n'.format(b64(hab.get("globalIdentity", ""))))
    f.write('GLOBAL_BOOT_B64="{}"\n'.format(b64(hab.get("globalBoot", ""))))
    f.write('GLOBAL_BOOTSTRAP_B64="{}"\n'.format(b64(hab.get("globalBootstrap", ""))))
    f.write('GLOBAL_SOUL_B64="{}"\n'.format(b64(hab.get("globalSoul", ""))))
    f.write('GLOBAL_AGENTS_B64="{}"\n'.format(b64(hab.get("globalAgents", ""))))
    f.write('GLOBAL_USER_B64="{}"\n'.format(b64(hab.get("globalUser", ""))))
    f.write('GLOBAL_TOOLS_B64="{}"\n'.format(b64(hab.get("globalTools", ""))))
    agents = hab.get("agents", [])
    f.write('AGENT_COUNT={}\n'.format(len(agents)))
    for i, agent_ref in enumerate(agents):
        n = i + 1
        name = agent_ref["agent"]
        lib_entry = lib.get(name, {})
        model = agent_ref.get("model") or lib_entry.get("model", "anthropic/claude-opus-4-5")
        identity = lib_entry.get("identity", "")
        soul = lib_entry.get("soul", "")
        agents_md = lib_entry.get("agents", "")
        boot = lib_entry.get("boot", "")
        bootstrap = lib_entry.get("bootstrap", "")
        user = lib_entry.get("user", "")
        # Telegram bot token: prefer telegramBotToken, fall back to botToken for compat
        tg_bot_token = agent_ref.get("telegramBotToken", agent_ref.get("botToken", ""))
        # Discord bot token
        dc_bot_token = agent_ref.get("discordBotToken", "")
        f.write('AGENT{}_NAME="{}"\n'.format(n, name))
        f.write('AGENT{}_NAME_B64="{}"\n'.format(n, b64(name)))
        # Backward compat: BOT_TOKEN = telegram bot token
        f.write('AGENT{}_BOT_TOKEN="{}"\n'.format(n, tg_bot_token))
        f.write('AGENT{}_BOT_TOKEN_B64="{}"\n'.format(n, b64(tg_bot_token)))
        # Explicit per-platform tokens
        f.write('AGENT{}_TELEGRAM_BOT_TOKEN="{}"\n'.format(n, tg_bot_token))
        f.write('AGENT{}_TELEGRAM_BOT_TOKEN_B64="{}"\n'.format(n, b64(tg_bot_token)))
        f.write('AGENT{}_DISCORD_BOT_TOKEN="{}"\n'.format(n, dc_bot_token))
        f.write('AGENT{}_DISCORD_BOT_TOKEN_B64="{}"\n'.format(n, b64(dc_bot_token)))
        f.write('AGENT{}_MODEL="{}"\n'.format(n, model))
        f.write('AGENT{}_IDENTITY_B64="{}"\n'.format(n, b64(identity)))
        f.write('AGENT{}_SOUL_B64="{}"\n'.format(n, b64(soul)))
        f.write('AGENT{}_AGENTS_B64="{}"\n'.format(n, b64(agents_md)))
        f.write('AGENT{}_BOOT_B64="{}"\n'.format(n, b64(boot)))
        f.write('AGENT{}_BOOTSTRAP_B64="{}"\n'.format(n, b64(bootstrap)))
        f.write('AGENT{}_USER_B64="{}"\n'.format(n, b64(user)))
os.chmod('/etc/habitat-parsed.env', 0o600)
print("Parsed habitat '{}' with {} agents (platform: {})".format(hab['name'], len(agents), platform))
