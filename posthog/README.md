# PostHog on Dokploy — Hetzner CX43

Self-hosted [PostHog](https://posthog.com) as a **single Dokploy Compose service**, tuned for a
Hetzner **CX43** (8 shared vCPU / 16 GB RAM / 160 GB NVMe) running PostHog and nothing else, on a
remote server managed by your main Dokploy instance.

```
Traefik (Dokploy, TLS)  →  Caddy (path routing)  →  35 containers on one internal network
```

## Files

| File | What it is |
|---|---|
| [`posthog-docker-compose.yml`](posthog-docker-compose.yml) | The whole stack. All config embedded inline via `configs:` — nothing to mount |
| [`posthog.env`](posthog.env) | Secrets, domain, image tags, and CX43 / 32 GB / 64 GB tuning tiers |
| [`server-setup.md`](server-setup.md) | Host prep on top of [`../SERVER-SETUP.md`](../SERVER-SETUP.md) |
| [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md) | Step-by-step deploy, verification, upgrades, troubleshooting |

## Quick start

```bash
# 1. Prepare the host
#    ../SERVER-SETUP.md, then server-setup.md  (the second one re-enables swap — read why)

# 2. Generate the five secrets
echo "POSTHOG_SECRET=$(openssl rand -hex 32)"
echo "ENCRYPTION_SALT_KEYS=$(openssl rand -hex 16)"   # exactly 32 hex chars
echo "BROWSERLESS_SECRET=$(openssl rand -hex 32)"
echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)"

# 3. Dokploy: Project -> Compose -> Source "Raw"
#    paste posthog-docker-compose.yml + posthog.env, set POSTHOG_DOMAIN, Deploy

# 4. Domains -> Add Domain -> Service: proxy, Port: 80, HTTPS on -> Redeploy
```

First boot takes **20–35 minutes** — ~5 GB of images to pull and 5–15 minutes of Django and
ClickHouse migrations. Full detail in [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md).

## Three things to know before you commit a server to this

**Point the domain at `proxy`, not `web`.** PostHog splits ingestion across separate containers —
`/e` and `/batch` go to `capture`, `/s` to `replay-capture`, `/flags` to `feature-flags`,
`/surveys` and `/array/*` to `hypercache-server`. Caddy is what knows the routing table. Point
Traefik at `web` and the app loads while every SDK call 404s.

**Pin the image tags after the first successful deploy.** PostHog stopped cutting releases;
`latest` is the tip of `master`, rebuilt many times a day. Left floating, any Dokploy redeploy —
even one you did to change an unrelated env var — upgrades PostHog and runs its migrations.

**16 GB is the floor, not headroom.** PostHog's own installer warns about memory before it starts.
This template ships explicit limits on all 35 containers and resizes ClickHouse, Redpanda,
PostgreSQL, Celery, Nginx Unit and every Node heap down from upstream's much larger defaults —
steady state lands around 12 GB. `server-setup.md` also deliberately **re-enables swap**, which
the shared `../SERVER-SETUP.md` turns off, as an OOM safety net.

## Relationship to upstream

This is PostHog's official hobby stack
([`docker-compose.hobby.yml`](https://github.com/PostHog/posthog/blob/master/docker-compose.hobby.yml)
+ [`docker-compose.base.yml`](https://github.com/PostHog/posthog/blob/master/docker-compose.base.yml)),
flattened into one pasteable file, with TLS delegated to Dokploy's Traefik, host port publishing
removed, credentials generated instead of using the published defaults, and everything resized for
16 GB. `DEPLOY-GUIDE.md` has the full table of what differs and why.

The ClickHouse XML configs are PostHog's own files embedded verbatim (comments stripped), with a
`zz-cx43` overlay layered on top for the sizing. The funnel UDF binaries, protobuf schemas and
GeoIP database are copied out of the PostHog app image at deploy time by a one-shot `assets`
container, so they always match `POSTHOG_APP_TAG` — upstream git-clones the repo for this.

## Not included

PostHog offers **no support and no guarantees** for self-hosted instances, and all paid-plan
features are Cloud-only. Their own scale question is whether you expect more than ~300k events,
1k recordings or 300k `/flags` calls per month — past that a CX43 is not the answer.

Backups are not automated by this template. See
[Backups](DEPLOY-GUIDE.md#backups) for what matters and in what order.
