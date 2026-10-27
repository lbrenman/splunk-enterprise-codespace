#!/usr/bin/env bash
# Backs up the Splunk volumes to ./backups/splunk-backup-<timestamp>.tar.gz
# Download the file (right-click in the Explorer -> Download) to keep it
# beyond the life of this Codespace.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p backups
STAMP=$(date +%Y%m%d-%H%M%S)
FILE="splunk-backup-${STAMP}.tar.gz"

WAS_RUNNING=false
if docker ps --format '{{.Names}}' | grep -q '^splunk$'; then
  WAS_RUNNING=true
  echo "Stopping Splunk for a consistent backup..."
  docker compose stop splunk
fi

docker run --rm \
  -v splunk-etc:/data/etc:ro \
  -v splunk-var:/data/var:ro \
  -v "$(pwd)/backups:/backup" \
  alpine tar czf "/backup/${FILE}" -C /data etc var

$WAS_RUNNING && docker compose start splunk
echo "Backup written to backups/${FILE}"
ls -lh "backups/${FILE}"
