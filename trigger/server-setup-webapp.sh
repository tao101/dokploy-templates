#!/bin/bash
# ============================================================
# Trigger.dev Webapp Server Setup (Dokploy)
# ============================================================
# Run this on the server where the webapp compose will be deployed.
# This server runs: trigger, postgres, redis, clickhouse, electric,
#                   minio, registry, and backup services.
#
# Usage: sudo bash server-setup-webapp.sh
# ============================================================

set -e

echo "=== Trigger.dev Webapp Server Setup ==="
echo ""

# ============================================
# 1. KERNEL PARAMETERS (sysctl)
# ============================================

echo "--- Applying kernel parameters ---"

# Redis: required for reliable BGSAVE and replication
# Without this, Redis logs: "WARNING Memory overcommit must be enabled!"
sysctl -w vm.overcommit_memory=1

# Minimize swap usage - PostgreSQL and Redis on swap is catastrophically slow
# Don't set to 0 (kernel needs some swap flexibility), 1 is the minimum
sysctl -w vm.swappiness=1

# Maximum open file descriptors system-wide
# ClickHouse needs 262144 per container, plus PG connections, task containers
sysctl -w fs.file-max=2097152

# Connection backlog for high-concurrency services
# PG max_connections=1500, ClickHouse max_concurrent_queries=300
sysctl -w net.core.somaxconn=65535

# TCP keepalive: detect dead connections faster
# Default is 7200s/75s/9 probes = ~2.3 hours to detect dead connection
# This reduces to 60s + 6*10s = ~2 minutes
sysctl -w net.ipv4.tcp_keepalive_time=60
sysctl -w net.ipv4.tcp_keepalive_intvl=10
sysctl -w net.ipv4.tcp_keepalive_probes=6

# Recycle TIME_WAIT sockets faster - important with many DB connections
sysctl -w net.ipv4.tcp_tw_reuse=1

# Huge pages for PostgreSQL shared_buffers
# Calculate: shared_buffers_in_MB / 2MB_per_page
# Examples:
#   4GB shared_buffers:  vm.nr_hugepages=2048
#   8GB shared_buffers:  vm.nr_hugepages=4096
#   16GB shared_buffers: vm.nr_hugepages=8192
#   32GB shared_buffers: vm.nr_hugepages=16384
# Uncomment the line matching your PG_SHARED_BUFFERS setting:
# sysctl -w vm.nr_hugepages=2048   # 4GB shared_buffers
# sysctl -w vm.nr_hugepages=4096   # 8GB shared_buffers
# sysctl -w vm.nr_hugepages=8192   # 16GB shared_buffers
# sysctl -w vm.nr_hugepages=16384  # 32GB shared_buffers

echo ""

# ============================================
# 2. PERSIST SYSCTL SETTINGS
# ============================================

echo "--- Persisting sysctl settings ---"

cat >> /etc/sysctl.conf << 'EOF'

# --- Trigger.dev Webapp Server Tuning ---
vm.overcommit_memory=1
vm.swappiness=1
fs.file-max=2097152
net.core.somaxconn=65535
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_tw_reuse=1
# Uncomment for huge pages (match your PG_SHARED_BUFFERS):
# vm.nr_hugepages=4096
EOF

echo "Settings persisted to /etc/sysctl.conf"
echo ""

# ============================================
# 3. FILE DESCRIPTOR LIMITS
# ============================================

echo "--- Setting file descriptor limits ---"

cat >> /etc/security/limits.conf << 'EOF'

# --- Trigger.dev: ClickHouse + high-concurrency services ---
* soft nofile 262144
* hard nofile 262144
root soft nofile 262144
root hard nofile 262144
EOF

echo "File descriptor limits set in /etc/security/limits.conf"
echo ""

# ============================================
# 4. DISABLE SWAP (32GB+ dedicated servers)
# ============================================

echo "--- Disabling swap ---"

swapoff -a

# Comment out swap entries in fstab to persist across reboots
sed -i '/\sswap\s/s/^/#/' /etc/fstab

echo "Swap disabled and fstab entries commented out"
echo ""

# ============================================
# 5. VERIFICATION
# ============================================

echo "=== Verification ==="
echo ""
echo "vm.overcommit_memory = $(sysctl -n vm.overcommit_memory) (expected: 1)"
echo "vm.swappiness        = $(sysctl -n vm.swappiness) (expected: 1)"
echo "fs.file-max           = $(sysctl -n fs.file-max) (expected: 2097152)"
echo "net.core.somaxconn    = $(sysctl -n net.core.somaxconn) (expected: 65535)"
echo "tcp_keepalive_time    = $(sysctl -n net.ipv4.tcp_keepalive_time) (expected: 60)"
echo "tcp_keepalive_intvl   = $(sysctl -n net.ipv4.tcp_keepalive_intvl) (expected: 10)"
echo "tcp_keepalive_probes  = $(sysctl -n net.ipv4.tcp_keepalive_probes) (expected: 6)"
echo "tcp_tw_reuse          = $(sysctl -n net.ipv4.tcp_tw_reuse) (expected: 1)"
echo "Swap active:           $(swapon --show | wc -l) entries (expected: 0)"
echo ""
echo "=== Webapp server setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Deploy trigger-webapp-docker-compose.yml via Dokploy"
echo "  2. Add domains in Dokploy UI (trigger:3000, registry:5000)"
echo "  3. See DEPLOY-GUIDE.md for full instructions"
