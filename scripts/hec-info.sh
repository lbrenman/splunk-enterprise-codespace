#!/usr/bin/env bash
# Prints the public HEC URL and token, ready to paste into a terminal OUTSIDE
# the Codespace (your laptop, another server) to send data to Splunk.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

if [ -n "${CODESPACE_NAME:-}" ]; then
  URL="https://${CODESPACE_NAME}-8088.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
else
  URL="http://localhost:8088"
fi

cat <<EOF
# ---- Paste into a terminal outside the Codespace ----
export HEC_URL=$URL
export HEC_TOKEN=$SPLUNK_HEC_TOKEN

# Check HEC is reachable (expect: {"text":"HEC is healthy","code":17})
curl -s \$HEC_URL/services/collector/health; echo

# Send one event
curl -s \$HEC_URL/services/collector/event -H "Authorization: Splunk \$HEC_TOKEN" \\
  -d '{"index":"demo","sourcetype":"api:access","event":{"method":"GET","path":"/hello","status":200,"latency_ms":42,"client_app":"my-laptop"}}'; echo

# Get the app emulator and stream traffic
curl -sO https://raw.githubusercontent.com/lbrenman/splunk-enterprise-codespace/main/scripts/app-emulator.sh
chmod +x app-emulator.sh
./app-emulator.sh live
# ------------------------------------------------------
EOF

if [ -n "${CODESPACE_NAME:-}" ]; then
  VIS=$(gh codespace ports -c "$CODESPACE_NAME" --json sourcePort,visibility \
        -q '.[] | select(.sourcePort==8088) | .visibility' 2>/dev/null || true)
  [ -n "$VIS" ] && [ "$VIS" != "public" ] && \
    echo "NOTE: port 8088 is '$VIS'. Make it Public: PORTS tab -> right-click 8088 -> Port Visibility -> Public"
fi
true
