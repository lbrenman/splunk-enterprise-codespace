#!/usr/bin/env bash
# Stops Splunk. Data is kept in the Docker volumes.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down
echo "Splunk stopped. Data preserved in volumes splunk-etc and splunk-var."
