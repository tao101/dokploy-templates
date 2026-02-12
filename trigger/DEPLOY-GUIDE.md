# Trigger.dev Distributed Deployment Guide (Dokploy)

Deploy Trigger.dev v4 with a separate webapp server and worker server(s) using Dokploy.

## Architecture

```
[Webapp Server]                         [Worker Server]
trigger:3000 (HTTPS, public)  <------   supervisor (connects via TRIGGER_API_URL)
postgres:5432                           supervisor:8020 (workload API)
redis:6379                     ------>  (webapp calls supervisor:8020)
clickhouse:8123                         docker-proxy:2375
electric:3000                           /var/run/docker.sock
minio:9000                              |
registry:5000 (HTTPS, public)           task containers (spawned)
```

**Communication flow:**
- **Worker -> Webapp**: HTTPS via public `TRIGGER_API_URL` (no firewall issue)
- **Webapp -> Worker**: HTTP to supervisor port 8020 (needs firewall rule on worker server)
- **Worker -> Registry**: HTTPS via public `DOCKER_REGISTRY_URL` (pulls task images)

## Prerequisites

- Two servers (or more for multiple workers)
- Dokploy installed on both servers
- DNS records pointing to both servers:
  - `trigger.yourdomain.com` -> Webapp server IP
  - `registry.yourdomain.com` -> Webapp server IP
- Docker installed on both servers (Dokploy handles this)

## Step 1: Prepare the Webapp Server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first (system updates, Dokploy install, Docker daemon tuning, kernel params, file descriptors, swap, firewall, NTP).
2. Then run **`server-setup-webapp.md`** on the webapp server for any remaining app-specific tuning.

If you already ran `SERVER-SETUP.md`, all base kernel tuning is done — `server-setup-webapp.md` has no additional required steps beyond the shared guide.

Verify output shows all expected values.

## Step 2: Deploy Webapp on Dokploy

### 2.1 Create Compose Project

1. In Dokploy UI, go to **Projects** -> **Create Project**
2. Name it `trigger-webapp` (or similar)
3. Inside the project, create a new **Compose** service
4. Set **Source** to "Raw" (paste compose directly)

### 2.2 Paste Compose File

Copy the entire contents of `trigger-webapp-docker-compose.yml` into the compose editor.

### 2.3 Configure Environment Variables

1. Go to the **Environment** tab of the compose service
2. Copy the contents of `trigger-webapp.env`
3. Paste into the environment variables section

### 2.4 Secrets

The env file comes with pre-generated secrets. If you want to regenerate any, run:

```bash
openssl rand -base64 32
```

**Important:** `MANAGED_WORKER_SECRET` and `REGISTRY_PASSWORD` must match between webapp and worker env files. The provided files already have matching values.

### 2.5 Select Hardware Tier

In the env vars, uncomment ONE tier section for PostgreSQL, Redis, and resource limits matching your server:

| Tier | Server | PG_SHARED_BUFFERS | REDIS_MAXMEMORY |
|------|--------|-------------------|-----------------|
| 1 | 4 vCPU, 16GB RAM | 4GB | 6gb |
| 2 | 8 vCPU, 32GB RAM | 8GB | 12gb |
| 3 | 16 vCPU, 64GB RAM | 16GB | 24gb |
| 4 | 32 vCPU, 128GB RAM | 32GB | 48gb |

### 2.6 Deploy

Click **Deploy**. Wait for all services to start (first deploy takes a few minutes as images are pulled).

Check logs for the trigger service - it should show startup messages and eventually print the worker token.

## Step 3: Configure Domains

After the first deploy succeeds, add domains in the Dokploy UI.

### 3.1 Trigger Webapp Domain

1. In Dokploy, go to your compose service -> **Domains**
2. Click **Add Domain**
3. Configure:
   - **Domain**: `trigger.yourdomain.com`
   - **Service Name**: `trigger` (the service name in the compose file)
   - **Container Port**: `3000`
   - **HTTPS**: Enabled (Traefik auto-provisions SSL via Let's Encrypt)

### 3.2 Registry Domain

1. Click **Add Domain** again
2. Configure:
   - **Domain**: `registry.yourdomain.com`
   - **Service Name**: `registry`
   - **Container Port**: `5000`
   - **HTTPS**: Enabled

### 3.3 Update Environment Variables

Update these env vars to match your domains:

```
TRIGGER_DOMAIN=trigger.yourdomain.com
REGISTRY_DOMAIN=registry.yourdomain.com
```

### 3.4 Redeploy

Redeploy the compose service so the trigger app picks up the correct domain URLs.

### 3.5 Verify

- Visit `https://trigger.yourdomain.com` - you should see the Trigger.dev login page
- Test registry: `curl -s https://registry.yourdomain.com/v2/` should return `{}`

## Step 4: Get Worker Token

After the webapp is running, retrieve the worker token from the trigger container logs:

```bash
# Find the trigger container
docker ps | grep trigger-webapp-trigger

# Get the worker token
docker logs <trigger-container-name> 2>&1 | grep -A15 "Worker Token"
```

Copy the `TRIGGER_WORKER_TOKEN` value (starts with `tr_wgt_`).

If you don't see the worker token in the logs, you can also find it in the Trigger.dev dashboard under **Settings** -> **Workers**.

## Step 5: Prepare the Worker Server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first (system updates, Dokploy install, Docker daemon tuning, kernel params, file descriptors, swap, firewall, NTP).
2. Then run **`server-setup-worker.md`** on the worker server for worker-specific tuning: ephemeral port range expansion (`ip_local_port_range`) and port 8020 firewall rules.

Replace `WEBAPP_IP` with your webapp server's actual IP address in the firewall commands.

Verify output shows all expected values and firewall rules are applied.

## Step 6: Deploy Worker on Dokploy

### 6.1 Create Compose Project

1. In Dokploy UI **on the worker server**, go to **Projects** -> **Create Project**
2. Name it `trigger-worker`
3. Inside the project, create a new **Compose** service
4. Set **Source** to "Raw"

### 6.2 Paste Compose File

Copy the entire contents of `trigger-worker-docker-compose.yml` into the compose editor.

### 6.3 Configure Environment Variables

1. Go to the **Environment** tab
2. Copy the contents of `trigger-worker.env`
3. Paste into the environment variables section

### 6.4 Set Required Values

Update these values:

| Variable | Value | Source |
|----------|-------|--------|
| `TRIGGER_API_URL` | `https://trigger.yourdomain.com` | Your webapp domain from Step 3 |
| `TRIGGER_WORKER_TOKEN` | `tr_wgt_xxxxx` | From Step 4 |
| `DOCKER_REGISTRY_URL` | `https://registry.yourdomain.com` | Your registry domain from Step 3 |

**Note:** `MANAGED_WORKER_SECRET` and `REGISTRY_PASSWORD` are pre-filled and already match the webapp env file. `DOCKER_RUNNER_NETWORKS` is hardcoded to `dokploy-network` in the compose file — no configuration needed.

### 6.5 Deploy

Click **Deploy**. Check the supervisor logs:

```bash
docker logs <trigger-worker-supervisor-container> 2>&1 | tail -50
```

You should see it connect to the webapp and start polling for work.

## Step 7: Verify Cross-Server Connectivity

### 7.1 Worker -> Webapp (HTTPS)

From the worker server, verify it can reach the webapp:

```bash
curl -s https://trigger.yourdomain.com/api/v1/health
```

Should return a 200 response. This is the public HTTPS endpoint - no special firewall rules needed.

### 7.2 Webapp -> Worker Supervisor (Port 8020)

The webapp needs to reach the supervisor's workload API on port 8020. The worker compose publishes this port to the host (`ports: ["8020:8020"]`), and the firewall rule from `server-setup-worker.md` restricts access to the webapp IP only.

From the webapp server, verify connectivity:

```bash
curl -s http://<worker-server-ip>:8020/health
```

Should return a 200 response. If it times out, check:
- Firewall on worker server allows webapp IP on port 8020 (set in `server-setup-worker.md`)
- The supervisor container is running and healthy
- Port 8020 is published (verify with `docker port <supervisor-container>`)

### 7.3 Worker -> Registry (HTTPS)

From the worker server, verify it can pull images:

```bash
curl -s https://registry.yourdomain.com/v2/
```

Should return `{}`.

### 7.4 Check Supervisor Logs

The supervisor logs should show:

```
Connected to webapp at https://trigger.yourdomain.com
Polling for work...
```

If you see connection errors, verify `TRIGGER_API_URL` and `TRIGGER_WORKER_TOKEN`.

## Step 8: Optional Configuration

### Email (Magic Link Login)

To enable email login, set these in the webapp env:

```
WHITELISTED_EMAILS=user@yourdomain.com
EMAIL_TRANSPORT=resend
FROM_EMAIL=noreply@yourdomain.com
RESEND_API_KEY=re_xxxxxxxxxxxx
```

### Alerts

Alerts reuse the email settings above. No separate alert configuration needed.

### Slack Integration

```
ORG_SLACK_INTEGRATION_CLIENT_ID=your-client-id
ORG_SLACK_INTEGRATION_CLIENT_SECRET=your-client-secret
```

### Admin Auto-Promotion

```
ADMIN_EMAILS=.*@yourcompany\.com
```

### Backups

Set `BACKUP_ENABLED=true` and configure S3 storage:

```
BACKUP_S3_ENDPOINT=https://s3.amazonaws.com
BACKUP_S3_BUCKET=my-trigger-backups
BACKUP_S3_ACCESS_KEY_ID=your-access-key
BACKUP_S3_SECRET_ACCESS_KEY=your-secret-key
BACKUP_S3_REGION=us-east-1
```

## Troubleshooting

### Supervisor can't connect to webapp

**Symptom:** Supervisor logs show connection refused or timeout to TRIGGER_API_URL.

**Fix:**
- Verify `TRIGGER_API_URL` is correct and accessible from worker server
- Check DNS resolution: `nslookup trigger.yourdomain.com` from worker server
- Verify the webapp's trigger service is running: `docker ps | grep trigger`

### Webapp can't reach supervisor on port 8020

**Symptom:** Tasks stay in "queued" state, never start executing.

**Fix:**
- Check firewall on worker server: `sudo ufw status` (or `firewall-cmd --list-all`)
- Verify webapp IP is allowed on port 8020
- Test from webapp server: `curl http://<worker-ip>:8020/health`
- Check supervisor is running: `docker ps | grep supervisor`

### Worker token invalid

**Symptom:** Supervisor logs show authentication errors.

**Fix:**
- Re-check the token from webapp logs: `docker logs <trigger-container> 2>&1 | grep -A15 "Worker Token"`
- Ensure no extra whitespace in the env var
- The token is generated on first webapp boot - if you recreated the database, you need a new token

### Task containers can't pull images

**Symptom:** Tasks fail with "image pull" errors.

**Fix:**
- Verify `DOCKER_REGISTRY_URL` matches the webapp's registry domain
- Verify `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` match webapp values
- Test: `docker login registry.yourdomain.com -u trigger -p <password>`

### ClickHouse not starting

**Symptom:** ClickHouse container exits or restarts repeatedly.

**Fix:**
- Check `ulimit -n` on the host is at least 262144
- Verify `fs.file-max` sysctl: `sysctl fs.file-max` (should be 2097152)
- Check ClickHouse logs: `docker logs <clickhouse-container>`

### PostgreSQL performance issues

**Symptom:** Slow queries, high CPU on database.

**Fix:**
- Ensure you selected the correct tier for your server size
- Check shared_buffers is set correctly: `docker exec <pg-container> psql -U postgres -c "SHOW shared_buffers;"`
- If using huge pages, verify: `sysctl vm.nr_hugepages` (uncomment in server-setup-webapp.md)
- Monitor connections: `docker exec <pg-container> psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"`

### Redis warnings in logs

**Symptom:** Redis logs show "WARNING Memory overcommit must be enabled!"

**Fix:**
- Verify `vm.overcommit_memory=1`: `sysctl vm.overcommit_memory`
- If not set, run: `sudo sysctl -w vm.overcommit_memory=1` and add to `/etc/sysctl.conf`

## File Reference

| File | Purpose |
|------|---------|
| `trigger-webapp-docker-compose.yml` | Webapp compose (trigger, postgres, redis, clickhouse, electric, minio, registry, backups) |
| `trigger-webapp.env` | Webapp environment with pre-generated secrets and tiered hardware tuning |
| `trigger-worker-docker-compose.yml` | Worker compose (supervisor, docker-proxy) |
| `trigger-worker.env` | Worker environment with matching secrets and scaling settings |
| `server-setup-webapp.md` | Host kernel tuning commands for webapp server |
| `server-setup-worker.md` | Host kernel tuning + firewall commands for worker server |
| `DEPLOY-GUIDE.md` | This guide |
