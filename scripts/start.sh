#!/usr/bin/env bash
# Starts Splunk (postStartCommand runs this on every Codespace start).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || bash scripts/setup.sh

# Wait for the Docker daemon (docker-in-docker can take a few seconds)
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

docker compose up -d

echo
echo "Splunk is starting. First boot takes ~2-4 minutes; restarts ~1 minute."
echo "Check progress with:  ./scripts/status.sh   or   ./scripts/logs.sh"
if [ -n "${CODESPACE_NAME:-}" ]; then
  echo "Splunk Web: https://${CODESPACE_NAME}-8000.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
else
  echo "Splunk Web: http://localhost:8000"
fi
