# AWS EC2 Multi-Project Deployment Automation Platform

A declarative, isolated, zero-downtime deployment platform designed for hosting multiple production and test applications on a single AWS EC2 instance without cross-project interference.

---

## Architecture Overview

* **Source of Truth:** `config/projects.yml`
* **Process Manager:** PM2 (with dedicated per-project ecosystem files)
* **Reverse Proxy:** Nginx (with modular per-domain configurations)
* **Deployment Pattern:** Atomic release directories with symlink switching (`releases/<TIMESTAMP>` → `current`)
* **Persistence:** Preserved `.env`, persistent database files (SQLite WAL), and user uploads in `shared/`
* **Failure Safety:** Automated pre-flight health checks and instant rollback to previous stable release

---

## Directory Structure

```text
/opt/devops-automation/
├── config/
│   └── projects.yml              # Central registry of all projects, ports, domains
├── templates/
│   ├── nginx/
│   │   ├── reverse-proxy.conf.j2 # Standard Node / Next.js proxy
│   │   └── hybrid-crm.conf.j2    # Hybrid virtual host (Static SPA + API + Uploads + PMA)
│   ├── pm2/
│   │   └── ecosystem.config.cjs.j2
│   └── systemd/
│       └── pm2-ec2-user.service   # Clean Amazon Linux PM2 boot persistence unit
├── scripts/
│   ├── deploy.sh                 # Atomic release deployment orchestrator
│   ├── rollback.sh               # Rollback handler (automatic or manual)
│   ├── health-check.sh           # Non-blocking health checker
│   ├── generate-nginx.sh         # Idempotent domain config generator
│   ├── generate-pm2.sh           # Isolated PM2 config generator
│   ├── validate-infrastructure.sh# Pre-flight system and syntax validator
│   ├── cleanup.sh                # Release pruner (preserves latest 3)
│   ├── status.sh                 # System observability dashboard
│   ├── cutover-nginx.sh          # Pre-validated Caddy → Nginx cutover script
│   └── rollback-ingress.sh       # Instant Nginx → Caddy fallback script
└── .github/
    └── workflows/
        └── deploy.yml            # Reusable GitHub Actions deployment pipeline
```

---

## On-Server Commands

```bash
# Check status of all applications and system resources
/opt/devops-automation/scripts/status.sh

# Run pre-flight infrastructure validation
/opt/devops-automation/scripts/validate-infrastructure.sh

# Deploy a new release manually
/opt/devops-automation/scripts/deploy.sh <project_name> <artifact_tarball_path>

# Roll back to the previous release
/opt/devops-automation/scripts/rollback.sh <project_name>

# Back up SQLite (Titan WAL) and MySQL
/opt/devops-automation/scripts/backup-databases.sh
```

---

## Adding a New Project in 3 Steps

1. **Add entry to `config/projects.yml`:**
   ```yaml
   projects:
     new-app:
       repository: "organization/new-app"
       type: "nextjs-standalone"
       environment: "production"
       domain: "app.example.com"
       bind_ip: "127.0.0.1"
       port: 3004
       health_check:
         path: "/"
         expected_status: 200
       runtime:
         entrypoint: "server.js"
         manager: "pm2"
       resources:
         memory_max_restart: "250M"
   ```

2. **In the application repository, build and trigger deployment:**
   Call the reusable GitHub Actions workflow `.github/workflows/deploy.yml`.

3. **Deploy:**
   The deployment engine will automatically create `/var/www/new-app/{releases,shared}`, allocate port `3004`, start PM2, generate `/etc/nginx/conf.d/app.example.com.conf`, and verify health without touching any existing project.
