#!/usr/bin/env bash
# Makes Splunk Web work behind the Codespaces port-forwarding proxy.
#
# Without this, Splunk Web redirects the browser to http://localhost:8000/...
# because the forwarder presents requests as coming to localhost:8000.
# This writes a small app (codespace_proxy) with a web.conf that tells Splunk
# Web (CherryPy) its public base URL, then restarts Splunk if the config changed.
#
# Safe to run repeatedly. Runs automatically from start.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${CODESPACE_NAME:-}" ]; then
  echo "Not running in a Codespace - proxy config not needed."
  exit 0
fi

DOMAIN="${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
BASE_URL="https://${CODESPACE_NAME}-8000.${DOMAIN}"
APP_DIR="/opt/splunk/etc/apps/codespace_proxy"

echo "Waiting for Splunk to become healthy..."
for i in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' splunk 2>/dev/null)" = "healthy" ] && break
  sleep 5
done

CURRENT=$(docker exec splunk sh -c "cat ${APP_DIR}/local/web.conf 2>/dev/null" || true)
DESIRED="[settings]
tools.proxy.on = true
tools.proxy.base = ${BASE_URL}"

if [ "$CURRENT" = "$DESIRED" ]; then
  echo "Proxy config already set for ${BASE_URL}"
  exit 0
fi

echo "Configuring Splunk Web for ${BASE_URL}"
docker exec -u root splunk bash -c "
  mkdir -p ${APP_DIR}/local ${APP_DIR}/default
  printf '[install]\nstate = enabled\n\n[ui]\nis_visible = false\nlabel = Codespace Proxy\n' > ${APP_DIR}/default/app.conf
  printf '%s\n' '[settings]' 'tools.proxy.on = true' 'tools.proxy.base = ${BASE_URL}' > ${APP_DIR}/local/web.conf
  chown -R splunk:splunk ${APP_DIR}
"

echo "Restarting Splunk to apply (about 1-2 minutes)..."
docker compose restart splunk
for i in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' splunk 2>/dev/null)" = "healthy" ] && break
  sleep 5
done

echo "Done. Open: ${BASE_URL}"
echo "Redirect check:"
curl -s -o /dev/null -w '  / -> %{redirect_url}\n' http://localhost:8000/ || true
