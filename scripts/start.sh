#!/usr/bin/env bash
# Starts Splunk (postStartCommand runs this on every Codespace start).
set -euo pipefail
cd "$(dirname "$0")/.."

# Log everything to splunk-start.log too (postStartCommand output isn't shown
# in the terminal). View it with:  cat splunk-start.log
exec > >(tee splunk-start.log) 2>&1
echo "start.sh: $(date)"

[ -f .env ] || bash scripts/setup.sh

# Wait for the Docker daemon (docker-in-docker can take a while on a fresh Codespace)
echo "Waiting for Docker..."
for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker isn't running. Try: ./scripts/start.sh"; exit 1; }

docker compose up -d

# Make Splunk Web redirects use the Codespace URL instead of localhost
# (also waits until Splunk is healthy)
bash scripts/configure-proxy.sh

# Create the demo index so external apps can send to index=demo
bash scripts/demo-data.sh init || echo "Warning: couldn't create the demo index (see README)."

# Make HEC (8088) reachable from outside the Codespace.
# The HEC token protects it. Splunk Web (8000) stays Private.
if [ -n "${CODESPACE_NAME:-}" ]; then
  if gh codespace ports visibility 8088:public -c "$CODESPACE_NAME" >/dev/null 2>&1; then
    echo "Port 8088 (HEC) is Public."
  else
    echo "Couldn't make port 8088 Public automatically."
    echo "  -> PORTS tab -> right-click 8088 -> Port Visibility -> Public"
  fi
fi

echo
echo "Splunk is running."
if [ -n "${CODESPACE_NAME:-}" ]; then
  echo "Splunk Web: https://${CODESPACE_NAME}-8000.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
else
  echo "Splunk Web: http://localhost:8000"
fi
echo "To send data from outside the Codespace:  ./scripts/hec-info.sh"
