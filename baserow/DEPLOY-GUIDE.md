# Deploying Baserow to Dokploy — Step-by-Step Guide

This guide walks you through deploying a self-hosted [Baserow](https://baserow.io) instance on Dokploy from start to finish. Everything is standalone — just paste the compose YAML and env vars into Dokploy, no extra files needed.

The deployment runs Baserow's recommended **separated-services** architecture (backend, web-frontend, three Celery workers, Postgres + pgvector, Redis, Caddy reverse proxy) with the Caddyfile embedded inline via Docker Compose `configs`.

## Prerequisites

- A server with [Dokploy](https://dokploy.com) installed
- A domain (or subdomain) you control, e.g. `baserow.yourdomain.com`
- SMTP credentials (any provider — SES, Mailgun, Postmark, Gmail SMTP, etc.)
- SSH access to your server (for verification commands)

---

## Step 1: Generate Secrets

Run these commands on any machine with `openssl` and save the output:

```bash
# SECRET_KEY (50+ chars, used by Django for cryptographic signing)
tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c50; echo

# BASEROW_JWT_SIGNING_KEY (separate signing key for JWT auth tokens)
tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c50; echo

# DATABASE_PASSWORD
openssl rand -hex 24

# REDIS_PASSWORD
openssl rand -hex 24
```

> **Why `BASEROW_JWT_SIGNING_KEY`?** If you leave it blank Baserow falls back to `SECRET_KEY`, which means rotating `SECRET_KEY` invalidates every session. Setting a separate JWT key lets you rotate them independently.

---

## Step 2: Create a Compose Project in Dokploy

1. Log into your Dokploy dashboard
2. Click **Create Project**
3. Give it a name (e.g. "Baserow")
4. Inside the project, click **Create Service** → **Compose**
5. Give the service a name (e.g. `baserow-stack`)

---

## Step 3: Paste the Compose YAML

1. Open the compose service you just created
2. Go to the **Compose** tab (or the compose editor)
3. Copy the **entire contents** of [`baserow-docker-compose.yml`](baserow-docker-compose.yml)
4. Paste it into the Dokploy compose editor
5. Save (don't deploy yet)

---

## Step 4: Configure Environment Variables

1. Go to the **Environment** tab of your compose service
2. Copy the **entire contents** of [`baserow.env`](baserow.env)
3. Paste it into the environment variables section
4. **Replace the placeholder values** with what you generated in Step 1 and your SMTP credentials

### Required changes (deploy will refuse to start without these)

| Variable | What to set |
|----------|-------------|
| `SECRET_KEY` | The 50-char random string you generated |
| `BASEROW_JWT_SIGNING_KEY` | The second 50-char random string you generated |
| `DATABASE_PASSWORD` | Your generated Postgres password |
| `REDIS_PASSWORD` | Your generated Redis password |
| `BASEROW_PUBLIC_URL` | `https://baserow.yourdomain.com` (the full URL, with scheme) |
| `EMAIL_SMTP_HOST` | Your SMTP server hostname (e.g. `smtp.resend.com`, `email-smtp.eu-west-1.amazonaws.com`) |
| `EMAIL_SMTP_USER` | Your SMTP username |
| `EMAIL_SMTP_PASSWORD` | Your SMTP password / API key |
| `FROM_EMAIL` | The sender address (e.g. `baserow@yourdomain.com`) |

### Recommended changes

| Variable | Default | What it controls |
|----------|---------|------------------|
| `CONTAINER_PREFIX` | `baserow` | Unique prefix so multiple stacks can coexist |
| `BASEROW_VERSION` | `2.2.2` | Pin to a specific release — bump deliberately |
| `BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER` | `true` | Tells Django that Traefik already terminated TLS |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `10m` / `3` | Docker log rotation per container |

### Email port quick reference

| Provider | Port | `USE_TLS` | `USE_SSL` |
|----------|------|-----------|-----------|
| STARTTLS (most providers — SES, Mailgun, Postmark, Resend, Gmail) | `587` | `True` | `False` |
| Implicit TLS / SSL | `465` | `False` | `True` |
| Plain SMTP (local relay, dev only) | `25` | `False` | `False` |

### Hardware tuning quick reference

Defaults in `baserow.env` target a small server (~4 GB RAM). If your Dokploy box is bigger, bump these:

| Variable | 4 GB | 8 GB | 16 GB | 32 GB |
|----------|------|------|-------|-------|
| `PG_SHARED_BUFFERS` | `512MB` | `2GB` | `4GB` | `8GB` |
| `PG_EFFECTIVE_CACHE_SIZE` | `2GB` | `6GB` | `12GB` | `24GB` |
| `PG_WORK_MEM` | `8MB` | `16MB` | `32MB` | `64MB` |
| `PG_MAX_CONNECTIONS` | `100` | `200` | `300` | `500` |
| `REDIS_MAXMEMORY` | `512mb` | `1gb` | `2gb` | `4gb` |
| `BASEROW_AMOUNT_OF_WORKERS` | `2` | `4` | `8` | `12` |
| `BASEROW_AMOUNT_OF_GUNICORN_WORKERS` | leave blank | leave blank | leave blank | leave blank |

5. Save the environment variables.

---

## Step 5: Add a Domain

### 5a. Create DNS Record

Create an A record pointing your subdomain to your server's IP:

```
baserow.yourdomain.com  →  YOUR_SERVER_IP
```

### 5b. Add Domain in Dokploy

1. Go to your Baserow compose project in the Dokploy dashboard
2. Navigate to the **Domains** tab
3. Click **Add Domain**:
   - **Domain**: `baserow.yourdomain.com`
   - **Service**: `caddy` (container name ends in `-caddy`)
   - **Port**: `80`
   - **HTTPS**: Enable (Dokploy auto-provisions a Let's Encrypt certificate via Traefik)
4. Save and wait for the certificate to provision

### 5c. Confirm `BASEROW_PUBLIC_URL` matches

Double-check the env tab — `BASEROW_PUBLIC_URL` must be `https://baserow.yourdomain.com` (no trailing slash). If you change it, redeploy so the backend and web-frontend pick up the new URL.

---

## Step 6: Deploy

1. Click **Deploy** in Dokploy
2. Watch the logs. First-time startup takes 2–5 minutes:
   - `db` boots, runs first-time init
   - `volume-permissions-fixer` chowns the media volume and exits (status: `Exited (0)` — this is correct)
   - `backend` runs migrations, syncs templates, then becomes healthy
   - `celery`, `celery-export-worker`, `celery-beat-worker` connect to Redis + Postgres
   - `web-frontend` becomes healthy
   - `caddy` becomes healthy last

If any container restarts repeatedly, check its logs in the Dokploy UI. Common first-run errors are covered in [Troubleshooting](#troubleshooting).

---

## Step 7: Create the First User (Becomes Instance Admin)

1. Open `https://baserow.yourdomain.com` in your browser
2. Click **Create new account**
3. Sign up with your real email — **the first account to register on a self-hosted instance is automatically promoted to Instance Admin** (`is_staff = true`)
4. Check your inbox for the verification email. If it doesn't arrive within ~1 minute, see [SMTP troubleshooting](#auth-emails-not-sending)

---

## Step 8: Lock the Instance to `@veedoo.io` Users

> Baserow does **not** have an env var to whitelist signups by email domain. The supported pattern is to disable public signups after you've created admin accounts, and then invite users one workspace at a time. Auto-admin-promotion by email domain is also UI-only — there is no env var for it.

### 8a. Create admin accounts for the rest of the `@veedoo.io` team

1. While public signups are still open, have each `@veedoo.io` colleague register at `https://baserow.yourdomain.com`
2. As the Instance Admin (the first user, from Step 7), open the **Admin panel** (top-left avatar → **Admin**)
3. Go to **Users**
4. For every `@veedoo.io` user you want to be an admin:
   - Click the **⋮** menu on their row → **Edit**
   - Tick **Is staff** (this grants Instance Admin / full access to the admin panel)
   - Tick **Is active** (should already be on)
   - Save

Anyone with `is_staff = true` has full control of the instance, including future user management.

### 8b. Disable public signups

1. Still in **Admin panel** → **Settings**
2. Under **Account restrictions** turn **Allow creating new accounts** **OFF**
3. A new toggle appears: **Allow signups via workspace invitations**
   - Turn it **ON** if you want to invite future `@veedoo.io` colleagues via workspace invitation emails (they can self-register after clicking the invite link)
   - Turn it **OFF** if you want admins to manually create every future account (most restrictive)
4. Save

The signup page is now hidden. Anyone visiting `https://baserow.yourdomain.com` lands on the login form only.

### 8c. (Optional) Audit accounts

Periodically check **Admin panel** → **Users** and disable / delete any account whose email isn't `@veedoo.io`. There's no automated guard, so the audit is manual.

### 8d. (Optional, Enterprise license) Use SSO instead

If you have a Baserow Enterprise license, configure SSO (SAML / OIDC / OAuth2 with Google Workspace, Azure AD, Okta, etc.) under **Admin panel** → **Authentication providers**. The IdP then enforces the `@veedoo.io` restriction natively, and you can disable email + password login entirely. See [Baserow SSO docs](https://baserow.io/user-docs/single-sign-on-sso-overview).

---

## Step 9: Verify

### Check all containers are healthy

SSH into your server and run:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}" | grep baserow
```

You should see (with your `CONTAINER_PREFIX`):

```
baserow-caddy           Up X minutes (healthy)
baserow-backend         Up X minutes (healthy)
baserow-web-frontend    Up X minutes (healthy)
baserow-celery          Up X minutes (healthy)
baserow-celery-export   Up X minutes (healthy)
baserow-celery-beat     Up X minutes (healthy)
baserow-db              Up X minutes (healthy)
baserow-redis           Up X minutes (healthy)
```

`baserow-volume-fixer` should show `Exited (0)` — that's the one-shot init job, not a failure.

### Test the API

```bash
curl -s https://baserow.yourdomain.com/api/_health/ | jq
```

Should return `{"OK": true, "checks": {...}}`.

### Test email

Trigger a password reset from the login screen and confirm the email arrives. If not, see [SMTP troubleshooting](#auth-emails-not-sending).

---

## Production Hardening

### Back up the database

The Postgres data lives in the named volume `baserow_pgdata`. Add a Dokploy backup or a host-level cron:

```bash
docker exec baserow-db pg_dump -U baserow -d baserow -F c -f /tmp/baserow.dump
docker cp baserow-db:/tmp/baserow.dump ./baserow-$(date +%Y%m%d).dump
```

### Move uploaded files to S3

Set the `AWS_*` block in `baserow.env`. Existing files in the `media` volume won't migrate automatically — copy them across before switching, or only enable S3 on a fresh instance.

### Restrict admin panel to internal IPs

Dokploy supports IP allowlists on a per-domain basis (Domains tab → Advanced). Restrict the domain to your office / VPN ranges if the instance is internal-only.

### Pin the Baserow version

Keep `BASEROW_VERSION` pinned. When upgrading, read the [Baserow changelog](https://gitlab.com/baserow/baserow/-/blob/master/changelog.md) first — major versions may require a Postgres or migration step.

### Rotate secrets

- `DATABASE_PASSWORD` — requires recreating the db service with the new password and editing `pg_hba.conf` or doing an `ALTER USER` while the old password still works
- `REDIS_PASSWORD` — restart all services after updating
- `SECRET_KEY` — invalidates password-reset links and signed cookies (sessions survive if `BASEROW_JWT_SIGNING_KEY` is set separately)
- `BASEROW_JWT_SIGNING_KEY` — invalidates every active JWT, forcing all users to re-authenticate

---

## Troubleshooting

### Container `backend` keeps restarting

Check `docker logs <prefix>-backend --tail 100`. Common causes:

- **`relation "..." does not exist`** — migrations didn't run. Set `MIGRATE_ON_STARTUP=true` and restart the backend.
- **`could not connect to server: Connection refused`** — `db` isn't healthy yet; verify with `docker ps`. Postgres healthcheck has a 30 s `start_period`.
- **`Authentication credentials were not provided`** — `SECRET_KEY` mismatch between backend and one of the Celery workers. They share the same anchor, so this only happens if you override env per-service.

### Auth emails not sending

- Confirm `EMAIL_SMTP=True` (case matters — Django reads this as a boolean string)
- For Gmail/Workspace, you need an **App Password**, not your account password, and 2FA must be on
- For SES, the SMTP user is the **IAM access key ID**, password is the SES SMTP password (not the secret key)
- Test from inside the backend container:

```bash
docker exec -it baserow-backend python /baserow/backend/src/baserow/manage.py shell -c \
  "from django.core.mail import send_mail; send_mail('test', 'hi', 'baserow@yourdomain.com', ['you@veedoo.io'])"
```

If this raises `SMTPAuthenticationError`, the credentials are wrong. If it returns `1` but no mail arrives, check your SPF/DKIM and the provider's bounce log.

### Caddy returns 502 Bad Gateway

The backend or web-frontend isn't ready yet. Wait 30 s and refresh. If it persists:

```bash
docker logs baserow-caddy --tail 50
docker logs baserow-backend --tail 50
docker logs baserow-web-frontend --tail 50
```

Verify the backend health endpoint inside the network:

```bash
docker exec baserow-caddy wget -qO- http://backend:8000/api/_health/
```

### Login URL says "http" but I have HTTPS

Set `BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER=true` (already on by default in `baserow.env`) and confirm `BASEROW_PUBLIC_URL` starts with `https://`. Then redeploy.

### Uploaded files give 404

The `volume-permissions-fixer` container chowns the media volume to UID 9999 on first start. If you renamed the project or recreated the volume, the chown didn't run. Either redeploy from clean or run manually:

```bash
docker exec -u root baserow-backend chown -R 9999:9999 /baserow/media
```

### `pgvector` extension errors after upgrade

If you migrated from a non-pgvector Postgres image, the extension needs to be installed once:

```bash
docker exec -it baserow-db psql -U baserow -d baserow -c 'CREATE EXTENSION IF NOT EXISTS vector;'
```

### "Allow creating new accounts" toggle missing

You must be Instance Admin (`is_staff = true`) to see the **Admin panel** in the top-left avatar menu. The first user to register on a fresh instance gets `is_staff = true` automatically; if you nuked the database and re-registered, the new first user has admin rights.

---

## File Reference

| File | Purpose |
|------|---------|
| [`baserow-docker-compose.yml`](baserow-docker-compose.yml) | Full multi-service compose with the Caddyfile embedded via `configs:` |
| [`baserow.env`](baserow.env) | Pre-populated env file with secrets, SMTP, tuning knobs, and AI/storage toggles |
| [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md) | This guide |
| [`README.md`](README.md) | Architecture reference, env summary, security checklist |
