#!/usr/bin/env python3
"""
Tests for workspace sync/restore functionality.

TDD-style tests: Write tests first, then implement to make them pass.
These tests verify that sync-openclaw-state.sh and restore-openclaw-state.sh
handle all workspace files, not just memory and transcripts.
"""
import os
import re
import pytest

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')

# Workspace files that must be synced per-agent
WORKSPACE_FILES = [
    'AGENTS.md',
    'BOOT.md', 
    'BOOTSTRAP.md',
    'IDENTITY.md',
    'SOUL.md',
    'USER.md',
]

# Shared files that must be synced (not per-agent)
SHARED_FILES = [
    'TOOLS.md',
    'HEARTBEAT.md',
]


def read_script(name):
    """Read a script file from the scripts directory."""
    path = os.path.join(SCRIPTS_DIR, name)
    with open(path, 'r') as f:
        return f.read()


class TestSyncWorkspaceFiles:
    """Tests for sync-openclaw-state.sh workspace file handling."""

    def test_sync_defines_workspace_files_list(self):
        """Sync script should define a list of workspace files to sync."""
        content = read_script('sync-openclaw-state.sh')
        # Should have a variable or loop that includes workspace files
        assert 'AGENTS.md' in content, "Sync must include AGENTS.md"
        assert 'SOUL.md' in content, "Sync must include SOUL.md"
        assert 'IDENTITY.md' in content, "Sync must include IDENTITY.md"

    def test_sync_includes_all_workspace_files(self):
        """Sync script should sync all required workspace files."""
        content = read_script('sync-openclaw-state.sh')
        for wf in WORKSPACE_FILES:
            assert wf in content, f"Sync must include {wf}"

    def test_sync_includes_shared_files(self):
        """Sync script should sync shared workspace files."""
        content = read_script('sync-openclaw-state.sh')
        for sf in SHARED_FILES:
            assert sf in content, f"Sync must include shared file {sf}"

    def test_sync_includes_shared_directory(self):
        """Sync script should sync the shared directory."""
        content = read_script('sync-openclaw-state.sh')
        # Should reference the shared directory for sync
        assert re.search(r'shared[/"]?\s', content) or 'shared/' in content, \
            "Sync must include shared directory"

    def test_sync_skips_symlinks(self):
        """Sync script should skip symlinks to avoid duplicating shared files."""
        content = read_script('sync-openclaw-state.sh')
        # Should check for symlinks with -L test
        assert '-L ' in content or '-h ' in content, \
            "Sync should check for symlinks to skip them"

    def test_sync_iterates_agents(self):
        """Sync script should iterate over all agents."""
        content = read_script('sync-openclaw-state.sh')
        # Should loop through agents using AGENT_COUNT
        assert 'seq 1 $AC' in content or 'seq 1 "$AC"' in content, \
            "Sync must iterate through agents using AGENT_COUNT"

    def test_sync_preserves_memory_sync(self):
        """Sync script should still sync memory directories (no regression)."""
        content = read_script('sync-openclaw-state.sh')
        assert '/memory' in content, "Sync must still include memory directories"

    def test_sync_preserves_transcript_sync(self):
        """Sync script should still sync session transcripts (no regression)."""
        content = read_script('sync-openclaw-state.sh')
        assert '.jsonl' in content, "Sync must still include session transcripts"


class TestRestoreWorkspaceFiles:
    """Tests for restore-openclaw-state.sh workspace file handling."""

    def test_restore_defines_workspace_files_list(self):
        """Restore script should define a list of workspace files to restore."""
        content = read_script('restore-openclaw-state.sh')
        assert 'AGENTS.md' in content, "Restore must include AGENTS.md"
        assert 'SOUL.md' in content, "Restore must include SOUL.md"
        assert 'IDENTITY.md' in content, "Restore must include IDENTITY.md"

    def test_restore_includes_all_workspace_files(self):
        """Restore script should restore all required workspace files."""
        content = read_script('restore-openclaw-state.sh')
        for wf in WORKSPACE_FILES:
            assert wf in content, f"Restore must include {wf}"

    def test_restore_includes_shared_files(self):
        """Restore script should restore shared workspace files."""
        content = read_script('restore-openclaw-state.sh')
        for sf in SHARED_FILES:
            assert sf in content, f"Restore must include shared file {sf}"

    def test_restore_includes_shared_directory(self):
        """Restore script should restore the shared directory."""
        content = read_script('restore-openclaw-state.sh')
        assert re.search(r'shared[/"]?\s', content) or 'shared/' in content, \
            "Restore must include shared directory"

    def test_restore_iterates_agents(self):
        """Restore script should iterate over all agents."""
        content = read_script('restore-openclaw-state.sh')
        assert 'seq 1 $AC' in content or 'seq 1 "$AC"' in content, \
            "Restore must iterate through agents using AGENT_COUNT"

    def test_restore_preserves_memory_restore(self):
        """Restore script should still restore memory directories (no regression)."""
        content = read_script('restore-openclaw-state.sh')
        assert '/memory' in content, "Restore must still include memory directories"

    def test_restore_preserves_transcript_restore(self):
        """Restore script should still restore session transcripts (no regression)."""
        content = read_script('restore-openclaw-state.sh')
        assert '.jsonl' in content, "Restore must still include session transcripts"

    def test_restore_sets_ownership(self):
        """Restore script should set correct file ownership."""
        content = read_script('restore-openclaw-state.sh')
        assert 'chown' in content, "Restore must set file ownership"


# NOTE: TestYamlInlineScripts removed - with slim YAML approach, sync/restore
# scripts are in scripts/ directory (tested above), not embedded in hatch.yaml.


class TestDropboxPriority:
    """Tests for Dropbox workspace files taking priority over config regeneration."""

    def test_restore_sets_dropbox_marker(self):
        """Restore script should create a marker file when workspace files are restored."""
        content = read_script('restore-openclaw-state.sh')
        assert 'dropbox-workspace-restored' in content, \
            "Restore must create dropbox-workspace-restored marker"

    def test_restore_marker_conditional_on_workspace_count(self):
        """Marker should only be set when workspace files were actually restored (WC > 0)."""
        content = read_script('restore-openclaw-state.sh')
        # Should check WC before setting marker
        assert re.search(r'\$WC.*-gt\s*0', content), \
            "Marker should only be set when workspace file count > 0"

    def test_build_config_checks_dropbox_marker(self):
        """build-full-config.sh should check for the Dropbox restore marker."""
        content = read_script('build-full-config.sh')
        assert 'dropbox-workspace-restored' in content, \
            "build-full-config.sh must check for dropbox-workspace-restored marker"

    def test_build_config_skips_workspace_when_marker_present(self):
        """build-full-config.sh should skip workspace file generation when marker exists."""
        content = read_script('build-full-config.sh')
        assert 'SKIP_WORKSPACE_FILES' in content, \
            "build-full-config.sh must use SKIP_WORKSPACE_FILES flag"
        # Should have a conditional around workspace file writes
        assert re.search(r'SKIP_WORKSPACE_FILES.*true', content), \
            "build-full-config.sh must check SKIP_WORKSPACE_FILES flag"

    def test_build_config_removes_marker_after_check(self):
        """build-full-config.sh should consume (remove) the marker file after checking it."""
        content = read_script('build-full-config.sh')
        assert 'rm -f /var/lib/init-status/dropbox-workspace-restored' in content, \
            "build-full-config.sh must remove marker after consuming it"

    def test_build_config_still_creates_symlinks(self):
        """build-full-config.sh should still create symlinks even when skipping workspace files."""
        content = read_script('build-full-config.sh')
        # Symlinks (TOOLS.md, HEARTBEAT.md, shared/) should be outside the skip block
        # The fi closing SKIP_WORKSPACE_FILES should come before the ln -sf lines
        lines = content.split('\n')
        fi_line = None
        ln_line = None
        for idx, line in enumerate(lines):
            if 'end SKIP_WORKSPACE_FILES' in line:
                fi_line = idx
            if fi_line and 'ln -sf' in line and 'TOOLS.md' in line:
                ln_line = idx
                break
        assert fi_line is not None and ln_line is not None and ln_line > fi_line, \
            "Symlinks must be created outside the SKIP_WORKSPACE_FILES conditional"

    def test_apply_config_clears_dropbox_marker(self):
        """apply-config.sh should clear the Dropbox marker so API uploads always regenerate."""
        content = read_script('apply-config.sh')
        assert 'dropbox-workspace-restored' in content, \
            "apply-config.sh must reference the dropbox-workspace-restored marker"
        assert 'rm -f /var/lib/init-status/dropbox-workspace-restored' in content, \
            "apply-config.sh must remove the marker before running build-full-config.sh"

    def test_apply_config_clears_marker_before_build(self):
        """apply-config.sh should clear marker BEFORE calling build-full-config.sh."""
        content = read_script('apply-config.sh')
        rm_pos = content.find('rm -f /var/lib/init-status/dropbox-workspace-restored')
        # Find the actual execution of build-full-config.sh (not header comments)
        build_pos = content.find('/usr/local/sbin/build-full-config.sh')
        assert rm_pos != -1, "apply-config.sh must have rm command for marker"
        assert build_pos != -1, "apply-config.sh must call build-full-config.sh"
        assert rm_pos < build_pos, \
            "Marker removal must happen before build-full-config.sh is called"

    def test_build_config_skips_tools_when_marker_present(self):
        """build-full-config.sh should also skip global TOOLS.md when preserving Dropbox files."""
        content = read_script('build-full-config.sh')
        assert re.search(r'SKIP_WORKSPACE_FILES.*true.*TOOLS', content, re.DOTALL), \
            "Global TOOLS.md generation should also check SKIP_WORKSPACE_FILES"


class TestSafetyChecks:
    """Tests for safety features in sync/restore."""

    def test_sync_has_path_validation(self):
        """Sync script should use rclone-validate.sh for path safety."""
        content = read_script('sync-openclaw-state.sh')
        assert 'rclone-validate' in content, \
            "Sync must source rclone-validate.sh for path safety"

    def test_restore_has_path_validation(self):
        """Restore script should use rclone-validate.sh for path safety."""
        content = read_script('restore-openclaw-state.sh')
        assert 'rclone-validate' in content, \
            "Restore must source rclone-validate.sh for path safety"

    def test_sync_handles_missing_files(self):
        """Sync script should handle missing files gracefully."""
        content = read_script('sync-openclaw-state.sh')
        # Should check if file exists before syncing
        assert '[ -f ' in content or '[ -e ' in content or 'if [' in content, \
            "Sync must check if files exist before syncing"

    def test_restore_handles_missing_backups(self):
        """Restore script should handle missing backups gracefully."""
        content = read_script('restore-openclaw-state.sh')
        # Should have error handling (|| true or similar)
        assert '|| true' in content or '|| {' in content, \
            "Restore must handle missing backups gracefully"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
