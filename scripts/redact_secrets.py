#!/usr/bin/env python3
"""
Secret redaction module for OpenClaw/Hatchery.
Redacts API keys, tokens, passwords, and other sensitive data from logs, messages, and reports.

Implements TASK-10: Secret redaction in logs and reports
"""

import re
import json
import os
import threading
from typing import Optional, Dict, List, Pattern


# Default redaction patterns
# Each pattern should have a 'regex' and optionally a 'format' for the replacement
DEFAULT_PATTERNS = [
    # OpenAI keys (match sk-proj- first, then generic sk-)
    # Word boundaries prevent false positives like "mask-abc123"
    {
        'name': 'openai_project_key',
        'regex': r'\b(sk-proj-[a-zA-Z0-9]{20,})\b',
        'format': 'sk-***REDACTED***'
    },
    {
        'name': 'openai_key',
        'regex': r'\b(sk-[a-zA-Z0-9]{20,})\b',
        'format': 'sk-***REDACTED***'
    },
    # Stripe keys
    {
        'name': 'stripe_publishable',
        'regex': r'pk_(live|test)_[a-zA-Z0-9]{10,}',
        'format': 'pk_***REDACTED***'
    },
    {
        'name': 'stripe_secret',
        'regex': r'sk_(live|test)_[a-zA-Z0-9]{10,}',
        'format': 'sk_***REDACTED***'
    },
    # AWS keys
    {
        'name': 'aws_access_key',
        'regex': r'AKIA[0-9A-Z]{16}',
        'format': 'AKIA***REDACTED***'
    },
    # GitHub tokens (more lenient for test data)
    {
        'name': 'github_pat',
        'regex': r'ghp_[a-zA-Z0-9]{6,}',
        'format': 'ghp_***REDACTED***'
    },
    {
        'name': 'github_oauth',
        'regex': r'gho_[a-zA-Z0-9]{6,}',
        'format': 'gho_***REDACTED***'
    },
    {
        'name': 'github_app',
        'regex': r'(ghu|ghs)_[a-zA-Z0-9]{6,}',
        'format': r'\1_***REDACTED***'
    },
    # Discord bot tokens
    {
        'name': 'discord_bot_token',
        'regex': r'[MN][A-Za-z\d]{23}\.[\w-]{6}\.[\w-]{27,}',
        'format': '***BOT-TOKEN-REDACTED***'
    },
    # Environment variables with secrets
    # Word boundaries and length limits prevent false positives
    {
        'name': 'env_var_key',
        'regex': r'\b([A-Z_]{3,50}_(API_KEY|KEY))\s*=\s*[\'"]?([a-zA-Z0-9_\-\.]{3,100})[\'"]?',
        'format': r'\1=***REDACTED***'
    },
    {
        'name': 'env_var_token',
        'regex': r'\b([A-Z_]{3,50}_TOKEN)\s*=\s*[\'"]?([a-zA-Z0-9_\-\.]{3,100})[\'"]?',
        'format': r'\1=***REDACTED***'
    },
    {
        'name': 'env_var_secret',
        'regex': r'\b([A-Z_]{3,50}_SECRET)\s*=\s*[\'"]?([a-zA-Z0-9_\-\.]{3,100})[\'"]?',
        'format': r'\1=***REDACTED***'
    },
    {
        'name': 'env_var_password',
        'regex': r'\b([A-Z_]{3,50}_PASSWORD)\s*=\s*[\'"]?([a-zA-Z0-9_\-\.]{3,100})[\'"]?',
        'format': r'\1=***REDACTED***'
    },
    # Authorization headers
    {
        'name': 'basic_auth',
        'regex': r'Authorization:\s*Basic\s+[A-Za-z0-9+/]+=*',
        'format': 'Authorization: Basic ***REDACTED***'
    },
    {
        'name': 'bearer_token',
        'regex': r'Authorization:\s*Bearer\s+[A-Za-z0-9\-._~+/]+=*',
        'format': 'Authorization: Bearer ***REDACTED***'
    },
]

# Patterns that should NOT be redacted
DEFAULT_ALLOWLIST = [
    r'^[0-9a-f]{40}$',  # Git SHA (40 hex chars)
    r'^[0-9a-f]{64}$',  # SHA-256 hash
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',  # UUID
    r'^TEST_SAFE_TOKEN_\d+$',  # Test tokens
]

# Global config cache with TTL
_config_cache: Optional[Dict] = None
_config_loaded_at: float = 0
CONFIG_TTL_SECONDS = 300  # 5 minutes

# Compiled regex patterns cache
_compiled_patterns: Optional[List] = None

# Thread safety lock for config loading
_config_lock = threading.Lock()


def invalidate_config_cache():
    """Manually invalidate config cache. Useful for testing or config hot-reload."""
    global _config_cache, _config_loaded_at, _compiled_patterns
    _config_cache = None
    _config_loaded_at = 0
    _compiled_patterns = None


def load_redaction_config(config_path: Optional[str] = None) -> Dict:
    """
    Load redaction configuration from file with TTL-based caching.
    Thread-safe using double-checked locking pattern.
    
    Args:
        config_path: Optional path to config file. Defaults to ~/clawd/shared/redaction-config.json
    
    Returns:
        Dictionary with 'patterns', 'redaction_format', and 'allowlist' keys
    """
    global _config_cache, _config_loaded_at, _compiled_patterns
    import time
    
    now = time.time()
    
    # Fast path: Check if cache is valid (exists and not expired) - no lock needed
    if _config_cache is not None and (now - _config_loaded_at) < CONFIG_TTL_SECONDS:
        return _config_cache
    
    # Slow path: Acquire lock to load/reload config
    with _config_lock:
        # Double-check after acquiring lock (another thread may have loaded it)
        if _config_cache is not None and (now - _config_loaded_at) < CONFIG_TTL_SECONDS:
            return _config_cache
        
        # Cache expired or doesn't exist - invalidate compiled patterns too
        _compiled_patterns = None
    
    if config_path is None:
        config_path = os.path.expanduser('~/clawd/shared/redaction-config.json')
    
    if os.path.exists(config_path):
        try:
            with open(config_path, 'r') as f:
                config = json.load(f)
                _config_cache = config
                _config_loaded_at = now
                return config
        except Exception as e:
            print(f"Warning: Failed to load config from {config_path}: {e}")
    
    # Return default config if file doesn't exist or fails to load
    default_config = {
        'patterns': DEFAULT_PATTERNS,
        'redaction_format': '***REDACTED***',
        'allowlist': DEFAULT_ALLOWLIST
    }
    _config_cache = default_config
    _config_loaded_at = now
    return default_config


def _compile_patterns(config: Dict) -> List:
    """
    Pre-compile regex patterns for performance.
    
    Args:
        config: Configuration dictionary with patterns
    
    Returns:
        List of tuples: (compiled_pattern, replacement_format)
    """
    patterns = config.get('patterns', DEFAULT_PATTERNS)
    compiled = []
    
    for pattern_def in patterns:
        try:
            regex_str = pattern_def['regex']
            replacement = pattern_def.get('format', '***REDACTED***')
            compiled_pattern = re.compile(regex_str, re.IGNORECASE)
            compiled.append((compiled_pattern, replacement))
        except re.error as e:
            print(f"Warning: Failed to compile pattern {pattern_def.get('name', 'unknown')}: {e}")
            continue
    
    return compiled


def is_allowlisted(text: str, config: Optional[Dict] = None) -> bool:
    """
    Check if a string matches any allowlist pattern.
    
    Args:
        text: String to check
        config: Optional config dict. Will load from default location if not provided.
    
    Returns:
        True if text matches any allowlist pattern, False otherwise
    """
    if config is None:
        config = load_redaction_config()
    
    allowlist = config.get('allowlist', DEFAULT_ALLOWLIST)
    
    for pattern in allowlist:
        if re.match(pattern, text.strip()):
            return True
    
    return False


def redact_api_keys(text: str, config: Optional[Dict] = None) -> str:
    """Redact API keys from text."""
    if config is None:
        config = load_redaction_config()
    
    patterns = config.get('patterns', DEFAULT_PATTERNS)
    api_key_patterns = [p for p in patterns if 'key' in p['name'].lower()]
    
    for pattern_def in api_key_patterns:
        pattern = pattern_def['regex']
        replacement = pattern_def.get('format', '***REDACTED***')
        text = re.sub(pattern, replacement, text)
    
    return text


def redact_tokens(text: str, config: Optional[Dict] = None) -> str:
    """Redact tokens from text."""
    if config is None:
        config = load_redaction_config()
    
    patterns = config.get('patterns', DEFAULT_PATTERNS)
    token_patterns = [p for p in patterns if 'token' in p['name'].lower()]
    
    for pattern_def in token_patterns:
        pattern = pattern_def['regex']
        replacement = pattern_def.get('format', '***REDACTED***')
        text = re.sub(pattern, replacement, text)
    
    return text


def redact_env_vars(text: str, config: Optional[Dict] = None) -> str:
    """Redact environment variables with sensitive suffixes."""
    if config is None:
        config = load_redaction_config()
    
    patterns = config.get('patterns', DEFAULT_PATTERNS)
    env_patterns = [p for p in patterns if 'env_var' in p['name'].lower()]
    
    for pattern_def in env_patterns:
        pattern = pattern_def['regex']
        replacement = pattern_def.get('format', '***REDACTED***')
        text = re.sub(pattern, replacement, text)
    
    return text


def redact_base64_credentials(text: str, config: Optional[Dict] = None) -> str:
    """Redact base64-encoded credentials (Basic auth, Bearer tokens, etc.)."""
    if config is None:
        config = load_redaction_config()
    
    patterns = config.get('patterns', DEFAULT_PATTERNS)
    auth_patterns = [p for p in patterns if 'auth' in p['name'].lower() or 'bearer' in p['name'].lower()]
    
    for pattern_def in auth_patterns:
        pattern = pattern_def['regex']
        replacement = pattern_def.get('format', '***REDACTED***')
        text = re.sub(pattern, replacement, text)
    
    return text


def redact_text(text: Optional[str], config: Optional[Dict] = None) -> Optional[str]:
    """
    Main redaction function. Applies all redaction patterns to input text.
    Uses pre-compiled regex patterns for performance.
    Respects allowlist to prevent redacting legitimate patterns (Git SHAs, UUIDs, etc.)
    
    Args:
        text: Text to redact
        config: Optional config dict. Will load from default location if not provided.
    
    Returns:
        Redacted text, or None/empty string if input was None/empty
    """
    global _compiled_patterns
    
    if text is None:
        return None
    
    if text == "":
        return ""
    
    if config is None:
        config = load_redaction_config()
    
    # Compile patterns if not cached
    if _compiled_patterns is None:
        _compiled_patterns = _compile_patterns(config)
    
    # Apply all compiled patterns with allowlist checking
    for compiled_pattern, replacement in _compiled_patterns:
        # Find all matches first
        matches = list(compiled_pattern.finditer(text))
        
        # Process matches in reverse order to preserve string indices
        for match in reversed(matches):
            matched_text = match.group(0)
            
            # Check allowlist before redacting
            if not is_allowlisted(matched_text, config):
                # Replace this specific match
                text = text[:match.start()] + replacement + text[match.end():]
    
    return text


def redact_file(input_path: str, output_path: Optional[str] = None, config: Optional[Dict] = None) -> None:
    """
    Redact secrets from a file.
    
    Args:
        input_path: Path to input file
        output_path: Path to output file. If None, overwrites input file.
        config: Optional config dict.
    """
    with open(input_path, 'r') as f:
        content = f.read()
    
    redacted = redact_text(content, config)
    
    output = output_path or input_path
    with open(output, 'w') as f:
        f.write(redacted)


def redact_discord_message(message: str, config: Optional[Dict] = None) -> str:
    """
    Pre-send hook for Discord messages.
    Applies redaction before message is sent.
    """
    return redact_text(message, config) or ""


def redact_report(report_content: str, config: Optional[Dict] = None) -> str:
    """
    Hook for report generation.
    Applies redaction to report content before writing.
    """
    return redact_text(report_content, config) or ""


if __name__ == '__main__':
    # CLI interface for testing
    import sys
    
    if len(sys.argv) > 1:
        text = ' '.join(sys.argv[1:])
        print(redact_text(text))
    else:
        print("Usage: redact_secrets.py <text>")
        print("Example: redact_secrets.py 'My API key is sk-1234567890'")
