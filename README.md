# Dokploy Templates

A collection of production-ready Docker Compose templates I use and open-source for anyone who wants to self-host **Supabase** and **Trigger.dev** using [Dokploy](https://dokploy.com).

Every template is **fully standalone** — config files are embedded inline in the compose file using Docker Compose `configs:`, so you just paste the compose + env into Dokploy and deploy. No external file mounts needed.

## What's Included

| Directory | What it deploys | Docs |
|---|---|---|
| [`supabase/`](supabase/) | Self-hosted Supabase (12 services: Postgres, Kong, Auth, REST, Realtime, Storage, Studio, etc.) — standard and optimized (Hetzner CCX33) variants | [README](supabase/README.md) · [Deploy Guide](supabase/DEPLOY-GUIDE.md) |
| [`trigger/`](trigger/) | Trigger.dev webapp + worker on separate servers (all-in-one compose per server) | [Deploy Guide](trigger/DEPLOY-GUIDE.md) |
| [`trigger-external-dbs/`](trigger-external-dbs/) | Trigger.dev with a dedicated DB server — databases on a remote, webapp as a Swarm stack, workers on separate remotes | [Deploy Guide](trigger-external-dbs/DEPLOY-GUIDE.md) |

## Key Features

- **Standalone templates** — paste compose + env into Dokploy, no extra files to mount
- **Production-tuned** — PostgreSQL, Redis, connection pooling, and resource limits sized for real workloads
- **Tiered resource configs** — env vars pre-configured for 4 server tiers (4–32 vCPU / 16–128GB RAM)
- **Secrets placeholders** — all sensitive values are `you-need-to-generate-this-value` with generation instructions in comments
- **Comprehensive docs** — deploy guides, server setup scripts, and architecture diagrams per template

## Prerequisites

- A Linux server (tested on Hetzner Cloud dedicated vCPU instances, Ubuntu 24.04)
- [Dokploy](https://dokploy.com) installed (`curl -sSL https://dokploy.com/install.sh | sh`)
- DNS records pointing to your server

## Getting Started

1. **Prepare your server** — follow [`SERVER-SETUP.md`](SERVER-SETUP.md) for kernel tuning, firewall, Docker config, and security hardening
2. **Pick a template** — choose from the table above based on what you want to deploy
3. **Follow the deploy guide** — each directory has step-by-step instructions
4. **Generate secrets** — replace all `you-need-to-generate-this-value` placeholders in the `.env` file (each has a comment showing the exact command)

## Directory Structure

```
├── SERVER-SETUP.md                          # Server prep (run first)
├── supabase/
│   ├── README.md                            # Full Supabase guide
│   ├── DEPLOY-GUIDE.md                      # Step-by-step deployment
│   ├── kernel-tuning-notes.md               # Optional host tuning
│   ├── supabase-docker-compose.yml          # Standard deployment
│   ├── supabase.env                         # Standard env template
│   ├── optimized-supabase-docker-compose.yml # Tuned for Hetzner CCX33
│   └── optimized-supabase.env               # Optimized env template
├── trigger/
│   ├── DEPLOY-GUIDE.md                      # Distributed deployment guide
│   ├── server-setup-webapp.md               # Webapp server tuning
│   ├── server-setup-worker.md               # Worker server tuning
│   ├── trigger-webapp-docker-compose.yml    # Webapp compose
│   ├── trigger-webapp.env                   # Webapp env template
│   ├── trigger-worker-docker-compose.yml    # Worker compose
│   └── trigger-worker.env                   # Worker env template
└── trigger-external-dbs/
    ├── DEPLOY-GUIDE.md                      # Multi-server deployment guide
    ├── server-setup-dbs.md                  # DB server tuning + firewall
    ├── server-setup-webapp.md               # Swarm webapp setup
    ├── server-setup-worker.md               # Worker server setup
    ├── trigger-dbs-docker-compose.yml       # Database services compose
    ├── trigger-dbs.env                      # DB env template
    ├── trigger-webapp-docker-compose.yml    # Webapp Swarm stack compose
    ├── trigger-webapp.env                   # Webapp env template
    ├── trigger-worker-docker-compose.yml    # Worker compose
    └── trigger-worker.env                   # Worker env template
```

## License

MIT
