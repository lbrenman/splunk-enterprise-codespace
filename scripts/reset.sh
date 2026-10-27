#!/usr/bin/env bash
# DESTROYS all Splunk data and config, then starts fresh.
set -euo pipefail
cd "$(dirname "$0")/.."
read -r -p "Delete ALL Splunk data (volumes splunk-etc, splunk-var)? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
docker compose down -v
docker compose up -d
echo "Splunk reset. Fresh instance starting."
