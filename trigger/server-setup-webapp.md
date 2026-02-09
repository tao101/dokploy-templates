# Webapp Server Setup

Run these commands on the server where the webapp compose will be deployed. This server runs: trigger, postgres, redis, clickhouse, electric, minio, registry, and backup services.

All commands require `sudo`.

## 1. Kernel Parameters

Apply immediately:

```bash
sudo sysctl -w vm.overcommit_memory=1
sudo sysctl -w vm.swappiness=1
sudo sysctl -w fs.file-max=2097152
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.ipv4.tcp_keepalive_time=60
sudo sysctl -w net.ipv4.tcp_keepalive_intvl=10
sudo sysctl -w net.ipv4.tcp_keepalive_probes=6
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
```

What each does:
- `vm.overcommit_memory=1` — Required for Redis BGSAVE. Without it Redis logs "WARNING Memory overcommit must be enabled!"
- `vm.swappiness=1` — Minimize swap. PostgreSQL and Redis on swap is catastrophically slow
- `fs.file-max=2097152` — ClickHouse needs 262144 per container, plus PG connections and task containers
- `net.core.somaxconn=65535` — Connection backlog for PG (1500 connections) and ClickHouse (300 queries)
- `tcp_keepalive_time/intvl/probes` — Detect dead connections in ~2 min instead of ~2.3 hours
- `tcp_tw_reuse=1` — Recycle TIME_WAIT sockets faster with many DB connections

## 2. Persist Across Reboots

Append to `/etc/sysctl.conf`:

```bash
echo "" | sudo tee -a /etc/sysctl.conf
echo "# --- Trigger.dev Webapp Server Tuning ---" | sudo tee -a /etc/sysctl.conf
echo "vm.overcommit_memory=1" | sudo tee -a /etc/sysctl.conf
echo "vm.swappiness=1" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=2097152" | sudo tee -a /etc/sysctl.conf
echo "net.core.somaxconn=65535" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_time=60" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_intvl=10" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_probes=6" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_tw_reuse=1" | sudo tee -a /etc/sysctl.conf
```

## 3. File Descriptor Limits

Append to `/etc/security/limits.conf`:

```bash
echo "" | sudo tee -a /etc/security/limits.conf
echo "# --- Trigger.dev: ClickHouse + high-concurrency services ---" | sudo tee -a /etc/security/limits.conf
echo "* soft nofile 262144" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 262144" | sudo tee -a /etc/security/limits.conf
echo "root soft nofile 262144" | sudo tee -a /etc/security/limits.conf
echo "root hard nofile 262144" | sudo tee -a /etc/security/limits.conf
```

## 4. Disable Swap

```bash
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
```

## 5. Optional: Huge Pages for PostgreSQL

Improves shared_buffers performance. Uncomment and run ONE line matching your `PG_SHARED_BUFFERS`:

```bash
# sudo sysctl -w vm.nr_hugepages=2048    # 4GB shared_buffers
# sudo sysctl -w vm.nr_hugepages=4096    # 8GB shared_buffers
# sudo sysctl -w vm.nr_hugepages=8192    # 16GB shared_buffers
# sudo sysctl -w vm.nr_hugepages=16384   # 32GB shared_buffers
```

If you enable huge pages, also add to `/etc/sysctl.conf`:

```bash
# echo "vm.nr_hugepages=4096" | sudo tee -a /etc/sysctl.conf
```

## 6. Verify

```bash
sysctl vm.overcommit_memory vm.swappiness fs.file-max net.core.somaxconn
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
sysctl net.ipv4.tcp_tw_reuse
swapon --show
ulimit -n
```

Expected:
- `vm.overcommit_memory = 1`
- `vm.swappiness = 1`
- `fs.file-max = 2097152`
- `net.core.somaxconn = 65535`
- `tcp_keepalive_time = 60`, `intvl = 10`, `probes = 6`
- `tcp_tw_reuse = 1`
- No swap entries
- `ulimit -n` = 262144 (may need re-login)
