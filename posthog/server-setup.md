# PostHog Server Setup — Hetzner CX43

> **Run [`../SERVER-SETUP.md`](../SERVER-SETUP.md) first.** It covers system updates, Dokploy
> install, Docker daemon tuning, base kernel parameters, file descriptor limits, journal limits,
> firewall, fail2ban, SSH hardening and NTP. This file only covers what PostHog needs **on top of**
> that guide — plus one setting it deliberately **reverses**.

The target is a Hetzner Cloud **CX43**: 8 shared AMD EPYC vCPU @ 2.0 GHz, 16 GB RAM, 160 GB local
NVMe, Ubuntu 24.04, running PostHog and nothing else, registered as a Dokploy **remote server**.

All commands need `sudo`.

---

## 0. Know what you are running on

Two things about the CX43 shape the whole configuration and are worth internalising before you start:

**16 GB is PostHog's stated floor, not comfortable headroom.** PostHog's own requirement is
"4 vCPU, 16 GB RAM, more than 30 GB storage", and their installer prints *"You REALLY need 8GB or
more of memory to run this stack"*. The stack is ~35 containers: ClickHouse, PostgreSQL, Redpanda,
ZooKeeper, Redis, Valkey, Temporal, MinIO, SeaweedFS, headless Chromium, three Django processes,
seven Node consumers and eleven Rust/Go services. With this template's limits, steady state is
about **12 GB of the 16 GB**. That is workable, and it is why sections 1 and 2 below exist.

**The vCPUs are shared, not dedicated.** CX43 is Hetzner's cost-optimised line, so you can see CPU
steal from neighbours. ClickHouse queries and ingestion bursts will be less predictable than on a
CCX box. If you later find query latency is the problem rather than memory, the fix is a dedicated
vCPU instance, not more tuning.

---

## 1. Enable swap — reversing the shared guide

`../SERVER-SETUP.md` section 7 disables swap, which is correct for the Supabase and Trigger.dev
templates: those run on machines with RAM to spare, where any swapping means something is wrong.

**PostHog on 16 GB is the exception.** Django, Celery and the Node consumers all hold a large set
of cold pages they touch once at import and never again. Without swap, those pages sit in RAM at
the expense of ClickHouse's page cache, and any spike — a large query, a heatmap render, a merge —
puts the machine one allocation away from the OOM killer. The OOM killer does not pick politely;
it tends to pick the biggest process, which is ClickHouse.

Swap here is not a performance tier. It is the difference between "a container gets slow for a few
seconds" and "ClickHouse is killed mid-merge".

```bash
# Undo the shared guide's swapoff, if you already ran it
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Then override the shared guide's `vm.swappiness = 1`:

```bash
printf '# PostHog on 16 GB: swap is an OOM safety net, not a performance tier.
# Overrides vm.swappiness=1 from 99-dokploy.conf (higher-numbered file wins).
vm.swappiness = 10
# ClickHouse maps a lot of small files; the 65530 default runs out.
vm.max_map_count = 262144
' | sudo tee /etc/sysctl.d/99-posthog.conf

sudo sysctl --system
```

Verify:

```bash
free -h                      # Swap: 8.0Gi total
sysctl vm.swappiness         # = 10
sysctl vm.max_map_count      # = 262144
```

> If `swapon` reports the file is already in use, swap is on already — skip to the sysctl block.

---

## 2. Confirm the ClickHouse-critical limits are in place

These all come from `../SERVER-SETUP.md`; this is just the check that they landed, because
ClickHouse is the service that fails first when they haven't.

```bash
sysctl fs.file-max            # 2097152
sysctl vm.overcommit_memory   # 1   (Redis BGSAVE)
ulimit -n                     # 262144 (re-login if it still shows 1024)
cat /sys/kernel/mm/transparent_hugepage/enabled   # always madvise [never]
```

Transparent hugepages must be `[never]`. ClickHouse logs a startup warning and suffers latency
spikes with THP on; `../SERVER-SETUP.md` section 4 disables it.

---

## 3. Plan the 160 GB disk before you have data on it

160 GB is the real constraint on how long this instance stays useful. Rough budget:

| Consumer | Steady state | Notes |
|---|---|---|
| Docker images | ~15 GB | Over half is `posthog/posthog`: 7.3 GB unpacked (~2.7 GB over the wire), pulled once and shared by 4 services |
| ClickHouse (`clickhouse-data`) | grows forever | events, persons, session metadata — **the one to watch** |
| SeaweedFS (`seaweedfs-data`) | grows forever | session replay snapshot blobs, the fastest grower per event |
| MinIO (`objectstorage-data`) | small | exports and AI blobs |
| PostgreSQL (`postgres-data`) | 2–10 GB | app metadata, flags, insights, Temporal |
| Redpanda (`redpanda-data`) | ≤ ~30 GB worst case | bounded by `KAFKA_RETENTION_*` in the env file |
| System + Dokploy + Traefik | ~5 GB | |

Redpanda is bounded by config. ClickHouse and SeaweedFS are not — they grow with the events and
recordings you send, and neither has a default retention policy. Set up the alarm now rather than
discovering it at 100% full, which on ClickHouse means a corrupted merge, not a clean stop.

```bash
# Weekly disk report to root's mail / journal, and a hard warning at 80%
printf '#!/bin/sh
USED=$(df --output=pcent / | tail -1 | tr -dc "0-9")
[ "$USED" -ge 80 ] && echo "PostHog host disk at ${USED}%% — prune ClickHouse or session recordings"
' | sudo tee /usr/local/bin/posthog-disk-check
sudo chmod +x /usr/local/bin/posthog-disk-check
( sudo crontab -l 2>/dev/null; echo "0 8 * * * /usr/local/bin/posthog-disk-check" ) | sudo crontab -
```

Check actual usage any time with:

```bash
docker system df -v | grep -E 'posthog|VOLUME NAME'
df -h /
```

`DEPLOY-GUIDE.md` has the pruning procedures for when this starts climbing.

---

## 4. Firewall

`../SERVER-SETUP.md` section 12 sets up UFW. For a PostHog remote server, the open set is small —
**no database, ClickHouse, Kafka or MinIO port is published to the host by this template**, so
there is nothing extra to allow:

```bash
sudo ufw status verbose
```

Expected:

- `22/tcp` — SSH (ideally limited to your IP and the Dokploy master's IP)
- `80/tcp`, `443/tcp` — Traefik, which fronts the `proxy` (Caddy) container
- everything else denied

The Dokploy master manages this server over SSH only; it does not need any other inbound port.

If you restrict SSH by source address, remember the Dokploy master needs in:

```bash
sudo ufw allow from <DOKPLOY_MASTER_IP> to any port 22 proto tcp
```

---

## 5. Docker log caps

The compose file caps each container at `50m x 3` files. With ~35 containers that is a 5.25 GB
ceiling on logs alone, so also confirm the daemon-level default from `../SERVER-SETUP.md`
section 5 is in place — it catches anything Dokploy starts outside this stack:

```bash
sudo cat /etc/docker/daemon.json | grep -A4 log-opts
```

---

## 6. Verify before deploying

```bash
echo "vCPU:      $(nproc)"                        # 8
echo "RAM:       $(free -g | awk '/^Mem:/{print $2}') GB"   # 15
echo "Swap:      $(free -g | awk '/^Swap:/{print $2}') GB"  # 7 or 8
echo "Disk:      $(df -h / | awk 'NR==2{print $4}') free"   # ~150G
echo "swappiness: $(sysctl -n vm.swappiness)"     # 10
echo "max_map_count: $(sysctl -n vm.max_map_count)" # 262144
echo "file-max:  $(sysctl -n fs.file-max)"        # 2097152
echo "nofile:    $(ulimit -n)"                    # 262144
echo "THP:       $(cat /sys/kernel/mm/transparent_hugepage/enabled)"  # [never]
echo "overcommit: $(sysctl -n vm.overcommit_memory)"  # 1
docker info --format 'Docker {{.ServerVersion}} / {{.Driver}}'
```

Once all of these look right, continue with [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md).
