#!/usr/bin/env bash
# Sends a test event to the HTTP Event Collector.
# Then search in Splunk Web:  index=main sourcetype=codespace:test
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

MSG="${1:-Hello from GitHub Codespaces}"
curl -s http://localhost:8088/services/collector/event \
  -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
  -d "{\"event\": {\"message\": \"${MSG}\", \"codespace\": \"${CODESPACE_NAME:-local}\"}, \"sourcetype\": \"codespace:test\", \"index\": \"main\"}"
echo
echo "Search for it with:  index=main sourcetype=codespace:test"
