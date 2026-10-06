#!/usr/bin/env bash
# ==============================================================================
# backup-databases.sh - Database Backup Engine
# Backs up SQLite (Titan with WAL checkpoint) and MySQL with verification.
# ==============================================================================

set -euo pipefail

BACKUP_ROOT="/var/backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

mkdir -p "${BACKUP_ROOT}/titan" "${BACKUP_ROOT}/mysql"

echo "======================================================================"
echo "          DevOps Automation - Database Backup Routine                 "
echo "  Timestamp: ${TIMESTAMP}                                             "
echo "======================================================================"

# 1. Titan SQLite Backup with WAL Checkpoint & Integrity Verification
TITAN_DB="/home/ec2-user/titan/database.db"
if [[ -f "/var/www/titan/shared/data/database.db" ]]; then
    TITAN_DB="/var/www/titan/shared/data/database.db"
fi

if [[ -f "$TITAN_DB" ]]; then
    echo "1. Backing up Titan SQLite database (${TITAN_DB})..."
    BACKUP_FILE="${BACKUP_ROOT}/titan/titan_${TIMESTAMP}.db"
    
    node - "$TITAN_DB" "$BACKUP_FILE" << 'EOF'
    const Database = require('/home/ec2-user/titan/node_modules/better-sqlite3');
    const sourceDb = process.argv[2];
    const targetDb = process.argv[3];

    try {
        const db = new Database(sourceDb);
        console.log("   Checkpointing WAL journal...");
        db.pragma("wal_checkpoint(TRUNCATE)");
        console.log("   Creating live snapshot...");
        db.backup(targetDb).then(() => {
            console.log("   Snapshot created. Verifying integrity...");
            const testDb = new Database(targetDb, { readonly: true });
            const check = testDb.pragma("integrity_check", { simple: true });
            if (check === "ok") {
                console.log("   ✅ Integrity check passed: ok");
                process.exit(0);
            } else {
                console.error("   ❌ Integrity check failed: " + check);
                process.exit(1);
            }
        }).catch(err => {
            console.error("   ❌ Backup failed: " + err.message);
            process.exit(1);
        });
    } catch(e) {
        console.error("   ❌ SQLite error: " + e.message);
        process.exit(1);
    }
EOF
    echo "   ✅ Titan SQLite backup saved at: ${BACKUP_FILE}"
else
    echo "ℹ️  Titan database not found at ${TITAN_DB}. Skipping."
fi

# 2. MySQL Backup (if running)
if systemctl is-active --quiet mysqld 2>/dev/null; then
    echo "2. Backing up MySQL databases..."
    MYSQL_BACKUP="${BACKUP_ROOT}/mysql/mysql_all_${TIMESTAMP}.sql.gz"
    
    # Dump using root or ec2-user socket
    if sudo mysqldump --all-databases --single-transaction --quick 2>/dev/null | gzip > "$MYSQL_BACKUP"; then
        if [[ -s "$MYSQL_BACKUP" ]]; then
            echo "   ✅ MySQL backup saved at: ${MYSQL_BACKUP} ($(du -h "$MYSQL_BACKUP" | cut -f1))"
        else
            echo "   ⚠️ MySQL backup file was empty. Check credentials."
            rm -f "$MYSQL_BACKUP"
        fi
    else
        echo "   ℹ️ Note: mysqldump requires password configuration. Configure ~/.my.cnf for automated dumps."
    fi
fi

# Keep only latest 7 database backups
find "${BACKUP_ROOT}/titan" -name "*.db" -mtime +7 -delete 2>/dev/null || true
find "${BACKUP_ROOT}/mysql" -name "*.sql.gz" -mtime +7 -delete 2>/dev/null || true

echo "======================================================================"
echo "          Database Backup Routine Completed                           "
echo "======================================================================"
