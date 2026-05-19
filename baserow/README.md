# Self-Hosted Baserow on Dokploy

Standalone Docker Compose template for deploying [Baserow](https://baserow.io) (the open-source Airtable alternative) on [Dokploy](https://dokploy.com). The Caddyfile is embedded inline via Docker Compose `configs:` — just paste the YAML and env vars into Dokploy and deploy.

For the end-to-end walkthrough (DNS, secrets, SMTP, admin lockdown to `@veedoo.io`), follow [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md).

## Files

| File | Description |
|------|-------------|
| `baserow-docker-compose.yml` | Full multi-service deployment: caddy, backend, web-frontend, three Celery workers, Postgres 15 + pgvector, Redis 6. Caddyfile embedded as an inline config. |
| `baserow.env` | Environment file with all required secrets, SMTP, hardware tuning knobs, AI / S3 toggles, and rate-limit settings. |
| `DEPLOY-GUIDE.md` | Step-by-step Dokploy deployment guide. |
| `README.md` | This file — architecture, env reference, troubleshooting. |

## Architecture

```
                    Dokploy / Traefik (HTTPS, public)
                                │
                                ▼  (HTTP :80, dokploy-network)
                            ┌────────┐
                            │ caddy  │     internal reverse proxy
                            └───┬────┘
              ┌─────────────────┼─────────────────┐
              │                 │                 │
              ▼                 ▼                 ▼
        /api  /ws         everything else      /media  /static
        /mcp  /assistant                       (file_server)
              │                 │                 │
              ▼                 ▼                 ▼
      ┌────────────┐     ┌──────────────┐    media volume
      │  backend   │     │ web-frontend │
      │ (Django)   │     │   (Nuxt)     │
      └─────┬──────┘     └──────────────┘
            │
   ┌────────┼────────────────────────────────┐
   │        │                                │
   ▼        ▼                                ▼
┌─────┐ ┌─────────────┐ ┌──────────────────┐ ┌───────────────┐
│ db  │ │   redis     │ │      celery      │ │ celery-export │
│ pg15│ │   (cache +  │ │ (general async)  │ │   (exports)   │
│+vec │ │   broker)   │ └──────────────────┘ └───────────────┘
└─────┘ └─────────────┘
                                 ┌────────────────┐
                                 │  celery-beat   │
                                 │  (scheduler)   │
                                 └────────────────┘
```

**Networks:**
- `default` — internal bridge, every service joined.
- `dokploy-network` — external (created by Dokploy). Only `caddy` joins it, so Traefik can reach it.

**Volumes:**
- `pgdata` — Postgres data directory
- `media` — user uploads (mounted into caddy, backend, all celery workers, and the one-shot fixer)
- `caddy_data` / `caddy_config` — Caddy runtime state

## Quick start

1. In Dokploy create a new **Compose** service.
2. Paste `baserow-docker-compose.yml` into the compose editor.
3. Paste `baserow.env` into the environment variables section.
4. Update the [required env vars](#required-env-vars).
5. Deploy. Wait 2–5 minutes for all containers to become healthy.
6. Add a domain pointing at the `caddy` service on port 80, HTTPS enabled.
7. Open the domain, register the first user (auto-promoted to Instance Admin), then follow [Step 8 of `DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md#step-8-lock-the-instance-to-veedooio-users) to lock signups to your team.

## Required env vars

The deploy will refuse to start until these are populated.

| Variable | What to set |
|----------|-------------|
| `SECRET_KEY` | Random 50-char string (`tr -dc 'a-zA-Z0-9' < /dev/urandom \| head -c50`) |
| `BASEROW_JWT_SIGNING_KEY` | A second random 50-char string |
| `DATABASE_PASSWORD` | Strong Postgres password |
| `REDIS_PASSWORD` | Strong Redis password |
| `BASEROW_PUBLIC_URL` | Full URL with scheme: `https://baserow.yourdomain.com` |
| `EMAIL_SMTP_HOST` / `_USER` / `_PASSWORD` | SMTP credentials (Baserow uses email for verification, invites, password reset, and webhook alerts) |
| `FROM_EMAIL` | Sender address |

## Recommended env vars

| Variable | Default | What it does |
|----------|---------|--------------|
| `BASEROW_VERSION` | `2.2.2` | Pin the image tag so redeploys don't pull a new major silently |
| `CONTAINER_PREFIX` | `baserow` | Lets multiple Baserow stacks live on the same Dokploy host |
| `BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER` | `true` | Tells Django that Traefik already terminated TLS |
| `BASEROW_BACKEND_LOG_LEVEL` | `INFO` | Drop to `WARNING` in production to reduce log volume |
| `BASEROW_FILE_UPLOAD_SIZE_LIMIT_MB` | `1024` | Max single-file upload (defaults to 1 TB unbounded in Baserow itself) |
| `BASEROW_ROW_PAGE_SIZE_LIMIT` | `200` | Max rows returned per API page |

## Email / SMTP cheat sheet

| Provider | Port | `EMAIL_SMTP_USE_TLS` | `EMAIL_SMTP_USE_SSL` |
|----------|------|----------------------|----------------------|
| AWS SES, Mailgun, Postmark, Resend (STARTTLS) | `587` | `True` | `False` |
| Gmail / Workspace (requires App Password + 2FA) | `587` | `True` | `False` |
| Implicit TLS / SSL | `465` | `False` | `True` |
| Local relay / dev | `25` | `False` | `False` |

`EMAIL_SMTP=True` must be set to enable SMTP at all — `EMAIL_SMTP_HOST` alone is not enough.

## Locking signups to `@veedoo.io`

Baserow has no env-var for per-domain signup whitelisting. The supported pattern (covered in detail in [Step 8 of `DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md#step-8-lock-the-instance-to-veedooio-users)):

1. The first user to register on a fresh instance is auto-promoted to Instance Admin (`is_staff = true`).
2. While signups are still public, register every `@veedoo.io` colleague you want as an admin.
3. In **Admin panel → Users**, tick **Is staff** on each `@veedoo.io` admin.
4. In **Admin panel → Settings**, turn **Allow creating new accounts** OFF.
5. Toggle **Allow signups via workspace invitations** ON if you want admins to invite future users by email (recommended) or OFF for fully manual provisioning.

For automated domain enforcement, the only built-in path is SSO (Baserow Enterprise) — point Baserow at your Google Workspace / Azure AD / Okta tenant and the IdP rejects non-`@veedoo.io` logins for you.

## Security checklist

The env file ships with placeholder secrets. **Replace all of these before exposing the instance publicly:**

| Variable | Why |
|----------|-----|
| `SECRET_KEY` | Signs password-reset tokens, signed cookies, and (if `BASEROW_JWT_SIGNING_KEY` is blank) all JWTs. Leaking it means anyone can forge auth tokens. |
| `BASEROW_JWT_SIGNING_KEY` | Signs auth JWTs. Rotate to invalidate every active session. |
| `DATABASE_PASSWORD` | Postgres superuser-equivalent inside the stack. |
| `REDIS_PASSWORD` | Without it the broker is open to anything that can reach port 6379. |
| `EMAIL_SMTP_PASSWORD` | Auth for whoever sends email on your behalf. Use a provider-specific API key, not your real password. |

Then:

- [ ] Pin `BASEROW_VERSION` (don't use `latest`).
- [ ] Disable public signups via Admin → Settings after creating your admin accounts.
- [ ] Set `BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER=true` (default).
- [ ] Set `BASEROW_WEBHOOKS_ALLOW_PRIVATE_ADDRESS=false` (default) unless you genuinely need internal webhooks.
- [ ] Schedule a Postgres backup (Dokploy backups or host-level `pg_dump` cron).
- [ ] Restrict the domain to internal IPs (Dokploy → Domains → Advanced) if the instance is for staff only.
- [ ] If you enable SSO, also disable email + password login in Admin → Authentication providers.

## Connecting external apps

Baserow exposes a REST API at `https://baserow.yourdomain.com/api/` and a websocket endpoint at `wss://baserow.yourdomain.com/ws/`.

Quick API smoke test (replace token with a real user token from **Settings → API tokens**):

```bash
curl -s https://baserow.yourdomain.com/api/database/rows/table/1/ \
  -H "Authorization: Token YOUR_DATABASE_TOKEN" | jq
```

For SDKs see the [Baserow API reference](https://baserow.io/api-docs).

## Troubleshooting

See [`DEPLOY-GUIDE.md` → Troubleshooting](DEPLOY-GUIDE.md#troubleshooting) for the full list. Most common issues:

| Symptom | Likely cause |
|---------|--------------|
| `backend` keeps restarting | Postgres healthcheck hasn't passed yet (wait 30 s) or `SECRET_KEY` is empty |
| 502 Bad Gateway from Caddy | Backend or web-frontend not ready — give it 60 s on first boot |
| Login URLs say `http://` not `https://` | `BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER` is off, or `BASEROW_PUBLIC_URL` starts with `http://` |
| Verification emails never arrive | `EMAIL_SMTP=True` missing, wrong SMTP creds, or sender domain failing SPF/DKIM |
| Uploaded files return 404 | Media volume permissions — see the `volume-permissions-fixer` section in the deploy guide |
| Admin panel missing | Only Instance Admins (`is_staff = true`) see it; the first registered user gets it automatically |
