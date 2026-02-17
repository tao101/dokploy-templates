# Trigger.dev Distributed Deployment Guide — External Databases (Dokploy Remote Servers)

Deploy Trigger.dev v4 with databases on a dedicated Dokploy remote server, the webapp as a Dokploy Stack (Docker Swarm with replicas), and multiple workers on Dokploy remote servers.

## Architecture

```
[DB Server - Dokploy Remote]            [Webapp Server - Dokploy Swarm]         [Worker Servers x4 - Dokploy Remote]
trigger-dbs (Compose)                   trigger-webapp (Stack)                  trigger-worker (Compose)
Standalone Docker, exposed ports        Only Swarm component                    Standalone Docker
  postgres :5432 ──┐                      trigger:3000 (replicas)  <────────── supervisor:8020
  redis :6379 ─────┤  public IP           registry:5000 (1 replica)             docker-proxy
  clickhouse :8123 ┤  (firewall-          |                                     task containers
  electric :3000 ──┤   restricted         connects via DB_HOST:port:            (trigger-tasks bridge network)
  minio :9000/:9001┘   to webapp IP)      ${DB_HOST}:5432 (postgres)
                                          ${DB_HOST}:6379 (redis)
                                          ${DB_HOST}:8123 (clickhouse)
                                          ${DB_HOST}:3000 (electric)
                                          ${DB_HOST}:9000 (minio)
```

**Deployment modes:**
- **Databases**: Dokploy remote server, **Compose** (`docker compose up`) — standalone Docker, exposed ports on host
- **Webapp**: Dokploy Swarm, **Stack** (`docker stack deploy`) — stateless, Swarm replicas, uses `dokploy-network` only for Traefik routing
- **Workers**: Dokploy remote servers, **Compose** (`docker compose up`) — standalone Docker, one per remote server, `trigger-tasks` bridge network for task containers

**Communication flow:**
- **Webapp -> DBs**: Via `DB_HOST:port` (DB server's public IP, firewall-restricted to webapp IP only)
- **Worker -> Webapp**: HTTPS via public `TRIGGER_API_URL` (no firewall issue)
- **Webapp -> Worker**: HTTP to supervisor port 8020 (firewall-restricted to webapp IP on each worker server)
- **Worker -> Registry**: HTTPS via public `DOCKER_REGISTRY_URL` (pulls task images)

## Prerequisites

- 1 Dokploy server with **Swarm enabled** (webapp server)
- 1+ Dokploy **remote servers** for databases (standalone Docker, NOT in Swarm)
- 1+ Dokploy **remote servers** for workers (standalone Docker, NOT in Swarm)
- **Network**: Webapp server must be able to reach DB server ports: 5432 (postgres), 6379 (redis), 3000 (electric), 8123 (clickhouse), 9000 (minio)
- **Network**: Webapp server must be able to reach each worker server on port 8020
- DNS records:
  - `trigger.yourdomain.com` -> Webapp server IP
  - `registry.yourdomain.com` -> Webapp server IP

## Shared Secrets Reference

These secrets must be identical across env files:

| Secret | `trigger-dbs.env` | `trigger-webapp.env` | `trigger-worker.env` |
|--------|:--:|:--:|:--:|
| `POSTGRES_PASSWORD` | Yes | Yes | - |
| `REDIS_PASSWORD` | Yes | Yes | - |
| `CLICKHOUSE_PASSWORD` | Yes | Yes | - |
| `MINIO_PASSWORD` | Yes | Yes | - |
| `ELECTRIC_SECRET` | Yes | - | - |
| `MANAGED_WORKER_SECRET` | - | Yes | Yes |
| `REGISTRY_PASSWORD` | - | Yes | Yes |

The provided env files already have matching pre-generated secrets. If you regenerate any, update all env files that reference it.

## Step 1: Prepare the Database Server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first (system updates, Dokploy install, Docker daemon tuning, kernel params, file descriptors, swap, firewall, NTP).
2. Then run **`server-setup-dbs.md`** on the DB server for database-specific tuning: `vm.overcommit_memory=1` (Redis), high `fs.file-max` (ClickHouse), huge pages (PostgreSQL).

**Note:** `server-setup-dbs.md` now includes firewall rules that restrict database ports (5432, 6379, 3000, 8123, 9000, 9001) to the webapp server's IP only. Make sure to set the correct webapp IP when running the script.

Verify output shows all expected values.

## Step 2: Deploy Databases on Dokploy

### 2.1 Create Compose Project

1. In Dokploy UI, go to the **DB remote server**, then **Projects** -> **Create Project**
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

Click **Deploy**. Wait for all 6 services to become healthy (first deploy takes a few minutes as images are pulled). The minio-init container will run once and exit after configuring MinIO.

### 2.5 Verify Database Health

Check that all services are healthy:

```bash
docker ps --filter "name=trigger-dbs" --format "table {{.Names}}\t{{.Status}}"
```

Expected: 5 long-running containers showing `(healthy)` plus minio-init which exits after completion.

### 2.6 Verify Port Connectivity

From the **webapp server**, verify the DB server ports are reachable:

```bash
nc -zv <DB_HOST> 5432    # postgres
nc -zv <DB_HOST> 6379    # redis
nc -zv <DB_HOST> 3000    # electric
nc -zv <DB_HOST> 8123    # clickhouse
nc -zv <DB_HOST> 9000    # minio
```

Replace `<DB_HOST>` with the DB server's public IP. All should report "Connection succeeded" or "open". If any fail, check the firewall rules on the DB server (the webapp IP must be allowed).

## Step 3: Prepare the Webapp Server

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first.
2. Then run **`server-setup-webapp.md`** — lighter tuning since no databases run here. **Includes NFS server setup** (§4) required for multi-node Swarm — the shared worker token volume uses NFS so trigger replicas can run on any Swarm node.

## Step 4: Deploy Webapp as Dokploy Stack

The webapp is deployed as a **Stack** (not Compose) to enable Docker Swarm replicas for high availability. It connects to the external databases via `DB_HOST:port` (the DB server's public IP).

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

**Required env vars to set:**
- `DB_HOST` -- the DB server's public IP address (used to construct connection strings for postgres, redis, clickhouse, electric, minio)
- `REDIS_PASSWORD` -- must match the value in `trigger-dbs.env`
- All other shared secrets (`POSTGRES_PASSWORD`, `CLICKHOUSE_PASSWORD`, `MINIO_PASSWORD`) must also match `trigger-dbs.env`

### 4.4 First Deploy -- Single Replica

**Important:** For the first deploy, ensure `TRIGGER_REPLICAS=1` in the env vars. This is already the default in `trigger-webapp.env`.

The single-replica first deploy is required to:
1. Run Prisma database migrations (only one instance should run migrations)
2. Generate the bootstrap worker token
3. Write the token to the shared volume

Click **Deploy**. The trigger app will connect to the external databases via `DB_HOST:port`.

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

**Important:** Shared secrets (POSTGRES_PASSWORD, REDIS_PASSWORD, CLICKHOUSE_PASSWORD, MINIO_PASSWORD) must match `trigger-dbs.env`. See the Shared Secrets Reference table above.

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

- Visit `https://trigger.yourdomain.com` -- you should see the Trigger.dev login page
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
   TRIGGER_REPLICAS=3
   ```
2. Redeploy the stack.

Each replica runs a single Node.js process — scale horizontally by adding replicas. Replicas spread across all Swarm nodes (manager + workers) via the NFS-backed shared volume. Adjust the replica count and per-replica resource limits based on your **total Swarm capacity** (all nodes combined):

| Server Size | Replicas | TRIGGER_CPUS | TRIGGER_MEMORY | TRIGGER_CPUS_RESERVED | TRIGGER_MEMORY_RESERVED |
|-------------|----------|-------------|---------------|----------------------|------------------------|
| 4 vCPU / 16GB | 2 | 1.5 | 6G | 1 | 3G |
| 8 vCPU / 32GB | 3 | 2 | 5G | 1 | 2G |
| 16 vCPU / 64GB | 6 | 2 | 8G | 1 | 4G |

Verify replicas are running:

```bash
docker service ls --filter "name=trigger-webapp_trigger"
# Should show 3/3 replicas (or your configured count)

docker service ps trigger-webapp_trigger
# Shows each replica's node and status — replicas should be distributed across Swarm nodes
```

## Step 8: Prepare Worker Servers

Repeat this step for **each** of your 4 worker servers.

1. Run **[`../SERVER-SETUP.md`](../SERVER-SETUP.md)** first on each worker server.
2. Then run **`server-setup-worker.md`** on each worker server for worker-specific tuning: ephemeral port range expansion (`ip_local_port_range`) and port 8020 firewall rules.

Replace `WEBAPP_IP` with your webapp server's actual IP address in the firewall commands.

## Step 9: Deploy Workers on Dokploy

Repeat this step for **each** of your 4 worker servers. Each worker gets its own Dokploy Compose project on its Dokploy remote server with the same compose file and env vars.

### 9.1 Create Compose Project

1. In Dokploy UI, go to the **worker remote server**, then **Projects** -> **Create Project**
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

### 10.1 Webapp -> Databases (via DB_HOST:port)

From the webapp server, verify the trigger service can reach the databases:

```bash
# Check trigger service logs for successful DB connection
docker service logs trigger-webapp_trigger --tail 200 2>&1 | grep -i "prisma\|database\|connected"

# Verify port connectivity from webapp server to DB server
nc -zv <DB_HOST> 5432    # postgres
nc -zv <DB_HOST> 6379    # redis
nc -zv <DB_HOST> 3000    # electric
nc -zv <DB_HOST> 8123    # clickhouse
nc -zv <DB_HOST> 9000    # minio
```

Replace `<DB_HOST>` with the DB server's public IP.

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
- Verify `DB_HOST` is set correctly in `trigger-webapp.env` (should be the DB server's public IP)
- Verify DB compose is deployed and all services are healthy on the DB server
- Test port connectivity from the webapp server: `nc -zv <DB_HOST> 5432`
- Check firewall rules on the DB server allow the webapp server's IP on ports 5432, 6379, 3000, 8123, 9000
- Check shared secrets match between `trigger-dbs.env` and `trigger-webapp.env`

### DB ports not reachable from webapp

**Symptom:** `nc -zv <DB_HOST> 5432` times out or connection refused from the webapp server.

**Fix:**
- Check firewall rules on the DB server: `sudo ufw status` (or `firewall-cmd --list-all`)
- Verify the webapp server's IP is allowed on ports 5432, 6379, 3000, 8123, 9000, 9001
- Verify ports are exposed on the DB server: `docker ps --filter "name=trigger-dbs" --format "table {{.Names}}\t{{.Ports}}"`
- If ports show but are unreachable, the firewall is likely blocking -- re-run `server-setup-dbs.md` firewall section with the correct webapp IP
- Test from the DB server itself: `nc -zv 127.0.0.1 5432` (if this fails, the container isn't exposing the port)

### Redis authentication failed

**Symptom:** Webapp logs show "NOAUTH Authentication required" or "ERR invalid password" for Redis connections.

**Fix:**
- Verify `REDIS_PASSWORD` in `trigger-webapp.env` matches `REDIS_PASSWORD` in `trigger-dbs.env` exactly
- Check for extra whitespace or special characters in the password
- Test from the webapp server: `redis-cli -h <DB_HOST> -p 6379 -a <password> ping` (should return `PONG`)

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
- The token is generated on first webapp boot -- if you recreated the database, you need a new token
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
| `trigger-dbs-docker-compose.yml` | Database compose (postgres, redis, clickhouse, electric, minio) with exposed host ports |
| `trigger-dbs.env` | Database environment with shared secrets and tuning (8vCPU/32GB) |
| `trigger-webapp-docker-compose.yml` | Webapp **Stack** compose (trigger with replicas, registry) connecting to external DBs via `DB_HOST:port` |
| `trigger-webapp.env` | Webapp environment with shared secrets, domains, `DB_HOST`, Swarm deploy resource limits |
| `trigger-worker-docker-compose.yml` | Worker compose (supervisor, docker-proxy) -- deploy one per Dokploy remote worker server |
| `trigger-worker.env` | Worker environment with matching secrets and scaling settings |
| `server-setup-dbs.md` | Host kernel tuning + firewall rules for dedicated database remote server |
| `server-setup-webapp.md` | Host tuning for webapp server (lighter, no DB tuning) |
| `server-setup-worker.md` | Host kernel tuning + firewall for worker remote server |
| `DEPLOY-GUIDE.md` | This guide |
