#!/usr/bin/env bash
# Follows the Splunk container logs (Ctrl+C to exit).
cd "$(dirname "$0")/.."
docker compose logs -f --tail=200 splunk
