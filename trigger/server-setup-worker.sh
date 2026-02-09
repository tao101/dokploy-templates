#!/bin/bash
# ============================================================
# Trigger.dev Worker Server Setup (Dokploy)
# ============================================================
# Run this on each worker server before deploying the worker compose.
# This server runs: supervisor, docker-proxy, and spawned task containers.
#
# Usage: sudo bash server-setup-worker.sh
#
# IMPORTANT: Set WEBAPP_IP below before running!
# ============================================================

set -e

# ============================================
# CONFIGURATION - SET THIS BEFORE RUNNING
# ============================================

# IP address of your webapp server (where trigger-webapp is deployed)
# The supervisor workload API (port 8020) will only be accessible from this IP
WEBAPP_IP="CHANGE_ME"

if [ "$WEBAPP_IP" = "CHANGE_ME" ]; then
  echo "ERROR: Set WEBAPP_IP at the top of this script before running."
  echo "This is the IP of your webapp server (where trigger-webapp is deployed)."
  exit 1
fi

echo "=== Trigger.dev Worker Server Setup ==="
echo "Webapp IP: $WEBAPP_IP"
echo ""

# ============================================
# 1. KERNEL PARAMETERS (sysctl)
# ============================================

echo "--- Applying kernel parameters ---"

# Minimize swap - task containers should never swap
sysctl -w vm.swappiness=1

# Maximum open file descriptors - each task container needs many
sysctl -w fs.file-max=2097152

# Connection backlog for many concurrent container connections
sysctl -w net.core.somaxconn=65535

# TCP keepalive: detect dead connections faster
sysctl -w net.ipv4.tcp_keepalive_time=60
sysctl -w net.ipv4.tcp_keepalive_intvl=10
sysctl -w net.ipv4.tcp_keepalive_probes=6

# Recycle TIME_WAIT sockets - important with many short-lived task containers
sysctl -w net.ipv4.tcp_tw_reuse=1

# Expand ephemeral port range for many concurrent containers
# Default is 32768-60999 (~28K ports), this gives ~64K ports
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

echo ""

# ============================================
# 2. PERSIST SYSCTL SETTINGS
# ============================================

echo "--- Persisting sysctl settings ---"

cat >> /etc/sysctl.conf << 'EOF'

# --- Trigger.dev Worker Server Tuning ---
vm.swappiness=1
fs.file-max=2097152
net.core.somaxconn=65535
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
EOF

echo "Settings persisted to /etc/sysctl.conf"
echo ""

# ============================================
# 3. FILE DESCRIPTOR LIMITS
# ============================================

echo "--- Setting file descriptor limits ---"

cat >> /etc/security/limits.conf << 'EOF'

# --- Trigger.dev: many task containers ---
* soft nofile 262144
* hard nofile 262144
root soft nofile 262144
root hard nofile 262144
EOF

echo "File descriptor limits set in /etc/security/limits.conf"
echo ""

# ============================================
# 4. DISABLE SWAP (dedicated servers)
# ============================================

echo "--- Disabling swap ---"

swapoff -a

# Comment out swap entries in fstab to persist across reboots
sed -i '/\sswap\s/s/^/#/' /etc/fstab

echo "Swap disabled and fstab entries commented out"
echo ""

# ============================================
# 5. FIREWALL - Restrict port 8020
# ============================================

echo "--- Configuring firewall ---"

# The supervisor exposes port 8020 (workload API) which the webapp
# needs to reach. Restrict to webapp IP only for security.

if command -v ufw &> /dev/null; then
  echo "Using ufw..."
  ufw allow from "$WEBAPP_IP" to any port 8020 comment "Trigger.dev webapp -> supervisor workload API"
  ufw deny 8020 comment "Block all other access to supervisor API"
  echo "ufw rules added for port 8020 (allowed from $WEBAPP_IP only)"
elif command -v firewall-cmd &> /dev/null; then
  echo "Using firewalld..."
  firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$WEBAPP_IP port protocol=tcp port=8020 accept"
  firewall-cmd --reload
  echo "firewalld rule added for port 8020 (allowed from $WEBAPP_IP only)"
else
  echo "WARNING: No ufw or firewalld found. Manually restrict port 8020 to $WEBAPP_IP"
  echo "Example iptables rule:"
  echo "  iptables -A INPUT -p tcp --dport 8020 -s $WEBAPP_IP -j ACCEPT"
  echo "  iptables -A INPUT -p tcp --dport 8020 -j DROP"
fi

echo ""

# ============================================
# 6. VERIFICATION
# ============================================

echo "=== Verification ==="
echo ""
echo "vm.swappiness         = $(sysctl -n vm.swappiness) (expected: 1)"
echo "fs.file-max           = $(sysctl -n fs.file-max) (expected: 2097152)"
echo "net.core.somaxconn    = $(sysctl -n net.core.somaxconn) (expected: 65535)"
echo "tcp_keepalive_time    = $(sysctl -n net.ipv4.tcp_keepalive_time) (expected: 60)"
echo "tcp_keepalive_intvl   = $(sysctl -n net.ipv4.tcp_keepalive_intvl) (expected: 10)"
echo "tcp_keepalive_probes  = $(sysctl -n net.ipv4.tcp_keepalive_probes) (expected: 6)"
echo "tcp_tw_reuse          = $(sysctl -n net.ipv4.tcp_tw_reuse) (expected: 1)"
echo "ip_local_port_range   = $(sysctl -n net.ipv4.ip_local_port_range) (expected: 1024 65535)"
echo "Swap active:           $(swapon --show | wc -l) entries (expected: 0)"
echo "Docker:                $(docker --version 2>/dev/null || echo 'NOT INSTALLED')"
echo ""
echo "=== Worker server setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Deploy trigger-worker-docker-compose.yml via Dokploy"
echo "  2. Set TRIGGER_API_URL, TRIGGER_WORKER_TOKEN, and other env vars"
echo "  3. See DEPLOY-GUIDE.md for full instructions"
