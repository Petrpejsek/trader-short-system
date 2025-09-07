#!/bin/bash

# ⏰ CRON JOBS SETUP SCRIPT
# Automatické nastavení všech potřebných cron jobů pro production monitoring

set -euo pipefail

# Konfigurace
PROJECT_NAME="trader-app"
DEPLOY_USER="deploy"
SCRIPT_DIR="/var/www/${PROJECT_NAME}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log "🔧 Nastavuji cron jobs pro ${PROJECT_NAME}..."

# Backup současného crontabu
crontab -l > /tmp/crontab_backup_$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# Vytvoření nového crontabu s našimi jobs
cat << EOF > /tmp/new_crontab
# ===============================
# ${PROJECT_NAME} CRON JOBS
# ===============================

# Health monitoring - každých 5 minut
*/5 * * * * ${SCRIPT_DIR}/health-monitor.sh >> /var/log/health-monitor.log 2>&1

# Kompletní health report - každou hodinu
0 * * * * ${SCRIPT_DIR}/health-monitor.sh --generate-report >> /var/log/health-monitor.log 2>&1

# SSL certifikát renewal check - každý den ve 2:30
30 2 * * * /usr/bin/certbot renew --quiet --no-self-upgrade

# Databáze backup - každý den ve 3:00
0 3 * * * pg_dump \$DATABASE_URL > /var/www/${PROJECT_NAME}/backups/db_backup_\$(date +\%Y\%m\%d).sql 2>/dev/null

# Cleanup starých logů - každou neděli v 4:00
0 4 * * 0 find /var/www/${PROJECT_NAME}/shared/logs -name "*.log" -mtime +7 -delete

# Cleanup starých backupů - každý měsíc 1. den v 5:00
0 5 1 * * find /var/www/${PROJECT_NAME}/backups -name "*.sql" -mtime +30 -delete

# PM2 logs rotation - každý den v 6:00
0 6 * * * pm2 flush

# System maintenance - každou neděli v 1:00
0 1 * * 0 ${SCRIPT_DIR}/maintenance.sh >> /var/log/maintenance.log 2>&1

# Nginx logs rotation - každý den v půlnoci
0 0 * * * /usr/sbin/logrotate -f /etc/logrotate.d/nginx

# Security scan - každý pátek ve 23:00
0 23 * * 5 ${SCRIPT_DIR}/security-scan.sh >> /var/log/security-scan.log 2>&1

EOF

# Instalace nového crontabu
crontab /tmp/new_crontab

# Cleanup
rm /tmp/new_crontab

log "✅ Cron jobs úspěšně nainstalovány!"
log "📋 Seznam aktivních cron jobů:"
crontab -l

log "📁 Log soubory budou v:"
echo "  - Health monitor: /var/log/health-monitor.log"
echo "  - Maintenance: /var/log/maintenance.log" 
echo "  - Security scan: /var/log/security-scan.log"
