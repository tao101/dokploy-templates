# Deploying Supabase to Dokploy — Step-by-Step Guide

This guide walks you through deploying a self-hosted Supabase instance on Dokploy from start to finish. Everything is standalone — just paste the compose YAML and env vars into Dokploy, no extra files needed.

## Prerequisites

- A server with [Dokploy](https://dokploy.com) installed
- A domain (or subdomain) you control, e.g. `supabase.yourdomain.com`
- SSH access to your server (for verification commands)

## Choose Your Variant

| Variant | File | Best for |
|---------|------|----------|
| **Standard** | `supabase-docker-compose.yml` + `supabase.env` | Dev, staging, or small production on any server |
| **Optimized** | `optimized-supabase-docker-compose.yml` + `optimized-supabase.env` | Production on Hetzner CCX33 or similar 8-core/32GB dedicated servers |

If unsure, start with **Standard**. You can switch later by replacing the compose and env files.

---

## Step 1: Generate Secrets

You need unique secrets for your deployment. Run these commands on any machine with `openssl`:

```bash
# Generate POSTGRES_PASSWORD (32 chars)
openssl rand -base64 24

# Generate JWT_SECRET (32 chars)
openssl rand -base64 24

# Generate DASHBOARD_PASSWORD
openssl rand -base64 24

# Generate SECRET_KEY_BASE (64-char hex)
openssl rand -hex 32

# Generate VAULT_ENC_KEY (32 chars)
openssl rand -base64 24

# Generate PG_META_CRYPTO_KEY (32 chars)
openssl rand -base64 24

# Generate LOGFLARE tokens (use same value for all three)
openssl rand -base64 24

# Generate REALTIME_DB_ENC_KEY (exactly 16 hex chars — optimized variant only)
openssl rand -hex 8
```

Save all generated values somewhere safe. You'll paste them into env vars in Step 4.

### Generate JWT Keys (ANON_KEY and SERVICE_ROLE_KEY)

These are JWTs signed with your `JWT_SECRET`. Use the [Supabase JWT Generator](https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys) or generate them manually:

**ANON_KEY payload:**
```json
{
  "iat": 1700000000,
  "exp": 1893456000,
  "role": "anon",
  "iss": "supabase"
}
```

**SERVICE_ROLE_KEY payload:**
```json
{
  "iat": 1700000000,
  "exp": 1893456000,
  "role": "service_role",
  "iss": "supabase"
}
```

Sign both with HS256 using your `JWT_SECRET`. You can use [jwt.io](https://jwt.io) to create them:
1. Set Algorithm to **HS256**
2. Edit the payload with the JSON above
3. Paste your `JWT_SECRET` into the "Verify Signature" secret field
4. Copy the encoded token

---

## Step 2: Create a Compose Project in Dokploy

1. Log into your Dokploy dashboard
2. Click **Create Project**
3. Give it a name (e.g. "Supabase")
4. Inside the project, click **Create Service** > **Compose**
5. Give the service a name (e.g. "supabase-stack")

---

## Step 3: Paste the Compose YAML

1. Open the compose service you just created
2. Go to the **Compose** tab (or the compose editor)
3. Copy the **entire contents** of your chosen compose file:
   - Standard: `supabase-docker-compose.yml`
   - Optimized: `optimized-supabase-docker-compose.yml`
4. Paste it into the Dokploy compose editor
5. Save (don't deploy yet)

---

## Step 4: Configure Environment Variables

1. Go to the **Environment** tab of your compose service
2. Copy the **entire contents** of your chosen env file:
   - Standard: `supabase.env`
   - Optimized: `optimized-supabase.env`
3. Paste it into the environment variables section
4. **Replace the following values** with your generated secrets:

### Required Changes

| Variable | What to set |
|----------|-------------|
| `CONTAINER_PREFIX` | A unique prefix for your containers (e.g. `myapp-supabase`). Dokploy may auto-generate this. |
| `POSTGRES_PASSWORD` | Your generated password |
| `JWT_SECRET` | Your generated JWT secret |
| `ANON_KEY` | Your generated anon JWT |
| `SERVICE_ROLE_KEY` | Your generated service_role JWT |
| `DASHBOARD_USERNAME` | Change from `supabase` to your username |
| `DASHBOARD_PASSWORD` | Your generated password |
| `SECRET_KEY_BASE` | Your generated 64-char hex string |
| `VAULT_ENC_KEY` | Your generated 32-char string |
| `PG_META_CRYPTO_KEY` | Your generated 32-char string |
| `LOGFLARE_PUBLIC_ACCESS_TOKEN` | Your generated token |
| `LOGFLARE_PRIVATE_ACCESS_TOKEN` | Same as above (for self-hosted) |
| `POOLER_TENANT_ID` | A unique identifier like `myproject-prod` |

### Domain Variables (set now or update after Step 6)

| Variable | Example |
|----------|---------|
| `SUPABASE_HOST` | `supabase.yourdomain.com` |
| `API_EXTERNAL_URL` | `https://supabase.yourdomain.com` |
| `SUPABASE_PUBLIC_URL` | `https://supabase.yourdomain.com` |
| `SITE_URL` | `https://yourapp.com` (your frontend app URL) |
| `ADDITIONAL_REDIRECT_URLS` | `https://supabase.yourdomain.com/*,https://yourapp.com/*` |

### Optimized Variant Only

If using the optimized variant, also review these (defaults are tuned for CCX33):

| Variable | Default | Purpose |
|----------|---------|---------|
| `PG_SHARED_BUFFERS` | `6GB` | 25% of RAM |
| `PG_EFFECTIVE_CACHE_SIZE` | `18GB` | 75% of RAM |
| `PG_MAX_CONNECTIONS` | `500` | Max direct PG connections |
| `POOLER_DEFAULT_POOL_SIZE` | `300` | Backend connections per tenant |
| `POOLER_MAX_CLIENT_CONN` | `2000` | Max client connections via Supavisor |
| `REALTIME_DB_ENC_KEY` | (must generate) | 16-char hex string |

5. Save the environment variables

---

## Step 5: Deploy

1. Click **Deploy** in Dokploy
2. Watch the logs — all 12 containers need to start and pass health checks
3. This typically takes 1-3 minutes for all services to become healthy
4. The startup order is: vector > db > analytics > (auth, rest, meta, realtime, storage, imgproxy, kong, studio, supavisor)

If any container keeps restarting, check its logs in the Dokploy UI. Common issues:
- **db**: Wrong `POSTGRES_PASSWORD` or corrupted data directory
- **analytics**: Missing or wrong `LOGFLARE_PUBLIC_ACCESS_TOKEN` / `LOGFLARE_PRIVATE_ACCESS_TOKEN`
- **kong**: Config syntax error (usually a quoting issue)
- **supavisor**: `POOLER_TENANT_ID` still set to `your-tenant-id`

---

## Step 6: Add a Domain

### 6a. Create DNS Record

Create an A record pointing your subdomain to your server's IP:

```
supabase.yourdomain.com  →  YOUR_SERVER_IP
```

### 6b. Add Domain in Dokploy

1. Go to your Supabase compose project in the Dokploy dashboard
2. Navigate to the **Domains** tab
3. Click **Add Domain**:
   - **Domain**: `supabase.yourdomain.com`
   - **Service**: Select the **Kong** service (container name ending in `-kong`)
   - **Port**: `8000`
   - **HTTPS**: Enable (Dokploy auto-provisions a Let's Encrypt certificate)
4. Save and wait for the certificate to provision

### 6c. Update Environment Variables

Update these env vars to match your domain, then **redeploy**:

```env
SUPABASE_HOST=supabase.yourdomain.com
API_EXTERNAL_URL=https://supabase.yourdomain.com
SUPABASE_PUBLIC_URL=https://supabase.yourdomain.com
ADDITIONAL_REDIRECT_URLS=https://supabase.yourdomain.com/*,https://yourapp.com/*
```

---

## Step 7: Verify

### Check all containers are healthy

SSH into your server and run:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}" | grep supabase
```

All 12 containers should show `(healthy)`.

### Test direct database access

```bash
psql "postgresql://postgres:YOUR_PASSWORD@YOUR_SERVER_IP:5435/postgres" \
  -c "SELECT version();"
```

### Test pooler (Supavisor)

```bash
psql "postgresql://postgres.YOUR_TENANT_ID:YOUR_PASSWORD@YOUR_SERVER_IP:6544/postgres?pgbouncer=true" \
  -c "SELECT 1 AS pooler_ok;"
```

### Access Studio

Open `https://supabase.yourdomain.com` in your browser. Log in with your `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD`.

### Test the API

```bash
curl -s https://supabase.yourdomain.com/rest/v1/ \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Authorization: Bearer YOUR_ANON_KEY"
```

---

## Connecting Your App

### Supabase JS Client

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://supabase.yourdomain.com',
  'YOUR_ANON_KEY'
)
```

### Prisma (External — from outside Dokploy)

```env
# Transaction mode pooler (runtime queries)
DATABASE_URL="postgresql://postgres.YOUR_TENANT_ID:YOUR_PASSWORD@YOUR_SERVER_IP:6544/postgres?pgbouncer=true"

# Direct DB (migrations only)
DIRECT_URL="postgresql://postgres:YOUR_PASSWORD@YOUR_SERVER_IP:5435/postgres"
```

### Prisma (Internal — from another Dokploy service)

Use container names instead of server IP:

```env
# Transaction mode pooler (runtime queries)
DATABASE_URL="postgresql://postgres.YOUR_TENANT_ID:YOUR_PASSWORD@CONTAINER_PREFIX-pooler:6543/postgres?pgbouncer=true"

# Direct DB (migrations only)
DIRECT_URL="postgresql://postgres:YOUR_PASSWORD@CONTAINER_PREFIX-db:5432/postgres"
```

Replace `CONTAINER_PREFIX` with your actual container prefix value. Both the app and Supabase must be on the `dokploy-network`.

### API Endpoints

All available through your domain:

| Endpoint | URL |
|----------|-----|
| REST API | `https://supabase.yourdomain.com/rest/v1/` |
| Auth | `https://supabase.yourdomain.com/auth/v1/` |
| Storage | `https://supabase.yourdomain.com/storage/v1/` |
| Realtime | `wss://supabase.yourdomain.com/realtime/v1/` |
| GraphQL | `https://supabase.yourdomain.com/graphql/v1` |

---

## Production Hardening

### Configure SMTP (required for email auth)

Replace the placeholder SMTP values in your env:

```env
SMTP_HOST=smtp.youremailprovider.com
SMTP_PORT=587
SMTP_USER=your-smtp-user
SMTP_PASS=your-smtp-password
SMTP_ADMIN_EMAIL=noreply@yourdomain.com
SMTP_SENDER_NAME=YourApp
```

### Lock down signups

```env
DISABLE_SIGNUP=true              # Block new registrations
ENABLE_EMAIL_AUTOCONFIRM=false   # Require email verification
```

### Kernel tuning (optimized variant, dedicated servers)

For production on dedicated servers, apply host-level optimizations. See [`kernel-tuning-notes.md`](kernel-tuning-notes.md) for sysctl settings, huge pages, and swap configuration.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Container keeps restarting | Check logs: in Dokploy UI or `docker logs CONTAINER_NAME --tail 100` |
| Studio can't connect | Verify `SUPABASE_PUBLIC_URL` matches your domain with correct scheme (http/https) |
| Pooler connection refused | Ensure `POOLER_TENANT_ID` is not still `your-tenant-id`; check supavisor logs |
| Auth emails not sending | Configure real SMTP credentials (defaults use a fake mail server) |
| "too many connections" | Check connection usage with `SELECT usename, count(*) FROM pg_stat_activity GROUP BY usename;` |
| PostgREST fails on startup | Ensure all schemas in `PGRST_DB_SCHEMAS` exist (`public,storage,graphql_public`) |
| Kong startup error | Usually a config quoting issue — check kong logs for YAML parse errors |

For detailed configuration reference and architecture diagrams, see [`README.md`](README.md).
