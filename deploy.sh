#!/bin/bash

# 🚀 ULTRA-PREMIUM DEPLOYMENT SCRIPT pro Digital Ocean
# Zero-downtime deployment s automatickým rollbackem a monitoring
# Author: Senior DevOps Engineer
# Version: 2.0.0

set -euo pipefail

# ===============================
# KONFIGURACE
# ===============================

# Barevný výstup pro lepší UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Emoji pro vizuální feedback
ROCKET="🚀"
CHECK="✅"
CROSS="❌"
WARNING="⚠️"
INFO="ℹ️"
GEAR="⚙️"
DATABASE="🗄️"
GLOBE="🌐"

# Základní konfigurace
PROJECT_NAME="trader-app"
DEPLOY_USER="deploy"
DOMAIN="${DOMAIN:-your-domain.com}"
BRANCH="${BRANCH:-main}"
NODE_VERSION="${NODE_VERSION:-18}"

# Cesty na serveru
PROJECT_DIR="/var/www/${PROJECT_NAME}"
CURRENT_DIR="${PROJECT_DIR}/current"
RELEASES_DIR="${PROJECT_DIR}/releases"
SHARED_DIR="${PROJECT_DIR}/shared"
BACKUP_DIR="${PROJECT_DIR}/backups"

# Deployment metadata
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}"

# Logging
LOG_FILE="${PROJECT_DIR}/logs/deploy_${TIMESTAMP}.log"

# ===============================
# UTILITY FUNKCE
# ===============================

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${BLUE}${INFO}${NC} ${timestamp} - ${message}" | tee -a "${LOG_FILE}" ;;
        "SUCCESS") echo -e "${GREEN}${CHECK}${NC} ${timestamp} - ${message}" | tee -a "${LOG_FILE}" ;;
        "WARN")  echo -e "${YELLOW}${WARNING}${NC} ${timestamp} - ${message}" | tee -a "${LOG_FILE}" ;;
        "ERROR") echo -e "${RED}${CROSS}${NC} ${timestamp} - ${message}" | tee -a "${LOG_FILE}" ;;
    esac
}

show_banner() {
    echo -e "${PURPLE}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════╗
    ║                  🚀 PREMIUM DEPLOYMENT SYSTEM                ║
    ║                    Zero-Downtime • Fast • Secure            ║
    ║                        Digital Ocean Ready                   ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_requirements() {
    log "INFO" "Kontroluji požadavky pro deployment..."
    
    local missing_deps=()
    
    # Kontrola binárních závislostí
    for cmd in git node npm pm2 nginx; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log "ERROR" "Chybí následující závislosti: ${missing_deps[*]}"
        log "INFO" "Spusťte nejdříve server-setup.sh script"
        exit 1
    fi
    
    # Kontrola disk space (min 1GB volného místa)
    local available_space=$(df /var/www | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt 1048576 ]; then
        log "WARN" "Málo volného místa na disku (méně než 1GB)"
    fi
    
    log "SUCCESS" "Všechny požadavky splněny"
}

create_directories() {
    log "INFO" "Vytvářím directory strukturu..."
    
    sudo mkdir -p "$RELEASES_DIR"
    sudo mkdir -p "$SHARED_DIR"/{logs,uploads,node_modules,.next}
    sudo mkdir -p "$BACKUP_DIR"
    sudo mkdir -p "${PROJECT_DIR}/logs"
    
    # Nastavení ownership
    sudo chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$PROJECT_DIR"
    
    log "SUCCESS" "Directory struktura připravena"
}

# ===============================
# HEALTH CHECKS
# ===============================

health_check() {
    local url=$1
    local max_attempts=30
    local wait_time=2
    
    log "INFO" "Spouštím health check pro: $url"
    
    for ((i=1; i<=max_attempts; i++)); do
        if curl -sf "$url" > /dev/null 2>&1; then
            log "SUCCESS" "Health check prošel na pokus $i"
            return 0
        fi
        
        if [ $i -lt $max_attempts ]; then
            log "INFO" "Health check pokus $i/$max_attempts selhal, čekám ${wait_time}s..."
            sleep $wait_time
        fi
    done
    
    log "ERROR" "Health check selhal po $max_attempts pokusech"
    return 1
}

database_health_check() {
    log "INFO" "Kontroluji připojení k databázi..."
    
    # Předpokládám PostgreSQL, upravte podle potřeby
    if psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1; then
        log "SUCCESS" "Databáze je dostupná"
        return 0
    else
        log "ERROR" "Nelze se připojit k databázi"
        return 1
    fi
}

# ===============================
# DEPLOYMENT PROCES
# ===============================

fetch_code() {
    log "INFO" "Stahuju nejnovější kód z Git repository..."
    
    cd "$RELEASES_DIR"
    git clone --depth 1 --branch "$BRANCH" "$GIT_REPOSITORY" "$TIMESTAMP"
    cd "$RELEASE_DIR"
    
    # Získání commit hash pro tracking
    local commit_hash=$(git rev-parse HEAD)
    echo "$commit_hash" > "$RELEASE_DIR/.commit_hash"
    
    log "SUCCESS" "Kód stažen, commit: ${commit_hash:0:8}"
}

install_dependencies() {
    log "INFO" "Instaluji Node.js závislosti..."
    
    cd "$RELEASE_DIR"
    
    # Používání shared node_modules pro rychlejší deployment
    if [ -d "$SHARED_DIR/node_modules" ]; then
        ln -sf "$SHARED_DIR/node_modules" "$RELEASE_DIR/node_modules"
    fi
    
    # Čištění NPM cache
    npm cache clean --force
    
    # Instalace závislostí s retry logikou
    local max_retries=3
    for ((i=1; i<=max_retries; i++)); do
        if npm ci --production; then
            log "SUCCESS" "Dependencies nainstalovány na pokus $i"
            break
        elif [ $i -eq $max_retries ]; then
            log "ERROR" "Instalace dependencies selhala po $max_retries pokusech"
            exit 1
        else
            log "WARN" "Instalace dependencies selhala, pokus $i/$max_retries"
            sleep 5
        fi
    done
    
    # Kopírování node_modules do shared directory
    cp -R "$RELEASE_DIR/node_modules" "$SHARED_DIR/" 2>/dev/null || true
}

build_application() {
    log "INFO" "Builduji aplikaci pro production..."
    
    cd "$RELEASE_DIR"
    
    # Linkování shared .next cache
    if [ -d "$SHARED_DIR/.next" ]; then
        rm -rf "$RELEASE_DIR/.next"
        ln -sf "$SHARED_DIR/.next" "$RELEASE_DIR/.next"
    fi
    
    # Build s retry logikou
    local max_retries=2
    for ((i=1; i<=max_retries; i++)); do
        if npm run build; then
            log "SUCCESS" "Build dokončen na pokus $i"
            break
        elif [ $i -eq $max_retries ]; then
            log "ERROR" "Build selhal po $max_retries pokusech"
            exit 1
        else
            log "WARN" "Build selhal, pokus $i/$max_retries"
            npm cache clean --force
            sleep 10
        fi
    done
    
    # Kopírování .next do shared directory
    cp -R "$RELEASE_DIR/.next" "$SHARED_DIR/" 2>/dev/null || true
}

setup_environment() {
    log "INFO" "Nastavuji environment variables..."
    
    cd "$RELEASE_DIR"
    
    # Linkování shared env files
    if [ -f "$SHARED_DIR/.env.production" ]; then
        ln -sf "$SHARED_DIR/.env.production" "$RELEASE_DIR/.env"
    else
        log "ERROR" ".env.production soubor nenalezen v $SHARED_DIR"
        exit 1
    fi
    
    log "SUCCESS" "Environment nakonfigurován"
}

run_database_migrations() {
    log "INFO" "Spouštím databázové migrace..."
    
    cd "$RELEASE_DIR"
    
    # Backup databáze před migrací
    if command -v pg_dump &> /dev/null; then
        local backup_file="$BACKUP_DIR/db_backup_${TIMESTAMP}.sql"
        pg_dump "$DATABASE_URL" > "$backup_file" 2>/dev/null || true
        log "INFO" "Databáze zálohována: $backup_file"
    fi
    
    # Spuštění migrací (upravte podle vašeho ORM)
    if [ -f "package.json" ] && grep -q "prisma" package.json; then
        npx prisma migrate deploy
        log "SUCCESS" "Prisma migrace dokončeny"
    elif [ -f "knexfile.js" ]; then
        npm run migrate:latest
        log "SUCCESS" "Knex migrace dokončeny"
    else
        log "INFO" "Žádné migrace k spuštění"
    fi
}

# ===============================
# ZERO-DOWNTIME SWITCHING
# ===============================

switch_to_new_release() {
    log "INFO" "Přepínám na nový release (zero-downtime)..."
    
    # Backup současného symlinka
    if [ -L "$CURRENT_DIR" ]; then
        local current_release=$(readlink "$CURRENT_DIR")
        echo "$current_release" > "$PROJECT_DIR/.previous_release"
    fi
    
    # Atomické přepnutí symlinka
    ln -sfn "$RELEASE_DIR" "${CURRENT_DIR}.tmp"
    mv "${CURRENT_DIR}.tmp" "$CURRENT_DIR"
    
    log "SUCCESS" "Symlink aktualizován"
}

reload_services() {
    log "INFO" "Reloaduji služby..."
    
    # Restart PM2 aplikace
    if pm2 list | grep -q "$PROJECT_NAME"; then
        pm2 reload "$PROJECT_NAME" --wait-ready --listen-timeout 10000
    else
        pm2 start "$CURRENT_DIR/ecosystem.config.js" --env production
    fi
    
    # Reload Nginx (bez downtime)
    sudo nginx -t && sudo nginx -s reload
    
    log "SUCCESS" "Služby reloadovány"
}

# ===============================
# ROLLBACK SYSTÉM
# ===============================

rollback() {
    log "WARN" "Spouštím rollback na předchozí verzi..."
    
    if [ -f "$PROJECT_DIR/.previous_release" ]; then
        local previous_release=$(cat "$PROJECT_DIR/.previous_release")
        
        if [ -d "$previous_release" ]; then
            ln -sfn "$previous_release" "$CURRENT_DIR"
            pm2 reload "$PROJECT_NAME"
            sudo nginx -s reload
            
            log "SUCCESS" "Rollback dokončen na: $(basename "$previous_release")"
        else
            log "ERROR" "Předchozí release nenalezen: $previous_release"
            exit 1
        fi
    else
        log "ERROR" "Žádná předchozí verze k rollbacku"
        exit 1
    fi
}

# ===============================
# CLEANUP & MAINTENANCE
# ===============================

cleanup_old_releases() {
    log "INFO" "Čistím staré releases..."
    
    cd "$RELEASES_DIR"
    
    # Ponechat posledních 5 releases
    local keep_releases=5
    local release_count=$(ls -1t | wc -l)
    
    if [ "$release_count" -gt "$keep_releases" ]; then
        ls -1t | tail -n +$((keep_releases + 1)) | xargs rm -rf
        log "INFO" "Smazáno $((release_count - keep_releases)) starých releases"
    fi
    
    # Čištění starých logů (starší než 7 dní)
    find "${PROJECT_DIR}/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    
    # Čištění starých DB backupů (starší než 7 dní) 
    find "$BACKUP_DIR" -name "*.sql" -mtime +7 -delete 2>/dev/null || true
    
    log "SUCCESS" "Cleanup dokončen"
}

# ===============================
# POST-DEPLOY VALIDACE
# ===============================

run_smoke_tests() {
    log "INFO" "Spouštím smoke testy..."
    
    cd "$CURRENT_DIR"
    
    # Test základní funkčnosti
    if [ -f "package.json" ] && grep -q "test:smoke" package.json; then
        npm run test:smoke
    else
        # Fallback - základní HTTP test
        health_check "http://localhost:3000/api/health"
    fi
    
    log "SUCCESS" "Smoke testy prošly"
}

send_deployment_notification() {
    local status=$1
    local message=$2
    
    # Slack webhook (upravte URL)
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"🚀 Deployment ${PROJECT_NAME}: ${status} - ${message}\"}" \
            "$SLACK_WEBHOOK_URL" 2>/dev/null || true
    fi
    
    log "INFO" "Notifikace odeslána"
}

# ===============================
# MAIN DEPLOYMENT FLOW
# ===============================

main() {
    local start_time=$(date +%s)
    
    show_banner
    
    # Validace argumentů
    if [ $# -eq 1 ] && [ "$1" = "rollback" ]; then
        rollback
        exit 0
    fi
    
    log "INFO" "Spouštím deployment ${PROJECT_NAME} na ${DOMAIN}"
    log "INFO" "Branch: ${BRANCH}, Node: ${NODE_VERSION}"
    
    # Pre-deployment checks
    check_requirements
    create_directories
    
    # Deployment proces s error handlingem
    trap 'log "ERROR" "Deployment selhal! Spouštím rollback..."; rollback; exit 1' ERR
    
    fetch_code
    install_dependencies
    build_application
    setup_environment
    
    # Database migrace s rollback možností
    if ! run_database_migrations; then
        log "ERROR" "Migrace selhaly!"
        exit 1
    fi
    
    # Zero-downtime switch
    switch_to_new_release
    reload_services
    
    # Post-deployment validace
    sleep 3  # Krátká pauza pro stabilizaci
    
    if ! health_check "https://${DOMAIN}"; then
        log "ERROR" "Health check selhal po deployi!"
        rollback
        exit 1
    fi
    
    if ! run_smoke_tests; then
        log "ERROR" "Smoke testy selhaly!"
        rollback
        exit 1
    fi
    
    # Cleanup a finalizace
    cleanup_old_releases
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log "SUCCESS" "🎉 Deployment úspěšně dokončen za ${duration}s!"
    
    # Deployment summary
    echo -e "\n${GREEN}${CHECK} DEPLOYMENT SUMMARY${NC}"
    echo -e "${CYAN}Project:${NC} ${PROJECT_NAME}"
    echo -e "${CYAN}Domain:${NC} https://${DOMAIN}"
    echo -e "${CYAN}Release:${NC} ${TIMESTAMP}"
    echo -e "${CYAN}Commit:${NC} $(cat "$RELEASE_DIR/.commit_hash" 2>/dev/null || echo "N/A")"
    echo -e "${CYAN}Duration:${NC} ${duration}s"
    
    send_deployment_notification "SUCCESS" "Deployed in ${duration}s"
}

# Spuštění main funkce s všemi argumenty
main "$@"
