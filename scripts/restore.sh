#!/usr/bin/env bash
# Restores Splunk volumes from a backup tarball.
# Usage: ./scripts/restore.sh backups/splunk-backup-YYYYMMDD-HHMMSS.tar.gz
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: $0 backups/<file>.tar.gz"
  ls -1 backups/*.tar.gz 2>/dev/null || true
  exit 1
fi

read -r -p "This REPLACES current Splunk data with ${FILE}. Continue? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

docker compose down
docker volume create splunk-etc >/dev/null
docker volume create splunk-var >/dev/null

DIR=$(cd "$(dirname "$FILE")" && pwd)
NAME=$(basename "$FILE")
docker run --rm \
  -v splunk-etc:/data/etc \
  -v splunk-var:/data/var \
  -v "${DIR}:/backup:ro" \
  alpine sh -c "rm -rf /data/etc/* /data/var/* && tar xzf /backup/${NAME} -C /data"

docker compose up -d
echo "Restore complete. Splunk is restarting."
