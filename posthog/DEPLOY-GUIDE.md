# PostHog Deployment Guide (Dokploy)

Deploy self-hosted PostHog as a single Dokploy Compose service on a Hetzner **CX43**
(8 shared vCPU / 16 GB / 160 GB NVMe), running on a **remote server** managed by your main
Dokploy instance.

The template is a flattened, retuned version of PostHog's official hobby stack
([`docker-compose.hobby.yml`](https://github.com/PostHog/posthog/blob/master/docker-compose.hobby.yml)
plus [`docker-compose.base.yml`](https://github.com/PostHog/posthog/blob/master/docker-compose.base.yml)),
which uses `extends:` across two files, bind-mounts a git checkout, and owns ports 80/443 itself —
none of which works with a paste-in Dokploy compose service.

---

## Before you start: is self-hosting the right call?

PostHog is candid that self-hosting is a downgrade, and the limits are worth reading before you
commit a server to it:

- **No support, no guarantees, no paid features.** All paid-plan features are Cloud-only, and
  PostHog offers no support for self-hosted instances.
- **There is no release train.** PostHog stopped cutting tagged releases; `latest` is the tip of
  `master`, rebuilt many times a day. See [Pinning image versions](#pinning-image-versions) — this
  is the single most important operational decision in this guide.
- **PostHog's own scale question** is whether you expect more than ~300k events, 1k recordings, or
  300k `/flags` calls per month. Past that, a CX43 will not be the comfortable answer.
- **Data retention is on you.** ClickHouse and the session-replay blob store grow without bound by
  default, on a 160 GB disk. See [Managing the 160 GB disk](#managing-the-160-gb-disk).

If those are all acceptable, continue.

---

## Architecture

Traefik (installed by Dokploy on the remote server) terminates TLS and forwards plain HTTP to a
Caddy container, which does PostHog's path-based routing across the split ingestion services.
Everything else stays on the internal compose network — **no database, ClickHouse, Kafka, MinIO
or SeaweedFS port is published to the host.**

```
                       Internet
                          │  443
                    ┌─────▼─────┐
                    │  Traefik  │  (Dokploy, TLS via Let's Encrypt)
                    └─────┬─────┘
                          │  80   (dokploy-network)
                    ┌─────▼─────┐
                    │   proxy   │  Caddy — path routing
                    └─────┬─────┘
        ┌─────────────────┼───────────────────────────────┐
        │                 │                               │
  /e /i/v0 /batch    /s  /flags /surveys /array      everything else
        │                 │                               │
   ┌────▼────┐      ┌─────▼──────┐               ┌────────▼────────┐
   │ capture │      │  replay-   │               │  web (Django,   │
   │capture- │      │  capture   │               │  Nginx Unit)    │
   │  ai     │      │feature-fl. │               └────────┬────────┘
   │capture- │      │hypercache  │                        │
   │  logs   │      │ livestream │                        │
   └────┬────┘      └─────┬──────┘                        │
        │                 │                               │
        └────────┬────────┘                               │
                 ▼                                        │
          ┌─────────────┐                                 │
          │  Redpanda   │  Kafka API                      │
          └──────┬──────┘                                 │
                 │                                        │
   ┌─────────────┴──────────────┐                         │
   │ ingestion-general          │                         │
   │ ingestion-sessionreplay    │                         │
   │ ingestion-error-tracking   │                         │
   │ ingestion-logs / -traces   │                         │
   │ plugins (CDP), recording-api                         │
   │ property-defs-rs, cymbal   │                         │
   └─────────────┬──────────────┘                         │
                 │                                        │
   ┌─────────────┴────────────────────────────────────────┴───────────┐
   │  clickhouse + zookeeper │ postgres │ redis7 │ valkey │            │
   │  minio │ seaweedfs │ temporal │ personhog-router/-replica         │
   └──────────────────────────────────────────────────────────────────┘

   worker (Celery)  ·  temporal-django-worker  ·  browserless (Chromium)
```

35 containers total, two of which (`assets`, `kafka-init`) are one-shot and exit after they run.

---

## Prerequisites

- A Hetzner CX43 (or equivalent 8 vCPU / 16 GB / 160 GB) running Ubuntu 24.04
- A main Dokploy instance, with this machine registered as a **remote server**
  (Dokploy installs Docker and its own Traefik there; the master only needs SSH)
- A DNS **A record** pointing `posthog.yourdomain.com` at the remote server's IP
- Port 80 and 443 open on the remote server (Let's Encrypt needs 80 to issue)

---

## Step 1: Prepare the server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** — system updates, Docker daemon tuning,
   kernel parameters, file descriptors, journal limits, firewall, fail2ban, SSH hardening, NTP.
2. Run **[`server-setup.md`](server-setup.md)** — the PostHog-specific deltas.

> **Read `server-setup.md` even if you have run `SERVER-SETUP.md` before.** It deliberately
> **reverses** the shared guide's "disable swap" step. On 16 GB, swap is the difference between a
> container stalling for a few seconds and the OOM killer taking ClickHouse out mid-merge.

---

## Step 2: Create the Compose service

1. In the Dokploy UI, go to **Projects → Create Project**, name it `posthog`
2. Inside the project, **Create Service → Compose**
3. Set **Server** to your remote CX43 (not the Dokploy master)
4. Set **Source** to `Raw`
5. Paste the entire contents of `posthog-docker-compose.yml` into the compose editor
6. Open the **Environment** tab and paste the entire contents of `posthog.env`

Leave the tier block at the top of the env file as-is — it is already the CX43 profile.

---

## Step 3: Generate the secrets

Five values in `posthog.env` ship as `you-need-to-generate-this-value`. Generate them all at once:

```bash
echo "POSTHOG_SECRET=$(openssl rand -hex 32)"
echo "ENCRYPTION_SALT_KEYS=$(openssl rand -hex 16)"
echo "BROWSERLESS_SECRET=$(openssl rand -hex 32)"
echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)"
```

Paste each into the environment tab, replacing the placeholder.

| Variable | Length | What breaks if you rotate it later |
|---|---|---|
| `POSTHOG_SECRET` | any | Every session is invalidated; internal service calls and livestream JWTs stop validating |
| `ENCRYPTION_SALT_KEYS` | **exactly 32 hex chars** | Every stored integration credential becomes unreadable — there is no recovery |
| `BROWSERLESS_SECRET` | any | Image exports and heatmap screenshots fail until both sides match |
| `POSTGRES_PASSWORD` | any | Nothing can reach the database until the volume's password is changed to match |
| `MINIO_ROOT_PASSWORD` | any | Exports and AI blobs become unreadable |

`ENCRYPTION_SALT_KEYS` **must** be exactly 32 hex characters — `openssl rand -hex 16`, not `-hex 32`.

Set `POSTHOG_DOMAIN` to your real hostname now as well. You will redeploy after adding the domain
in step 5, but setting it up front saves one cycle.

---

## Step 4: First deploy

Click **Deploy**. The first run is slow and mostly silent — this is expected:

| Phase | Duration | What is happening |
|---|---|---|
| Image pull | 3–15 min | ~5 GB over the wire, ~18 GB unpacked; `posthog/posthog` alone unpacks to 7.3 GB |
| `assets` | seconds | Copies ClickHouse UDF binaries, protobuf schemas and the GeoIP database out of the app image |
| Data layer | 1–2 min | Postgres, ClickHouse, Redpanda, ZooKeeper, MinIO, SeaweedFS, Temporal come up in order |
| `kafka-init` | ~30 s | Creates the ingestion topics and sets Redpanda retention |
| `web` migrations | **45–60 min** | Django + ClickHouse migrations, run once by the `web` container. Django alone is ~2,700 migrations applied single-threaded at ~35/min on a CX43 core |
| Everything else | 1–2 min | Consumers and edge services start once `web` is up |

**Budget about an hour end to end on a CX43.** The `web` healthcheck has a 60-minute `start_period`
for exactly this reason — do not interpret "starting" as stuck before then. Measured on
Sep 2026 `master`: 50 minutes of Django migrations, then the 320 ClickHouse migrations in under
a minute. Postgres sits idle the whole time; the bottleneck is Python on one shared core.

While `web` is still migrating, the domain answers **502 from Caddy** (the certificate is issued
as soon as Traefik sees the `proxy` container). That is expected until `web` turns healthy. The
`proxy` healthcheck deliberately probes Caddy itself rather than `web`: Traefik silently drops any
container whose healthcheck fails, so a proxy health tied to `web` would turn every redeploy into
a Traefik 404 for the duration of the migrate step.

Watch the migration run:

```bash
docker logs -f posthog-web
```

You want to reach `All migrations completed successfully.` followed by
`🔧 Starting with Nginx Unit server`.

---

## Step 5: Add the domain

1. Dokploy UI → your compose service → **Domains** → **Add Domain**
2. Configure:
   - **Domain**: `posthog.yourdomain.com`
   - **Service Name**: `proxy` ← the Caddy container, **not** `web`
   - **Container Port**: `80`
   - **HTTPS**: enabled (Traefik provisions the certificate)
3. Make sure `POSTHOG_DOMAIN` in the environment matches exactly
4. **Redeploy**

Pointing the domain at `web` instead of `proxy` is the single most common mistake here: the app
loads, but `/e`, `/i/v0`, `/batch`, `/s`, `/flags` and `/surveys` all 404, because those paths are
served by separate containers that only Caddy knows how to reach.

---

## Step 6: Create the first user and verify

Visit `https://posthog.yourdomain.com`. The first visitor gets the signup page and becomes the
instance owner — **do this immediately**, before anyone else finds the URL.

Then run through the checks that actually exercise the split services:

```bash
# App is up
curl -s https://posthog.yourdomain.com/_health

# Ingestion (capture, a separate Rust container) — expect {"status":1}
curl -s https://posthog.yourdomain.com/e/ \
  -H 'Content-Type: application/json' \
  -d '{"api_key":"<your project API key>","event":"deploy_smoke_test","distinct_id":"setup"}'

# Feature flags (feature-flags, another Rust container)
curl -s -X POST https://posthog.yourdomain.com/flags/?v=2 \
  -H 'Content-Type: application/json' \
  -d '{"api_key":"<your project API key>","distinct_id":"setup"}'

# Remote config / surveys (hypercache-server)
curl -s -o /dev/null -w '%{http_code}\n' https://posthog.yourdomain.com/array/<your project API key>/config
```

Get the project API key from **Project Settings → Project API Key** in the UI.

Then confirm the event landed: **Activity** in the PostHog UI should show `deploy_smoke_test`
within a few seconds. That single check proves the whole path — Caddy → capture → Redpanda →
`ingestion-general` → ClickHouse → query.

---

## Verify the tuning actually applied

Config that silently fails to load is worse than no config. These three checks confirm the parts
of this template that could fail quietly:

```bash
# 1. ClickHouse server limits (config.d/zz-cx43.xml merged)
docker exec posthog-clickhouse clickhouse-client -q "
  SELECT name, value FROM system.server_settings
  WHERE name IN ('max_server_memory_usage','mark_cache_size','max_concurrent_queries')
  FORMAT PrettyCompactMonoBlock"
# expect 2415919104 / 536870912 / 40 — NOT 0 / 5368709120 / 200

# 2. ClickHouse per-query limits (users.d/zz-cx43.xml merged into PostHog's users.xml)
docker exec posthog-clickhouse clickhouse-client -q "
  SELECT name, value FROM system.settings
  WHERE name IN ('max_memory_usage','max_threads') FORMAT PrettyCompactMonoBlock"
# expect 1610612736 / 4 — NOT 10000000000

# 3. Funnel UDFs registered (they live in binaries copied from the app image)
docker exec posthog-clickhouse clickhouse-client -q "
  SELECT count() FROM system.functions WHERE origin='ExecutableUserDefined'"
# expect 15 or more; 0 means the assets container did not run
```

And the resource limits themselves:

```bash
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' | sort -k3 -hr | head -15
free -h
```

Steady state should be roughly 12 GB used of 16 GB, with swap barely touched. If `docker stats`
shows `web` pinned at its limit and `free -h` shows a gigabyte or more of swap in use, the Django
processes have outgrown `MEM_WEB` — raise it before touching anything else.

---

## Pinning image versions

**This is the most important operational decision in this guide.**

PostHog no longer cuts tagged releases. Their own installer says so: *"PostHog don't create tagged
releases anymore. It's way better to use 'latest' than 'latest-release'."* `posthog/posthog:latest`
is rebuilt many times per day from the tip of `master`.

The template ships `POSTHOG_APP_TAG=latest` so your first deploy gets a coherent set of images.
**Once the instance is verified healthy, pin it.** Otherwise every Dokploy redeploy — including a
redeploy you did for an unrelated reason, like changing an env var — silently upgrades PostHog to
whatever `master` looked like that morning, migrations and all.

Every image carries the commit it was built from in its `org.opencontainers.image.revision`
label. The ghcr.io Rust/Go services are rebuilt only when their own code changes, so on any given
day they sit at *different* commits — one shared tag cannot pin them all, which is why the compose
file accepts a per-image override for each of them. Print the exact pins for what is running now:

```bash
rev() { docker inspect "$1" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'; }
echo "POSTHOG_APP_TAG=$(rev posthog/posthog:latest)"
echo "POSTHOG_NODE_TAG=$(rev posthog/posthog-node:latest)"
g=ghcr.io/posthog/posthog
echo "CAPTURE_TAG=sha-$(rev $g/capture:master | cut -c1-7)"
echo "CAPTURE_LOGS_TAG=sha-$(rev $g/capture-logs:master | cut -c1-7)"
echo "FEATURE_FLAGS_TAG=sha-$(rev $g/feature-flags:master | cut -c1-7)"
echo "HYPERCACHE_TAG=sha-$(rev $g/hypercache-server:master | cut -c1-7)"
echo "PERSONHOG_TAG=sha-$(rev $g/personhog-router:master | cut -c1-7)"
echo "PROPERTY_DEFS_TAG=sha-$(rev $g/property-defs-rs:master | cut -c1-7)"
echo "CYMBAL_TAG=sha-$(rev $g/cymbal:master | cut -c1-7)"
echo "LIVESTREAM_TAG=sha-$(rev $g/livestream:master)"   # livestream tags use the full SHA
```

Paste the output into the environment tab (replacing the three `latest` / `master` lines and
uncommenting the per-image block), leave `POSTHOG_GHCR_TAG=master` as the fallback, and redeploy.
The images are already on disk, so the redeploy only recreates the containers.

`posthog/posthog` and `posthog/posthog-node` publish full-SHA tags. The Rust services publish
`sha-<7 chars>`; `livestream` publishes `sha-<40 chars>`. Confirm a tag exists before relying on
it: `docker manifest inspect ghcr.io/posthog/posthog/capture:sha-abc1234 >/dev/null && echo ok`.

> **Known upstream quirk:** `posthog/posthog-node:latest` is rebuilt far less often than
> `posthog/posthog:latest`. This is upstream's arrangement, not a mistake in this template — the
> hobby stack runs the same combination. If ingestion misbehaves after an app upgrade, a stale node
> image is the first thing to check.

---

## Upgrading

1. **Back up first** (see [Backups](#backups)). Migrations are one-way.
2. Note the currently running tags so you can roll back.
3. Update `POSTHOG_APP_TAG` / `POSTHOG_NODE_TAG` and the per-image ghcr pins together (or
   clear the per-image pins to follow `POSTHOG_GHCR_TAG` again).
4. **Do not touch** `POSTHOG_SECRET`, `ENCRYPTION_SALT_KEYS`, `POSTGRES_PASSWORD`,
   `MINIO_ROOT_PASSWORD` or `BROWSERLESS_SECRET`.
5. Redeploy. `web` runs the migrations again on start; watch `docker logs -f posthog-web`.
6. If PostHog reports a pending **async migration**, run it from
   **Settings → Async Migrations** in the UI. This template does not auto-run them, matching
   upstream — async migrations can rewrite large ClickHouse tables and should be started
   deliberately, with disk headroom confirmed.
7. Re-run the checks in [Step 6](#step-6-create-the-first-user-and-verify).

The `assets` container re-runs on every deploy, so ClickHouse UDF binaries and protobuf schemas
stay in step with the app image automatically.

### Rolling back

Set the tags back and redeploy. **This only works if the new version did not run a destructive
migration** — which is why step 1 is a backup, not a suggestion.

---

## Managing the 160 GB disk

Redpanda is bounded by `KAFKA_RETENTION_MS` / `KAFKA_RETENTION_BYTES`. ClickHouse and the session
replay blob store are **not** — they grow with what you send, forever, by default.

Check where the space is going:

```bash
docker system df -v | grep -E 'posthog_(clickhouse|seaweedfs|postgres|objectstorage|redpanda)'

docker exec posthog-clickhouse clickhouse-client -q "
  SELECT table, formatReadableSize(sum(bytes_on_disk)) AS size, sum(rows) AS rows
  FROM system.parts WHERE active AND database='posthog'
  GROUP BY table ORDER BY sum(bytes_on_disk) DESC LIMIT 15
  FORMAT PrettyCompactMonoBlock"
```

Three levers, cheapest first:

**1. Shorten replay retention.** Session recordings are almost always the biggest consumer per
event. Set it per project in **Project Settings → Recordings**, then let the blob store expire.

**2. Trim performance events.** In the PostHog UI at `/instance/settings`, lower
`RECORDINGS_PERFORMANCE_EVENTS_TTL_WEEKS` from its default of 3.

**3. Add a TTL to the events table.** This is destructive and irreversible — take a backup and be
sure about the window before running it:

```bash
docker exec posthog-clickhouse clickhouse-client -q "
  ALTER TABLE posthog.sharded_events
  MODIFY TTL toDate(timestamp) + INTERVAL 12 MONTH"
```

ClickHouse needs free space to apply a TTL (it rewrites parts). **Do this while you still have
headroom**, not at 95% full — a merge that runs out of disk leaves parts in a bad state.

Reclaim Docker space after upgrades:

```bash
docker image prune -af --filter "until=168h"
```

---

## What differs from upstream hobby

Every deviation from PostHog's `docker-compose.hobby.yml`, and why:

| Change | Reason |
|---|---|
| `extends:` flattened into one file | Dokploy raw compose is a single pasted file; `extends` needs `docker-compose.base.yml` on disk next to it |
| `build:` removed from the Rust services | Upstream deploys with `--no-build` anyway; the `image:` tags are what actually run |
| Caddy listens on `:80`, `auto_https off`, no published ports | Traefik owns 80/443 and TLS on a Dokploy host; two ACME clients on one box fight over the certificate |
| Caddy passes `X-Forwarded-For` through untouched | With two proxy hops Caddy would otherwise append Traefik's container IP, and PostHog would geolocate your own reverse proxy instead of the visitor |
| `elasticsearch` dropped | Only there because upstream's `temporal` keeps a `depends_on` on it; hobby sets `ENABLE_ES=false`, so Temporal uses Postgres visibility and never queries it. Saves ~700 MB |
| `temporal-ui`, `temporal-admin-tools` dropped | Developer conveniences that also publish host ports |
| `asyncmigrationscheck` dropped | Upstream sets `deploy.replicas: 0` on it — it never runs |
| **`capture-ai` added** | Upstream's Caddyfile routes `/i/v0/ai` to a `capture-ai` service that the hobby compose never defines, so LLM-analytics ingestion 502s |
| All host port publishing removed | Upstream exposes MinIO (19000/19001), SeaweedFS, Temporal (7233) and the Temporal UI (8081) on the host. Nothing outside the compose network needs them |
| `assets` init container replaces the git clone | Upstream clones the PostHog repo to bind-mount UDF binaries, protobuf schemas and a downloaded GeoIP database. Taking them from the app image instead removes the deploy-time network dependency and guarantees they match `POSTHOG_APP_TAG` |
| ClickHouse XML configs embedded as compose `configs:` | Same reason — no repo checkout on the host |
| Postgres and MinIO credentials generated | Upstream ships the published defaults `posthog:posthog` and `object_storage_root_user` |
| Explicit memory limits on every service | On 16 GB, one runaway container takes the box down. Limits also let ClickHouse and the JVMs size themselves off their share instead of the whole host |
| ClickHouse caches, query budget and thread pools resized | Upstream sets a 5 GiB mark cache, 8 GiB uncompressed cache and a 10 GB per-query budget — sized for a large analytics box, not for sharing 16 GB with 34 other containers |
| System log tables disabled, `query_log` TTL cut to 3 days | Per-second `metric_log` / `asynchronous_metric_log` rows are the classic way a small ClickHouse disk fills up. `query_log` is kept because it is the one you need when debugging |
| Redpanda `--memory 2G`, retention capped | Upstream's `KAFKA_LOG_RETENTION_*` env vars are Bitnami-Kafka variables that Redpanda ignores, leaving the 7-day default in place |
| `WEB_CONCURRENCY` and `NGINX_UNIT_APP_PROCESSES` pinned | Celery defaults to one Django fork per vCPU — 8 of them, plus 4 Unit processes, would be ~5 GB of Python before anything else starts |
| Node heaps capped per service | Seven Node consumers with default heaps will happily take more than their share |
| `SESSION_RECORDING_V2_S3_ENABLED=True` | Upstream wires up every replay-storage variable but leaves the master switch off outside `DEBUG` |

---

## Tuning knobs

All in `posthog.env`. The most useful ones, in the order you would reach for them:

| Symptom | Knob | Notes |
|---|---|---|
| UI feels serialised / slow under a few users | `WEB_PROCESSES` | Each is a full Django interpreter, ~1 GB resident once warm. Raise `MEM_WEB` with it |
| Background tasks (exports, cohorts, alerts) lag | `CELERY_CONCURRENCY` | Same cost per worker. Raise `MEM_WORKER` with it |
| `worker` memory creeps up over days | `CELERY_MAX_MEMORY_PER_CHILD` (KB), `CELERY_MAX_TASKS_PER_CHILD` | Recycles forked children |
| ClickHouse queries fail with "Memory limit exceeded" | `CH_MAX_MEMORY_USAGE`, `CH_EXTERNAL_GROUP_BY`, `CH_EXTERNAL_SORT` | Raising the spill thresholds trades RAM for disk I/O |
| ClickHouse gets OOM-killed | Lower `CH_MAX_SERVER_MEMORY` | Keep it ~1 GB under `MEM_CLICKHOUSE` for allocator and thread overhead |
| Ingestion falls behind | `NODE_HEAP_INGESTION` + `MEM_INGESTION` | `ingestion-general` is the hot path |
| Redpanda disk grows | `KAFKA_RETENTION_MS`, `KAFKA_RETENTION_BYTES` | Applies to new topics; use `rpk topic alter-config` for existing ones |
| Image exports time out | `BROWSERLESS_CONCURRENT`, `BROWSERLESS_TIMEOUT` | Chromium is memory-hungry; raise `MEM_BROWSERLESS` too |

Moving to a bigger machine: the env file has ready-made blocks for 8 vCPU / 32 GB and
16 vCPU / 64 GB at the bottom. Uncomment one — the values below it override the CX43 block.

### Reclaiming RAM

If you do not use a feature, its containers can be commented out of the compose file:

| Comment out | Costs you |
|---|---|
| `browserless` | Image exports and heatmap screenshots (~1 GB limit, ~300 MB idle) |
| `cymbal` + `cymbal-resolution` + `ingestion-error-tracking` | Error tracking |
| `ingestion-logs` + `ingestion-traces` + `capture-logs` | Log and trace ingestion |
| `livestream` | The live-events activity feed |
| `capture-ai` | The `/i/v0/ai` LLM-analytics endpoint |

Leave `valkey` alone even though it looks redundant next to `redis7` — every CDP process
dual-writes to it and refuses to start without `CDP_VALKEY_HOST`.

---

## Backups

Nothing in this template backs itself up. What matters, in order:

| Volume | Contains | Losing it means |
|---|---|---|
| `postgres-data` | Users, projects, dashboards, insights, flags, integrations, Temporal state | Total loss — the events in ClickHouse become unreadable data |
| `clickhouse-data` | Events, persons, session metadata | All analytics history |
| `seaweedfs-data` | Session replay blobs | All recordings |
| `objectstorage-data` | Exports, AI blobs | Exported files |

`redpanda-data`, `redis7-data`, `caddy-*` and the ZooKeeper volumes are reconstructible.

Postgres is the one to automate first — it is small, and it is the volume whose loss cannot be
worked around:

```bash
docker exec posthog-db pg_dump -U posthog -Fc posthog > posthog-$(date +%F).dump
```

ClickHouse, for a consistent copy of a single table:

```bash
docker exec posthog-clickhouse clickhouse-client -q \
  "BACKUP DATABASE posthog TO Disk('backups', 'posthog-$(date +%F)')"
```

(Requires a `backups` disk configured in ClickHouse; on a 160 GB box, back up to off-host storage.)

Dokploy's **Volume Backups** feature works on named volumes and can push to S3-compatible storage —
that is the least-effort route for all four volumes above. Whatever you choose, **restore-test it
once**, because the first time you find out a PostHog backup is incomplete should not be the time
you need it.

---

## Troubleshooting

### `web` never becomes healthy

```bash
docker logs posthog-web --tail 200
```

- Still printing migration output? Wait — first boot legitimately takes 5–15 minutes.
- `waiting for clickhouse` / `waiting for postgres` in a loop → check those two containers first.
- Migration errors mentioning ClickHouse → `docker logs posthog-clickhouse --tail 100`.

### `web` restart-loops: `Unknown table expression identifier 'system.crash_log'`

`docker logs posthog-web` shows `migrate_clickhouse` failing with that error and
`Error in ClickHouse migrations, exiting.`, and `docker inspect posthog-web` shows a climbing
`RestartCount`. ClickHouse creates its `system.*_log` tables lazily, and PostHog's
`0159_crash_log_metrics` migration builds a view over `system.crash_log` before anything has
been logged. The template's ClickHouse entrypoint runs `SYSTEM FLUSH LOGS` at start for exactly
this reason; if you are on an older copy of the template, run it by hand once and restart `web`:

```bash
docker exec posthog-clickhouse clickhouse-client -q "SYSTEM FLUSH LOGS"
docker restart posthog-web
```

Each failed loop re-spends the full Django migration planning time, so do not wait it out.

### The app loads but events are not captured

Almost always the domain pointing at `web` instead of `proxy`. Verify:

```bash
curl -si https://posthog.yourdomain.com/e/ -d '{}' | head -1
```

A 404 with a Django error page means Traefik is bypassing Caddy. Fix the domain's **Service Name**
to `proxy` and redeploy.

### Events accepted but never appear in the UI

The path is capture → Redpanda → `ingestion-general` → ClickHouse. Find the broken link:

```bash
docker exec posthog-kafka rpk topic list --brokers kafka:9092
docker logs posthog-ingestion-general --tail 100
docker exec posthog-clickhouse clickhouse-client -q "SELECT count() FROM posthog.events"
```

Consumer lag:

```bash
docker exec posthog-kafka rpk group list --brokers kafka:9092
docker exec posthog-kafka rpk group describe <group> --brokers kafka:9092
```

### ClickHouse restarts or gets OOM-killed

```bash
docker inspect posthog-clickhouse --format '{{.State.OOMKilled}} {{.RestartCount}}'
```

If `true`, lower `CH_MAX_SERVER_MEMORY` (and `CH_MAX_MEMORY_USAGE`) rather than raising
`MEM_CLICKHOUSE` — on 16 GB there is nowhere to raise it to. Confirm swap is on
(`free -h`); `server-setup.md` section 1 exists precisely for this failure.

### Funnels error with "Unknown function aggregate_funnel..."

The UDF binaries did not get copied out of the app image.

```bash
docker logs posthog-assets
docker exec posthog-clickhouse ls /var/lib/clickhouse/user_scripts | head
docker exec posthog-clickhouse clickhouse-client -q \
  "SELECT name FROM system.functions WHERE origin='ExecutableUserDefined' ORDER BY name"
```

Redeploy to re-run `assets`, then restart ClickHouse.

### "too many connections" from Postgres

```bash
docker exec posthog-db psql -U posthog -c \
  "SELECT count(*), state FROM pg_stat_activity GROUP BY state"
```

Raise `PG_MAX_CONNECTIONS` and `MEM_DB` together — each backend costs a few MB.

### Email is configured but nothing sends

PostHog's email settings are **instance settings stored in the database**. The `EMAIL_*` env vars
only seed them on the very first boot; after that the database value wins. Set them at
`https://posthog.yourdomain.com/instance/settings` instead, and make sure `EMAIL_ENABLED` is on
there (this template seeds it to `False`, since there is no SMTP server by default).

### Disk full

See [Managing the 160 GB disk](#managing-the-160-gb-disk). If ClickHouse is already wedged, free
space first (`docker image prune -af`), restart ClickHouse, *then* apply retention — a TTL needs
free space to run.

---

## File reference

| File | Purpose |
|---|---|
| `posthog-docker-compose.yml` | The whole stack: 35 services, all config embedded inline |
| `posthog.env` | Secrets, domain, image tags, and CX43 / 32 GB / 64 GB tuning tiers |
| `server-setup.md` | Host prep on top of `../SERVER-SETUP.md` (swap, `max_map_count`, disk plan) |
| `DEPLOY-GUIDE.md` | This guide |
| `README.md` | Overview and quick reference |
