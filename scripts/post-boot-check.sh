#!/bin/bash
# =============================================================================
# post-boot-check.sh -- DEPRECATED
# =============================================================================
# This script is no longer needed in the simplified architecture.
# Config is applied directly by build-full-config.sh during phase 2.
# Health check runs via ExecStartPost in openclaw.service.
#
# Kept for backwards compatibility - does nothing.
# =============================================================================

LOG="/var/log/post-boot-check.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) post-boot-check.sh is deprecated - skipping" >> "$LOG"
exit 0
