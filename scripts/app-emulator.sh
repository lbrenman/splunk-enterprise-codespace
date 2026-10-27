#!/usr/bin/env bash
# =============================================================================
# app-emulator.sh - emulates an API-driven business app sending telemetry to
# Splunk over HTTP Event Collector (HEC). Run it from ANYWHERE (your laptop,
# another server, inside the Codespace) - it only needs bash + curl.
#
# Usage:
#   export HEC_URL=https://<codespace-name>-8088.app.github.dev
#   export HEC_TOKEN=<SPLUNK_HEC_TOKEN from the Codespace's .env>
#
#   ./app-emulator.sh live        # stream live traffic (default). Ctrl+C to stop
#   ./app-emulator.sh outage      # run a 3-minute /orders outage NOW (use in a 2nd terminal)
#   ./app-emulator.sh attack      # run a brute-force + data-theft attack NOW (2nd terminal)
#   ./app-emulator.sh backfill    # send 24h of history incl. a past outage and attack
#
# Optional env:
#   INDEX=demo   Splunk index (the Codespace creates "demo" on start; "main" always exists)
#   RATE=5       average API calls per second in live mode
#
# What it sends (all synthetic):
#   sourcetype=api:access        API gateway access logs
#   sourcetype=integration:run   integration flow runs (order sync to SAP, Salesforce sync)
#   sourcetype=business:order    orders placed (revenue)
#   sourcetype=auth              admin console login attempts
#
# Compatible with macOS's default bash 3.2.
# =============================================================================
set -euo pipefail

HEC_URL="${HEC_URL:-}"
HEC_TOKEN="${HEC_TOKEN:-}"
INDEX="${INDEX:-demo}"
RATE="${RATE:-5}"
MODE="${1:-live}"

usage() {
  sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$MODE" = "-h" ] || [ "$MODE" = "--help" ] && usage
[ -n "$HEC_URL" ] && [ -n "$HEC_TOKEN" ] || { echo "Set HEC_URL and HEC_TOKEN first."; echo; usage; }
HEC_URL="${HEC_URL%/}"
EVENT_URL="$HEC_URL/services/collector/event"

TMP=$(mktemp "${TMPDIR:-/tmp}/hec.XXXXXX")
trap 'rm -f "$TMP"; echo' EXIT
BATCH=0
TOTAL=0

# ----------------------------------------------------------------- reference data
ENDPOINTS=("GET /customers" "GET /products" "POST /orders" "GET /orders" "GET /inventory")
BASE_LAT=(80 40 150 90 60)
APPS=("mobile-app" "web-portal" "partner-acme" "partner-globex" "partner-initech")
REGIONS=("us-east" "us-west" "eu-west" "ap-south")
CLIENT_IPS=("8.8.8.8" "1.1.1.1" "81.2.69.142" "89.160.20.112" "175.16.199.1"
            "216.160.83.56" "2.125.160.216" "24.24.24.24" "202.196.224.1" "67.43.156.1")
USERS=("alice" "bob" "carol" "dave" "erin" "frank" "grace" "heidi" "svc-integration")
PRODUCTS=("Widget" "Gadget" "Gizmo" "Doohickey" "Sprocket")
ATTACKER_IP="185.220.101.45"

# ----------------------------------------------------------------- helpers
pick() { eval "REPLY=\${$1[\$((RANDOM % \${#$1[@]}))]}"; }
rand_big() { REPLY=$(( (RANDOM * 32768 + RANDOM) % $1 )); }
new_trace() { printf -v REPLY '%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM; }

check_hec() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$HEC_URL/services/collector/health" || true)
  case "$code" in
    200) ;;
    000) die "Can't reach $HEC_URL. Is the Codespace running? Is the URL right?" ;;
    401|403|302|307)
         die "Got HTTP $code from $HEC_URL - port 8088 is probably Private.
       In the Codespace: PORTS tab -> right-click 8088 -> Port Visibility -> Public" ;;
    *)   die "Unexpected HTTP $code from $HEC_URL/services/collector/health" ;;
  esac
}

flush() {
  [ -s "$TMP" ] || return 0
  local resp
  resp=$(curl -s "$EVENT_URL" -H "Authorization: Splunk $HEC_TOKEN" \
    -H "Content-Type: application/json" --data-binary @"$TMP" || true)
  if ! printf '%s' "$resp" | grep -q '"code":0'; then
    echo >&2
    echo "HEC rejected the batch: ${resp:-<no response>}" >&2
    printf '%s' "$resp" | grep -q 'Invalid token' && \
      echo "-> Check HEC_TOKEN (cat .env in the Codespace)." >&2
    printf '%s' "$resp" | grep -q 'Incorrect index' && \
      echo "-> The token can't write to index '$INDEX'. Try INDEX=main." >&2
    exit 1
  fi
  : > "$TMP"
  BATCH=0
}

# emit <epoch> <sourcetype> <host> <json-event>
emit() {
  printf '{"time":%s,"index":"%s","sourcetype":"%s","source":"app-emulator","host":"%s","event":%s}\n' \
    "$1" "$INDEX" "$2" "$3" "$4" >> "$TMP"
  BATCH=$((BATCH + 1)); TOTAL=$((TOTAL + 1))
  [ "$BATCH" -ge 500 ] && flush
  return 0
}

# gen_api <epoch> <outage 0|1> [endpoint-index]
gen_api() {
  local t=$1 outage=$2
  local i=${3:-$((RANDOM % ${#ENDPOINTS[@]}))}
  local ep=${ENDPOINTS[$i]} base=${BASE_LAT[$i]}
  local method=${ep%% *} path=${ep#* }
  local ip app region tid err="" status=200 r=$((RANDOM % 100))
  local latency=$((base + RANDOM % base)) bytes=$((500 + RANDOM % 20000))
  pick CLIENT_IPS; ip=$REPLY
  pick APPS; app=$REPLY
  pick REGIONS; region=$REPLY
  new_trace; tid=$REPLY

  if [ "$outage" = 1 ] && [ "$path" = "/orders" ]; then
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

  emit "$t" "api:access" "api-gw-01" "$(printf '{"method":"%s","path":"%s","status":%d,"latency_ms":%d,"bytes":%d,"client_app":"%s","client_ip":"%s","region":"%s","trace_id":"%s"%s}' \
    "$method" "$path" "$status" "$latency" "$bytes" "$app" "$ip" "$region" "$tid" "$err")"

  # Order creation triggers the SAP sync flow; successful ones become revenue
  if [ "$method" = "POST" ] && [ "$path" = "/orders" ]; then
    if [ "$status" = 503 ]; then
      emit $((t + 1)) "integration:run" "ipaas-01" "$(printf '{"flow":"order-sync-to-SAP","target":"SAP S/4HANA","status":"failed","duration_ms":30000,"records":0,"trace_id":"%s","error":"SAP BAPI_SALESORDER_CREATE timeout after 30000ms"}' "$tid")"
    elif [ "$status" = 200 ]; then
      local amount product
      printf -v amount '%d.%02d' $((20 + RANDOM % 480)) $((RANDOM % 100))
      pick PRODUCTS; product=$REPLY
      rand_big 1000000
      emit $((t + 1)) "integration:run" "ipaas-01" "$(printf '{"flow":"order-sync-to-SAP","target":"SAP S/4HANA","status":"success","duration_ms":%d,"records":1,"trace_id":"%s"}' $((300 + RANDOM % 900)) "$tid")"
      emit $((t + 2)) "business:order" "orders-svc" "$(printf '{"order_id":"ORD-%06d","amount":%s,"currency":"USD","product":"%s","region":"%s","client_app":"%s","trace_id":"%s"}' \
        "$REPLY" "$amount" "$product" "$region" "$app" "$tid")"
    fi
  fi
}

# gen_auth <epoch> <user> <success|failure> <ip>
gen_auth() {
  local reason=""
  [ "$3" = "failure" ] && reason=',"reason":"bad_password"'
  emit "$1" "auth" "admin-console" "$(printf '{"user":"%s","result":"%s","client_ip":"%s","method":"password","app":"admin-console"%s}' "$2" "$3" "$4" "$reason")"
}

gen_normal_login() {
  local u ip
  pick USERS; u=$REPLY
  pick CLIENT_IPS; ip=$REPLY
  if [ $((RANDOM % 100)) -lt 5 ]; then gen_auth "$1" "$u" failure "$ip"
  else gen_auth "$1" "$u" success "$ip"; fi
}

gen_sfdc_sync() {
  emit "$1" "integration:run" "ipaas-01" "$(printf '{"flow":"customer-sync-SFDC","target":"Salesforce","status":"success","duration_ms":%d,"records":%d}' $((2000 + RANDOM % 3000)) $((10 + RANDOM % 200)))"
}

# gen_exfil <epoch> <page>
gen_exfil() {
  new_trace
  emit "$1" "api:access" "api-gw-01" "$(printf '{"method":"GET","path":"/customers","query":"page=%d&limit=5000","status":200,"latency_ms":%d,"bytes":%d,"client_app":"unknown","client_ip":"%s","region":"eu-west","trace_id":"%s"}' \
    "$2" $((900 + RANDOM % 600)) $((2000000 + RANDOM * 64)) "$ATTACKER_IP" "$REPLY")"
}

status_line() { printf '\r%-60s' "$1 | events sent: $TOTAL"; }

# ----------------------------------------------------------------- modes
mode_live() {
  echo "Streaming live app traffic to $HEC_URL (index=$INDEX, ~$RATE API calls/sec). Ctrl+C to stop."
  echo "Tip: in another terminal run '$0 outage' or '$0 attack' to inject an incident."
  local tick=0 t n
  while true; do
    t=$(date +%s)
    n=$(( RATE / 2 + RANDOM % (RATE + 1) ))
    for ((k = 0; k < n; k++)); do gen_api "$t" 0; done
    [ $((RANDOM % 10)) -eq 0 ] && gen_normal_login "$t"
    [ $((tick % 60)) -eq 0 ] && gen_sfdc_sync "$t"
    flush
    status_line "live"
    tick=$((tick + 1))
    sleep 1
  done
}

mode_outage() {
  local secs=180 end t
  echo "Injecting a ${secs}s outage on /orders (order-sync-to-SAP timing out)..."
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    t=$(date +%s)
    for ((k = 0; k < RATE; k++)); do gen_api "$t" 1 $(( RANDOM % 2 == 0 ? 2 : 3 )); done
    flush
    status_line "outage: $(( end - t ))s left"
    sleep 1
  done
  echo; echo "Outage over. In Splunk: index=$INDEX sourcetype=api:access status>=500 earliest=-15m | timechart span=10s count by path"
}

mode_attack() {
  echo "Running attack from $ATTACKER_IP: brute force -> successful login -> bulk /customers download..."
  local u
  for ((n = 0; n < 60; n++)); do
    u="admin"; [ $((n % 4)) -eq 0 ] && { pick USERS; u=$REPLY; }
    gen_auth "$(date +%s)" "$u" failure "$ATTACKER_IP"
    flush; status_line "brute force: attempt $((n + 1))/60"
    sleep 0.5
  done
  gen_auth "$(date +%s)" "admin" success "$ATTACKER_IP"; flush
  status_line "login SUCCEEDED as admin"; sleep 2
  for ((n = 0; n < 40; n++)); do
    gen_exfil "$(date +%s)" "$n"; flush
    status_line "downloading customers: page $((n + 1))/40"
    sleep 1
  done
  echo; echo "Attack done. In Splunk: index=$INDEX client_ip=$ATTACKER_IP earliest=-15m | table _time sourcetype user result path bytes"
}

mode_backfill() {
  local now off t start
  now=$(date +%s)
  echo "Sending 24 hours of history to $HEC_URL (index=$INDEX)..."
  for ((n = 0; n < 3500; n++)); do            # API traffic; outage 2-3 hours ago
    rand_big 86400; off=$REPLY
    if [ "$off" -ge 7200 ] && [ "$off" -le 10800 ]; then gen_api $((now - off)) 1; else gen_api $((now - off)) 0; fi
    [ $((n % 250)) -eq 0 ] && status_line "backfill"
  done
  for ((off = 0; off < 86400; off += 900)); do gen_sfdc_sync $((now - off)); done
  for ((n = 0; n < 600; n++)); do rand_big 86400; gen_normal_login $((now - REPLY)); done
  start=$((now - 5400))                         # attack ~90 minutes ago
  for ((n = 0; n < 80; n++)); do
    local u="admin"; [ $((n % 4)) -eq 0 ] && { pick USERS; u=$REPLY; }
    gen_auth $((start + n * 3)) "$u" failure "$ATTACKER_IP"
  done
  gen_auth $((start + 245)) "admin" success "$ATTACKER_IP"
  for ((n = 0; n < 40; n++)); do gen_exfil $((start + 300 + n * 5)) "$n"; done
  flush
  status_line "backfill done"; echo
  echo "In Splunk (time range: Last 24 hours):  index=$INDEX | stats count by sourcetype"
}

# ----------------------------------------------------------------- main
check_hec
case "$MODE" in
  live)     mode_live ;;
  outage)   mode_outage ;;
  attack)   mode_attack ;;
  backfill) mode_backfill ;;
  *)        usage ;;
esac
