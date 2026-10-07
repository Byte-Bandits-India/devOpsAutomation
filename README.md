# AWS EC2 Multi-Project DevOps Deployment Platform

A centralized, declarative, isolated, and automated deployment platform designed for AWS EC2 instances hosting multiple independent web applications and backend APIs.

```text
GitHub Actions CI/CD (Per Repository)
              │
              ▼ (Build in CI: Next.js / Vite / Express)
     Production Artifact (.tar.gz)
              │
              ▼ (SSH / SCP via Reusable Workflow)
       Target EC2 Server (/tmp)
              │
              ▼ (devops-automation/scripts/deploy.sh)
    ┌─────────────────────────────────────────────────────────┐
    │  /var/www/<project>/releases/<timestamp>                │
    │  ├── Atomic Symlink Switch (current -> release)        │
    │  ├── Persistent Shared Symlinks (.env, uploads, db)     │
    │  ├── Isolated PM2 Reload (pm2 startOrReload <proj>)     │
    │  ├── Isolated Nginx Config (/etc/nginx/conf.d/<domain>) │
    │  └── Automated Deep Health Check (/health or /ping)     │
    └─────────────────────────────────────────────────────────┘
              │ (If health check fails)
              └──► Instant Automatic Rollback to previous release
```

---

## 🌟 Key Architectural Principles

1. **100% Native Runtime (Host Nginx + PM2 + PHP-FPM)**:
   - Zero Docker runtime dependency in production.
   - Eliminated container virtualization overhead, cgroup memory contention, and port collisions on a resource-constrained `t3.micro` instance (913 MB RAM, 10 GB disk).
2. **Zero Cross-Project Blast Radius**:
   - Every project runs in its own directory tree (`/var/www/<project>/`).
   - Every project has an isolated PM2 ecosystem config (`/var/www/<project>/ecosystem.config.cjs`). Deploying Project A **never** restarts or reloads Project B.
   - Every domain has an isolated Nginx virtual host configuration (`/etc/nginx/conf.d/<domain>.conf`).
3. **Atomic Deployments & Zero Downtime**:
   - Deploys to a new timestamped release folder.
   - Atomically switches the `current` symlink via `ln -sfn`.
   - Performs automated health checks against local endpoints before marking active.
   - Instantly rolls back symlink and PM2 state if the health check fails.
4. **Single Source of Truth (`config/projects.yml`)**:
   - Central registry defining ports, domains, memory limits, persistent assets, health check paths, and database types for all server projects.

---

## 📁 System Layout

```text
/opt/devops-automation/
├── config/
│   └── projects.yml                 # Declarative registry of all projects & ports
├── templates/
│   ├── nginx/
│   │   ├── reverse-proxy.conf.j2    # Template for standard Next.js / Node upstreams
│   │   ├── hybrid-crm.conf.j2       # Template for static SPA + Node API + phpMyAdmin
│   │   └── static-spa.conf.j2       # Template for pure static frontends
│   ├── pm2/
│   │   └── ecosystem.config.cjs.j2  # Template for isolated PM2 process manifests
│   └── systemd/
│       └── pm2-ec2-user.service     # Clean native Amazon Linux 2023 PM2 service
├── scripts/
│   ├── deploy.sh                    # Core atomic release & deployment engine
│   ├── rollback.sh                  # Instant one-step rollback engine
│   ├── health-check.sh              # Deep health probe runner
│   ├── status.sh                    # Unified multi-project status dashboard
│   ├── backup-databases.sh          # SQLite WAL checkpoint & MySQL dump engine
│   ├── generate-nginx.sh            # Generates isolated Nginx virtual host configs
│   ├── generate-pm2.sh              # Generates isolated PM2 ecosystem configs
│   ├── cutover-nginx.sh             # Zero-downtime ingress migration engine
│   ├── rollback-ingress.sh          # Ingress emergency fallback engine
│   ├── cleanup.sh                   # Release & log retention pruner
│   └── validate-infrastructure.sh   # Comprehensive pre-flight system auditor
├── .github/workflows/
│   └── deploy.yml                   # Reusable GitHub Actions deployment pipeline
└── examples/
    ├── nextjs-workflow.yml          # Example CI/CD for Next.js 14/15 Standalone
    ├── express-workflow.yml         # Example CI/CD for Express / Node.js APIs
    └── static-spa-workflow.yml      # Example CI/CD for React / Vite SPAs
```

---

## 🚀 How to Add a New Project (3 Simple Steps)

When you create a new application or connect an existing GitHub repository, you only need to complete three simple steps:

### Step 1: Register in `config/projects.yml`

Open `/opt/devops-automation/config/projects.yml` and add your project block. For example:

```yaml
  my-new-app:
    repository: "Byte-Bandits-India/my-new-app"
    type: "nextjs-standalone"          # or 'node' or 'static-spa'
    environment: "production"
    allowed_branches:
      - "main"
    domain: "app.xylozentech.com"
    bind_ip: "127.0.0.1"
    port: 3004                         # Choose next available port (e.g. 3004, 3005)
    health_check:
      path: "/"
      expected_status: 200
      timeout_seconds: 5
      max_retries: 5
      retry_delay_seconds: 3
    runtime:
      entrypoint: "server.js"
      manager: "pm2"
    resources:
      memory_max_restart: "250M"       # Memory ceiling for PM2 auto-restart
    persistent:
      directories:
        - "public/uploads"             # Shared paths preserved across releases
```

### Step 2: Initialize Server Configuration & SSL (Single Command)

Run the automated onboarding engine to check ports, create directories, configure Nginx, and request SSL:

```bash
/opt/devops-automation/scripts/onboard-project.sh my-new-app --issue-ssl
```

This single command:
1. Validates `projects.yml` and verifies the assigned port has no collisions.
2. Creates `/var/www/<project>/releases` and `/var/www/<project>/shared` (with `.env` template).
3. Generates the isolated Nginx virtual host configuration (`/etc/nginx/conf.d/<domain>.conf`).
4. Issues a trusted Let's Encrypt SSL certificate and reloads Nginx.
5. Generates the isolated PM2 process manifest (`ecosystem.config.cjs`).

### Step 3: Connect Your GitHub Repository

In your application's GitHub repository, add `.github/workflows/deploy.yml`:

```yaml
name: Production Deployment

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci && npm run build
      
      # Package production artifact
      - run: |
          mkdir -p /tmp/artifact
          cp -a .next/standalone/. /tmp/artifact/
          mkdir -p /tmp/artifact/.next
          cp -a .next/static /tmp/artifact/.next/
          cp -a public /tmp/artifact/ 2>/dev/null || true
          tar -czf /tmp/release.tar.gz -C /tmp/artifact .

      # Trigger centralized deployment engine
      - uses: Byte-Bandits-India/devOpsAutomation/.github/workflows/deploy.yml@main
        with:
          project_name: "my-new-app"
          environment: "production"
          artifact_path: "/tmp/release.tar.gz"
        secrets:
          EC2_HOST: ${{ secrets.EC2_HOST }}
          EC2_USER: ${{ secrets.EC2_USER }}
          EC2_SSH_KEY: ${{ secrets.EC2_SSH_KEY }}
```

**That's it!** Every `git push` to `main` will build the artifact in GitHub Actions, SCP it to EC2, execute `deploy.sh`, reload only that PM2 process, verify health, and prune old releases without affecting any other project.

---

## 🛠️ Operational Command Cheat Sheet

All administrative operations are accessible directly on the EC2 server:

| Operation | Command | Description |
| :--- | :--- | :--- |
| **Status Overview** | `/opt/devops-automation/scripts/status.sh` | Visual multi-project dashboard showing RAM, disk, ports, PM2 status, active releases, and domains. |
| **Deploy Project** | `/opt/devops-automation/scripts/deploy.sh <project> <artifact>` | Deploys an artifact (.tar.gz or dir) with atomic switch & health check. |
| **Instant Rollback** | `/opt/devops-automation/scripts/rollback.sh <project>` | Reverts `current` symlink to previous release and reloads PM2 in < 2s. |
| **Health Check** | `/opt/devops-automation/scripts/health-check.sh <project>` | Performs retried HTTP health check against local port. |
| **Database Backup** | `/opt/devops-automation/scripts/backup-databases.sh` | Safe SQLite WAL checkpoint + snapshot & MySQL compressed dump. |
| **Prune Old Releases** | `/opt/devops-automation/scripts/cleanup.sh [project]` | Enforces 3-release retention and cleans old deployment logs. |
| **Infrastructure Audit**| `/opt/devops-automation/scripts/validate-infrastructure.sh` | Comprehensive pre-flight check of disk, RAM, ports, PM2, and Nginx. |
| **Ingress Fallback** | `/opt/devops-automation/scripts/rollback-ingress.sh` | Stops Nginx and brings Caddy back online in < 2 seconds. |

---

## 📋 Active Applications & Port Allocation

| Component | Port | Type | Domain | Active Release / Path | Memory Limit |
| :--- | :---: | :--- | :--- | :--- | :---: |
| **Titan Eye** | `3001` | Node / Express + SQLite WAL | `titan.xylozentech.com` | `/var/www/titan/current` | `250M` |
| **Xylozen** | `3002` | Next.js 14 Standalone | `xylozentech.com`, `www.xylozentech.com` | `/var/www/xylozen/current` | `250M` |
| **ByteBandits** | `3003` | Next.js 15 Standalone | `thebytebandits.com`, `www.thebytebandits.com` | `/var/www/bytebandits/current` | `250M` |
| **CRM Prod API** | `4001` | Node / Express + MySQL | `crm.xylozentech.com/api` | `/var/www/dashboard-prod-backend/current` | `300M` |
| **CRM Prod Frontend**| `-` | Static SPA | `crm.xylozentech.com/` | `/var/www/dashboard-prod-frontend/current/dist` | N/A |
| **CRM Test API** | `4002` | Node / Express + MySQL | `testcrm.xylozentech.com/api` | `/var/www/dashboard-test-backend/current` | `250M` |
| **CRM Test Frontend**| `-` | Static SPA | `testcrm.xylozentech.com/` | `/var/www/dashboard-test-frontend/current/dist` | N/A |
| **phpMyAdmin** | `-` | Native PHP-FPM (`/run/php-fpm/www.sock`) | `crm.xylozentech.com/phpmyadmin/` | `/var/www/phpmyadmin` | N/A |

---

## ⏰ Automated Systemd Timers

1. **SSL Automated Renewals**:
   - `certbot-renew.timer` (runs twice daily).
   - Deployment hook in `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` automatically reloads Nginx upon successful renewal.
2. **Automated Database Backups**:
   - `db-backup.timer` (runs daily at `03:00 UTC`).
   - Executes `/opt/devops-automation/scripts/backup-databases.sh` and logs to `/var/log/deployments/db-backup.log`.
3. **PM2 Process Persistence**:
   - `pm2-ec2-user.service` enabled under systemd to automatically resurrect PM2 processes on server reboot.
