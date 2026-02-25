# =============================================================================
# hatchery/agent:latest — Minimal OpenClaw runtime container
# =============================================================================
# Runs a single OpenClaw gateway instance. Host orchestrates everything else
# (config, health checks, safe mode, auth).
#
# Build:
#   docker build --build-arg BOT_UID=$(id -u bot) \
#     --build-arg OPENCLAW_VERSION=$(openclaw --version) \
#     -t hatchery/agent:latest .
#
# Run (compose manages this via generated docker-compose.yaml):
#   docker run --rm -e GROUP_PORT=18790 hatchery/agent:latest \
#     --bind loopback --port 18790
# =============================================================================
ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm-slim

ARG BOT_UID=1000
ARG BOT_GID=${BOT_UID}
ARG OPENCLAW_VERSION=latest

# System deps for OpenClaw + compose healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq bash ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# Create bot user matching host UID (bind mount permissions)
# node:*-slim images ship a 'node' user at UID 1000 — remove it first if it conflicts
RUN if id node >/dev/null 2>&1; then userdel -r node 2>/dev/null || true; fi \
    && groupadd -g ${BOT_GID} bot 2>/dev/null || true \
    && useradd -u ${BOT_UID} -g ${BOT_GID} -m -s /bin/bash bot

# Install OpenClaw globally
RUN npm install -g openclaw@${OPENCLAW_VERSION}

USER bot
WORKDIR /home/bot

ENV NODE_ENV=production
ENV NODE_OPTIONS=--experimental-sqlite

# Health check for compose --wait
# Shell form required: GROUP_PORT is a runtime env var, not a build arg
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
    CMD curl -sf http://127.0.0.1:${GROUP_PORT:-18790}/ || exit 1

ENTRYPOINT ["openclaw", "gateway"]
CMD ["--bind", "loopback", "--port", "18790"]
