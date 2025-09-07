#!/bin/bash

# 🔄 EMERGENCY ROLLBACK SCRIPT
# Rychlý a bezpečný návrat na předchozí verzi s automatickou validací
# Použití: ./rollback.sh [version] nebo ./rollback.sh --auto

set -euo pipefail

# Barevný výstup
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Emoji
ROLLBACK="🔄"
CHECK="✅"
CROSS="❌"
WARNING="⚠️"
INFO="ℹ️"

# Konfigurace
PROJECT_NAME="trader-app"
DOMAIN="${DOMAIN:-your-domain.com}"
PROJECT_DIR="/var/www/${PROJECT_NAME}"
CURRENT_DIR="${PROJECT_DIR}/current"
RELEASES_DIR="${PROJECT_DIR}/releases"
BACKUP_DIR="${PROJECT_DIR}/backups"

# Logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${PROJECT_DIR}/logs/rollback_${TIMESTAMP}.log"

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
    echo -e "${YELLOW}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════╗
    ║               🔄 EMERGENCY ROLLBACK SYSTEM                   ║
    ║                Fast • Safe • Automated                      ║
    ║                 Last Resort Recovery                        ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_prerequisites() {
    log "INFO" "Kontroluji předpoklady pro rollback..."
    
    # Kontrola existence project directory
    if [ ! -d "$PROJECT_DIR" ]; then
        log "ERROR" "Project directory neexistuje: $PROJECT_DIR"
        exit 1
    fi
    
    # Kontrola existence releases
    if [ ! -d "$RELEASES_DIR" ]; then
        log "ERROR" "Releases directory neexistuje: $RELEASES_DIR"
        exit 1
    fi
    
    # Kontrola PM2
    if ! command -v pm2 &> /dev/null; then
        log "ERROR" "PM2 není nainstalován"
        exit 1
    fi
    
    # Kontrola Nginx
    if ! command -v nginx &> /dev/null; then
        log "ERROR" "Nginx není nainstalován"
        exit 1
    fi
    
    log "SUCCESS" "Předpoklady splněny"
}

get_current_version() {
    if [ -L "$CURRENT_DIR" ]; then
        local current_path=$(readlink "$CURRENT_DIR")
        basename "$current_path"
    else
        echo "NONE"
    fi
}

list_available_versions() {
    log "INFO" "Dostupné verze pro rollback:"
    
    if [ ! -d "$RELEASES_DIR" ] || [ -z "$(ls -A "$RELEASES_DIR")" ]; then
        log "ERROR" "Žádné verze k rollbacku nejsou dostupné"
        exit 1
    fi
    
    local current_version=$(get_current_version)
    local count=1
    
    # Seřazení podle data (nejnovější první)
    for version in $(ls -1t "$RELEASES_DIR"); do
        if [ -d "$RELEASES_DIR/$version" ]; then
            local status=""
            if [ "$version" = "$current_version" ]; then
                status="${GREEN}(CURRENT)${NC}"
            fi
            
            # Zobrazení informací o verzi
            local commit_file="$RELEASES_DIR/$version/.commit_hash"
            local commit_hash="N/A"
            if [ -f "$commit_file" ]; then
                commit_hash=$(cat "$commit_file" | cut -c1-8)
            fi
            
            local deploy_time=$(stat -c %Y "$RELEASES_DIR/$version" 2>/dev/null || echo "0")
            local deploy_date=$(date -d "@$deploy_time" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "Unknown")
            
            echo -e "${BLUE}${count}.${NC} ${version} ${status}"
            echo -e "   ${BLUE}├─${NC} Commit: ${commit_hash}"
            echo -e "   ${BLUE}└─${NC} Deployed: ${deploy_date}"
            
            ((count++))
        fi
    done
}

backup_current_state() {
    log "INFO" "Vytvářím backup současného stavu..."
    
    local current_version=$(get_current_version)
    if [ "$current_version" != "NONE" ]; then
        # Backup symlinku
        echo "$current_version" > "$PROJECT_DIR/.pre_rollback_version"
        
        # Backup databáze
        if command -v pg_dump &> /dev/null && [ -n "${DATABASE_URL:-}" ]; then
            local db_backup="$BACKUP_DIR/pre_rollback_${TIMESTAMP}.sql"
            pg_dump "$DATABASE_URL" > "$db_backup" 2>/dev/null || true
            log "INFO" "Databáze zálohována: $db_backup"
        fi
        
        # Backup logů
        mkdir -p "$BACKUP_DIR/logs_${TIMESTAMP}"
        cp -r "${PROJECT_DIR}/logs" "$BACKUP_DIR/logs_${TIMESTAMP}/" 2>/dev/null || true
        
        log "SUCCESS" "Backup dokončen"
    fi
}

validate_target_version() {
    local target_version=$1
    local target_path="$RELEASES_DIR/$target_version"
    
    log "INFO" "Validuji cílovou verzi: $target_version"
    
    # Kontrola existence
    if [ ! -d "$target_path" ]; then
        log "ERROR" "Verze neexistuje: $target_version"
        return 1
    fi
    
    # Kontrola základních souborů
    local required_files=("package.json")
    for file in "${required_files[@]}"; do
        if [ ! -f "$target_path/$file" ]; then
            log "ERROR" "Chybí povinný soubor: $file v $target_version"
            return 1
        fi
    done
    
    # Kontrola node_modules (pokud existují)
    if [ -d "$target_path/node_modules" ] || [ -L "$target_path/node_modules" ]; then
        log "INFO" "Node modules nalezeny"
    else
        log "WARN" "Node modules chybí, bude potřeba reinstalace"
    fi
    
    log "SUCCESS" "Verze $target_version je validní"
    return 0
}

perform_rollback() {
    local target_version=$1
    local target_path="$RELEASES_DIR/$target_version"
    
    log "INFO" "Spouštím rollback na verzi: $target_version"
    
    # 1. Backup současného stavu
    backup_current_state
    
    # 2. Validace cílové verze
    if ! validate_target_version "$target_version"; then
        exit 1
    fi
    
    # 3. Atomické přepnutí symlinku
    log "INFO" "Přepínám symlink..."
    ln -sfn "$target_path" "${CURRENT_DIR}.tmp"
    mv "${CURRENT_DIR}.tmp" "$CURRENT_DIR"
    
    # 4. Reinstalace dependencies (pokud potřeba)
    if [ ! -d "$target_path/node_modules" ] && [ ! -L "$target_path/node_modules" ]; then
        log "INFO" "Reinstaluji dependencies..."
        cd "$target_path"
        npm install --production --silent
    fi
    
    # 5. Restart aplikačních služeb
    log "INFO" "Restartuji služby..."
    
    # PM2 restart
    if pm2 list | grep -q "$PROJECT_NAME"; then
        pm2 restart "$PROJECT_NAME"
        sleep 5
    else
        log "WARN" "PM2 aplikace $PROJECT_NAME není spuštěná"
    fi
    
    # Nginx reload
    if nginx -t > /dev/null 2>&1; then
        nginx -s reload
    else
        log "ERROR" "Nginx konfigurace má chyby!"
        return 1
    fi
    
    log "SUCCESS" "Služby restartovány"
}

health_check_after_rollback() {
    local target_version=$1
    
    log "INFO" "Spouštím health check po rollbacku..."
    
    # Základní HTTP health check
    local max_attempts=30
    local wait_time=2
    
    for ((i=1; i<=max_attempts; i++)); do
        if curl -sf "https://${DOMAIN}/health" > /dev/null 2>&1; then
            log "SUCCESS" "Health check prošel na pokus $i"
            break
        elif curl -sf "http://localhost:3000/health" > /dev/null 2>&1; then
            log "SUCCESS" "Local health check prošel na pokus $i"
            break
        fi
        
        if [ $i -eq $max_attempts ]; then
            log "ERROR" "Health check selhal po $max_attempts pokusech"
            return 1
        fi
        
        log "INFO" "Health check pokus $i/$max_attempts, čekám ${wait_time}s..."
        sleep $wait_time
    done
    
    # Detailní application check
    log "INFO" "Kontroluji aplikační metriky..."
    
    # PM2 status
    if pm2 list | grep -q "online.*$PROJECT_NAME"; then
        log "SUCCESS" "PM2 aplikace běží správně"
    else
        log "ERROR" "PM2 aplikace není online"
        return 1
    fi
    
    # Kontrola error logů
    local error_log="${PROJECT_DIR}/shared/logs/error.log"
    if [ -f "$error_log" ]; then
        local recent_errors=$(tail -20 "$error_log" | grep -i error | wc -l)
        if [ "$recent_errors" -gt 5 ]; then
            log "WARN" "Detekováno $recent_errors chyb v posledních 20 řádkách error logu"
        fi
    fi
    
    return 0
}

emergency_recovery() {
    log "ERROR" "Rollback selhal! Spouštím emergency recovery..."
    
    # Obnovení z pre-rollback backup
    if [ -f "$PROJECT_DIR/.pre_rollback_version" ]; then
        local recovery_version=$(cat "$PROJECT_DIR/.pre_rollback_version")
        log "INFO" "Obnovuji na verzi před rollbackem: $recovery_version"
        
        local recovery_path="$RELEASES_DIR/$recovery_version"
        if [ -d "$recovery_path" ]; then
            ln -sfn "$recovery_path" "$CURRENT_DIR"
            pm2 restart "$PROJECT_NAME" 2>/dev/null || true
            nginx -s reload 2>/dev/null || true
            
            log "SUCCESS" "Emergency recovery dokončeno"
        else
            log "ERROR" "Recovery verze neexistuje: $recovery_version"
        fi
    else
        log "ERROR" "Žádná recovery verze není dostupná!"
    fi
}

auto_rollback() {
    log "INFO" "Spouštím automatický rollback na poslední funkční verzi..."
    
    local current_version=$(get_current_version)
    local versions=($(ls -1t "$RELEASES_DIR"))
    
    for version in "${versions[@]}"; do
        if [ "$version" != "$current_version" ] && [ -d "$RELEASES_DIR/$version" ]; then
            log "INFO" "Zkouším rollback na verzi: $version"
            
            if perform_rollback "$version"; then
                if health_check_after_rollback "$version"; then
                    log "SUCCESS" "Automatický rollback na $version úspěšný!"
                    return 0
                else
                    log "WARN" "Health check pro $version selhal, zkouším další verzi..."
                fi
            fi
        fi
    done
    
    log "ERROR" "Žádná funkční verze pro automatický rollback nenalezena"
    return 1
}

interactive_rollback() {
    echo
    list_available_versions
    echo
    
    while true; do
        echo -e "${YELLOW}Vyberte verzi pro rollback (číslo nebo název):${NC}"
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            # Výběr podle čísla
            local versions=($(ls -1t "$RELEASES_DIR"))
            local index=$((choice - 1))
            
            if [ $index -ge 0 ] && [ $index -lt ${#versions[@]} ]; then
                local selected_version="${versions[$index]}"
                break
            else
                echo -e "${RED}Neplatné číslo. Zkuste znovu.${NC}"
            fi
        else
            # Přímý název verze
            if [ -d "$RELEASES_DIR/$choice" ]; then
                local selected_version="$choice"
                break
            else
                echo -e "${RED}Verze '$choice' neexistuje. Zkuste znovu.${NC}"
            fi
        fi
    done
    
    # Potvrzení
    local current_version=$(get_current_version)
    echo
    echo -e "${YELLOW}POTVRZENÍ ROLLBACKU:${NC}"
    echo -e "Současná verze: ${GREEN}$current_version${NC}"
    echo -e "Cílová verze: ${BLUE}$selected_version${NC}"
    echo
    echo -e "${RED}Pokračovat s rollbackem? [y/N]:${NC}"
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        perform_rollback "$selected_version"
        
        if health_check_after_rollback "$selected_version"; then
            show_rollback_summary "$current_version" "$selected_version"
        else
            emergency_recovery
            exit 1
        fi
    else
        log "INFO" "Rollback zrušen uživatelem"
        exit 0
    fi
}

show_rollback_summary() {
    local from_version=$1
    local to_version=$2
    
    echo -e "\n${GREEN}🎉 ROLLBACK ÚSPĚŠNĚ DOKONČEN!${NC}\n"
    
    echo -e "${PURPLE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ ROLLBACK SUMMARY:${NC}"
    echo -e "${BLUE}Project:${NC} ${PROJECT_NAME}"
    echo -e "${BLUE}Domain:${NC} https://${DOMAIN}"
    echo -e "${BLUE}From Version:${NC} ${from_version}"
    echo -e "${BLUE}To Version:${NC} ${to_version}"
    echo -e "${BLUE}Rollback Time:${NC} $(date)"
    
    echo -e "\n${YELLOW}📊 SYSTEM STATUS:${NC}"
    if pm2 list | grep -q "online.*$PROJECT_NAME"; then
        echo -e "${GREEN}✅ PM2 Application: Online${NC}"
    else
        echo -e "${RED}❌ PM2 Application: Offline${NC}"
    fi
    
    if curl -sf "https://${DOMAIN}/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Health Check: Passing${NC}"
    else
        echo -e "${RED}❌ Health Check: Failing${NC}"
    fi
    
    echo -e "\n${YELLOW}📋 DALŠÍ AKCE:${NC}"
    echo -e "${BLUE}• Monitorujte aplikaci:${NC} pm2 monit"
    echo -e "${BLUE}• Zkontrolujte logy:${NC} tail -f $PROJECT_DIR/shared/logs/error.log"
    echo -e "${BLUE}• Rollback log:${NC} $LOG_FILE"
    
    echo -e "${PURPLE}═══════════════════════════════════════════════════════${NC}\n"
}

main() {
    local start_time=$(date +%s)
    
    show_banner
    
    # Kontrola předpokladů
    check_prerequisites
    
    # Parsování argumentů
    case "${1:-}" in
        "--auto"|"-a")
            log "INFO" "Spouštím automatický rollback"
            if ! auto_rollback; then
                emergency_recovery
                exit 1
            fi
            ;;
        "--list"|"-l")
            list_available_versions
            exit 0
            ;;
        "--help"|"-h")
            echo "Použití: $0 [možnosti]"
            echo "Možnosti:"
            echo "  --auto, -a     Automatický rollback na poslední funkční verzi"
            echo "  --list, -l     Seznam dostupných verzí"
            echo "  --help, -h     Tato nápověda"
            echo "  [version]      Rollback na konkrétní verzi"
            exit 0
            ;;
        "")
            # Interaktivní režim
            interactive_rollback
            ;;
        *)
            # Konkrétní verze
            local target_version="$1"
            local current_version=$(get_current_version)
            
            if [ "$target_version" = "$current_version" ]; then
                log "ERROR" "Cílová verze je stejná jako současná: $target_version"
                exit 1
            fi
            
            perform_rollback "$target_version"
            
            if health_check_after_rollback "$target_version"; then
                show_rollback_summary "$current_version" "$target_version"
            else
                emergency_recovery
                exit 1
            fi
            ;;
    esac
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log "SUCCESS" "Rollback dokončen za ${duration} sekund"
}

# Error handling
trap 'log "ERROR" "Rollback selhal! Spouštím emergency recovery..."; emergency_recovery; exit 1' ERR

main "$@"
