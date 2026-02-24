#!/bin/bash
# =============================================================================
# install-docker.sh — Install Docker and build hatchery/agent image
# =============================================================================
# Called by provision.sh Stage 5 when container isolation is configured.
# Installs Docker from official apt repo (not curl|sh), configures log rotation,
# adds bot user to docker group, and builds the base agent image.
#
# Inputs:
#   USERNAME          — system user to add to docker group
#   ISOLATION_DEFAULT — checked for "container" (also checks per-agent settings)
#   ISOLATION_GROUPS  — groups to check for container isolation
#   AGENT_COUNT       — number of agents (for per-agent isolation check)
#
# Env:
#   CONTAINER_IMAGE   — image tag (default: hatchery/agent:latest)
#   DOCKERFILE_PATH   — path to Dockerfile (default: /opt/hatchery/Dockerfile)
#   DRY_RUN           — if set, skip actual install
#   SKIP_DOCKER_BUILD — if set, skip image build (install only)
# =============================================================================
set -euo pipefail
umask 022

SVC_USER="${USERNAME:-bot}"
IMAGE="${CONTAINER_IMAGE:-hatchery/agent:latest}"
DOCKERFILE="${DOCKERFILE_PATH:-/opt/hatchery/Dockerfile}"

# --- Check if Docker is needed ---
needs_docker() {
    # Explicit container default
    [ "${ISOLATION_DEFAULT:-none}" = "container" ] && return 0

    # Any agent explicitly set to container mode
    local i
    for i in $(seq 1 "${AGENT_COUNT:-0}"); do
        local iso_var="AGENT${i}_ISOLATION"
        [ "${!iso_var:-}" = "container" ] && return 0
    done

    return 1
}

if ! needs_docker; then
    echo "No container isolation configured — skipping Docker install."
    exit 0
fi

if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN: Would install Docker and build ${IMAGE}"
    exit 0
fi

echo "Installing Docker for container isolation..."

# --- Install Docker from official apt repo ---
# Per AGENTS.md: no curl|sh, use official repo with signed key
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck disable=SC1091
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin

# --- Add bot user to docker group ---
usermod -aG docker "$SVC_USER"

# --- Configure Docker log rotation ---
# Prevents unbounded log growth on ephemeral droplets
cat > /etc/docker/daemon.json <<'DAEMON'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    }
}
DAEMON

# --- Enable and start Docker ---
systemctl enable docker
systemctl restart docker

echo "Docker installed and configured."

# --- Build base image ---
if [ -n "${SKIP_DOCKER_BUILD:-}" ]; then
    echo "SKIP_DOCKER_BUILD set — skipping image build."
    exit 0
fi

if [ ! -f "$DOCKERFILE" ]; then
    echo "WARNING: Dockerfile not found at ${DOCKERFILE} — skipping build." >&2
    echo "Image must be pulled or built manually: docker build -t ${IMAGE} ..."
    exit 0
fi

echo "Building ${IMAGE}..."

# Get bot UID for bind mount permissions
BOT_UID=$(id -u "$SVC_USER" 2>/dev/null || echo 1000)

# Get installed OpenClaw version for pinning
OC_VERSION=$(openclaw --version 2>/dev/null || echo "latest")

docker build \
    --build-arg "BOT_UID=${BOT_UID}" \
    --build-arg "OPENCLAW_VERSION=${OC_VERSION}" \
    -t "$IMAGE" \
    -f "$DOCKERFILE" \
    "$(dirname "$DOCKERFILE")"

echo "Image ${IMAGE} built successfully."
docker images "$IMAGE" --format "{{.Repository}}:{{.Tag}} — {{.Size}}"
