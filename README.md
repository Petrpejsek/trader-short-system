# 🚀 Premium Deployment System pro Digital Ocean

Ultra-profesionální deployment systém s zero-downtime deployment, automatickým rollbackem, monitoringem a auto-healing funkcemi.

## 📋 Obsah

- [Rychlé nastavení](#-rychlé-nastavení)
- [Detailní instalace](#-detailní-instalace)
- [Deployment proces](#-deployment-proces)
- [Monitoring](#-monitoring)
- [Rollback](#-rollback)
- [Maintenance](#-maintenance)
- [Troubleshooting](#-troubleshooting)

## 🚀 Rychlé nastavení

### 1. Příprava Digital Ocean droplet

```bash
# Vytvořte nový Ubuntu 22.04 droplet (min 2GB RAM)
# Připojte se jako root přes SSH

# Stažení deployment systému
git clone https://github.com/your-username/trader-app-deployment.git
cd trader-app-deployment

# Spuštění server setup (jako root)
chmod +x server-setup.sh
./server-setup.sh your-domain.com
```

### 2. Konfigurace DNS

V DNS nastavení vaší domény přidejte A záznam:
```
A    @    your-server-ip
A    www  your-server-ip
```

### 3. SSL certifikát

```bash
# Po propagaci DNS
sudo certbot --nginx -d your-domain.com -d www.your-domain.com
```

### 4. Environment variables

```bash
# Zkopírujte template a upravte hodnoty
cp .env.production.template /var/www/trader-app/shared/.env.production
nano /var/www/trader-app/shared/.env.production
```

### 5. První deployment

```bash
# Nastavení Git repository
export GIT_REPOSITORY="git@github.com:your-username/trader-app.git"
export DOMAIN="your-domain.com"

# Spuštění deploymentu
chmod +x deploy.sh
./deploy.sh
```

## 🔧 Detailní instalace

### Systémové požadavky

- **OS**: Ubuntu 22.04 LTS
- **RAM**: Minimálně 2GB (doporučeno 4GB+)
- **Disk**: Minimálně 20GB SSD
- **CPU**: 2 cores (doporučeno 4+)
- **Network**: Veřejná IP adresa

### Architektura systému

```
┌─────────────────────────────────────────────┐
│                 NGINX                       │
│         (Load Balancer + SSL)               │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│                 PM2                         │
│         (Process Manager)                   │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│              Node.js App                    │
│            (Cluster Mode)                   │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│             PostgreSQL                      │
│           (Database)                        │
└─────────────────────────────────────────────┘
```

### Directory struktura

```
/var/www/trader-app/
├── current/                 # Symlink na aktuální release
├── releases/               # Všechny deployed verze
│   ├── 20240101_120000/
│   ├── 20240101_130000/
│   └── ...
├── shared/                 # Sdílené soubory mezi releases
│   ├── logs/
│   ├── uploads/
│   ├── node_modules/
│   ├── .next/
│   └── .env.production
├── backups/               # Zálohy databáze a aplikace
│   ├── db_backup_*.sql
│   └── logs_*/
└── logs/                  # Deployment logy
    └── deploy_*.log
```

## 🚢 Deployment proces

### Základní deployment

```bash
# Standardní deployment z main branch
./deploy.sh

# Deployment z konkrétní branch
BRANCH=feature/new-ui ./deploy.sh

# Deployment s debug výstupem
DEBUG=1 ./deploy.sh
```

### Deployment flow

1. **Pre-deployment checks**
   - Systémové požadavky
   - Disk space
   - Git repository dostupnost

2. **Code fetch**
   - Git clone z specified branch
   - Commit hash tracking

3. **Dependencies installation**
   - NPM install s cache optimalizací
   - Shared node_modules linking

4. **Application build**
   - Production build
   - Static assets optimalizace

5. **Database migrations**
   - Automatické DB backup
   - Migrace spuštění
   - Rollback při chybě

6. **Zero-downtime switch**
   - Atomické symlink přepnutí
   - Service reload
   - Health check validace

7. **Post-deployment**
   - Smoke testy
   - Cleanup starých releases
   - Notifikace odeslání

## 📊 Monitoring

### Health monitor

```bash
# Manuální health check
./health-monitor.sh

# Generování reportu
./health-monitor.sh --generate-report

# Real-time monitoring
watch -n 5 './health-monitor.sh'
```

### Monitoring features

- ✅ **System metrics**: CPU, RAM, Disk, Load average
- ✅ **Application health**: Response time, Error rate, PM2 status
- ✅ **Service monitoring**: Nginx, PostgreSQL, Redis status
- ✅ **Auto-healing**: Automatický restart při problémech
- ✅ **Alerting**: Slack, Discord, Email notifikace
- ✅ **Reporting**: HTML reporty každou hodinu

### Cron jobs setup

```bash
# Instalace všech cron jobů
chmod +x setup-cron.sh
./setup-cron.sh
```

## 🔄 Rollback

### Rychlý rollback

```bash
# Automatický rollback na poslední funkční verzi
./rollback.sh --auto

# Interaktivní výběr verze
./rollback.sh

# Rollback na konkrétní verzi
./rollback.sh 20240101_120000
```

### Rollback features

- ✅ **Zero-downtime**: Bez výpadku služby
- ✅ **Automatická validace**: Health checks před potvrzením
- ✅ **Emergency recovery**: Automatický návrat při selhání
- ✅ **Database backup**: Záloha před každým rollbackem
- ✅ **Interactive mode**: Přehledný výběr verzí

## 🔧 Maintenance

### Běžné úkoly

```bash
# Status všech služeb
pm2 status
systemctl status nginx postgresql

# Logs monitoring
tail -f /var/www/trader-app/shared/logs/app.log
tail -f /var/log/nginx/trader-app.error.log

# Database backup
pg_dump $DATABASE_URL > backup.sql

# SSL certifikát renewal
certbot renew --dry-run
```

### Performance optimalizace

```bash
# PM2 monitoring
pm2 monit

# Nginx testing
nginx -t && nginx -s reload

# Database optimalizace
psql $DATABASE_URL -c "VACUUM ANALYZE;"
```

## 🔒 Security

### Firewall konfigurace

```bash
# UFW status
ufw status verbose

# Fail2ban logs
journalctl -u fail2ban -f
```

### SSL monitoring

```bash
# Certifikát expiry check
certbot certificates

# SSL test
openssl s_client -connect your-domain.com:443 -servername your-domain.com
```

## 🚨 Troubleshooting

### Deployment selhání

1. **Kontrola logů**:
   ```bash
   tail -f /var/www/trader-app/logs/deploy_*.log
   ```

2. **Rollback na funkční verzi**:
   ```bash
   ./rollback.sh --auto
   ```

3. **Debug mode deployment**:
   ```bash
   DEBUG=1 ./deploy.sh
   ```

### Application issues

1. **PM2 debugging**:
   ```bash
   pm2 logs trader-app --lines 100
   pm2 restart trader-app
   ```

2. **Health check selhání**:
   ```bash
   curl -v https://your-domain.com/health
   ./health-monitor.sh
   ```

3. **Database problémy**:
   ```bash
   psql $DATABASE_URL -c "SELECT 1;"
   systemctl status postgresql
   ```

### Nginx issues

1. **Konfigurace test**:
   ```bash
   nginx -t
   systemctl reload nginx
   ```

2. **SSL problémy**:
   ```bash
   certbot renew --dry-run
   ```

## 📞 Support

### Log files lokace

- **Deployment**: `/var/www/trader-app/logs/`
- **Application**: `/var/www/trader-app/shared/logs/`
- **Nginx**: `/var/log/nginx/`
- **System**: `/var/log/syslog`

### Monitoring dashboards

- **PM2 Web**: `http://your-server:9615`
- **Health Reports**: `/var/www/monitoring/reports/`
- **System Metrics**: `/var/www/monitoring/metrics/`

### Emergency contacts

Přidejte svoje kontaktní údaje pro emergency situace:

```bash
# V .env.production
ALERT_EMAIL=admin@your-domain.com
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
```

---

**Vytvořeno s ❤️ pro profesionální deployment na Digital Ocean**

*Pokud máte otázky nebo potřebujete podporu, vytvořte issue v repository.*
