#!/usr/bin/env bash
# Runs once when the Codespace is created (postCreateCommand).
# Creates .env with a random admin password and HEC token if it doesn't exist.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  # Generate the secrets BEFORE writing .env, so a failure can never leave the
  # placeholder values behind. (No "tr </dev/urandom | head" - with pipefail,
  # tr gets SIGPIPE and the script aborts.)
  PASS="Splunk-$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')"
  TOKEN="$(cat /proc/sys/kernel/random/uuid)"
  sed -e "s|^SPLUNK_PASSWORD=.*|SPLUNK_PASSWORD=${PASS}|" \
      -e "s|^SPLUNK_HEC_TOKEN=.*|SPLUNK_HEC_TOKEN=${TOKEN}|" \
      .env.example > .env.tmp
  mv .env.tmp .env
  echo "Created .env with a generated admin password and HEC token."
else
  echo ".env already exists - leaving it alone."
  grep -q '^SPLUNK_HEC_TOKEN=00000000-0000-0000-0000-000000000000' .env && \
    echo "WARNING: .env has the placeholder HEC token. Run ./scripts/rotate-hec-token.sh"
fi

chmod +x scripts/*.sh

echo "Pulling Splunk image (this can take a few minutes)..."
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker compose pull

echo
echo "Setup complete. Credentials are in .env  (cat .env)"
