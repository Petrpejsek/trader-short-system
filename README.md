# Trader SHORT - MVP Analyze → Signals

**🔻 Specializovaná verze pro SHORT trading strategie 🔻**

Tato verze trader-SHORT-new-new-new je optimalizována specificky pro short trading pozice. Obsahuje všechny funkce původního crypto-trading-analyzer s fokusem na bearish market podmínky a short pozice.

MVP Analyze pipeline (M1–M4) is implemented:
- M1: Public Fetcher (Binance Futures)
- M2: Features (deterministic indicators)
- M3-mini: Rules-based Market Decision
- M4-mini: Rules-based Signals (1–3 setups)

Run:
- Start backend: `npm run dev:server`
- Start UI: `npm run dev`
- Open http://localhost:4200 and click Run

QA:
- Export fixtures: `npm run export:m1m2`
- Run checks: `npm run qa:m2`

Status: MVP Analyze→Signals – DONE

## MVP Analyze→Signals – DEV freeze

- Pass: duration_ms ≈ 1.1–1.9 s, featuresMs 2–4 ms, sizes OK
- Fail (tolerováno v DEV): symbols = 24
  - Poznámka: "blokováno symboly – chybí H1 u altů; WS/TTL/backfill jen částečně pokrývá TopN"
- Akční bod (další sprint): Perf Sprint – stabilizovat symbols ≥ 30 (WS alt H1 prewarm + robustnější backfill a telemetrie drop:*:alt:*:noH1)

## M4 Signals – DEV OK

- QA_M4_GO: YES (schema valid, deterministic order, guards in place, setups≤3).
- Export: see `fixtures/signals/last_signals.json`.
- Notes: backend/UI unchanged per scope; future step – GPT Decider (M3) integration plan.

## Order Guards

To prevent Binance -2021 ("Order would immediately trigger."), exits are created in a simple and reliable way:

- workingType: always MARK_PRICE for SL and TP (and for guard checks).
- Default (simplest): Do NOT send exits before fill. As soon as ENTRY is filled (even partial), immediately create:
  - SL = STOP_MARKET, closePosition: true, reduceOnly: true
  - TP = TAKE_PROFIT_MARKET, closePosition: true, reduceOnly: true
- Optional pre-entry mode (flag PREENTRY_EXITS_ENABLED): when enabled, send pre-entry exits only if BOTH conditions pass:
  - LONG: tpStop > mark + 5*tickSize AND slStop < mark - 3*tickSize
  - SHORT: mirrored
  - If the guard fails, exits are created on fill (no pending loops).
- Validation: prices/qty are rounded to tickSize/stepSize; entry↔tp/sl relations are validated (LONG: tp>entry, sl<entry; SHORT mirrored).

Config (`config/trading.json`):

```json
{
  "EXIT_WORKING_TYPE": "MARK_PRICE",
  "PREENTRY_EXITS_ENABLED": false,
  "TP_PREENTRY_MIN_GAP_TICKS": 5,
  "SL_PREENTRY_MIN_GAP_TICKS": 3,
  "MIN_TP_TICKS": 2,
  "MIN_SL_TICKS": 2,
  "PENDING_WATCH_INTERVAL_MS": 500,
  "PENDING_MAX_WAIT_MS": 120000
}
```

Log lines (one-liners per decision):

```text
[EXIT_DECISION] { phase: "pre_fill"|"on_fill", symbol, side, entry, tp, sl, last, mark, workingType, decision: "send_exits_now"|"send_exits_on_fill", reason }
```

Examples of reasons: "preentry_guard_failed", "preentry_disabled", "post_fill_default".

---

# 🚀 Production Deployment System

Ultra-profesionální deployment systém s zero-downtime deployment, automatickým rollbackem, monitoringem a auto-healing funkcemi pro Digital Ocean.

## 📋 Deployment Features

✅ **Zero-downtime deployment** - Bez výpadku služby  
✅ **Automatický rollback** - Návrat při chybách během 30 sekund  
✅ **SSL/TLS** - Automatické HTTPS s Let's Encrypt  
✅ **Load balancing** - PM2 cluster mode pro maximum výkonu  
✅ **Auto-healing** - Automatické opravy běžných problémů  
✅ **Real-time monitoring** - Health checks každých 5 minut  
✅ **Alerting** - Slack/Discord/Email notifikace  
✅ **Security hardening** - Firewall, fail2ban, security headers  
✅ **Database backups** - Automatické zálohy před každým deploymentem  

## 🚀 Rychlé nastavení

### 1. Příprava Digital Ocean droplet

```bash
# Vytvořte nový Ubuntu 22.04 droplet (min 2GB RAM)
# Připojte se jako root přes SSH

# Stažení deployment systému
git clone https://github.com/Petrpejsek/trader-short-system.git
cd trader-short-system

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
cp env.production.template /var/www/trader-app/shared/.env.production
nano /var/www/trader-app/shared/.env.production
```

### 5. První deployment

```bash
# Nastavení Git repository
export GIT_REPOSITORY="git@github.com:Petrpejsek/trader-short-system.git"
export DOMAIN="your-domain.com"

# Spuštění deploymentu
chmod +x deploy.sh
./deploy.sh
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

## 🚨 Emergency kontakty

```bash
# V .env.production
ALERT_EMAIL=admin@your-domain.com
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
```

---

## Production overview

**Deployment systém je připraven pro production nasazení trader-short-system aplikace!** 

Pro detailní deployment dokumentaci viz soubor `DEPLOYMENT_CHECKLIST.md`.

**Vytvořeno s ❤️ pro profesionální deployment na Digital Ocean** 🚀