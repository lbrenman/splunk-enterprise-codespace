#!/usr/bin/env bash
# Replaces the HEC token with a new random one - in .env AND in the running
# Splunk - then proves the new token works and the old one doesn't.
# Use it if your token is the placeholder (all zeros) or may have leaked.
# Any app sending to HEC must switch to the new token (./scripts/hec-info.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

OLD="$SPLUNK_HEC_TOKEN"
NEW="$(cat /proc/sys/kernel/random/uuid)"

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' splunk 2>/dev/null)" = "healthy" ] && \
      curl -fs -o /dev/null http://localhost:8088/services/collector/health && return 0
    sleep 5
  done
  return 1
}

test_token() {  # prints the HEC response for a tiny test event
  curl -s http://localhost:8088/services/collector/event -H "Authorization: Splunk $1" \
    -d '{"index":"main","sourcetype":"hec:token-test","event":"token rotation check"}'
}

echo "Rotating HEC token..."

# 1. Swap the token in Splunk's own config (wherever it's defined)
docker exec -u root splunk sh -c '
  for f in $(grep -rl "$1" /opt/splunk/etc/apps/*/local/inputs.conf /opt/splunk/etc/system/local/inputs.conf 2>/dev/null); do
    sed -i "s/$1/$2/g" "$f"; echo "  updated $f"
  done' _ "$OLD" "$NEW"

# 2. Update .env, then recreate the container so it also gets the new value
sed -i "s|^SPLUNK_HEC_TOKEN=.*|SPLUNK_HEC_TOKEN=${NEW}|" .env
echo "  updated .env"
echo "Restarting Splunk with the new token (1-2 min)..."
docker compose up -d --force-recreate splunk >/dev/null
wait_healthy || { echo "ERROR: Splunk didn't come back healthy - check ./scripts/logs.sh"; exit 1; }

# 3. Prove it
NEW_RESULT=$(test_token "$NEW")
OLD_RESULT=$(test_token "$OLD")
echo "  new token: $NEW_RESULT"
echo "  old token: $OLD_RESULT"
if printf '%s' "$NEW_RESULT" | grep -q '"code":0' && ! printf '%s' "$OLD_RESULT" | grep -q '"code":0'; then
  echo "Done. New token is active and the old one is rejected."
  echo "Get the new export lines with:  ./scripts/hec-info.sh"
else
  echo "WARNING: rotation didn't fully take effect. Paste the output above for help." >&2
  exit 1
fi
