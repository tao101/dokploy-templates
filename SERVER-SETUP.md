# Server Setup — Hetzner Ubuntu + Dokploy

Common server preparation for any Hetzner Cloud dedicated server (CCX/CX series) running Ubuntu before deploying templates via Dokploy. Run this once on every fresh server.

All commands require `sudo`. Copy-paste each block in order.

---

## 1. System Updates

Fresh Ubuntu servers ship with stale packages. Update everything first:

```bash
sudo apt update && sudo apt upgrade -y
```

Reboot if the kernel was upgraded:

```bash
sudo reboot
```

## 2. Install Dokploy

Dokploy installs Docker, Traefik, and its management UI in one command:

```bash
curl -sSL https://dokploy.com/install.sh | sh
```

After install, access the Dokploy dashboard at `http://YOUR_SERVER_IP:3000` to create your admin account.

> **Note:** Dokploy installs Docker Engine and configures Traefik as a reverse proxy. You do not need to install Docker separately.

## 3. Kernel Tuning

Write all sysctl params to a drop-in file (idempotent — safe to re-run):

```bash
printf '# Dokploy Server Tuning — Hetzner Dedicated
# Memory
vm.overcommit_memory = 1
vm.swappiness = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
# File Descriptors & inotify
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
# TCP Buffer Sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
# Connection Backlog
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
# TIME_WAIT
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 262144
# TCP Keepalive — detect dead connections in ~2 min
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
# Connection Tracking — prevent nf_conntrack table full
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
' | sudo tee /etc/sysctl.d/99-dokploy.conf
```

Apply immediately:

```bash
sudo sysctl --system
```

What each group does:
- **Memory** — `overcommit_memory=1`: required for Redis BGSAVE, benefits PostgreSQL shared memory. `swappiness=1`: minimize swap (PG/Redis on swap is catastrophically slow). `dirty_ratio/dirty_background_ratio`: flush dirty pages sooner — better for NVMe with many concurrent writes.
- **File descriptors & inotify** — `file-max=2097152`: system-wide FD ceiling (ClickHouse needs 262K per container). `inotify` watches/instances: needed by file-watching services and Docker events.
- **TCP buffers** — Increase send/receive buffer sizes for high-throughput API workloads and database connections. Default 128KB is too small for concurrent external API calls.
- **Connection backlog** — `somaxconn`, `tcp_max_syn_backlog`, `netdev_max_backlog`: prevent connection drops during traffic bursts to PostgreSQL (500-1500 connections), ClickHouse (300 queries), and Supavisor (2000 clients).
- **TIME_WAIT** — `tcp_tw_reuse=1`: recycle TIME_WAIT sockets faster. `tcp_max_tw_buckets=262144`: allow more sockets in TIME_WAIT before kernel starts dropping.
- **TCP Keepalive** — Detect dead connections in ~2 min instead of default ~2.3 hours. Critical for database connection pools (Supavisor, PgBouncer) and distributed task scheduling (Trigger.dev).
- **Connection tracking** — `nf_conntrack_max=262144`: prevent "nf_conntrack: table full, dropping packet" under Docker networking load. Timeout tuning: reclaim TIME_WAIT entries after 30s, keep established connections for 24h.

## 4. Disable Transparent Hugepages

THP causes unpredictable latency spikes during V8 garbage collection (Node.js / Trigger.dev) and memory bloat with allocation-heavy workloads. This is different from PostgreSQL huge pages (section 14) which are beneficial.

```bash
printf '[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=multi-user.target
' | sudo tee /etc/systemd/system/disable-thp.service

sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp.service
```

Verify:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
# Should show: always madvise [never]
```

## 5. Docker Daemon Tuning

Back up existing config (Dokploy may have created one):

```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true
```

Write the production config:

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "live-restore": false,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 262144,
      "Soft": 262144
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 8192,
      "Soft": 8192
    }
  },
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "metrics-addr": "127.0.0.1:9323"
}
EOF
```

What each setting does:

| Setting | Why |
|---|---|
| `log-driver: json-file` + rotation | Global log rotation (50MB x 5 per container). Uses `json-file` because Supabase Vector reads Docker log files directly. Individual compose services can override. |
| `storage-driver: overlay2` | Optimal for ext4/xfs on NVMe. Hetzner dedicated servers use ext4 by default. |
| `live-restore: false` | **Must be `false` for Dokploy.** Dokploy uses Docker Swarm mode for replicas and service orchestration — `live-restore` is incompatible with Swarm and will break Dokploy. Docker restarts will briefly stop containers (~5s), but Swarm automatically reschedules them. |
| `userland-proxy: false` | Uses pure iptables instead of a proxy process per published port — faster, zero memory overhead. |
| `nofile: 262144` | Per-container file descriptor limit. ClickHouse, PostgreSQL, and high-concurrency services need this. |
| `nproc: 8192` | Per-container process limit. Prevents fork bombs from consuming all PIDs. |
| `max-concurrent-downloads/uploads` | Speeds up image pulls on fast NVMe + network. |
| `metrics-addr` | Exposes Docker engine metrics on localhost:9323 (Prometheus-compatible). Only listens on loopback. |

### Docker Service Systemd Limits

Ensure the Docker daemon itself has high resource limits:

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity
' | sudo tee /etc/systemd/system/docker.service.d/limits.conf
```

### Apply Docker Changes

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

> **Note:** If Dokploy overwrites `daemon.json` after updates, re-run the `tee` command above.

## 6. File Descriptor Limits

Set process-level file descriptor limits for all users. This supplements the system-wide `fs.file-max` (section 3) and Docker daemon `default-ulimits` (section 5):

```bash
printf '# Dokploy: high-concurrency services
* soft nofile 262144
* hard nofile 262144
root soft nofile 262144
root hard nofile 262144
' | sudo tee -a /etc/security/limits.conf
```

> **Note:** The `root` lines are required because `*` does not apply to root on most Linux distributions. Takes effect on the next login session.

## 7. Disable Swap

PostgreSQL, Redis, and ClickHouse on swap is catastrophically slow. On dedicated servers with sufficient RAM, disable swap entirely:

```bash
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
```

The first command disables swap immediately. The second comments out swap entries in `/etc/fstab` so swap stays off after reboot.

## 8. Disable Unnecessary Services

These consume memory, CPU, and I/O on a dedicated Docker server:

```bash
# Snap package manager (~150MB RAM, periodic background checks)
sudo systemctl disable --now snapd.service snapd.socket 2>/dev/null || true

# Multipath I/O — for SAN storage, not needed on cloud/dedicated
sudo systemctl disable --now multipathd.service 2>/dev/null || true

# Modem manager — mobile broadband, not needed on server
sudo systemctl disable --now ModemManager.service 2>/dev/null || true

# Desktop account management via D-Bus
sudo systemctl disable --now accounts-daemon.service 2>/dev/null || true

# Ubuntu crash reporting
sudo systemctl disable --now apport.service 2>/dev/null || true

# Prevent server from sleeping/suspending
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

## 9. Journal Log Limits

Prevent systemd journal from growing to 4GB (default). Docker logs go through the Docker log driver, not journald:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=7day
RateLimitIntervalSec=30s
RateLimitBurst=10000
Compress=yes
' | sudo tee /etc/systemd/journald.conf.d/size-limit.conf
sudo systemctl restart systemd-journald
```

## 10. DNS Caching

Configure the host's DNS resolver to use fast upstream servers with caching. Benefits host-level processes (Dokploy, Docker daemon, apt):

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=8.8.4.4
DNSStubListener=yes
Cache=yes
CacheFromLocalhost=yes
' | sudo tee /etc/systemd/resolved.conf.d/dns-cache.conf
sudo systemctl restart systemd-resolved
```

> **Note:** Docker containers use Docker's embedded DNS server (`127.0.0.11`), which forwards external lookups to the host's resolver automatically. Do **not** set `"dns"` in `daemon.json` — it breaks container DNS in bridge networks because `127.0.0.53` is unreachable from the container's network namespace.

## 11. Filesystem Mount Options

Check your current mount options:

```bash
mount | grep ' / '
```

If the root filesystem is ext4 on SSD/NVMe, add `noatime` and `discard` in `/etc/fstab`:

```bash
# Edit /etc/fstab — find the root (/) line and add noatime,discard
# Example: change "defaults" to "defaults,noatime,discard"
sudo nano /etc/fstab
```

- **`noatime`** — Stops updating "last accessed" timestamp on every file read. Docker overlay2 reads layer files constantly — this eliminates unnecessary writes.
- **`discard`** — Enables TRIM for SSDs/NVMe, maintaining write performance over time.

> Takes effect after reboot (section 15).

## 12. Firewall & Security

### UFW Firewall

Ubuntu ships with UFW disabled by default. Enable it with a baseline policy:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh comment "SSH access"
sudo ufw allow 80/tcp comment "HTTP - Traefik/Dokploy"
sudo ufw allow 443/tcp comment "HTTPS - Traefik/Dokploy"
sudo ufw allow 3000/tcp comment "Dokploy dashboard"
sudo ufw --force enable
```

What each rule does:
- `deny incoming` / `allow outgoing` — Default policy: block all inbound, allow all outbound.
- `ssh` — Allow SSH (port 22). **Critical:** always allow SSH before enabling UFW or you will lock yourself out.
- `80/tcp` and `443/tcp` — HTTP and HTTPS for Traefik (Dokploy's reverse proxy). Required for Let's Encrypt certificate provisioning and web traffic.
- `3000/tcp` — Dokploy management dashboard. Restrict this to your IP in production (see below).

**Optional — restrict Dokploy dashboard to your IP:**

```bash
sudo ufw delete allow 3000/tcp
sudo ufw allow from YOUR_IP to any port 3000 comment "Dokploy dashboard - restricted"
```

> **Note:** App-specific firewall rules (e.g., Trigger.dev worker port 8020) are in the app-specific server setup docs, not here.

### Unattended Security Updates

```bash
sudo apt install -y unattended-upgrades
printf 'Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
' | sudo tee /etc/apt/apt.conf.d/50unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

> `Automatic-Reboot: false` — security patches apply automatically, but kernel patches wait for your maintenance window.

### Fail2Ban

```bash
sudo apt install -y fail2ban
printf '[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
maxretry = 3
bantime  = 86400
' | sudo tee /etc/fail2ban/jail.local
sudo systemctl enable --now fail2ban
```

### SSH Hardening

> Make sure you have SSH key access before applying `PasswordAuthentication no`.

```bash
printf 'PasswordAuthentication no
PermitRootLogin no
MaxAuthTries 3
AllowAgentForwarding no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
' | sudo tee /etc/ssh/sshd_config.d/hardening.conf
sudo systemctl reload sshd
```

## 13. Time Synchronization

Accurate time is critical for JWT validation (Supabase auth tokens), TLS certificates, and distributed task scheduling (Trigger.dev). Hetzner Ubuntu images ship with `systemd-timesyncd` enabled, but verify it is running:

```bash
sudo timedatectl set-ntp true
timedatectl status
```

Expected output should show:
- `NTP service: active`
- `System clock synchronized: yes`

### Alternative: Use chrony (more precise)

For production servers that need sub-millisecond accuracy:

```bash
sudo apt install -y chrony
sudo systemctl enable chrony
sudo systemctl start chrony
chronyc tracking
```

> **Note:** `chrony` and `systemd-timesyncd` conflict. Installing chrony automatically disables timesyncd. Use one or the other, not both.

## 14. Optional: Huge Pages for PostgreSQL

Huge pages reduce TLB misses for PostgreSQL's shared_buffers. Only useful if your compose sets `huge_pages=try` or `huge_pages=on` in PostgreSQL config.

Each huge page is 2MB. Calculate: `shared_buffers / 2MB = nr_hugepages`.

| shared_buffers | nr_hugepages | Typical server |
|----------------|-------------|----------------|
| 4GB            | 2048        | 4 vCPU / 16GB RAM |
| 6GB            | 3072        | 8 vCPU / 32GB RAM (Supabase CCX33) |
| 8GB            | 4096        | 8 vCPU / 32GB RAM (Trigger Tier 2) |
| 16GB           | 8192        | 16 vCPU / 64GB RAM |
| 32GB           | 16384       | 32 vCPU / 128GB RAM |

Apply (uncomment ONE line matching your `shared_buffers`):

```bash
# sudo sysctl -w vm.nr_hugepages=2048    # 4GB shared_buffers
# sudo sysctl -w vm.nr_hugepages=3072    # 6GB shared_buffers (Supabase CCX33)
# sudo sysctl -w vm.nr_hugepages=4096    # 8GB shared_buffers
# sudo sysctl -w vm.nr_hugepages=8192    # 16GB shared_buffers
# sudo sysctl -w vm.nr_hugepages=16384   # 32GB shared_buffers
```

Persist (uncomment and adjust the value):

```bash
# echo "vm.nr_hugepages=4096" | sudo tee -a /etc/sysctl.d/99-dokploy.conf && sudo sysctl --system
```

> **Note:** Huge pages reserve physical RAM at boot. If `nr_hugepages` is set too high, other services may not get enough memory. Only enable this if your server has dedicated RAM headroom. This is separate from Transparent Hugepages (section 4) which should always be disabled.

## 15. Final Reboot

After all changes, do a single reboot to apply fstab mount options, THP disable service, and ensure everything comes up cleanly:

```bash
sudo reboot
```

## 16. Verify

Run this single block after reboot to confirm everything is applied:

```bash
echo "=== Kernel Parameters ==="
sysctl vm.overcommit_memory vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
sysctl fs.file-max fs.inotify.max_user_watches
sysctl net.core.somaxconn net.core.rmem_max net.core.wmem_max
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
sysctl net.ipv4.tcp_tw_reuse net.ipv4.tcp_max_tw_buckets
sysctl net.netfilter.nf_conntrack_max

echo ""
echo "=== Transparent Hugepages ==="
cat /sys/kernel/mm/transparent_hugepage/enabled

echo ""
echo "=== Swap ==="
swapon --show
free -h | grep -i swap

echo ""
echo "=== File Descriptor Limits ==="
ulimit -n

echo ""
echo "=== Docker ==="
docker --version
docker info --format '{{.LoggingDriver}} | Storage: {{.Driver}} | Live Restore: {{.LiveRestore}}'
docker run --rm alpine sh -c 'ulimit -n'

echo ""
echo "=== Firewall ==="
sudo ufw status numbered

echo ""
echo "=== Time Sync ==="
timedatectl status | grep -E "NTP|synchronized"

echo ""
echo "=== DNS ==="
resolvectl status | head -10

echo ""
echo "=== Security ==="
sudo fail2ban-client status sshd 2>/dev/null || echo "fail2ban not running"
sudo systemctl is-active unattended-upgrades

echo ""
echo "=== Conntrack ==="
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

echo ""
echo "=== Dokploy ==="
curl -s -o /dev/null -w "Dokploy dashboard: HTTP %{http_code}\n" http://localhost:3000
```

Expected:
- `vm.overcommit_memory = 1`, `vm.swappiness = 1`, `dirty_ratio = 15`, `dirty_background_ratio = 5`
- `fs.file-max = 2097152`, `inotify.max_user_watches = 524288`
- `net.core.somaxconn = 65535`, `rmem_max = 16777216`, `wmem_max = 16777216`
- `tcp_keepalive_time = 60`, `intvl = 10`, `probes = 6`
- `tcp_tw_reuse = 1`, `tcp_max_tw_buckets = 262144`
- `nf_conntrack_max = 262144`
- THP: `always madvise [never]`
- No swap entries (or 0B total)
- `ulimit -n` = 262144 (host and container)
- Docker: `json-file`, `overlay2`, live restore `false`
- UFW: active, with rules for 22, 80, 443, 3000
- NTP service: active, clock synchronized: yes
- DNS: Cloudflare/Google upstream with caching
- fail2ban: active on sshd
- conntrack count well below max (262144)
- Dokploy dashboard: HTTP 200

## Application Order Summary

| Step | What | Downtime? |
|---|---|---|
| 1. System updates | `apt upgrade` + reboot | Yes (~30s) |
| 2. Install Dokploy | Curl install script | No |
| 3. Kernel sysctl | Instant via `sysctl --system` | No |
| 4. Disable THP | Instant via systemd unit | No |
| 5. Docker daemon | Requires `systemctl restart docker` | Brief (~5s) |
| 6. File descriptors | Append to limits.conf | No (next login) |
| 7. Disable swap | Instant | No |
| 8. Disable services | Instant | No |
| 9. Journal limits | Instant | No |
| 10. DNS caching | Instant | No |
| 11. Filesystem fstab | Requires reboot | Yes |
| 12. Firewall & security | Instant (except UFW enable) | No |
| 13. Time sync | Instant | No |
| 14. Huge pages | Optional | No |
| 15. Final reboot | Single reboot for fstab + THP | Yes (~30s) |

## 17. What's Next

This server is now ready for any Dokploy template. Follow the app-specific guide for your deployment:

| Template | Deploy Guide | Extra Server Setup |
|----------|-------------|-------------------|
| **Supabase** | [`supabase/DEPLOY-GUIDE.md`](supabase/DEPLOY-GUIDE.md) | None (kernel tuning covered above) |
| **Trigger.dev Webapp** | [`trigger/DEPLOY-GUIDE.md`](trigger/DEPLOY-GUIDE.md) | None (kernel tuning covered above) |
| **Trigger.dev Worker** | [`trigger/DEPLOY-GUIDE.md`](trigger/DEPLOY-GUIDE.md) | [`trigger/server-setup-worker.md`](trigger/server-setup-worker.md) (port range + firewall) |

> **Trigger.dev Worker servers** need additional setup from [`server-setup-worker.md`](trigger/server-setup-worker.md): ephemeral port range expansion (`ip_local_port_range`) and port 8020 firewall rules. Run those after completing this guide.
