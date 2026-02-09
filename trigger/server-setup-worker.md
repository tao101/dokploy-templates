# Worker Server Setup

Run these commands on each worker server before deploying the worker compose. This server runs: supervisor, docker-proxy, and spawned task containers.

All commands require `sudo`.

## 1. Kernel Parameters

Apply immediately:

```bash
sudo sysctl -w vm.swappiness=1
sudo sysctl -w fs.file-max=2097152
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.ipv4.tcp_keepalive_time=60
sudo sysctl -w net.ipv4.tcp_keepalive_intvl=10
sudo sysctl -w net.ipv4.tcp_keepalive_probes=6
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"
```

What each does:
- `vm.swappiness=1` — Task containers should never swap
- `fs.file-max=2097152` — Each task container needs many file descriptors
- `net.core.somaxconn=65535` — Connection backlog for many concurrent containers
- `tcp_keepalive_time/intvl/probes` — Detect dead connections in ~2 min instead of ~2.3 hours
- `tcp_tw_reuse=1` — Recycle TIME_WAIT sockets with many short-lived task containers
- `ip_local_port_range=1024 65535` — ~64K ephemeral ports (default ~28K is too few for many containers)

## 2. Persist Across Reboots

Append to `/etc/sysctl.conf`:

```bash
echo "" | sudo tee -a /etc/sysctl.conf
echo "# --- Trigger.dev Worker Server Tuning ---" | sudo tee -a /etc/sysctl.conf
echo "vm.swappiness=1" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=2097152" | sudo tee -a /etc/sysctl.conf
echo "net.core.somaxconn=65535" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_time=60" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_intvl=10" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_probes=6" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_tw_reuse=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.ip_local_port_range=1024 65535" | sudo tee -a /etc/sysctl.conf
```

## 3. File Descriptor Limits

Append to `/etc/security/limits.conf`:

```bash
echo "" | sudo tee -a /etc/security/limits.conf
echo "# --- Trigger.dev: many task containers ---" | sudo tee -a /etc/security/limits.conf
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

## 5. Firewall — Restrict Port 8020

The supervisor exposes port 8020 (workload API) which the webapp server needs to reach. Restrict access to the webapp server IP only.

Replace `WEBAPP_IP` with the actual IP of your webapp server.

### Option A: ufw (Ubuntu/Debian)

```bash
sudo ufw allow from WEBAPP_IP to any port 8020 comment "Trigger.dev webapp -> supervisor"
sudo ufw deny 8020 comment "Block all other access to supervisor API"
```

### Option B: firewalld (RHEL/CentOS/Fedora)

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=WEBAPP_IP port protocol=tcp port=8020 accept'
sudo firewall-cmd --reload
```

### Option C: iptables (fallback)

```bash
sudo iptables -A INPUT -p tcp --dport 8020 -s WEBAPP_IP -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8020 -j DROP
```

## 6. Verify

```bash
sysctl vm.swappiness fs.file-max net.core.somaxconn
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
sysctl net.ipv4.tcp_tw_reuse net.ipv4.ip_local_port_range
swapon --show
ulimit -n
docker --version
```

Check firewall rules:

```bash
# ufw
sudo ufw status | grep 8020

# firewalld
sudo firewall-cmd --list-rich-rules

# iptables
sudo iptables -L -n | grep 8020
```

Expected:
- `vm.swappiness = 1`
- `fs.file-max = 2097152`
- `net.core.somaxconn = 65535`
- `tcp_keepalive_time = 60`, `intvl = 10`, `probes = 6`
- `tcp_tw_reuse = 1`
- `ip_local_port_range = 1024 65535`
- No swap entries
- Port 8020 allowed from webapp IP only
