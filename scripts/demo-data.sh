#!/usr/bin/env bash
# Generates realistic demo data and sends it to Splunk via HEC (curl).
#
# Usage:
#   ./scripts/demo-data.sh            # backfill the last 24 hours (~5,000 events)
#   ./scripts/demo-data.sh live       # stream live traffic every second (Ctrl+C to stop)
#   ./scripts/demo-data.sh reset      # delete and recreate the demo index
#
# Data sources (all in index=demo):
#   sourcetype=api:access        API gateway access logs
#   sourcetype=integration:run   Integration flow executions (e.g. order sync to SAP)
#   sourcetype=business:order    Orders placed (revenue)
#   sourcetype=auth              Login attempts
#
# Stories hidden in the data (see README -> "Demo: seeing the value of Splunk"):
#   1. Outage 2-3 hours ago: POST/GET /orders fail with 503s; root cause is the
#      order-sync-to-SAP integration timing out. Revenue dips during the outage.
#   2. Security incident ~90 minutes ago: brute-force login against "admin" from
#      185.220.101.45, a successful login, then bulk download of /customers data.
#
# Env overrides: HEC_URL (default http://localhost:8088), DEMO_INDEX (default demo)
# All IPs, users and orders are synthetic.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

HEC_URL="${HEC_URL:-http://localhost:8088}"
MGMT_URL="${MGMT_URL:-https://localhost:8089}"
INDEX="${DEMO_INDEX:-demo}"
MODE="${1:-backfill}"
NOW=$(date +%s)

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
BATCH=0
TOTAL=0

# ---------------------------------------------------------------- reference data
ENDPOINTS=("GET /customers" "GET /products" "POST /orders" "GET /orders" "GET /inventory")
BASE_LAT=(80 40 150 90 60)                       # typical latency (ms) per endpoint
APPS=("mobile-app" "web-portal" "partner-acme" "partner-globex" "partner-initech")
REGIONS=("us-east" "us-west" "eu-west" "ap-south")
CLIENT_IPS=("8.8.8.8" "1.1.1.1" "81.2.69.142" "89.160.20.112" "175.16.199.1"
            "216.160.83.56" "2.125.160.216" "24.24.24.24" "202.196.224.1" "67.43.156.1")
USERS=("alice" "bob" "carol" "dave" "erin" "frank" "grace" "heidi" "svc-integration")
PRODUCTS=("Widget" "Gadget" "Gizmo" "Doohickey" "Sprocket")
ATTACKER_IP="185.220.101.45"

# ---------------------------------------------------------------- helpers
api() { curl -sk -u "admin:${SPLUNK_PASSWORD}" "$@"; }

SPLUNK_DB_DIR="/opt/splunk/var/lib/splunk"

# The index exists once its data directory does (no API auth needed to check).
# "main" lives in defaultdb rather than main/.
index_exists() {
  [ "$INDEX" = "main" ] && return 0
  docker exec splunk test -d "$SPLUNK_DB_DIR/$INDEX/db" 2>/dev/null
}

wait_healthy() {
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' splunk 2>/dev/null)" = "healthy" ] && \
      curl -fs -o /dev/null "$HEC_URL/services/collector/health" && return 0
    sleep 5
  done
  return 1
}

# Creates the index, trying (1) REST API, (2) Splunk CLI, (3) an indexes.conf
# app + restart. Stops the script if none work, so no events are sent into the void.
ensure_index() {
  index_exists && return 0
  echo "Creating index '$INDEX'..."

  local code
  code=$(api -o /dev/null -w "%{http_code}" "$MGMT_URL/services/data/indexes" -d name="$INDEX" || true)
  sleep 2
  if index_exists; then echo "Created index '$INDEX' (REST API)"; return 0; fi
  echo "  REST API returned HTTP $code - trying the Splunk CLI..."

  docker exec -u splunk splunk /opt/splunk/bin/splunk add index "$INDEX" \
    -auth "admin:${SPLUNK_PASSWORD}" >/dev/null 2>&1 || true
  sleep 2
  if index_exists; then echo "Created index '$INDEX' (CLI)"; return 0; fi
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
  if index_exists; then echo "Created index '$INDEX' (indexes.conf)"; return 0; fi

  echo "ERROR: couldn't create index '$INDEX'. Create it in Splunk Web (Settings -> Indexes -> New Index)" >&2
  echo "       or rerun with DEMO_INDEX=main. No events were sent." >&2
  exit 1
}

flush() {
  [ -s "$TMP" ] || return 0
  local resp
  resp=$(curl -s "$HEC_URL/services/collector/event" \
    -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" --data-binary @"$TMP")
  if ! grep -q '"code":0' <<<"$resp"; then
    echo "HEC error: $resp" >&2
    if grep -q 'Incorrect index' <<<"$resp"; then
      echo "Your HEC token isn't allowed to write to '$INDEX'. Either add it in" >&2
      echo "Settings -> Data Inputs -> HTTP Event Collector -> (token) -> Allowed indexes," >&2
      echo "or rerun with DEMO_INDEX=main and use index=main in the searches." >&2
    fi
    exit 1
  fi
  : > "$TMP"
  BATCH=0
}

# emit <epoch> <sourcetype> <json-event>
emit() {
  printf '{"time":%s,"index":"%s","sourcetype":"%s","source":"demo-data","host":"api-gw-01","event":%s}\n' \
    "$1" "$INDEX" "$2" "$3" >> "$TMP"
  BATCH=$((BATCH + 1)); TOTAL=$((TOTAL + 1))
  [ "$BATCH" -ge 500 ] && flush
  return 0
}

pick() { local -n arr=$1; REPLY=${arr[$((RANDOM % ${#arr[@]}))]}; }
rand_off() { REPLY=$(( (RANDOM * 32768 + RANDOM) % $1 )); }

# gen_api <epoch> <incident 0|1> [ip] [app] [endpoint-index]
gen_api() {
  local t=$1 incident=$2
  local i=${5:-$((RANDOM % ${#ENDPOINTS[@]}))}
  local ep=${ENDPOINTS[$i]} base=${BASE_LAT[$i]}
  local method=${ep%% *} path=${ep#* }
  local ip app region tid err="" status=200 r=$((RANDOM % 100))
  local latency=$((base + RANDOM % base)) bytes=$((500 + RANDOM % 20000))
  if [ -n "${3:-}" ]; then ip=$3; else pick CLIENT_IPS; ip=$REPLY; fi
  if [ -n "${4:-}" ]; then app=$4; else pick APPS; app=$REPLY; fi
  pick REGIONS; region=$REPLY
  printf -v tid '%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM

  if [ "$incident" = 1 ] && [ "$path" = "/orders" ]; then
    if [ $r -lt 70 ]; then
      status=503; latency=$((3000 + RANDOM % 5000)); bytes=120
      err=',"error":"Upstream timeout: order-sync-to-SAP"'
    else
      latency=$((latency * 4))
    fi
  else
    if   [ $r -lt 2 ]; then status=500; err=',"error":"Internal server error"'
    elif [ $r -lt 6 ]; then status=404; bytes=90
    elif [ $r -lt 8 ]; then status=401; bytes=60
    fi
  fi

  emit "$t" "api:access" "$(printf '{"method":"%s","path":"%s","status":%d,"latency_ms":%d,"bytes":%d,"client_app":"%s","client_ip":"%s","region":"%s","trace_id":"%s"%s}' \
    "$method" "$path" "$status" "$latency" "$bytes" "$app" "$ip" "$region" "$tid" "$err")"

  # Each order creation triggers an integration flow; successful ones become orders
  if [ "$method" = "POST" ] && [ "$path" = "/orders" ]; then
    if [ "$status" = 503 ]; then
      emit $((t + 1)) "integration:run" "$(printf '{"flow":"order-sync-to-SAP","target":"SAP S/4HANA","status":"failed","duration_ms":30000,"records":0,"trace_id":"%s","error":"SAP BAPI_SALESORDER_CREATE timeout after 30000ms"}' "$tid")"
    elif [ "$status" = 200 ]; then
      local amount product
      printf -v amount '%d.%02d' $((20 + RANDOM % 480)) $((RANDOM % 100))
      pick PRODUCTS; product=$REPLY
      emit $((t + 1)) "integration:run" "$(printf '{"flow":"order-sync-to-SAP","target":"SAP S/4HANA","status":"success","duration_ms":%d,"records":1,"trace_id":"%s"}' $((300 + RANDOM % 900)) "$tid")"
      emit $((t + 2)) "business:order" "$(printf '{"order_id":"ORD-%06d","amount":%s,"currency":"USD","product":"%s","region":"%s","client_app":"%s","trace_id":"%s"}' \
        $(( (RANDOM * 32768 + RANDOM) % 1000000 )) "$amount" "$product" "$region" "$app" "$tid")"
    fi
  fi
}

gen_auth() {  # gen_auth <epoch> <user> <result> <ip> [reason]
  local reason=""
  [ -n "${5:-}" ] && reason=",\"reason\":\"$5\""
  emit "$1" "auth" "$(printf '{"user":"%s","result":"%s","client_ip":"%s","method":"password","app":"admin-console"%s}' "$2" "$3" "$4" "$reason")"
}

# ---------------------------------------------------------------- modes
backfill() {
  echo "Generating 24 hours of demo data into index=$INDEX ..."

  # 1. API traffic (with the outage 2-3 hours ago)
  for ((n = 0; n < 3500; n++)); do
    rand_off 86400; local off=$REPLY
    local incident=0
    [ "$off" -ge 7200 ] && [ "$off" -le 10800 ] && incident=1
    gen_api $((NOW - off)) $incident
  done

  # 2. Scheduled integration flows every 15 minutes
  for ((off = 0; off < 86400; off += 900)); do
    emit $((NOW - off)) "integration:run" "$(printf '{"flow":"customer-sync-SFDC","target":"Salesforce","status":"success","duration_ms":%d,"records":%d}' $((2000 + RANDOM % 3000)) $((10 + RANDOM % 200)))"
  done

  # 3. Normal logins (~5% typos)
  for ((n = 0; n < 600; n++)); do
    rand_off 86400; local t=$((NOW - REPLY))
    pick USERS; local u=$REPLY
    pick CLIENT_IPS; local ip=$REPLY
    if [ $((RANDOM % 100)) -lt 5 ]; then gen_auth "$t" "$u" failure "$ip" bad_password
    else gen_auth "$t" "$u" success "$ip"; fi
  done

  # 4. Security incident ~90 minutes ago
  local start=$((NOW - 5400))
  for ((n = 0; n < 80; n++)); do                       # brute force / credential stuffing
    local u="admin"
    [ $((n % 4)) = 0 ] && { pick USERS; u=$REPLY; }
    gen_auth $((start + n * 3)) "$u" failure "$ATTACKER_IP" bad_password
  done
  gen_auth $((start + 245)) "admin" success "$ATTACKER_IP"   # ...and it works
  for ((n = 0; n < 40; n++)); do                       # bulk customer data download
    local t=$((start + 300 + n * 5))
    local tid; printf -v tid '%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM
    emit "$t" "api:access" "$(printf '{"method":"GET","path":"/customers","query":"page=%d&limit=5000","status":200,"latency_ms":%d,"bytes":%d,"client_app":"unknown","client_ip":"%s","region":"eu-west","trace_id":"%s"}' \
      "$n" $((900 + RANDOM % 600)) $((2000000 + RANDOM * 64)) "$ATTACKER_IP" "$tid")"
  done

  flush
  echo "Sent $TOTAL events to index=$INDEX."
  echo "Open Search & Reporting, set the time range to 'Last 24 hours', and try:  index=$INDEX | stats count by sourcetype"
}

live() {
  echo "Streaming live events to index=$INDEX (Ctrl+C to stop)."
  echo "Tip: in Search, pick a real-time window (e.g. '5 minute window') and run:"
  echo "  index=$INDEX sourcetype=api:access | timechart span=10s count by status"
  while true; do
    local t; t=$(date +%s)
    for ((n = 0; n < 5 + RANDOM % 10; n++)); do gen_api "$t" 0; done
    flush
    printf '\rEvents sent: %d' "$TOTAL"
    sleep 1
  done
}

reset() {
  read -r -p "Delete ALL data in index '$INDEX'? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  [ "$INDEX" = "main" ] && { echo "Refusing to wipe index 'main'."; exit 1; }
  # Stop Splunk, delete the index's data directory straight from the volume,
  # and start again - Splunk recreates it empty. No API credentials needed.
  echo "Stopping Splunk..."
  docker compose stop splunk >/dev/null
  docker run --rm -v splunk-var:/splunkvar alpine rm -rf "/splunkvar/lib/splunk/$INDEX"
  echo "Starting Splunk (1-2 min)..."
  docker compose start splunk >/dev/null
  wait_healthy || true
  ensure_index
  echo "Index '$INDEX' reset."
}

# ---------------------------------------------------------------- main
case "$MODE" in
  backfill) ensure_index; backfill ;;
  live)     ensure_index; live ;;
  reset)    reset ;;
  *) echo "Usage: $0 [backfill|live|reset]"; exit 1 ;;
esac
