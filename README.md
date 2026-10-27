# Splunk Enterprise (Free) in GitHub Codespaces

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/lbrenman/splunk-enterprise-codespace?quickstart=1)

Run a fully working **Splunk Enterprise** instance (official `splunk/splunk` Docker image, **Splunk Free license**) inside a GitHub Codespace with **persistent data**, an HTTP Event Collector (HEC) ready to receive events, and helper scripts for start/stop/backup/restore.

Great for demos, learning SPL, testing log forwarding from integrations (e.g. sending events from an iPaaS flow to HEC), and building dashboards — without installing anything locally.

---

## Quick start

1. Click **Open in GitHub Codespaces** above (a 4-core / 16 GB machine is requested automatically).
2. Wait for the Codespace to build. `scripts/setup.sh` runs once and:
   - creates `.env` from `.env.example`
   - generates a random **admin password** and **HEC token**
   - pulls the Splunk image
3. `scripts/start.sh` runs on every start and launches Splunk with `docker compose up -d`.
4. First boot takes **~2–4 minutes**. Check with:
   ```bash
   ./scripts/status.sh
   ```
5. Open the **PORTS** tab and click the globe next to **Splunk Web (8000)**.

### Credentials

```bash
cat .env
```

- **Username:** `admin`
- **Password:** value of `SPLUNK_PASSWORD`
- **HEC token:** value of `SPLUNK_HEC_TOKEN`

> **Splunk Free has no login screen.** Splunk Web opens directly as admin. The password is only used for the CLI and REST API *from inside the container* (see [From the terminal](#from-the-terminal-rest-api)). It **can't be changed** on the Free license ("Requires license feature='Auth'"). Keep port 8000 **Private** (the Codespaces default); see [Security](#security).

---

## What's in the repo

```
.
├── .devcontainer/
│   └── devcontainer.json   # Ubuntu + docker-in-docker, port forwarding, 4-core host
├── scripts/
│   ├── setup.sh            # one-time: create .env, generate secrets, pull image
│   ├── start.sh            # start Splunk (runs on every Codespace start)
│   ├── configure-proxy.sh  # fix Splunk Web redirects behind the Codespaces proxy
│   ├── stop.sh             # stop Splunk, keep data
│   ├── status.sh           # health, Web/HEC reachability, volumes
│   ├── logs.sh             # follow container logs
│   ├── test-hec.sh         # send a test event to HEC
│   ├── hec-info.sh         # print the public HEC URL + token for sending from outside
│   ├── app-emulator.sh     # portable app emulator (bash + curl) - run it from your laptop
│   ├── demo-data.sh        # in-Codespace wrapper: create demo index, run emulator, verify, reset
│   ├── backup.sh           # tar.gz backup of all Splunk data to ./backups
│   ├── restore.sh          # restore from a backup
│   └── reset.sh            # wipe everything and start fresh
├── docker-compose.yml      # Splunk service + named volumes
├── .env.example            # config template (copied to .env, which is gitignored)
├── .gitignore
└── README.md
```

---

## Ports

| Port | Purpose | Notes |
|------|---------|-------|
| 8000 | Splunk Web | HTTP inside the container; Codespaces adds HTTPS on the forwarded URL |
| 8088 | HTTP Event Collector | HTTP (set `SPLUNK_HEC_SSL=true` for HTTPS) |
| 8089 | Management / REST API | HTTPS, self-signed cert |
| 9997 | Forwarder receiving | For Universal Forwarders (not auto-forwarded) |

Forwarded URLs look like `https://<codespace-name>-8000.app.github.dev`.

---

## Persistence

Splunk's state lives in two **named Docker volumes**:

| Volume | Mount | Contains |
|--------|-------|----------|
| `splunk-etc` | `/opt/splunk/etc` | config, apps, users, dashboards, saved searches |
| `splunk-var` | `/opt/splunk/var` | indexes (your events), KV store, internal logs |

| Event | Data kept? |
|-------|-----------|
| `./scripts/stop.sh` / `docker compose down` | ✅ Yes |
| Codespace stopped (manually or idle timeout) and restarted | ✅ Yes |
| Codespace rebuilt (*Rebuild Container*) | ✅ Yes — docker-in-docker keeps `/var/lib/docker` in a persistent volume |
| `./scripts/reset.sh` / `docker compose down -v` | ❌ No — deliberately wiped |
| Codespace **deleted** | ❌ No — download a backup first |

### Keeping data beyond the Codespace

```bash
./scripts/backup.sh
# -> backups/splunk-backup-20261027-154500.tar.gz
```

Right-click the file in the Explorer → **Download**. To restore into a new Codespace, upload it to `backups/` and run:

```bash
./scripts/restore.sh backups/splunk-backup-20261027-154500.tar.gz
```

`backups/` is gitignored so data never ends up in the repo.

> **Tip:** Codespaces are auto-deleted after a period of inactivity (30 days by default). Adjust under GitHub **Settings → Codespaces → Default retention period**, or keep a backup.

---

## Sending data

### Test event via HEC

```bash
./scripts/test-hec.sh "my first event"
```

Then search in Splunk Web (see [Finding your events](#finding-your-events)):

```
index=main sourcetype=codespace:test
```

### From curl (inside the Codespace)

```bash
source .env
curl http://localhost:8088/services/collector/event \
  -H "Authorization: Splunk $SPLUNK_HEC_TOKEN" \
  -d '{"event": {"action": "login", "user": "demo"}, "sourcetype": "_json", "index": "main"}'
```

### From outside the Codespace (e.g. a cloud integration)

`start.sh` makes port **8088 Public** automatically on every start. If it couldn't, do it yourself: **PORTS** tab → right-click **8088** → **Port Visibility → Public**.

In the Codespace terminal, run:

```bash
./scripts/hec-info.sh
```

It prints ready-to-paste `export HEC_URL=...` / `export HEC_TOKEN=...` lines and a test `curl` to run on your laptop or any other machine:

```
POST https://<codespace-name>-8088.app.github.dev/services/collector/event
Authorization: Splunk <SPLUNK_HEC_TOKEN>
```

The HEC token protects port 8088, so making it public is reasonable for a demo. Do **not** make **8000** public on the Free license, because it has no login.

Keep in mind:
- **The Codespace must be running.** It stops after 30 minutes idle by default, and incoming HEC traffic doesn't count as activity. You can raise this (max 240 min) under GitHub **Settings → Codespaces → Default idle timeout**.
- **The URL is tied to this Codespace.** A new Codespace has a new URL and a new token.
- **Use an existing index.** Events sent to a non-existent index are silently dropped even though HEC says `Success`. `main` always exists; `start.sh` also creates `demo`.

A successful send returns:

```json
{"text":"Success","code":0}
```

---

## Finding your events

### In Splunk Web

1. Open Splunk Web (PORTS tab → globe next to **8000**).
2. Go to **Apps → Search & Reporting** (or click **Search & Reporting** on the home page).
3. Set the time picker (right of the search bar) to **Last 15 minutes** — or **All time** if nothing shows up.
4. Run a search:

   ```
   index=main sourcetype=_json
   ```

Events sent with `"sourcetype": "_json"` have their JSON fields extracted automatically, so you can filter on them directly:

```
index=main action=login user=demo
```

A few more useful searches:

```
index=main | stats count by sourcetype          # what's been ingested
index=main sourcetype=_json | table _time action user
index=main sourcetype=codespace:test            # events from ./scripts/test-hec.sh
index=_internal sourcetype=splunkd component=HttpInputDataHandler   # HEC errors
```

### From the terminal (REST API)

On the **Free license, Splunk only accepts REST/CLI calls from inside the container**. Calls from the Codespace terminal count as "remote" and get `401`. Run them through `docker exec`. `$SPLUNK_PASSWORD` is expanded inside the container, so no quoting issues:

```bash
docker exec splunk sh -c 'curl -sk -u "admin:$SPLUNK_PASSWORD" \
  https://localhost:8089/services/search/jobs/export \
  -d search="search index=main sourcetype=_json earliest=-1h" \
  -d output_mode=json'
```

The CLI works the same way:

```bash
docker exec -u splunk splunk sh -c '/opt/splunk/bin/splunk search "index=main | head 5" -auth "admin:$SPLUNK_PASSWORD"'
```

> With the Enterprise trial license (`SPLUNK_LICENSE_URI=` empty), remote REST works directly with `curl -sk -u admin:<password> https://localhost:8089/...`.

### Event not showing up?

- **Check the HEC response** — anything other than `{"text":"Success","code":0}` means the event was rejected (e.g. `Invalid token`, `Incorrect index`).
- **Wait a few seconds** — events take a moment to become searchable.
- **Widen the time range** — events are timestamped on receipt in the container's time zone (`TZ` in `.env`, default `America/New_York`). Try **All time**.
- **Check the index** — the `index` in your payload must exist; `main` always does.

---

## Demo: seeing the value of Splunk

Sending a single `{"action":"login"}` event doesn't show much. Splunk's value shows up when you have **lots of machine data from different systems**. It lets you ask questions you didn't plan for and **correlate across sources** in seconds, with no schema or data model defined up front.

This demo simulates a small API-driven business. It's the kind of landscape an iPaaS / API management platform sits in the middle of:

| Sourcetype | What it represents |
|---|---|
| `api:access` | API gateway access logs: endpoint, status, latency, bytes, client app, client IP, trace ID |
| `integration:run` | Integration flow executions: order sync to SAP, customer sync from Salesforce |
| `business:order` | Orders placed, with amount, product, region |
| `auth` | Admin console login attempts |

You'll play both roles: **the app** (sending data from your laptop) and **the analyst** (searching in Splunk Web to figure out what happened).

### Step 1 — Send data from outside, like a real app

All of this runs on **your laptop**, or any machine with `bash` and `curl` (macOS, Linux, WSL). Nothing runs inside the Codespace except Splunk.

**1a. Get the connection details.** In the Codespace terminal:

```bash
./scripts/hec-info.sh
```

Copy the two `export` lines it prints and paste them into a terminal on your laptop:

```bash
export HEC_URL=https://<codespace-name>-8088.app.github.dev
export HEC_TOKEN=<your token>
```

**1b. Send events by hand** to see exactly what an app sends. This is one of each type:

```bash
# API gateway access log
curl -s $HEC_URL/services/collector/event -H "Authorization: Splunk $HEC_TOKEN" \
  -d '{"index":"demo","sourcetype":"api:access","event":{"method":"POST","path":"/orders","status":200,"latency_ms":182,"bytes":734,"client_app":"partner-acme","client_ip":"8.8.8.8","region":"us-east","trace_id":"a1b2c3d4"}}'

# Integration flow run (same trace_id = same business transaction)
curl -s $HEC_URL/services/collector/event -H "Authorization: Splunk $HEC_TOKEN" \
  -d '{"index":"demo","sourcetype":"integration:run","event":{"flow":"order-sync-to-SAP","target":"SAP S/4HANA","status":"success","duration_ms":640,"records":1,"trace_id":"a1b2c3d4"}}'

# Business event
curl -s $HEC_URL/services/collector/event -H "Authorization: Splunk $HEC_TOKEN" \
  -d '{"index":"demo","sourcetype":"business:order","event":{"order_id":"ORD-000123","amount":249.99,"currency":"USD","product":"Widget","region":"us-east","client_app":"partner-acme","trace_id":"a1b2c3d4"}}'

# Login attempt
curl -s $HEC_URL/services/collector/event -H "Authorization: Splunk $HEC_TOKEN" \
  -d '{"index":"demo","sourcetype":"auth","event":{"user":"alice","result":"failure","reason":"bad_password","client_ip":"8.8.8.8","app":"admin-console"}}'

# Batch: several events in one request, with explicit timestamps (epoch seconds)
NOW=$(date +%s)
curl -s $HEC_URL/services/collector/event -H "Authorization: Splunk $HEC_TOKEN" -d "
{\"time\":$((NOW-600)),\"index\":\"demo\",\"sourcetype\":\"auth\",\"event\":{\"user\":\"bob\",\"result\":\"success\",\"client_ip\":\"1.1.1.1\"}}
{\"time\":$((NOW-300)),\"index\":\"demo\",\"sourcetype\":\"auth\",\"event\":{\"user\":\"bob\",\"result\":\"success\",\"client_ip\":\"1.1.1.1\"}}"
```

Each call should return `{"text":"Success","code":0}`. In Splunk Web, search `index=demo` with the time range **Last 15 minutes** and you'll see them.

**1c. Run the app emulator** for realistic volume. Download it to your laptop:

```bash
curl -sO https://raw.githubusercontent.com/lbrenman/splunk-enterprise-codespace/main/scripts/app-emulator.sh
chmod +x app-emulator.sh
```

Then pick a mode:

| Command | What it emulates |
|---|---|
| `./app-emulator.sh backfill` | 24 hours of history (~5,700 events), including a past outage and a past attack. **Start here** so the searches below have data. |
| `./app-emulator.sh live` | The app running now: ~5 API calls/sec plus logins and integration runs. Leave it running in one terminal. |
| `./app-emulator.sh outage` | Run in a **second** terminal while `live` runs. `/orders` breaks for 3 minutes. |
| `./app-emulator.sh attack` | Run in a **second** terminal. A brute-force login, a successful break-in, then bulk data theft over ~2 minutes. |

Options: `RATE=20 ./app-emulator.sh live` for more traffic; `INDEX=main ./app-emulator.sh ...` to use the `main` index.

The planted incidents in the backfilled history:
1. **An outage 2–3 hours ago.** `/orders` returns 503s. *Why?* And *what did it cost?*
2. **A security incident ~90 minutes ago.** Brute force against `admin`, a successful login, then bulk download of customer data.

In **Search & Reporting**, set the time picker to **Last 24 hours** for Steps 2–8.

> Inside the Codespace you can do the same with `./scripts/demo-data.sh [backfill|live|outage|attack]`. It also checks the data landed. `./scripts/demo-data.sh reset` wipes the `demo` index.

### Step 2 — What do we have?

```
index=demo | stats count by sourcetype
```

```
index=demo sourcetype=api:access | head 20
```

Click any event and expand it. Every JSON key is already a searchable field, with no parsing rules or table schema needed. The **fields sidebar** on the left shows the top values for each field. Click `status` or `client_app` to see the distribution instantly.

### Step 3 — Operations: is the API healthy?

**Error rate over time.** Switch to the **Visualization** tab and choose a line chart:

```
index=demo sourcetype=api:access
| timechart span=15m count as requests count(eval(status>=500)) as errors
| eval error_rate_pct=round(errors/requests*100,1)
| fields _time error_rate_pct
```

➡ You'll see a clear spike 2–3 hours ago.

**Latency percentiles per endpoint** (the SLA view):

```
index=demo sourcetype=api:access
| eval endpoint=method." ".path
| stats count as calls p50(latency_ms) as p50_ms p95(latency_ms) as p95_ms max(latency_ms) as max_ms by endpoint
| sort - p95_ms
```

**Which endpoint broke, and when?** Use a column or line chart:

```
index=demo sourcetype=api:access status>=500
| timechart span=10m count by path
```

**What's the error?**

```
index=demo sourcetype=api:access status>=500
| stats count by path status error
| sort - count
```

➡ `Upstream timeout: order-sync-to-SAP`. The API is only the messenger.

### Step 4 — Root cause: correlate across systems

The API gateway and the integration platform are different systems with different logs. They share a `trace_id`, so Splunk can join them on the fly:

```
index=demo (sourcetype=api:access status>=500) OR (sourcetype=integration:run status=failed)
| stats values(sourcetype) as seen_in values(path) as api_path values(flow) as flow values(target) as target values(error) as errors dc(sourcetype) as systems by trace_id
| where systems=2
```

Then summarize the failing integration:

```
index=demo sourcetype=integration:run
| timechart span=15m count by status
```

```
index=demo sourcetype=integration:run status=failed
| stats count min(_time) as first_failure max(_time) as last_failure by flow target error
| convert ctime(first_failure) ctime(last_failure)
```

➡ **Root cause:** the order-sync-to-SAP flow timed out against SAP. You also get the exact start and end of the outage. It took a few searches, with no war room and no SSH-ing into boxes.

### Step 5 — Business impact: what did it cost?

**Revenue over time.** The dip lines up with the outage:

```
index=demo sourcetype=business:order
| timechart span=15m sum(amount) as revenue count as orders
```

**Estimated lost revenue** = failed order attempts × average order value:

```
index=demo sourcetype=api:access method=POST path=/orders status>=500
| stats count as failed_orders
| appendcols [ search index=demo sourcetype=business:order | stats avg(amount) as avg_order_value ]
| eval estimated_lost_revenue="$".tostring(round(failed_orders*avg_order_value,2),"commas")
```

**Which partners were affected?** This is useful for proactive customer communication:

```
index=demo sourcetype=api:access path=/orders status>=500
| stats count as failed_calls by client_app
| sort - failed_calls
```

➡ This connects *technical* data (HTTP 503s) to *business* data (dollars). Turning IT events into business metrics is a big part of what people pay Splunk for.

### Step 6 — Security: detect the attack

**Brute-force detection.** Find IPs with lots of failed logins:

```
index=demo sourcetype=auth result=failure
| stats count as failures dc(user) as users_tried values(user) as users min(_time) as first max(_time) as last by client_ip
| where failures > 10
| convert ctime(first) ctime(last)
```

**Did they get in?** Look for failures followed by a success from the same IP:

```
index=demo sourcetype=auth
| stats count(eval(result="failure")) as failures count(eval(result="success")) as successes values(user) as users by client_ip
| where failures > 10 AND successes > 0
```

**Follow the attacker across systems.** This is one search across auth *and* API logs:

```
index=demo client_ip="185.220.101.45"
| eval activity=case(sourcetype=="auth", "LOGIN ".upper(result)." user=".user, sourcetype=="api:access", method." ".path." ".coalesce(query,"")." bytes=".bytes)
| table _time sourcetype activity
| sort _time
```

**Data exfiltration.** Find who downloaded the most data:

```
index=demo sourcetype=api:access
| stats sum(bytes) as total_bytes count as calls by client_ip client_app
| eval MB=round(total_bytes/1024/1024,1)
| sort - MB
| head 10
```

➡ The story is a brute force, then a successful `admin` login, then ~100 MB of `/customers` data pulled by an `unknown` client. That's a breach investigation reconstructed in minutes from logs you were already collecting.

### Step 7 — Usage analytics, geo and anomalies

**Partner / app usage and quality of service:**

```
index=demo sourcetype=api:access
| stats count as calls count(eval(status>=500)) as errors avg(latency_ms) as avg_latency_ms by client_app
| eval error_pct=round(errors/calls*100,2), avg_latency_ms=round(avg_latency_ms)
| sort - calls
```

**Where is traffic coming from?** Use the **Visualization** tab and choose **Cluster Map**:

```
index=demo sourcetype=api:access
| iplocation client_ip
| geostats count by client_app
```

**Statistical anomaly detection.** Flag 10-minute windows where latency is more than 2 standard deviations above normal:

```
index=demo sourcetype=api:access
| timechart span=10m avg(latency_ms) as avg_latency
| eventstats avg(avg_latency) as mean stdev(avg_latency) as sd
| eval threshold=round(mean+2*sd), avg_latency=round(avg_latency)
| where avg_latency > threshold
```

**Real-time view** while `./scripts/demo-data.sh live` is running. Set the time picker to **Real-time → 1 minute window**:

```
index=demo sourcetype=api:access
| timechart span=5s count by status
```

### Step 8 — Make it a dashboard

Run any search above, then choose **Save As → Dashboard Panel → New Dashboard** (e.g. "API Operations"). Add the error-rate, revenue, failed-logins and partner-usage searches as panels. You end up with one screen showing ops, business and security together, built from raw logs in a few minutes.

> **Splunk Free vs. trial:** Free supports searches and dashboards. **Alerts** (e.g. "email me when error_rate_pct > 5" or "when failures > 10 from one IP") and scheduled reports need the Enterprise trial. Set `SPLUNK_LICENSE_URI=` (empty) in `.env` and run `./scripts/reset.sh`.

### Step 9 — Catch an incident as it happens

This is the most convincing part: break things live and watch Splunk show it.

1. **Laptop, terminal 1:** `./app-emulator.sh live` (leave it running)
2. **Splunk Web:** run this with the time picker set to **Real-time → 5 minute window**, and the **Visualization** tab on a line chart:

   ```
   index=demo sourcetype=api:access
   | timechart span=10s count(eval(status>=500)) as errors avg(latency_ms) as avg_latency_ms
   ```

3. **Laptop, terminal 2:** `./app-emulator.sh outage`. Within seconds, errors and latency jump on the chart.
4. Investigate while it's happening, with the time range set to **Last 15 minutes**:

   ```
   index=demo sourcetype=api:access status>=500 | stats count by path error
   ```
   ```
   index=demo sourcetype=integration:run status=failed | stats count by flow target error
   ```

5. **Laptop, terminal 2:** `./app-emulator.sh attack`. Then hunt for it:

   ```
   index=demo sourcetype=auth result=failure earliest=-15m
   | stats count by client_ip user
   ```
   ```
   index=demo client_ip=185.220.101.45 earliest=-15m
   | table _time sourcetype user result path query bytes
   | sort _time
   ```

Put the real-time error chart and the failed-login count on a dashboard (Step 8), and you have a live ops/security wall screen fed entirely by HTTP POSTs from an app.

### Why this matters

- **No schema up front.** You sent JSON, and every field was searchable immediately. Questions you didn't plan for are still answerable.
- **Correlation across silos.** API gateway, integration platform, business events and auth logs are joined by `trace_id` or `client_ip` at search time.
- **One tool, many audiences.** The same data answers ops (*is it up?*), engineering (*why did it break?*), business (*what did it cost?*) and security (*were we breached?*).
- **Ingest from anywhere.** Anything that can make an HTTP POST can feed HEC, including integration flows, API gateway policies, scripts and apps.

---

## Configuration (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `SPLUNK_PASSWORD` | generated | Admin password (min 8 chars) |
| `SPLUNK_LICENSE_URI` | `Free` | `Free` for Splunk Free; **empty** for the 60-day Enterprise trial (with login, alerts, etc.) |
| `SPLUNK_HEC_TOKEN` | generated | HEC token (GUID) |
| `SPLUNK_HEC_SSL` | `false` | HTTPS on HEC |
| `SPLUNK_IMAGE` | `splunk/splunk:latest` | Pin a version, e.g. `splunk/splunk:9.4` |
| `TZ` | `America/New_York` | Container time zone |

After editing `.env`:

```bash
docker compose up -d   # recreates the container; volumes are kept
```

> Changing `SPLUNK_PASSWORD` after first boot does **not** change the existing admin password (it's stored in `splunk-etc`). Change it in Splunk Web or run `./scripts/reset.sh`.

---

## Splunk Free vs. Enterprise Trial

| | Splunk Free (`SPLUNK_LICENSE_URI=Free`) | Enterprise Trial (empty) |
|---|---|---|
| Daily ingest | 500 MB/day | 500 MB/day (trial) |
| Duration | Unlimited | 60 days, then converts |
| Login / users / roles | ❌ None — single admin, no login | ✅ |
| Alerts & scheduled reports | ❌ | ✅ |
| HEC, search, dashboards, apps | ✅ | ✅ |

Switching from trial to Free later can be done in **Settings → Licensing** in Splunk Web.

---

## Common commands

```bash
./scripts/start.sh      # start
./scripts/stop.sh       # stop (keeps data)
./scripts/status.sh     # health check
./scripts/logs.sh       # follow logs
./scripts/backup.sh     # backup to ./backups
./scripts/reset.sh      # wipe all data

docker exec -it splunk bash                                 # shell into container
docker exec -it splunk sudo -u splunk /opt/splunk/bin/splunk status
```

---

## Security

- Codespace ports are **Private** by default — only you (signed in to GitHub) can reach them. Keep it that way for 8000/8089.
- With the **Free** license, Splunk Web has no authentication; anyone who can reach port 8000 is admin.
- `.env` holds your password and HEC token and is **gitignored**. Don't commit it.
- Use the Enterprise trial (empty `SPLUNK_LICENSE_URI`) if you need login protection.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Clicking port 8000 jumps to `localhost:8000` / "not ready" | Splunk Web is redirecting to localhost. Run `./scripts/configure-proxy.sh` (runs automatically on start) — it sets `tools.proxy.base` to the Codespace URL in a small `codespace_proxy` app |
| Port 8000 shows 502 / not responding | Splunk is still booting — run `./scripts/status.sh`, wait 2–4 min on first boot |
| `scripts/start.sh: Permission denied` | `chmod +x scripts/*.sh` (or run with `bash scripts/start.sh`); to fix permanently: `git update-index --chmod=+x scripts/*.sh` and commit |
| REST call to `localhost:8089` returns `401` (even with the right password) | Expected on the Free license — remote management is disabled. Run it inside the container: `docker exec splunk sh -c 'curl -sk -u "admin:$SPLUNK_PASSWORD" https://localhost:8089/...'` |
| `Requires license feature='Auth'` when changing the password | The Free license has no user management, so the admin password can't be changed. Use the Enterprise trial if you need it |
| Container exits immediately | `./scripts/logs.sh` — usually a password under 8 characters or a license-acceptance error |
| `minimum free disk space` error | Splunk needs ≥5 GB free: `df -h`, delete old backups, or use a larger machine |
| Slow / out of memory | Use a 4-core (16 GB) or larger Codespace machine type |
| `docker: Cannot connect to the Docker daemon` | Wait a few seconds after start, then `./scripts/start.sh` |
| HEC returns `Invalid token` | Token in `.env` changed after first boot — HEC token is set on first boot; reset or add a new token in **Settings → Data Inputs → HTTP Event Collector** |
| Forgot settings after rebuild | Check volumes exist: `docker volume ls` (should list `splunk-etc`, `splunk-var`) |

---

## References

- Splunk Docker image: <https://hub.docker.com/r/splunk/splunk>
- docker-splunk docs: <https://splunk.github.io/docker-splunk/>
- HTTP Event Collector: <https://docs.splunk.com/Documentation/Splunk/latest/Data/UsetheHTTPEventCollector>
- Splunk Free: <https://docs.splunk.com/Documentation/Splunk/latest/Admin/MoreaboutSplunkFree>

## License

The contents of this repository are provided as-is for demo and learning purposes. Splunk Enterprise is subject to the [Splunk General Terms](https://www.splunk.com/en_us/legal/splunk-general-terms.html), which you accept by starting the container.
