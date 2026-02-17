# Self-Hosted Supabase on Dokploy

Standalone Docker Compose templates for deploying Supabase on [Dokploy](https://dokploy.com). All configuration files (Kong routes, Vector logging, SQL init scripts, Supavisor pooler config) are embedded inline via Docker Compose `configs` -- just paste the compose YAML and env vars into Dokploy and deploy.

## Files

| File | Description |
|------|-------------|
| `supabase-docker-compose.yml` | Standard Supabase deployment. Works on any server. |
| `supabase.env` | Environment variables for the standard deployment. |
| `optimized-supabase-docker-compose.yml` | Production-optimized for Hetzner CCX33 (8 vCPU, 32GB RAM, NVMe SSD). Adds PostgreSQL tuning, `shm_size`, Docker log rotation, explicit service pool sizes. |
| `optimized-supabase.env` | Environment variables for the optimized deployment. Includes PG tuning params, Supavisor pool sizing for 2000 connections, Realtime scaling, and service connection budgets. |
| `kernel-tuning-notes.md` | Optional host-level kernel tuning (sysctl, hugepages, swap). Includes a full post-deployment verification checklist. |

**Which variant to use:**
- **Standard** -- Development, staging, or small production on any server.
- **Optimized** -- Production on Hetzner CCX33 or similar 8-core/32GB dedicated servers with NVMe storage. Targets 800 pooled connections, 500 concurrent Realtime users, and 300-1000 queries/sec.

## Quick Start (Standard)

1. In Dokploy, create a new **Compose** project.
2. Paste the contents of `supabase-docker-compose.yml` into the compose editor.
3. Paste the contents of `supabase.env` into the environment variables section.
4. Update these env vars at minimum:
   - `POSTGRES_PASSWORD` -- Strong random password
   - `JWT_SECRET` -- Strong random secret (min 32 chars)
   - `ANON_KEY` / `SERVICE_ROLE_KEY` -- Generate new JWTs signed with your `JWT_SECRET`
   - `SUPABASE_HOST` -- Your domain (e.g., `supabase.example.com`)
   - `API_EXTERNAL_URL` -- Full URL with scheme (e.g., `https://supabase.example.com`)
   - `SUPABASE_PUBLIC_URL` -- Same as `API_EXTERNAL_URL`
   - `POOLER_TENANT_ID` -- Unique identifier for your tenant (e.g., `my-project-prod`)
5. Deploy. All 12 containers should become healthy.

## Quick Start (Optimized for CCX33)

Same steps as above, but use `optimized-supabase-docker-compose.yml` and `optimized-supabase.env`.

Additional env vars to review:

| Variable | Default | Purpose |
|----------|---------|---------|
| `PG_SHARED_BUFFERS` | `6GB` | PostgreSQL shared memory (25% of RAM) |
| `PG_EFFECTIVE_CACHE_SIZE` | `18GB` | Planner hint for OS cache (75% of RAM) |
| `PG_MAX_CONNECTIONS` | `500` | Max direct PG connections |
| `POOLER_DEFAULT_POOL_SIZE` | `300` | Backend connections per Supavisor tenant |
| `POOLER_MAX_CLIENT_CONN` | `2000` | Max client connections through Supavisor |
| `RT_MAX_CONCURRENT_USERS` | `1000` | Realtime concurrent user ceiling |
| `PGRST_DB_POOL` | `15` | PostgREST connection pool |
| `GOTRUE_DB_POOL` | `15` | GoTrue (Auth) connection pool |

After deploying, optionally apply kernel tuning from [`kernel-tuning-notes.md`](kernel-tuning-notes.md).

## Adding a Domain (Studio + API Access)

After deploying, you need to add a domain to access Studio and the Supabase API.

### 1. DNS

Create an A record pointing to your server:

```
supabase.yourdomain.com  →  YOUR_SERVER_IP
```

### 2. Add domain in Dokploy

1. Go to your Supabase compose project in the Dokploy dashboard.
2. Navigate to the **Domains** tab.
3. Add a new domain:
   - **Domain**: `supabase.yourdomain.com`
   - **Service**: select the **Kong** service (container name ending in `-kong`)
   - **Port**: `8000`
   - **HTTPS**: Enable (Dokploy auto-provisions a Let's Encrypt certificate)
4. Save and wait for the certificate to provision.

### 3. Update env vars to match the domain

Update these environment variables in Dokploy, then redeploy:

```env
SUPABASE_HOST=supabase.yourdomain.com
API_EXTERNAL_URL=https://supabase.yourdomain.com
SUPABASE_PUBLIC_URL=https://supabase.yourdomain.com
ADDITIONAL_REDIRECT_URLS=https://supabase.yourdomain.com/*,https://yourapp.com/*
```

Once DNS propagates and the certificate is ready, access Studio at `https://supabase.yourdomain.com` (login with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`).

All Supabase APIs are also available through this domain (e.g., `https://supabase.yourdomain.com/rest/v1/`, `/auth/v1/`, `/storage/v1/`, `/realtime/v1/`).

## Security: Env Vars You Must Change

The `.env` files ship with placeholder secrets. **You must replace all of these before going to production.** Leaving defaults exposes your database and API to anyone.

| Variable | What to do |
|----------|------------|
| `POSTGRES_PASSWORD` | Generate a strong random password (32+ chars). Used by all internal services to connect to PostgreSQL. |
| `JWT_SECRET` | Generate a strong random secret (32+ chars). Used to sign and verify all JWTs. |
| `ANON_KEY` | Generate a new JWT with `role: anon`, signed with your new `JWT_SECRET`. See [Supabase JWT generator](https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys). |
| `SERVICE_ROLE_KEY` | Generate a new JWT with `role: service_role`, signed with your new `JWT_SECRET`. **This key bypasses RLS** -- never expose it client-side. |
| `DASHBOARD_USERNAME` | Change from `supabase` to your own username. |
| `DASHBOARD_PASSWORD` | Generate a strong random password. This protects access to Supabase Studio. |
| `SECRET_KEY_BASE` | Generate a random 64-char hex string. Used by Supavisor for encryption. |
| `VAULT_ENC_KEY` | Generate a random 32-char string. Used for Vault encryption. |
| `PG_META_CRYPTO_KEY` | Generate a random 32-char string. Used by Studio and Meta for metadata encryption. |
| `LOGFLARE_API_KEY` | Generate a random string. Used for log ingestion authentication. |
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | Generate a random string (can be same as `LOGFLARE_API_KEY`). |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | Generate a random string (can be same as above for self-hosted). |
| `POOLER_TENANT_ID` | Change from `your-tenant-id` to a unique identifier (e.g., `myproject-prod`). |
| `REALTIME_DB_ENC_KEY` | Generate a random **16-char** hex string. Must be exactly 16 bytes (AES-128). Used by Realtime for encryption. |

**Also update for production:**

| Variable | What to do |
|----------|------------|
| `SITE_URL` | Set to your application URL (e.g., `https://myapp.com`). Used for auth redirects. |
| `ADDITIONAL_REDIRECT_URLS` | Comma-separated list of allowed redirect URLs for auth. |
| `SMTP_*` | Configure real SMTP credentials. The defaults use a fake mail server that doesn't send real emails. |
| `ENABLE_EMAIL_AUTOCONFIRM` | Set to `false` for production (requires email verification). |
| `DISABLE_SIGNUP` | Set to `true` if you want to restrict new user registration. |

You can generate random secrets with:

```bash
# 32-char random string
openssl rand -base64 24

# 64-char random hex string
openssl rand -hex 32
```

## Configuration Reference

### Secrets (must change before production)

| Variable | Description |
|----------|-------------|
| `POSTGRES_PASSWORD` | PostgreSQL superuser password |
| `JWT_SECRET` | JWT signing secret (min 32 chars) |
| `ANON_KEY` | Anonymous role JWT (generate with your JWT_SECRET) |
| `SERVICE_ROLE_KEY` | Service role JWT (generate with your JWT_SECRET) |
| `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` | Supabase Studio login |
| `SECRET_KEY_BASE` | Supavisor encryption key |
| `VAULT_ENC_KEY` | Vault encryption key |
| `PG_META_CRYPTO_KEY` | Metadata encryption key (min 32 chars) |

### Domain and URLs

| Variable | Example | Description |
|----------|---------|-------------|
| `SUPABASE_HOST` | `supabase.example.com` | Hostname for Traefik routing |
| `API_EXTERNAL_URL` | `https://supabase.example.com` | Public API URL |
| `SUPABASE_PUBLIC_URL` | `https://supabase.example.com` | Studio public URL |
| `SITE_URL` | `https://myapp.com` | Your application URL (for auth redirects) |
| `ADDITIONAL_REDIRECT_URLS` | `https://myapp.com/*` | Comma-separated allowed redirect URLs |

### SMTP (required for email auth)

| Variable | Description |
|----------|-------------|
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | SMTP port (587 for TLS) |
| `SMTP_USER` | SMTP username |
| `SMTP_PASS` | SMTP password |
| `SMTP_ADMIN_EMAIL` | Sender email address |
| `SMTP_SENDER_NAME` | Display name for emails |

### Connection Pooling (Supavisor)

| Variable | Standard | Optimized | Description |
|----------|----------|-----------|-------------|
| `POOLER_DEFAULT_POOL_SIZE` | `20` | `60` | Backend PG connections per tenant |
| `POOLER_MAX_CLIENT_CONN` | `100` | `800` | Max client connections |
| `POOLER_TENANT_ID` | `your-tenant-id` | `baseloop-prod` | Unique tenant identifier |
| `POOLER_PROXY_PORT_TRANSACTION` | `6544` | `6544` | Transaction mode port |
| `POSTGRES_DIRECT_PORT` | `5435` | `5435` | Direct DB access (migrations) |

### Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | (generated) | Used by Vector and services to send logs |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | (generated) | Used by Studio for analytics queries |
| `LOG_MAX_SIZE` | `10m` | Docker log file max size (optimized only) |
| `LOG_MAX_FILE` | `3` | Docker log file count (optimized only) |

## Architecture

### Services (12 containers)

| Service | Image | Role |
|---------|-------|------|
| **db** | `supabase/postgres:17.6.1.081` | PostgreSQL 17 database |
| **kong** | `kong:2.8.1` | API gateway / reverse proxy |
| **auth** | `supabase/gotrue:v2.185.0` | Authentication (GoTrue) |
| **rest** | `postgrest/postgrest:v14.3` | RESTful API (PostgREST) |
| **realtime** | `supabase/realtime:v2.72.0` | WebSocket subscriptions |
| **storage** | `supabase/storage-api:v1.37.7` | File storage API |
| **imgproxy** | `darthsim/imgproxy:v3.30.1` | Image transformation |
| **meta** | `supabase/postgres-meta:v0.95.2` | Database metadata API |
| **studio** | `supabase/studio:2026.02.09-sha-18cc6f8` | Dashboard UI |
| **analytics** | `supabase/logflare:1.30.3` | Log analytics |
| **vector** | `timberio/vector:0.28.1-alpine` | Log collection |
| **supavisor** | `supabase/supavisor:2.7.4` | Connection pooler |

**Note:** Edge Functions (`supabase/edge-runtime`) is not included in these templates. If you need Deno Edge Functions, add the `functions` service back from the [official Supabase docker-compose](https://github.com/supabase/supabase/blob/master/docker/docker-compose.yml).

### Connection Flow

```
Client App (Prisma, Supabase JS, etc.)
  │
  ├─ API requests ──→ Kong (:8000) ──→ auth / rest / storage / realtime / meta / functions
  │
  ├─ Pooled DB ────→ Supavisor (:6544 transaction mode) ──→ PostgreSQL (:5432)
  │                  (800 clients → 60 backend connections)
  │
  └─ Direct DB ────→ PostgreSQL (:5435 mapped to :5432)
                     (for migrations only)
```

### Connection Budget (Optimized, max_connections=500)

| Consumer | Connections |
|----------|-------------|
| Supavisor pool | ~300 |
| PostgREST | ~15 |
| GoTrue (Auth) | ~15 |
| Realtime | 10-30 |
| Other services | 10-30 |
| **Headroom** | **~110** |

### Port Mapping

| Port | Service | Protocol |
|------|---------|----------|
| `8000` | Kong (HTTP API) | HTTP |
| `8443` | Kong (HTTPS API) | HTTPS |
| `3000` | Studio (Dashboard) | HTTP |
| `5432` | Supavisor (session mode) | PostgreSQL |
| `6544` | Supavisor (transaction mode) | PostgreSQL |
| `5435` | PostgreSQL (direct access) | PostgreSQL |

## Kernel Tuning (Optional)

For production on dedicated servers, host-level kernel optimizations can further improve performance. See [`kernel-tuning-notes.md`](kernel-tuning-notes.md) for:

- **sysctl settings** -- `vm.swappiness`, `vm.overcommit_memory`, `net.core.somaxconn`, `fs.file-max`
- **Huge pages** -- Pre-allocate for PostgreSQL shared_buffers
- **Swap** -- Recommended to disable on dedicated DB servers

These are optional. The compose files work without them.

## Post-Deployment Verification

After deploying, verify your setup works correctly. See [`kernel-tuning-notes.md`](kernel-tuning-notes.md) for the full checklist with SQL queries, including:

1. All 12 containers healthy
2. PostgreSQL tuning parameters applied correctly
3. Connection usage within budget
4. Supavisor pooler accepting connections
5. Realtime tenant limits configured
6. Prisma connection strings (external and Dokploy-internal)

Quick smoke test:

```bash
# Check all containers are healthy
docker compose ps

# Verify PostgreSQL version
psql "postgresql://postgres:YOUR_PASSWORD@SERVER_IP:5435/postgres" -c "SELECT version();"

# Test pooler
psql "postgresql://postgres.YOUR_TENANT:YOUR_PASSWORD@SERVER_IP:6544/postgres?pgbouncer=true" -c "SELECT 1;"
```

## PostgreSQL 17 Upgrade Notes

These templates use PostgreSQL 17 (`supabase/postgres:17.6.1.081`).

### New deployments

Just deploy as-is. PG17 initializes a fresh data directory.

### Upgrading from PG15

PG15 and PG17 data formats are **incompatible**. You cannot just change the image tag.

**Option 1: pg_dump/restore** (simplest for small databases)

```bash
# Dump from PG15
pg_dump -Fc "postgresql://postgres:PASSWORD@SERVER:5435/postgres" > backup.dump

# Remove old data directory
rm -rf /path/to/pgdata

# Start PG17 container (fresh init)
# Restore
pg_restore -d "postgresql://postgres:PASSWORD@SERVER:5435/postgres" backup.dump
```

**Option 2: pg_upgrade** (faster for large databases)

Requires both PG15 and PG17 binaries. See [Supabase upgrade docs](https://supabase.com/docs/guides/platform/upgrading).

### PG17 breaking changes

- **Authentication**: Supabase prefers `scram-sha-256` over `md5`. Custom roles may need password reset.
- **Logical replication**: Slots are NOT preserved during major version upgrades.
- **Expression indexes**: May need explicit `search_path` on referenced functions.

## Troubleshooting

### Containers keep restarting

Check logs for the failing container:

```bash
docker compose logs <service-name> --tail 100
```

Common causes:
- **db**: Wrong `POSTGRES_PASSWORD` or corrupted data directory
- **analytics**: Token errors -- ensure `LOGFLARE_PUBLIC_ACCESS_TOKEN` and `LOGFLARE_PRIVATE_ACCESS_TOKEN` are set
- **meta**: Missing `PG_META_CRYPTO_KEY`
- **kong**: Config syntax error in inline kong.yml

### Studio can't connect

- Verify `SUPABASE_PUBLIC_URL` matches your actual domain with correct scheme (http/https)
- Check Kong is healthy and routing correctly
- Ensure `PG_META_CRYPTO_KEY` is set in the env

### Pooler connection refused

- Verify `POOLER_TENANT_ID` is set to a real value (not `your-tenant-id`)
- Check Supavisor logs: `docker compose logs supavisor`
- Ensure the pooler init script ran successfully (check for `_supavisor` schema in the database)

### PostgREST schema errors

PostgREST v14 validates schemas on startup. If `PGRST_DB_SCHEMAS` references a schema that doesn't exist, it will fail. Default is `public,storage,graphql_public` which all exist in a standard Supabase setup.

### Realtime hitting connection limits

If Realtime shows "too many connections":
1. Check connection usage: `SELECT usename, count(*) FROM pg_stat_activity GROUP BY usename;`
2. Reduce other service pools if needed
3. Consider increasing `PG_MAX_CONNECTIONS` (requires restart)
