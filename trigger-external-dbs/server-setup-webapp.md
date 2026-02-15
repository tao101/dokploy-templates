# Webapp Server Setup

> **Run [`../SERVER-SETUP.md`](../SERVER-SETUP.md) first.** It covers system updates, Dokploy install, Docker daemon tuning, kernel parameters, file descriptors, swap, firewall, and NTP. Then come back here for webapp-specific tuning.

Run these commands on the server where the webapp compose will be deployed. This server runs: trigger (web app) and registry only — databases are on a separate server.

All commands require `sudo`.

## 1. Kernel Parameters

Apply immediately:

```bash
sudo sysctl -w vm.swappiness=1
sudo sysctl -w fs.file-max=262144
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.ipv4.tcp_keepalive_time=60
sudo sysctl -w net.ipv4.tcp_keepalive_intvl=10
sudo sysctl -w net.ipv4.tcp_keepalive_probes=6
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
```

What each does:
- `vm.swappiness=1` — Minimize swap usage
- `fs.file-max=262144` — Standard limit (lower than DB server since no ClickHouse)
- `net.core.somaxconn=65535` — Connection backlog for incoming HTTP requests
- `tcp_keepalive_time/intvl/probes` — Detect dead connections to remote DBs in ~2 min
- `tcp_tw_reuse=1` — Recycle TIME_WAIT sockets for DB connection pools to remote server

## 2. Persist Across Reboots

Append to `/etc/sysctl.conf`:

```bash
echo "" | sudo tee -a /etc/sysctl.conf
echo "# --- Trigger.dev Webapp Server Tuning ---" | sudo tee -a /etc/sysctl.conf
echo "vm.swappiness=1" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=262144" | sudo tee -a /etc/sysctl.conf
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
echo "# --- Trigger.dev: webapp + registry ---" | sudo tee -a /etc/security/limits.conf
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "root soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "root hard nofile 65536" | sudo tee -a /etc/security/limits.conf
```

## 4. Disable Swap

```bash
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
```

## 5. Verify

```bash
sysctl vm.swappiness fs.file-max net.core.somaxconn
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
sysctl net.ipv4.tcp_tw_reuse
swapon --show
ulimit -n
```

Expected:
- `vm.swappiness = 1`
- `fs.file-max = 262144`
- `net.core.somaxconn = 65535`
- `tcp_keepalive_time = 60`, `intvl = 10`, `probes = 6`
- `tcp_tw_reuse = 1`
- No swap entries
- `ulimit -n` = 65536 (may need re-login)
