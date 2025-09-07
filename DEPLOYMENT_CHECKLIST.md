# ✅ DEPLOYMENT CHECKLIST

**Před každým deploymentem do production proveďte následující kontroly:**

## 📋 Pre-deployment checklist

### 🔧 Server připravenost

- [ ] **Server běží** a je dostupný přes SSH
- [ ] **Disk space** - minimálně 2GB volného místa
- [ ] **RAM usage** - méně než 80% využití
- [ ] **CPU load** - load average pod 2.0
- [ ] **Services status** - Nginx, PostgreSQL, PM2 running
- [ ] **SSL certifikát** - platný a ne expiring (<30 dní)

```bash
# Quick server check
df -h /
free -m
uptime
systemctl status nginx postgresql
certbot certificates
```

### 🛡️ Security check

- [ ] **Firewall** - UFW enabled s správnými rules
- [ ] **Fail2ban** - aktivní a running
- [ ] **SSH keys** - pouze authorized keys, žádné password auth
- [ ] **Sudo access** - deploy user má správná práva
- [ ] **File permissions** - 755 pro directories, 644 pro soubory

```bash
# Security verification
ufw status
systemctl status fail2ban
ls -la /home/deploy/.ssh/authorized_keys
```

### 💾 Database připravenost

- [ ] **Database connection** - PostgreSQL accessible
- [ ] **Migrations ready** - všechny migrace tested lokálně
- [ ] **Backup space** - dostatek místa pro DB backup
- [ ] **Connection pool** - není saturated
- [ ] **Long running queries** - žádné blocking queries

```bash
# Database checks
psql $DATABASE_URL -c "SELECT 1;"
psql $DATABASE_URL -c "SELECT COUNT(*) FROM pg_stat_activity;"
```

## 🚀 Deployment execution

### 📝 Pre-deploy actions

- [ ] **Git status clean** - všechny změny committed
- [ ] **Tests passed** - unit + integration testy prošly
- [ ] **Build successful** - lokální build bez chyb
- [ ] **Dependencies updated** - package.json vs package-lock.json sync
- [ ] **Environment variables** - všechny potřebné ENV vars nastaveny

```bash
# Local validation
npm test
npm run build
git status
```

### 🎯 During deployment

- [ ] **Monitor logs** - sledovat deployment výstup
- [ ] **Watch system resources** - CPU/RAM během buildu
- [ ] **Verify each step** - každý krok deployment scriptu
- [ ] **Database migrations** - successful bez chyb
- [ ] **Service restart** - PM2 a Nginx reload successful

```bash
# Real-time monitoring during deploy
tail -f /var/www/trader-app/logs/deploy_*.log
htop
```

### ✅ Post-deploy validation

- [ ] **Health check** - aplikace odpovídá na `/health`
- [ ] **SSL certificate** - HTTPS funkční
- [ ] **API endpoints** - klíčové API funkční
- [ ] **Database queries** - základní DB operace fungují
- [ ] **Static assets** - CSS/JS/images loading
- [ ] **Performance** - response times v normálu

```bash
# Post-deploy validation
curl -f https://your-domain.com/health
curl -f https://your-domain.com/api/status
./health-monitor.sh
```

## 🔍 Production verification

### 🌐 Frontend checks

- [ ] **Homepage loading** - hlavní stránka accessible
- [ ] **User registration/login** - auth flow funguje
- [ ] **Trading interface** - hlavní funkce aplikace
- [ ] **Mobile responsiveness** - mobile layout OK
- [ ] **Console errors** - žádné JS chyby v console

### 🔌 Backend checks

- [ ] **API responses** - všechny kritické endpointy
- [ ] **Database queries** - CRUD operace fungují
- [ ] **WebSocket connections** - real-time data flow
- [ ] **Background jobs** - scheduled tasky running
- [ ] **Log output** - normální log levels, žádné errors

### 📊 Performance validation

- [ ] **Response times** - < 2s pro hlavní stránky
- [ ] **Database queries** - žádné slow queries
- [ ] **Memory usage** - app využívá < 1GB RAM
- [ ] **CPU utilization** - < 50% průměrné zatížení
- [ ] **Concurrent users** - load test passed

```bash
# Performance monitoring
pm2 monit
curl -o /dev/null -s -w "Total: %{time_total}s\n" https://your-domain.com
```

## 🚨 Troubleshooting během deploymentu

### ❌ Deployment selhal

**Immediate actions:**
1. **Check logs**: `tail -f /var/www/trader-app/logs/deploy_*.log`
2. **System status**: `./health-monitor.sh`
3. **Service status**: `pm2 status && systemctl status nginx`
4. **Automatic rollback**: `./rollback.sh --auto`

### 🐛 Application issues po deploy

**Debugging steps:**
1. **Application logs**: `pm2 logs trader-app --lines 50`
2. **Error rates**: Check error log for spikes
3. **Database connectivity**: `psql $DATABASE_URL -c "SELECT 1;"`
4. **Nginx errors**: `tail -f /var/log/nginx/error.log`

### 🔄 Rollback decision

**Rollback immediately if:**
- [ ] Health check failing > 2 minutes
- [ ] Critical functionality broken
- [ ] Database corruption detected
- [ ] Security vulnerability introduced
- [ ] Performance degraded > 50%

```bash
# Emergency rollback
./rollback.sh --auto
```

## 📈 Post-deployment monitoring

### ⏰ First 30 minutes

- [ ] **Active monitoring** - sledovat všechny metriky
- [ ] **Error rates** - < 1% error rate
- [ ] **Response times** - stability check
- [ ] **User feedback** - monitoring support channels
- [ ] **Resource usage** - CPU/RAM stabilní

### 🔍 First 24 hours

- [ ] **Performance trends** - žádná degradace
- [ ] **Error patterns** - žádné nové error types
- [ ] **User activity** - normální usage patterns
- [ ] **Background jobs** - všechny tasky running
- [ ] **Database health** - query performance stable

### 📊 Weekly review

- [ ] **System metrics** - trend analysis
- [ ] **Application performance** - week-over-week comparison
- [ ] **Security logs** - žádné security incidents
- [ ] **Backup verification** - restore test successful
- [ ] **Capacity planning** - resource usage trends

## 🎯 Success criteria

**Deployment je úspěšný když:**

✅ **Functional requirements:**
- Všechny kritické user flows fungují
- API endpointy odpovídají správně
- Database operace jsou rychlé a spolehlivé
- Real-time features (WebSocket) fungují

✅ **Performance requirements:**
- Response times < 2s pro 95% requestů
- Error rate < 0.5%
- CPU utilization < 60%
- Memory usage < 80%

✅ **Monitoring requirements:**
- Health checks passing
- Alerts configured a functional
- Logs collection working
- Backup process verified

---

## 📞 Emergency contacts

**V případě critical issues:**

- **DevOps Lead**: `+420-XXX-XXX-XXX`
- **Technical Lead**: `+420-XXX-XXX-XXX`
- **Slack Alert Channel**: `#alerts-production`
- **Email**: `alerts@your-domain.com`

**Remember: Lepší je bezpečný rollback než broken production! 🔒**
