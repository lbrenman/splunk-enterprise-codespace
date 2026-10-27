#!/usr/bin/env bash
# Runs once when the Codespace is created (postCreateCommand).
# Creates .env with a random admin password and HEC token if it doesn't exist.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  cp .env.example .env
  PASS="Splunk-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
  TOKEN="$(cat /proc/sys/kernel/random/uuid)"
  sed -i "s|^SPLUNK_PASSWORD=.*|SPLUNK_PASSWORD=${PASS}|" .env
  sed -i "s|^SPLUNK_HEC_TOKEN=.*|SPLUNK_HEC_TOKEN=${TOKEN}|" .env
  echo "Created .env with a generated admin password and HEC token."
else
  echo ".env already exists - leaving it alone."
fi

chmod +x scripts/*.sh

echo "Pulling Splunk image (this can take a few minutes)..."
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker compose pull

echo
echo "Setup complete. Credentials are in .env  (cat .env)"
