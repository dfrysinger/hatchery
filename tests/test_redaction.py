#!/usr/bin/env python3
"""
Test suite for secret redaction functionality.
Implements AC1 and AC4 from TASK-10.
"""

import pytest
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

from redact_secrets import (
    redact_text,
    redact_api_keys,
    redact_tokens,
    redact_env_vars,
    redact_base64_credentials,
    load_redaction_config,
    is_allowlisted
)


class TestAPIKeyRedaction:
    """AC1: Test API key pattern redaction"""
    
    def test_openai_key_redaction(self):
        text = "Using OpenAI key: sk-proj-1234567890abcdef"
        result = redact_text(text)
        assert "sk-***REDACTED***" in result
        assert "1234567890abcdef" not in result
    
    def test_stripe_key_redaction(self):
        text = "Stripe key: pk_live_1234567890abcdef"
        result = redact_text(text)
        assert "pk_***REDACTED***" in result
        assert "1234567890abcdef" not in result
    
    def test_aws_key_redaction(self):
        text = "AWS key: AKIAIOSFODNN7EXAMPLE"
        result = redact_text(text)
        assert "AKIA***REDACTED***" in result
        assert "IOSFODNN7EXAMPLE" not in result
    
    def test_preserve_key_prefix(self):
        """Ensure first few chars are preserved for debugging"""
        text = "Key: sk-proj-abcd1234"
        result = redact_text(text)
        assert "sk-" in result or "sk-p" in result
        assert "abcd1234" not in result


class TestTokenRedaction:
    """AC1: Test token pattern redaction"""
    
    def test_github_token_redaction(self):
        text = "GitHub token: ghp_1234567890abcdefghijklmnop"
        result = redact_text(text)
        assert "ghp_***REDACTED***" in result
        assert "1234567890abcdefghijklmnop" not in result
    
    def test_github_oauth_token_redaction(self):
        text = "OAuth: gho_1234567890abcdefghijklmnop"
        result = redact_text(text)
        assert "gho_***REDACTED***" in result
        assert "1234567890abcdefghijklmnop" not in result
    
    def test_discord_bot_token_redaction(self):
        # Using pattern that matches Discord format but is clearly a test token
        # Format: [MN][23chars].[6chars].[27+chars] - using TEST markers
        text = "Bot token: MTEST0000000000000000000.TEST00.TEST000000000000000000000000000"
        result = redact_text(text)
        assert "***BOT-TOKEN-REDACTED***" in result or "***REDACTED***" in result
        assert "TEST00" not in result


class TestEnvVarRedaction:
    """AC1: Test environment variable redaction"""
    
    def test_api_key_env_var(self):
        text = "export OPENAI_API_KEY=sk-1234567890"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "sk-1234567890" not in result
    
    def test_token_env_var(self):
        text = "GITHUB_TOKEN=ghp_abcdef123456"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "ghp_abcdef123456" not in result
    
    def test_secret_env_var(self):
        text = "DATABASE_SECRET=mypassword123"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "mypassword123" not in result
    
    def test_password_env_var(self):
        text = "DB_PASSWORD=supersecret"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "supersecret" not in result


class TestBase64CredentialRedaction:
    """AC1: Test base64 credential redaction"""
    
    def test_basic_auth_header(self):
        text = "Authorization: Basic dXNlcm5hbWU6cGFzc3dvcmQ="
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "dXNlcm5hbWU6cGFzc3dvcmQ=" not in result
    
    def test_bearer_token(self):
        text = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" not in result


class TestEdgeCases:
    """AC4: Test edge cases"""
    
    def test_secret_at_start_of_string(self):
        text = "sk-1234567890 is the key"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "1234567890" not in result
    
    def test_secret_at_end_of_string(self):
        text = "The key is sk-1234567890"
        result = redact_text(text)
        assert "***REDACTED***" in result
        assert "1234567890" not in result
    
    def test_multiple_secrets_in_line(self):
        text = "API: sk-abc123 and TOKEN: ghp_def456"
        result = redact_text(text)
        assert result.count("***REDACTED***") >= 2
        assert "abc123" not in result
        assert "def456" not in result
    
    def test_legitimate_hex_not_redacted(self):
        """Git SHAs should not be redacted"""
        text = "Commit: a1b2c3d4e5f6789012345678901234567890abcd"
        result = redact_text(text)
        # Should NOT be redacted (40-char hex is a git SHA)
        assert "a1b2c3d4e5f6789012345678901234567890abcd" in result
    
    def test_uuid_not_redacted(self):
        """UUIDs should not be redacted"""
        text = "ID: 123e4567-e89b-12d3-a456-426614174000"
        result = redact_text(text)
        # Should NOT be redacted
        assert "123e4567-e89b-12d3-a456-426614174000" in result
    
    def test_empty_string(self):
        result = redact_text("")
        assert result == ""
    
    def test_none_value(self):
        result = redact_text(None)
        assert result is None or result == ""


class TestConfiguration:
    """AC3: Test configuration loading and allowlisting"""
    
    def test_load_config_from_file(self):
        """Config should load from ~/clawd/shared/redaction-config.json"""
        config = load_redaction_config()
        assert config is not None
        assert 'patterns' in config
        assert 'redaction_format' in config
        assert 'allowlist' in config
    
    def test_allowlist_pattern(self):
        """Allowlisted patterns should not be redacted"""
        # TEST_SAFE_TOKEN_\d+ is in the allowlist
        text = "Test pattern: TEST_SAFE_TOKEN_12345"
        result = is_allowlisted("TEST_SAFE_TOKEN_12345")
        assert result is True
        
        # Verify it's not redacted even though it could match token patterns
        result_text = redact_text(text)
        assert "TEST_SAFE_TOKEN_12345" in result_text
        assert "***REDACTED***" not in result_text
    
    def test_git_sha_allowlisted(self):
        """Git SHAs should be allowlisted (40 hex chars)"""
        git_sha = "a1b2c3d4e5f6789012345678901234567890abcd"
        result = is_allowlisted(git_sha)
        assert result is True
        
        # Should not be redacted in text
        text = f"Commit: {git_sha}"
        result_text = redact_text(text)
        assert git_sha in result_text
    
    def test_uuid_allowlisted(self):
        """UUIDs should be allowlisted"""
        uuid = "123e4567-e89b-12d3-a456-426614174000"
        result = is_allowlisted(uuid)
        assert result is True
        
        # Should not be redacted in text
        text = f"ID: {uuid}"
        result_text = redact_text(text)
        assert uuid in result_text
    
    def test_non_allowlisted_redacted(self):
        """Non-allowlisted patterns should be redacted"""
        # This is NOT in the allowlist and matches sk- pattern
        secret = "sk-1234567890abcdefghij1234567890abcdefghij12345678"
        result = is_allowlisted(secret)
        assert result is False
        
        # Should be redacted
        text = f"Secret: {secret}"
        result_text = redact_text(text)
        assert secret not in result_text
        assert "***REDACTED***" in result_text


class TestIntegration:
    """AC4: Integration tests"""
    
    def test_console_log_redaction(self):
        """Test that console.log output is redacted"""
        # This would test actual logging redaction
        # For now, just test the redaction function works
        secret = "sk-1234567890abcdef"
        log_message = f"API Key: {secret}"
        redacted = redact_text(log_message)
        assert secret not in redacted
        assert "***REDACTED***" in redacted
    
    def test_discord_message_redaction(self):
        """Test that Discord messages are redacted"""
        message = "Sending token: ghp_secrettoken123"
        redacted = redact_text(message)
        assert "ghp_secrettoken123" not in redacted
        assert "***REDACTED***" in redacted
    
    def test_report_content_redaction(self):
        """Test that report files have secrets redacted"""
        report_content = """
        # Report
        Using API key: sk-test123456
        Status: Success
        """
        redacted = redact_text(report_content)
        assert "sk-test123456" not in redacted
        assert "***REDACTED***" in redacted


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
