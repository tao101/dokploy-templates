# Trigger.dev Distributed Deployment Guide — External Databases (Dokploy Swarm)

Deploy Trigger.dev v4 with databases on a dedicated server, the webapp as a Dokploy Stack (Docker Swarm with replicas), and multiple workers on remote servers.

## Architecture

```
[DB Server - 8vCPU/32GB]           [Webapp Server - Swarm Stack]         [Worker Servers x4 - 8vCPU/32GB each]
trigger-dbs (Compose)              trigger-webapp (Stack)                trigger-worker (Compose)
  postgres ──┐                       trigger:3000 (replicas)  <──────── supervisor:8020
  redis ─────┤  dokploy-network      registry:5000 (1 replica)          docker-proxy
  clickhouse ┤  (overlay aliases)    |                                   task containers
  electric ──┤  ─────────────────>   connects via aliases:
  minio ─────┘                       trigger-postgres
                                     trigger-redis
                                     trigger-clickhouse
                                     trigger-electric
                                     trigger-minio
```

**Deployment modes:**
- **Databases**: Dokploy **Compose** (`docker compose up`) — stateful, single server
- **Webapp**: Dokploy **Stack** (`docker stack deploy`) — stateless, Swarm replicas
- **Workers**: Dokploy **Compose** (`docker compose up`) — one per remote server

**Communication flow:**
- **Webapp -> DBs**: Via `dokploy-network` overlay aliases (no public ports needed)
- **Worker -> Webapp**: HTTPS via public `TRIGGER_API_URL` (no firewall issue)
- **Webapp -> Worker**: HTTP to supervisor port 8020 (needs firewall rule on each worker server)
- **Worker -> Registry**: HTTPS via public `DOCKER_REGISTRY_URL` (pulls task images)

## Prerequisites

- Minimum 6 servers (1 DB + 1 webapp + 4 workers), all in the **same Dokploy Swarm cluster**
- Dokploy installed on all servers with Swarm mode enabled
- `dokploy-network` must be an overlay network (Dokploy creates this automatically in Swarm mode)
- DNS records:
  - `trigger.yourdomain.com` -> Webapp server IP
  - `registry.yourdomain.com` -> Webapp server IP

## Shared Secrets Reference

These secrets must be identical across env files:

| Secret | `trigger-dbs.env` | `trigger-webapp.env` | `trigger-worker.env` |
|--------|:--:|:--:|:--:|
| `POSTGRES_PASSWORD` | Yes | Yes | - |
| `CLICKHOUSE_PASSWORD` | Yes | Yes | - |
| `MINIO_PASSWORD` | Yes | Yes | - |
| `ELECTRIC_SECRET` | Yes | - | - |
| `MANAGED_WORKER_SECRET` | - | Yes | Yes |
| `REGISTRY_PASSWORD` | - | Yes | Yes |

The provided env files already have matching pre-generated secrets. If you regenerate any, update all env files that reference it.

## Step 1: Prepare the Database Server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first (system updates, Dokploy install, Docker daemon tuning, kernel params, file descriptors, swap, firewall, NTP).
2. Then run **`server-setup-dbs.md`** on the DB server for database-specific tuning: `vm.overcommit_memory=1` (Redis), high `fs.file-max` (ClickHouse), huge pages (PostgreSQL).

Verify output shows all expected values.

## Step 2: Deploy Databases on Dokploy

### 2.1 Create Compose Project

1. In Dokploy UI, go to **Projects** -> **Create Project**
2. Name it `trigger-dbs` (or similar)
3. Inside the project, create a new **Compose** service
4. Set **Source** to "Raw" (paste compose directly)

### 2.2 Paste Compose File

Copy the entire contents of `trigger-dbs-docker-compose.yml` into the compose editor.

### 2.3 Configure Environment Variables

1. Go to the **Environment** tab of the compose service
2. Copy the contents of `trigger-dbs.env`
3. Paste into the environment variables section

### 2.4 Deploy

Click **Deploy**. Wait for all 5 services to become healthy (first deploy takes a few minutes as images are pulled).

### 2.5 Verify Database Health

Check that all services are healthy:

```bash
docker ps --filter "name=trigger-dbs" --format "table {{.Names}}\t{{.Status}}"
```

Expected: all 5 containers showing `(healthy)`.

### 2.6 Verify Network Aliases

From any node in the Swarm cluster, verify the aliases are resolvable on `dokploy-network`:

```bash
# Create a temporary container on dokploy-network to test alias resolution
docker run --rm --network dokploy-network alpine nslookup trigger-postgres
docker run --rm --network dokploy-network alpine nslookup trigger-redis
docker run --rm --network dokploy-network alpine nslookup trigger-clickhouse
docker run --rm --network dokploy-network alpine nslookup trigger-electric
docker run --rm --network dokploy-network alpine nslookup trigger-minio
```

All should resolve to an IP address. If any fail, the DB compose may not have deployed correctly.

## Step 3: Prepare the Webapp Server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first.
2. Then run **`server-setup-webapp.md`** — lighter tuning since no databases run here.

## Step 4: Deploy Webapp as Dokploy Stack

The webapp is deployed as a **Stack** (not Compose) to enable Docker Swarm replicas for high availability.

### 4.1 Create Stack Project

1. In Dokploy UI **on the webapp server**, go to **Projects** -> **Create Project**
2. Name it `trigger-webapp` (or similar)
3. Inside the project, create a new **Stack** service (NOT Compose)
4. Set **Source** to "Raw"

### 4.2 Paste Compose File

Copy the entire contents of `trigger-webapp-docker-compose.yml` into the stack editor.

### 4.3 Configure Environment Variables

1. Go to the **Environment** tab
2. Copy the contents of `trigger-webapp.env`
3. Paste into the environment variables section

### 4.4 First Deploy — Single Replica

**Important:** For the first deploy, ensure `TRIGGER_REPLICAS=1` in the env vars. This is already the default in `trigger-webapp.env`.

The single-replica first deploy is required to:
1. Run Prisma database migrations (only one instance should run migrations)
2. Generate the bootstrap worker token
3. Write the token to the shared volume

Click **Deploy**. The trigger app will connect to the external databases via `dokploy-network` aliases.

### 4.5 Verify First Deploy

Check the Swarm service status:

```bash
# List stack services
docker service ls --filter "name=trigger-webapp"

# Check trigger service logs
docker service logs trigger-webapp_trigger --tail 100

# Look for successful startup and worker token
docker service logs trigger-webapp_trigger 2>&1 | grep -A15 "Worker Token"
```

**Note:** If databases are not yet healthy when the webapp starts, the trigger container will restart automatically (via `deploy.restart_policy`). It will recover once DBs are reachable. Always deploy DBs first and verify they're healthy.

### 4.6 Secrets

The env file comes with pre-generated secrets. If you want to regenerate any, run:

```bash
openssl rand -base64 32
```

**Important:** Shared secrets (POSTGRES_PASSWORD, CLICKHOUSE_PASSWORD, MINIO_PASSWORD) must match `trigger-dbs.env`. See the Shared Secrets Reference table above.

## Step 5: Configure Domains

After the first deploy succeeds, add domains in the Dokploy UI.

### 5.1 Trigger Webapp Domain

1. In Dokploy, go to your stack service -> **Domains**
2. Click **Add Domain**
3. Configure:
   - **Domain**: `trigger.yourdomain.com`
   - **Service Name**: `trigger` (the service name in the compose file)
   - **Container Port**: `3000`
   - **HTTPS**: Enabled (Traefik auto-provisions SSL via Let's Encrypt)

### 5.2 Registry Domain

1. Click **Add Domain** again
2. Configure:
   - **Domain**: `registry.yourdomain.com`
   - **Service Name**: `registry`
   - **Container Port**: `5000`
   - **HTTPS**: Enabled

### 5.3 Update Environment Variables

Update these env vars to match your domains:

```
TRIGGER_DOMAIN=trigger.yourdomain.com
REGISTRY_DOMAIN=registry.yourdomain.com
```

### 5.4 Redeploy

Redeploy the stack service so the trigger app picks up the correct domain URLs.

### 5.5 Verify

- Visit `https://trigger.yourdomain.com` — you should see the Trigger.dev login page
- Test registry: `curl -s https://registry.yourdomain.com/v2/` should return `{}`

## Step 6: Get Worker Token

After the webapp is running, retrieve the worker token from the Swarm service logs:

```bash
# Get the worker token from service logs
docker service logs trigger-webapp_trigger 2>&1 | grep -A15 "Worker Token"
```

Copy the `TRIGGER_WORKER_TOKEN` value (starts with `tr_wgt_`).

If you don't see the worker token in the logs, you can also find it in the Trigger.dev dashboard under **Settings** -> **Workers**.

## Step 7: Scale Up Webapp Replicas

Now that the worker token is generated and migrations have run, scale up the webapp:

1. In the webapp env vars, change:
   ```
   TRIGGER_REPLICAS=2
   ```
2. Redeploy the stack.

Adjust the replica count and resource limits based on your webapp server size:

| Server Size | Replicas | TRIGGER_CPUS | TRIGGER_MEMORY | TRIGGER_CPUS_RESERVED | TRIGGER_MEMORY_RESERVED |
|-------------|----------|-------------|---------------|----------------------|------------------------|
| 8 vCPU / 32GB | 2 | 3 | 12G | 2 | 8G |
| 8 vCPU / 32GB | 1 | 6 | 24G | 4 | 12G |
| 4 vCPU / 8GB | 1 | 3 | 6G | 1 | 4G |

Verify replicas are running:

```bash
docker service ls --filter "name=trigger-webapp_trigger"
# Should show 2/2 replicas (or your configured count)

docker service ps trigger-webapp_trigger
# Shows each replica's node and status
```

## Step 8: Prepare Worker Servers

Repeat this step for **each** of your 4 worker servers.

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first on each worker server.
2. Then run **`server-setup-worker.md`** on each worker server for worker-specific tuning: ephemeral port range expansion (`ip_local_port_range`) and port 8020 firewall rules.

Replace `WEBAPP_IP` with your webapp server's actual IP address in the firewall commands.

## Step 9: Deploy Workers on Dokploy

Repeat this step for **each** of your 4 worker servers. Each worker gets its own Dokploy Compose project with the same compose file and env vars.

### 9.1 Create Compose Project

1. In Dokploy UI **on the worker server**, go to **Projects** -> **Create Project**
2. Name it `trigger-worker` (or `trigger-worker-1`, `trigger-worker-2`, etc.)
3. Inside the project, create a new **Compose** service
4. Set **Source** to "Raw"

### 9.2 Paste Compose File

Copy the entire contents of `trigger-worker-docker-compose.yml` into the compose editor.

### 9.3 Configure Environment Variables

1. Go to the **Environment** tab
2. Copy the contents of `trigger-worker.env`
3. Paste into the environment variables section

### 9.4 Set Required Values

Update these values (same for all workers):

| Variable | Value | Source |
|----------|-------|--------|
| `TRIGGER_API_URL` | `https://trigger.yourdomain.com` | Your webapp domain from Step 5 |
| `TRIGGER_WORKER_TOKEN` | `tr_wgt_xxxxx` | From Step 6 |
| `DOCKER_REGISTRY_URL` | `https://registry.yourdomain.com` | Your registry domain from Step 5 |

**Note:** `MANAGED_WORKER_SECRET` and `REGISTRY_PASSWORD` are pre-filled and already match the webapp env file. All 4 workers use the same token and secrets.

### 9.5 Deploy

Click **Deploy** on each worker server. Check the supervisor logs:

```bash
docker logs <trigger-worker-supervisor-container> 2>&1 | tail -50
```

You should see it connect to the webapp and start polling for work.

### 9.6 Verify All Workers

From any server, check the Trigger.dev dashboard -> **Settings** -> **Workers**. All 4 workers should appear as connected.

## Step 10: Verify Cross-Service Connectivity

### 10.1 Webapp -> Databases (via overlay aliases)

From the webapp server, verify the trigger service can reach the databases:

```bash
# Check trigger service logs for successful DB connection
docker service logs trigger-webapp_trigger --tail 200 2>&1 | grep -i "prisma\|database\|connected"

# Verify overlay alias resolution from webapp node
docker run --rm --network dokploy-network alpine nslookup trigger-postgres
```

### 10.2 Worker -> Webapp (HTTPS)

From each worker server, verify it can reach the webapp:

```bash
curl -s https://trigger.yourdomain.com/api/v1/health
```

Should return a 200 response.

### 10.3 Webapp -> Worker Supervisor (Port 8020)

From the webapp server, verify connectivity to **each** worker:

```bash
curl -s http://<worker-1-ip>:8020/health
curl -s http://<worker-2-ip>:8020/health
curl -s http://<worker-3-ip>:8020/health
curl -s http://<worker-4-ip>:8020/health
```

Should return a 200 response. If it times out, check:
- Firewall on worker server allows webapp IP on port 8020
- The supervisor container is running and healthy

### 10.4 Worker -> Registry (HTTPS)

From each worker server:

```bash
curl -s https://registry.yourdomain.com/v2/
```

Should return `{}`.

### 10.5 Check Supervisor Logs

On each worker, the supervisor logs should show:

```
Connected to webapp at https://trigger.yourdomain.com
Polling for work...
```

## Step 11: Optional Configuration

### Email (Magic Link Login)

Set these in the **webapp** env:

```
WHITELISTED_EMAILS=user@yourdomain.com
EMAIL_TRANSPORT=resend
FROM_EMAIL=noreply@yourdomain.com
RESEND_API_KEY=re_xxxxxxxxxxxx
```

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

Set in the **dbs** env (`trigger-dbs.env`):

```
BACKUP_ENABLED=true
BACKUP_S3_ENDPOINT=https://s3.amazonaws.com
BACKUP_S3_BUCKET=my-trigger-backups
BACKUP_S3_ACCESS_KEY_ID=your-access-key
BACKUP_S3_SECRET_ACCESS_KEY=your-secret-key
BACKUP_S3_REGION=us-east-1
```

## Troubleshooting

### Swarm service commands (webapp)

Since the webapp runs as a Stack, use `docker service` commands instead of `docker` commands:

```bash
# List services
docker service ls --filter "name=trigger-webapp"

# View logs (aggregated from all replicas)
docker service logs trigger-webapp_trigger --tail 100

# View logs from a specific replica
docker service ps trigger-webapp_trigger    # find task ID
docker service logs <task-id>

# Force redeploy (rolling update)
docker service update --force trigger-webapp_trigger

# Scale replicas
docker service scale trigger-webapp_trigger=3

# Inspect service config
docker service inspect trigger-webapp_trigger --pretty
```

### Webapp can't connect to databases

**Symptom:** Trigger service crash-loops with "connection refused" to postgres.

**Fix:**
- Verify DB compose is deployed and all 5 services are healthy
- Verify `dokploy-network` is an overlay network: `docker network inspect dokploy-network | grep Driver`
- Test alias resolution: `docker run --rm --network dokploy-network alpine nslookup trigger-postgres`
- Check shared secrets match between `trigger-dbs.env` and `trigger-webapp.env`

### Network aliases not resolving

**Symptom:** `nslookup trigger-postgres` fails from webapp node.

**Fix:**
- Both servers must be in the same Docker Swarm cluster
- `dokploy-network` must be an overlay network (not bridge)
- Re-deploy the DB compose — the aliases are registered when containers join the network
- Check: `docker network inspect dokploy-network --format '{{json .Containers}}'`

### Supervisor can't connect to webapp

**Symptom:** Supervisor logs show connection refused or timeout to TRIGGER_API_URL.

**Fix:**
- Verify `TRIGGER_API_URL` is correct and accessible from worker server
- Check DNS resolution: `nslookup trigger.yourdomain.com` from worker server
- Verify the webapp service is running: `docker service ls --filter "name=trigger-webapp_trigger"`
- Check service logs: `docker service logs trigger-webapp_trigger --tail 50`

### Webapp can't reach supervisor on port 8020

**Symptom:** Tasks stay in "queued" state, never start executing.

**Fix:**
- Check firewall on **each** worker server: `sudo ufw status` (or `firewall-cmd --list-all`)
- Verify webapp IP is allowed on port 8020
- Test from webapp server: `curl http://<worker-ip>:8020/health`

### Worker token invalid

**Symptom:** Supervisor logs show authentication errors.

**Fix:**
- Re-check the token from webapp service logs: `docker service logs trigger-webapp_trigger 2>&1 | grep -A15 "Worker Token"`
- Ensure no extra whitespace in the env var
- The token is generated on first webapp boot — if you recreated the database, you need a new token
- All 4 workers use the same token

### Task containers can't pull images

**Symptom:** Tasks fail with "image pull" errors.

**Fix:**
- Verify `DOCKER_REGISTRY_URL` matches the webapp's registry domain
- Verify `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` match webapp values
- Test: `docker login registry.yourdomain.com -u trigger -p <password>`

### Replicas not starting

**Symptom:** `docker service ls` shows 1/2 or 0/2 replicas.

**Fix:**
- Check pending tasks: `docker service ps trigger-webapp_trigger --no-trunc`
- Look for resource constraint errors (insufficient CPU/memory)
- Adjust `TRIGGER_CPUS`, `TRIGGER_MEMORY` in webapp env if the server is smaller
- Check node availability: `docker node ls`

### ClickHouse not starting

**Symptom:** ClickHouse container exits or restarts repeatedly.

**Fix:**
- Check `ulimit -n` on the DB server is at least 262144
- Verify `fs.file-max` sysctl: `sysctl fs.file-max` (should be 2097152)
- Check ClickHouse logs: `docker logs <clickhouse-container>`

### PostgreSQL performance issues

**Symptom:** Slow queries, high CPU on database server.

**Fix:**
- Check shared_buffers: `docker exec <pg-container> psql -U postgres -c "SHOW shared_buffers;"`
- If using huge pages, verify: `sysctl vm.nr_hugepages`
- Monitor connections: `docker exec <pg-container> psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"`

### Redis warnings in logs

**Symptom:** Redis logs show "WARNING Memory overcommit must be enabled!"

**Fix:**
- Verify `vm.overcommit_memory=1` on the **DB server**: `sysctl vm.overcommit_memory`
- If not set, run: `sudo sysctl -w vm.overcommit_memory=1` and add to `/etc/sysctl.conf`

## File Reference

| File | Purpose |
|------|---------|
| `trigger-dbs-docker-compose.yml` | Database compose (postgres, redis, clickhouse, electric, minio) with overlay network aliases |
| `trigger-dbs.env` | Database environment with shared secrets and tuning (8vCPU/32GB) |
| `trigger-webapp-docker-compose.yml` | Webapp **Stack** compose (trigger with replicas, registry) connecting to external DBs via aliases |
| `trigger-webapp.env` | Webapp environment with shared secrets, domains, Swarm deploy resource limits |
| `trigger-worker-docker-compose.yml` | Worker compose (supervisor, docker-proxy) — deploy one per worker server |
| `trigger-worker.env` | Worker environment with matching secrets and scaling settings |
| `server-setup-dbs.md` | Host kernel tuning for dedicated database server |
| `server-setup-webapp.md` | Host tuning for webapp server (lighter, no DB tuning) |
| `server-setup-worker.md` | Host kernel tuning + firewall for worker server |
| `DEPLOY-GUIDE.md` | This guide |
