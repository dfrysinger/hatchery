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
# Schema:   Supports both v2 (new) and v1 (legacy) formats:
#
#   v2 (preferred):
#     {
#       "platforms": { "discord": { "ownerId": "..." } },
#       "agents": [{ "tokens": { "discord": "..." } }]
#     }
#
#   v1 (legacy, deprecated - see issue #112):
#     {
#       "discord": { "ownerId": "..." },
#       "agents": [{ "discordBotToken": "..." }]
#     }
#
# Original: /usr/local/bin/parse-habitat.py (in hatch.yaml write_files)
# =============================================================================
import json, base64, os, sys

def d(val):
    try: return base64.b64decode(val).decode()
    except: return ""

def b64(s):
    return base64.b64encode((s or "").encode()).decode()

# =============================================================================
# Schema Validation
# =============================================================================
def validate_type(value, expected_type, field_name, required=False):
    """Validate a field's type. Returns (is_valid, error_message)."""
    if value is None:
        if required:
            return False, f"'{field_name}' is required but missing"
        return True, None
    if not isinstance(value, expected_type):
        # Use readable type names
        type_names = {
            str: "string", int: "int", float: "number", bool: "bool",
            dict: "object", list: "array"
        }
        actual = type_names.get(type(value), type(value).__name__)
        if isinstance(expected_type, tuple):
            expected = '/'.join(type_names.get(t, t.__name__) for t in expected_type)
        else:
            expected = type_names.get(expected_type, expected_type.__name__)
        return False, f"'{field_name}' must be {expected}, got {actual}"
    return True, None

def validate_habitat_schema(hab):
    """Validate habitat JSON schema. Returns list of error messages."""
    errors = []
    
    # Root must be a dict
    if not isinstance(hab, dict):
        return [f"Habitat must be a JSON object, got {type(hab).__name__}"]
    
    # Required field: name (string)
    if "name" not in hab:
        errors.append("'name' is required")
    elif not isinstance(hab["name"], str):
        errors.append(f"'name' must be string, got {type(hab['name']).__name__}")
    elif not hab["name"].strip():
        errors.append("'name' cannot be empty")
    
    # Optional: platform (string)
    if "platform" in hab:
        valid, err = validate_type(hab["platform"], str, "platform")
        if not valid:
            errors.append(err)
        elif hab["platform"] not in ("telegram", "discord", "both"):
            errors.append(f"'platform' must be 'telegram', 'discord', or 'both', got '{hab['platform']}'")
    
    # Optional: platforms (dict)
    if "platforms" in hab:
        valid, err = validate_type(hab["platforms"], dict, "platforms")
        if not valid:
            errors.append(err)
        else:
            for platform_name, platform_cfg in hab["platforms"].items():
                if not isinstance(platform_cfg, dict):
                    errors.append(f"'platforms.{platform_name}' must be object, got {type(platform_cfg).__name__}")
    
    # Optional: agents (list) - technically required for useful config but we allow empty
    if "agents" in hab:
        if hab["agents"] is None:
            errors.append("'agents' cannot be null (use [] for empty)")
        elif not isinstance(hab["agents"], list):
            errors.append(f"'agents' must be array, got {type(hab['agents']).__name__}")
        else:
            for i, agent in enumerate(hab["agents"]):
                agent_errors = validate_agent_schema(agent, i)
                errors.extend(agent_errors)
    
    # Optional: destructMinutes (int or float, coercible to int)
    # Note: bool is subclass of int in Python, so explicitly exclude it
    if "destructMinutes" in hab:
        dm = hab["destructMinutes"]
        if dm is not None:
            if isinstance(dm, bool):
                errors.append("'destructMinutes' must be number, got bool (use integer like 30)")
            elif not isinstance(dm, (int, float)):
                errors.append(f"'destructMinutes' must be number, got {type(dm).__name__}")
    
    # Optional: remoteApi (bool)
    if "remoteApi" in hab:
        valid, err = validate_type(hab["remoteApi"], bool, "remoteApi")
        if not valid:
            errors.append(err)
    
    # Optional: apiBindAddress (string)
    if "apiBindAddress" in hab:
        valid, err = validate_type(hab["apiBindAddress"], str, "apiBindAddress")
        if not valid:
            errors.append(err)
    
    # Optional: council (dict)
    if "council" in hab:
        valid, err = validate_type(hab["council"], dict, "council")
        if not valid:
            errors.append(err)
    
    # Optional: sharedPaths (list of strings)
    if "sharedPaths" in hab:
        if not isinstance(hab["sharedPaths"], list):
            errors.append(f"'sharedPaths' must be array, got {type(hab['sharedPaths']).__name__}")
        else:
            for j, path in enumerate(hab["sharedPaths"]):
                if not isinstance(path, str):
                    errors.append(f"'sharedPaths[{j}]' must be string, got {type(path).__name__}")
    
    # Optional: isolation (string)
    if "isolation" in hab:
        valid, err = validate_type(hab["isolation"], str, "isolation")
        if not valid:
            errors.append(err)
    
    # Optional string fields
    for field in ["domain", "bgColor", "globalIdentity", "globalBoot", "globalBootstrap", 
                  "globalSoul", "globalAgents", "globalUser", "globalTools"]:
        if field in hab and hab[field] is not None:
            valid, err = validate_type(hab[field], str, field)
            if not valid:
                errors.append(err)
    
    return errors

def validate_agent_schema(agent, index):
    """Validate a single agent entry. Returns list of error messages."""
    errors = []
    prefix = f"agents[{index}]"
    
    # Agent can be string shorthand or dict
    if isinstance(agent, str):
        if not agent.strip():
            errors.append(f"'{prefix}' string shorthand cannot be empty")
        return errors
    
    if agent is None:
        errors.append(f"'{prefix}' cannot be null")
        return errors
    
    if not isinstance(agent, dict):
        errors.append(f"'{prefix}' must be string or object, got {type(agent).__name__}")
        return errors
    
    # Required: agent (string) - the agent name
    if "agent" not in agent:
        errors.append(f"'{prefix}.agent' is required")
    elif not isinstance(agent["agent"], str):
        errors.append(f"'{prefix}.agent' must be string, got {type(agent['agent']).__name__}")
    elif not agent["agent"].strip():
        errors.append(f"'{prefix}.agent' cannot be empty")
    
    # Optional: model (string)
    if "model" in agent and agent["model"] is not None:
        valid, err = validate_type(agent["model"], str, f"{prefix}.model")
        if not valid:
            errors.append(err)
    
    # Optional: tokens (dict)
    if "tokens" in agent:
        if not isinstance(agent["tokens"], dict):
            errors.append(f"'{prefix}.tokens' must be object, got {type(agent['tokens']).__name__}")
        else:
            for token_key, token_val in agent["tokens"].items():
                if token_val is not None and not isinstance(token_val, str):
                    errors.append(f"'{prefix}.tokens.{token_key}' must be string, got {type(token_val).__name__}")
    
    # Optional: isolationGroup (string)
    if "isolationGroup" in agent and agent["isolationGroup"] is not None:
        valid, err = validate_type(agent["isolationGroup"], str, f"{prefix}.isolationGroup")
        if not valid:
            errors.append(err)
    
    # Optional: isolation (string)
    if "isolation" in agent and agent["isolation"] is not None:
        valid, err = validate_type(agent["isolation"], str, f"{prefix}.isolation")
        if not valid:
            errors.append(err)
    
    # Optional: network (string)
    if "network" in agent and agent["network"] is not None:
        valid, err = validate_type(agent["network"], str, f"{prefix}.network")
        if not valid:
            errors.append(err)
    
    # Optional: capabilities (list of strings)
    if "capabilities" in agent:
        if not isinstance(agent["capabilities"], list):
            errors.append(f"'{prefix}.capabilities' must be array, got {type(agent['capabilities']).__name__}")
        else:
            for j, cap in enumerate(agent["capabilities"]):
                if not isinstance(cap, str):
                    errors.append(f"'{prefix}.capabilities[{j}]' must be string, got {type(cap).__name__}")
    
    # Optional: resources (dict)
    # Note: bool is subclass of int in Python, so explicitly exclude it
    if "resources" in agent:
        if not isinstance(agent["resources"], dict):
            errors.append(f"'{prefix}.resources' must be object, got {type(agent['resources']).__name__}")
        else:
            for res_key in ["memory", "cpu"]:
                if res_key in agent["resources"] and agent["resources"][res_key] is not None:
                    val = agent["resources"][res_key]
                    if isinstance(val, bool):
                        errors.append(f"'{prefix}.resources.{res_key}' must be string or number, got bool")
                    elif not isinstance(val, (str, int, float)):
                        errors.append(f"'{prefix}.resources.{res_key}' must be string or number, got {type(val).__name__}")
    
    return errors

# =============================================================================
# Main Script
# =============================================================================
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

# Validate schema before processing
validation_errors = validate_habitat_schema(hab)
if validation_errors:
    print("ERROR: Invalid habitat schema:", file=sys.stderr)
    for err in validation_errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

lib = {}
if lib_raw:
    try:
        lib = json.loads(d(lib_raw))
    except (json.JSONDecodeError, Exception):
        print("WARN: Failed to parse AGENT_LIB_B64, using empty library", file=sys.stderr)
    else:
        # Validate agent library is a dict
        if not isinstance(lib, dict):
            print(f"WARN: AGENT_LIB_B64 must be object, got {type(lib).__name__}. Using empty library.", file=sys.stderr)
            lib = {}

with open('/etc/habitat.json', 'w') as f:
    json.dump(hab, f, indent=2)
os.chmod('/etc/habitat.json', 0o600)

# Track deprecation warnings to emit at end
deprecation_warnings = []

# Helper: get platform config with v2/v1 fallback
def get_platform_config(hab, platform_name):
    """Get platform config: v2 (platforms.X) or v1 (X) format."""
    platforms = hab.get("platforms", {})
    if platform_name in platforms:
        return platforms[platform_name]
    # v1 fallback: top-level discord/telegram
    if platform_name in hab:
        deprecation_warnings.append(
            f"DEPRECATION: Top-level '{platform_name}' is v1 schema. "
            f"Use 'platforms.{platform_name}' instead. See issue #112."
        )
        return hab[platform_name]
    return {}

# Helper: normalize agent reference (string shorthand to dict)
def normalize_agent_ref(agent_ref):
    """Normalize agent reference to dict format.
    
    Converts string shorthand ("Claude") to dict format ({"agent": "Claude"}).
    Dict refs are returned unchanged.
    """
    if isinstance(agent_ref, str):
        return {"agent": agent_ref}
    return agent_ref

# Helper: get agent token with v2/v1 fallback
def get_agent_token(agent_ref, platform_name, agent_name=""):
    """Get agent token: v2 (tokens.X) or v1 (XBotToken) format.
    
    Returns empty string for missing or null tokens (never None).
    """
    tokens = agent_ref.get("tokens", {})
    if platform_name in tokens:
        # Normalize null to empty string to avoid "None" in env vars
        return tokens[platform_name] or ""
    # v1 fallback: discordBotToken, telegramBotToken, botToken
    if platform_name == "discord":
        if "discordBotToken" in agent_ref:
            deprecation_warnings.append(
                f"DEPRECATION: Agent '{agent_name}' uses 'discordBotToken' (v1 schema). "
                f"Use 'tokens.discord' instead. See issue #112."
            )
            return agent_ref["discordBotToken"]
    elif platform_name == "telegram":
        if "telegramBotToken" in agent_ref:
            deprecation_warnings.append(
                f"DEPRECATION: Agent '{agent_name}' uses 'telegramBotToken' (v1 schema). "
                f"Use 'tokens.telegram' instead. See issue #112."
            )
            return agent_ref["telegramBotToken"]
        if "botToken" in agent_ref:
            deprecation_warnings.append(
                f"DEPRECATION: Agent '{agent_name}' uses 'botToken' (v1 schema). "
                f"Use 'tokens.telegram' instead. See issue #112."
            )
            return agent_ref["botToken"]
    return ""

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

    # Discord config (v2: platforms.discord, v1: discord)
    discord_cfg = get_platform_config(hab, "discord")
    f.write('DISCORD_GUILD_ID="{}"\n'.format(discord_cfg.get("serverId", "")))
    f.write('DISCORD_GUILD_ID_B64="{}"\n'.format(b64(discord_cfg.get("serverId", ""))))
    f.write('DISCORD_OWNER_ID="{}"\n'.format(discord_cfg.get("ownerId", "")))
    f.write('DISCORD_OWNER_ID_B64="{}"\n'.format(b64(discord_cfg.get("ownerId", ""))))

    # Telegram config (v2: platforms.telegram, v1: telegram)
    telegram_cfg = get_platform_config(hab, "telegram")
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

    # API server bind address
    # Priority: 1. apiBindAddress (explicit override)
    #           2. remoteApi boolean (user-friendly flag)
    #           3. Default: 127.0.0.1 (secure-by-default)
    if "apiBindAddress" in hab:
        api_bind = hab["apiBindAddress"]
    elif hab.get("remoteApi", False):
        api_bind = "0.0.0.0"  # Remote access enabled
    else:
        api_bind = "127.0.0.1"  # Secure default
    f.write('API_BIND_ADDRESS="{}"\n'.format(api_bind))

    f.write('GLOBAL_IDENTITY_B64="{}"\n'.format(b64(hab.get("globalIdentity", ""))))
    f.write('GLOBAL_BOOT_B64="{}"\n'.format(b64(hab.get("globalBoot", ""))))
    f.write('GLOBAL_BOOTSTRAP_B64="{}"\n'.format(b64(hab.get("globalBootstrap", ""))))
    f.write('GLOBAL_SOUL_B64="{}"\n'.format(b64(hab.get("globalSoul", ""))))
    f.write('GLOBAL_AGENTS_B64="{}"\n'.format(b64(hab.get("globalAgents", ""))))
    f.write('GLOBAL_USER_B64="{}"\n'.format(b64(hab.get("globalUser", ""))))
    f.write('GLOBAL_TOOLS_B64="{}"\n'.format(b64(hab.get("globalTools", ""))))

    agents = hab.get("agents", [])
    f.write('AGENT_COUNT={}\n'.format(len(agents)))

    for i, raw_agent_ref in enumerate(agents):
        n = i + 1
        agent_ref = normalize_agent_ref(raw_agent_ref)
        name = agent_ref["agent"]
        lib_entry = lib.get(name, {})
        model = agent_ref.get("model") or lib_entry.get("model", "anthropic/claude-opus-4-5")
        identity = lib_entry.get("identity", "")
        soul = lib_entry.get("soul", "")
        agents_md = lib_entry.get("agents", "")
        boot = lib_entry.get("boot", "")
        bootstrap = lib_entry.get("bootstrap", "")
        user = lib_entry.get("user", "")

        # Get tokens (v2: tokens.X, v1: XBotToken)
        tg_bot_token = get_agent_token(agent_ref, "telegram", name)
        dc_bot_token = get_agent_token(agent_ref, "discord", name)

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

# Emit deprecation warnings
for warning in deprecation_warnings:
    print(warning, file=sys.stderr)

print("Parsed habitat '{}' with {} agents (platform: {})".format(hab['name'], len(agents), platform))
