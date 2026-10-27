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

> **Splunk Free has no login screen** — Splunk Web opens directly as admin. The password is still used for the REST API (port 8089) and CLI. Keep port 8000 **Private** (the Codespaces default) — see [Security](#security).

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

Then search in Splunk Web:

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

1. In the **PORTS** tab, right-click port **8088** → **Port Visibility → Public**.
2. Use the forwarded URL:
   ```
   POST https://<codespace-name>-8088.app.github.dev/services/collector/event
   Authorization: Splunk <SPLUNK_HEC_TOKEN>
   ```
3. Set it back to **Private** when finished.

HEC is protected by the token, so making **8088** public is reasonable for a demo. Do **not** make **8000** public on the Free license (no login).

### REST API

```bash
source .env
curl -k -u admin:$SPLUNK_PASSWORD \
  https://localhost:8089/services/search/jobs/export \
  -d search="search index=main | head 5" -d output_mode=json
```

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
