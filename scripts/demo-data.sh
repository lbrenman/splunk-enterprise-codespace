#!/usr/bin/env bash
# In-Codespace helper around scripts/app-emulator.sh.
# (To send data from OUTSIDE the Codespace, run app-emulator.sh directly - see README.)
#
# Usage:
#   ./scripts/demo-data.sh init       # create the demo index (start.sh runs this automatically)
#   ./scripts/demo-data.sh            # backfill 24h of history, then verify it's searchable
#   ./scripts/demo-data.sh live       # stream live traffic (Ctrl+C to stop)
#   ./scripts/demo-data.sh outage     # inject a 3-minute outage now
#   ./scripts/demo-data.sh attack     # run the security incident now
#   ./scripts/demo-data.sh reset      # wipe the demo index and start over
#
# Env overrides: DEMO_INDEX (default demo)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

INDEX="${DEMO_INDEX:-demo}"
MODE="${1:-backfill}"
MGMT_URL="https://localhost:8089"
SPLUNK_DB_DIR="/opt/splunk/var/lib/splunk"

# REST calls run inside the container: the Free license rejects management API
# calls that don't come from localhost (they return 401).
api() { docker exec splunk sh -c 'curl -sk -u "admin:$SPLUNK_PASSWORD" "$@"' _ "$@"; }

# True if Splunk knows the index: asks the REST API (from inside the container),
# falling back to checking for its data directory as root. (The container's
# default user can't read Splunk's data folders, so the check must run as root.)
index_exists() {
  [ "$INDEX" = "main" ] && return 0
  local code
  code=$(api -o /dev/null -w "%{http_code}" "$MGMT_URL/services/data/indexes/$INDEX" 2>/dev/null || true)
  [ "$code" = "200" ] && return 0
  docker exec -u root splunk test -d "$SPLUNK_DB_DIR/$INDEX/db" 2>/dev/null
}

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' splunk 2>/dev/null)" = "healthy" ] && \
      curl -fs -o /dev/null http://localhost:8088/services/collector/health && return 0
    sleep 5
  done
  return 1
}

# Creates the index via (1) REST API, (2) Splunk CLI, (3) indexes.conf + restart.
ensure_index() {
  index_exists && { echo "Index '$INDEX' exists."; return 0; }
  echo "Creating index '$INDEX'..."
  local code
  code=$(api -o /dev/null -w "%{http_code}" "$MGMT_URL/services/data/indexes" -d name="$INDEX" || true)
  sleep 2
  if index_exists; then echo "Created index '$INDEX'."; return 0; fi
  echo "  REST API returned HTTP $code - trying the Splunk CLI..."

  docker exec -u splunk splunk sh -c \
    '/opt/splunk/bin/splunk add index "$1" -auth "admin:$SPLUNK_PASSWORD"' _ "$INDEX" >/dev/null 2>&1 || true
  sleep 2
  if index_exists; then echo "Created index '$INDEX' (CLI)."; return 0; fi
  echo "  CLI didn't work either - adding indexes.conf and restarting Splunk (1-2 min)..."

  docker exec -i -u root splunk bash -c \
    "mkdir -p /opt/splunk/etc/apps/demo_index/local && cat > /opt/splunk/etc/apps/demo_index/local/indexes.conf && chown -R splunk:splunk /opt/splunk/etc/apps/demo_index" <<EOF
[$INDEX]
homePath   = \$SPLUNK_DB/$INDEX/db
coldPath   = \$SPLUNK_DB/$INDEX/colddb
thawedPath = \$SPLUNK_DB/$INDEX/thaweddb
EOF
  docker compose restart splunk >/dev/null
  wait_healthy || true
  if index_exists; then echo "Created index '$INDEX' (indexes.conf)."; return 0; fi

  echo "ERROR: couldn't create index '$INDEX'. Create it in Splunk Web" >&2
  echo "       (Settings -> Indexes -> New Index) or use DEMO_INDEX=main." >&2
  exit 1
}

# HEC says "Success" even if Splunk later drops events, so search to confirm.
verify() {
  echo "Verifying the data is searchable..."
  local count=""
  for _ in $(seq 1 12); do
    sleep 5
    count=$(api "$MGMT_URL/services/search/jobs/export" \
      -d search="| tstats count where index=$INDEX" -d output_mode=csv 2>/dev/null | tail -n 1 | tr -dc '0-9')
    [ -n "$count" ] && [ "$count" -gt 0 ] && break
  done
  if [ -n "$count" ] && [ "$count" -gt 0 ]; then
    echo "OK: $count events searchable in index=$INDEX."
    echo "Next: Splunk Web -> Search & Reporting, time range 'Last 24 hours':  index=$INDEX | stats count by sourcetype"
  else
    echo "WARNING: couldn't confirm the events are searchable (count='${count:-unknown}')." >&2
    echo "Check in Splunk Web:  index=$INDEX | stats count by sourcetype   (time range: All time)" >&2
  fi
}

emulate() {
  HEC_URL=http://localhost:8088 HEC_TOKEN="$SPLUNK_HEC_TOKEN" INDEX="$INDEX" \
    bash scripts/app-emulator.sh "$1"
}

reset() {
  [ "$INDEX" = "main" ] && { echo "Refusing to wipe index 'main'."; exit 1; }
  read -r -p "Delete ALL data in index '$INDEX'? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  echo "Stopping Splunk..."
  docker compose stop splunk >/dev/null
  docker run --rm -v splunk-var:/splunkvar alpine rm -rf "/splunkvar/lib/splunk/$INDEX"
  echo "Starting Splunk (1-2 min)..."
  docker compose start splunk >/dev/null
  wait_healthy || true
  ensure_index
  echo "Index '$INDEX' reset."
}

case "$MODE" in
  init)                  ensure_index ;;
  backfill)              ensure_index; emulate backfill; verify ;;
  live|outage|attack)    ensure_index; emulate "$MODE" ;;
  reset)                 reset ;;
  *) echo "Usage: $0 [init|backfill|live|outage|attack|reset]"; exit 1 ;;
esac
