#!/usr/bin/env bash
# Shows container health and whether Splunk Web / HEC respond.
set -uo pipefail
cd "$(dirname "$0")/.."

docker compose ps
echo
HEALTH=$(docker inspect -f '{{.State.Health.Status}}' splunk 2>/dev/null || echo "not running")
echo "Container health: ${HEALTH}"

if curl -fs -o /dev/null http://localhost:8000; then
  echo "Splunk Web (8000): UP"
else
  echo "Splunk Web (8000): not ready yet"
fi

if curl -fs -o /dev/null http://localhost:8088/services/collector/health; then
  echo "HEC (8088):        UP"
else
  echo "HEC (8088):        not ready yet"
fi

echo
docker volume ls --filter name=splunk-
