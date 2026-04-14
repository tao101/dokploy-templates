# Kernel Tuning Notes for Hetzner (16 vCPU, 64GB RAM - Supabase Production)

> **Run [`../SERVER-SETUP.md`](../SERVER-SETUP.md) first.** It covers all base kernel tuning (sysctl params, file descriptors, swap, Docker daemon tuning, firewall, NTP). This file covers Supabase-specific sysctl values and the post-deployment validation checklist.

These are optional host-level optimizations. The optimized docker-compose works without them, but applying these can improve performance further.

**All commands require sudo.** Values below are tuned for 16 vCPU / 64GB RAM.

## Sysctl Settings

```bash
# Reduce swap usage (1 = minimal swap, don't set to 0 on Linux)
sysctl -w vm.swappiness=1

# Allow overcommit for PostgreSQL shared memory allocation
sysctl -w vm.overcommit_memory=1

# Increase max connection backlog for high connection counts
sysctl -w net.core.somaxconn=65535

# Increase file descriptor limits
sysctl -w fs.file-max=2097152

# TCP keepalive — detect dead connections faster (for Supavisor + Prisma)
sysctl -w net.ipv4.tcp_keepalive_time=60      # Start keepalive after 60s idle (default: 7200)
sysctl -w net.ipv4.tcp_keepalive_intvl=10      # Retry every 10s (default: 75)
sysctl -w net.ipv4.tcp_keepalive_probes=6      # Give up after 6 probes (default: 9)

# Connection reuse — recycle TIME_WAIT sockets faster under high churn
sysctl -w net.ipv4.tcp_tw_reuse=1

# Huge pages for PostgreSQL shared_buffers (16GB / 2MB per page = 8192 pages)
# Only useful if PG_HUGE_PAGES=on (currently set to 'try')
sysctl -w vm.nr_hugepages=8192
```

To persist across reboots, add to `/etc/sysctl.conf`:

```
vm.swappiness=1
vm.overcommit_memory=1
net.core.somaxconn=65535
fs.file-max=2097152
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_tw_reuse=1
vm.nr_hugepages=8192
```

## Disable Swap (Recommended)

PostgreSQL on swap is catastrophically slow. On a dedicated server with 64GB RAM:

```bash
swapoff -a
# Remove swap entries from /etc/fstab to persist
```

## Post-Deployment Validation Checklist

After deploying with `optimized-supabase-docker-compose.yml`:

### 1. Verify all containers are healthy

```bash
docker compose -f optimized-supabase-docker-compose.yml --env-file optimized-supabase.env ps
```

### 2. Verify PostgreSQL tuning applied

```bash
psql "postgresql://postgres:YOUR_PASSWORD@SERVER_IP:5435/postgres" -c "
  SELECT name, setting, unit FROM pg_settings
  WHERE name IN (
    'shared_buffers', 'effective_cache_size', 'work_mem',
    'maintenance_work_mem', 'autovacuum_work_mem',
    'max_connections', 'random_page_cost', 'effective_io_concurrency',
    'maintenance_io_concurrency',
    'wal_buffers', 'max_wal_size', 'min_wal_size',
    'max_worker_processes', 'max_parallel_workers',
    'max_parallel_workers_per_gather', 'max_parallel_maintenance_workers',
    'huge_pages', 'checkpoint_completion_target'
  )
  ORDER BY name;
"
```

### 3. Verify connection usage is within budget

```bash
psql "postgresql://postgres:YOUR_PASSWORD@SERVER_IP:5435/postgres" -c "
  SELECT usename, count(*), state
  FROM pg_stat_activity
  GROUP BY usename, state
  ORDER BY count DESC;
"
```

Expected budget (max_connections=500):
- Supavisor pool: ~300
- PostgREST: ~15
- GoTrue: ~15
- Realtime: 10-30
- Other services: 10-30
- Headroom: ~110

### 4. Verify Supavisor pooler is accepting connections

```bash
psql "postgresql://postgres.baseloop-prod:YOUR_PASSWORD@SERVER_IP:6544/postgres?pgbouncer=true" -c "SELECT 1 AS pooler_ok;"
```

### 5. Verify Realtime tenant limits

```bash
psql "postgresql://postgres:YOUR_PASSWORD@SERVER_IP:5435/postgres" -c "
  SELECT external_id, max_concurrent_users, max_events_per_second, max_joins_per_second
  FROM _realtime.tenants;
"
```

If Realtime tenant limits show defaults (200 concurrent users), run this SQL to update them:

```sql
UPDATE _realtime.tenants
SET max_concurrent_users = 1000,
    max_events_per_second = 2500,
    max_joins_per_second = 500,
    max_bytes_per_second = 500000
WHERE external_id = 'realtime-dev';
```

### 6. Prisma connection strings for external apps

```env
# Transaction mode pooler (app runtime queries)
DATABASE_URL="postgresql://postgres.baseloop-prod:YOUR_PASSWORD@SERVER_IP:6544/postgres?pgbouncer=true"

# Direct to DB (migrations only)
DIRECT_URL="postgresql://postgres:YOUR_PASSWORD@SERVER_IP:5435/postgres"
```

### 7. Prisma connection strings for Dokploy internal apps

```env
# Transaction mode pooler (app runtime queries)
DATABASE_URL="postgresql://postgres.baseloop-prod:YOUR_PASSWORD@baseloop-supabase-soskt5-supabase-pooler:6543/postgres?pgbouncer=true"

# Direct to DB (migrations only)
DIRECT_URL="postgresql://postgres:YOUR_PASSWORD@baseloop-supabase-soskt5-supabase-db:5432/postgres"
```

## PostgreSQL 17 Upgrade Notes

These compose files use PostgreSQL 17 (`supabase/postgres:17.6.1.041`). Key considerations:

### New deployments
Just use the compose file as-is. PG17 will initialize a fresh PGDATA directory.

### Upgrading existing PG15 deployments
You CANNOT just change the image tag — PG15 and PG17 data formats are incompatible.

Options:
1. **pg_dump/restore** (simplest for small databases):
   - `pg_dump` from PG15 instance
   - Remove old PGDATA directory
   - Start PG17 container (fresh init)
   - `pg_restore` into PG17

2. **pg_upgrade** (faster for large databases):
   - Requires both PG15 and PG17 binaries in the same environment
   - See: https://supabase.com/docs/guides/platform/upgrading

### PG17 breaking changes to be aware of
- Authentication: Supabase prefers `scram-sha-256` over `md5`. Custom roles may need password reset.
- Logical replication slots are NOT preserved during major version upgrades.
- Expression indexes may need `search_path` set explicitly on referenced functions.
