#!/bin/bash

# 🔧 DIGITAL OCEAN SERVER SETUP SCRIPT
# Kompletní konfigurace Ubuntu 22.04 serveru pro production deployment
# Optimalizováno pro Next.js/Node.js aplikace s PostgreSQL

set -euo pipefail

# Barevný výstup
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Emoji
ROCKET="🚀"
CHECK="✅"
GEAR="⚙️"
LOCK="🔒"
DATABASE="🗄️"
GLOBE="🌐"

# Konfigurace
PROJECT_NAME="trader-app"
DEPLOY_USER="deploy"
NODE_VERSION="18"
POSTGRES_VERSION="14"
DOMAIN="${1:-your-domain.com}"

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%H:%M:%S')
    
    case $level in
        "INFO")  echo -e "${BLUE}${GEAR}${NC} ${timestamp} - ${message}" ;;
        "SUCCESS") echo -e "${GREEN}${CHECK}${NC} ${timestamp} - ${message}" ;;
        "WARN")  echo -e "${YELLOW}⚠️${NC} ${timestamp} - ${message}" ;;
        "ERROR") echo -e "${RED}❌${NC} ${timestamp} - ${message}" ;;
    esac
}

show_banner() {
    echo -e "${PURPLE}"
    cat << "EOF"
    ╔══════════════════════════════════════════════════════════════╗
    ║               🔧 DIGITAL OCEAN SERVER SETUP                  ║
    ║            Production-Ready • Secure • Optimized            ║
    ║                     Ubuntu 22.04 LTS                        ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_system() {
    log "INFO" "Kontroluji systémové požadavky..."
    
    # Kontrola Ubuntu verze
    if ! lsb_release -d | grep -q "Ubuntu 22.04"; then
        log "WARN" "Doporučuje se Ubuntu 22.04 LTS"
    fi
    
    # Kontrola RAM (min 1GB)
    local ram_mb=$(free -m | awk 'NR==2{print $2}')
    if [ "$ram_mb" -lt 1024 ]; then
        log "WARN" "Málo RAM (${ram_mb}MB), doporučuje se min 2GB"
    fi
    
    # Kontrola disk space (min 10GB)
    local disk_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$disk_gb" -lt 10 ]; then
        log "WARN" "Málo místa na disku (${disk_gb}GB), doporučuje se min 20GB"
    fi
    
    log "SUCCESS" "Systémová kontrola dokončena"
}

update_system() {
    log "INFO" "Aktualizuji systém..."
    
    # Aktualizace package listu
    sudo apt update
    
    # Upgrade všech balíčků
    sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
    
    # Instalace základních nástrojů
    sudo apt install -y \
        curl \
        wget \
        git \
        unzip \
        htop \
        tree \
        jq \
        build-essential \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        ufw \
        fail2ban
    
    log "SUCCESS" "Systém aktualizován"
}

setup_firewall() {
    log "INFO" "Konfiguruji firewall (UFW)..."
    
    # Reset UFW
    sudo ufw --force reset
    
    # Defaultní policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # SSH - DŮLEŽITÉ: otevřít před aktivací UFW!
    sudo ufw allow ssh
    sudo ufw allow 22/tcp
    
    # HTTP/HTTPS
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    
    # Node.js app (pro development)
    sudo ufw allow 3000/tcp
    
    # Aktivace UFW
    sudo ufw --force enable
    
    # Fail2ban konfigurace
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    
    log "SUCCESS" "Firewall nastaven a aktivován"
}

install_nodejs() {
    log "INFO" "Instaluji Node.js ${NODE_VERSION}..."
    
    # Odstranění starých verzí
    sudo apt remove -y nodejs npm 2>/dev/null || true
    
    # NodeSource repository
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    
    # Instalace Node.js
    sudo apt install -y nodejs
    
    # Instalace global packages
    sudo npm install -g pm2 npm@latest
    
    # PM2 startup script
    sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u "$DEPLOY_USER" --hp "/home/$DEPLOY_USER"
    
    log "SUCCESS" "Node.js ${NODE_VERSION} nainstalován"
    node --version
    npm --version
}

install_postgresql() {
    log "INFO" "Instaluji PostgreSQL ${POSTGRES_VERSION}..."
    
    # PostgreSQL repository
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    
    sudo apt update
    sudo apt install -y "postgresql-${POSTGRES_VERSION}" "postgresql-client-${POSTGRES_VERSION}" postgresql-contrib
    
    # Spuštění služby
    sudo systemctl enable postgresql
    sudo systemctl start postgresql
    
    # Vytvoření databáze a uživatele pro projekt
    sudo -u postgres psql << EOF
CREATE DATABASE ${PROJECT_NAME}_production;
CREATE USER ${PROJECT_NAME}_user WITH PASSWORD '$(openssl rand -base64 32)';
GRANT ALL PRIVILEGES ON DATABASE ${PROJECT_NAME}_production TO ${PROJECT_NAME}_user;
EOF
    
    # Konfigurace PostgreSQL pro production
    local pg_config="/etc/postgresql/${POSTGRES_VERSION}/main/postgresql.conf"
    local pg_hba="/etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf"
    
    sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" "$pg_config"
    sudo sed -i "s/#max_connections = 100/max_connections = 200/" "$pg_config"
    sudo sed -i "s/#shared_buffers = 128MB/shared_buffers = 256MB/" "$pg_config"
    
    sudo systemctl restart postgresql
    
    log "SUCCESS" "PostgreSQL ${POSTGRES_VERSION} nainstalován a nakonfigurován"
}

install_nginx() {
    log "INFO" "Instaluji a konfiguruji Nginx..."
    
    # Instalace Nginx
    sudo apt install -y nginx
    
    # Odstranění default site
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Základní konfigurace pro lepší výkon
    sudo tee /etc/nginx/nginx.conf > /dev/null << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    # Základní nastavení
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # MIME types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # Gzip komprese
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json;
    
    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;
    
    # SSL konfigurace
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    
    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    # Virtual Host Configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # Restart Nginx
    sudo systemctl enable nginx
    sudo systemctl restart nginx
    
    log "SUCCESS" "Nginx nainstalován a nakonfigurován"
}

install_ssl() {
    log "INFO" "Instaluji Certbot pro SSL certifikáty..."
    
    # Certbot instalace
    sudo apt install -y snapd
    sudo snap install core; sudo snap refresh core
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot
    
    log "SUCCESS" "Certbot nainstalován"
    log "INFO" "Pro získání SSL certifikátu spusťte: sudo certbot --nginx -d $DOMAIN"
}

create_deploy_user() {
    log "INFO" "Vytvářím deploy uživatele..."
    
    # Vytvoření uživatele
    if ! id "$DEPLOY_USER" &>/dev/null; then
        sudo useradd -m -s /bin/bash "$DEPLOY_USER"
        sudo usermod -aG sudo "$DEPLOY_USER"
        
        # SSH klíče
        sudo mkdir -p "/home/$DEPLOY_USER/.ssh"
        sudo touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
        sudo chmod 700 "/home/$DEPLOY_USER/.ssh"
        sudo chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
        sudo chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
        
        log "SUCCESS" "Deploy user '$DEPLOY_USER' vytvořen"
        log "INFO" "Přidejte SSH klíč do: /home/$DEPLOY_USER/.ssh/authorized_keys"
    else
        log "INFO" "Deploy user '$DEPLOY_USER' již existuje"
    fi
}

setup_project_structure() {
    log "INFO" "Vytvářím projektovou strukturu..."
    
    local project_dir="/var/www/$PROJECT_NAME"
    
    # Vytvoření directories
    sudo mkdir -p "$project_dir"/{releases,shared/{logs,uploads,node_modules,.next},backups,logs}
    
    # Nastavení ownership
    sudo chown -R "$DEPLOY_USER:$DEPLOY_USER" "$project_dir"
    sudo chmod -R 755 "$project_dir"
    
    # Git konfigurace pro deploy usera
    sudo -u "$DEPLOY_USER" git config --global user.name "Deploy User"
    sudo -u "$DEPLOY_USER" git config --global user.email "deploy@$DOMAIN"
    
    log "SUCCESS" "Projektová struktura vytvořena v $project_dir"
}

optimize_system() {
    log "INFO" "Optimalizuji systém pro production..."
    
    # Swap soubor (pokud neexistuje)
    if [ ! -f /swapfile ]; then
        sudo fallocate -l 2G /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    
    # Systémové limity
    sudo tee -a /etc/security/limits.conf > /dev/null << EOF
# Optimization for Node.js apps
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOF
    
    # Kernel optimalizace
    sudo tee -a /etc/sysctl.conf > /dev/null << EOF
# Network optimizations
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr

# File system optimizations
fs.file-max = 2097152
vm.swappiness = 10
EOF
    
    sudo sysctl -p
    
    log "SUCCESS" "Systém optimalizován"
}

create_monitoring_scripts() {
    log "INFO" "Vytvářím monitoring skripty..."
    
    # System health check script
    sudo tee "/usr/local/bin/health-check.sh" > /dev/null << 'EOF'
#!/bin/bash
# System Health Check Script

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔍 SYSTEM HEALTH CHECK - $(date)"
echo "================================="

# CPU Usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
echo -e "CPU Usage: ${cpu_usage}%"

# Memory Usage
mem_info=$(free | grep Mem)
mem_used=$(echo $mem_info | awk '{print int($3/$2*100)}')
echo -e "Memory Usage: ${mem_used}%"

# Disk Usage
disk_usage=$(df -h / | tail -1 | awk '{print $5}' | cut -d'%' -f1)
echo -e "Disk Usage: ${disk_usage}%"

# Services Status
services=("nginx" "postgresql" "pm2")
for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}✅ $service: Running${NC}"
    else
        echo -e "${RED}❌ $service: Stopped${NC}"
    fi
done

# Load Average
load_avg=$(uptime | awk -F'load average:' '{print $2}')
echo -e "Load Average:${load_avg}"

# Active Connections
connections=$(netstat -an | wc -l)
echo -e "Active Connections: $connections"

echo "================================="
EOF
    
    sudo chmod +x "/usr/local/bin/health-check.sh"
    
    # Cron job pro denní zdravotní kontroly
    (sudo crontab -l 2>/dev/null; echo "0 9 * * * /usr/local/bin/health-check.sh >> /var/log/health-check.log 2>&1") | sudo crontab -
    
    log "SUCCESS" "Monitoring skripty vytvořeny"
}

setup_log_rotation() {
    log "INFO" "Nastavuji rotaci logů..."
    
    # Logrotate pro project logy
    sudo tee "/etc/logrotate.d/$PROJECT_NAME" > /dev/null << EOF
/var/www/$PROJECT_NAME/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    copytruncate
    su $DEPLOY_USER $DEPLOY_USER
}
EOF
    
    log "SUCCESS" "Rotace logů nastavena"
}

show_summary() {
    echo -e "\n${GREEN}🎉 SERVER SETUP DOKONČEN!${NC}\n"
    
    echo -e "${PURPLE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ NAINSTALOVANÉ SLUŽBY:${NC}"
    echo -e "${BLUE}   • Node.js $(node --version)${NC}"
    echo -e "${BLUE}   • npm $(npm --version)${NC}"
    echo -e "${BLUE}   • PM2 $(pm2 --version)${NC}"
    echo -e "${BLUE}   • PostgreSQL ${POSTGRES_VERSION}${NC}"
    echo -e "${BLUE}   • Nginx $(nginx -v 2>&1 | cut -d' ' -f3 | cut -d'/' -f2)${NC}"
    echo -e "${BLUE}   • Certbot (pro SSL)${NC}"
    
    echo -e "\n${YELLOW}📋 DALŠÍ KROKY:${NC}"
    echo -e "${BLUE}1.${NC} Nakonfigurujte DNS záznam pro: $DOMAIN"
    echo -e "${BLUE}2.${NC} Přidejte SSH klíč do: /home/$DEPLOY_USER/.ssh/authorized_keys"
    echo -e "${BLUE}3.${NC} Získejte SSL certifikát: sudo certbot --nginx -d $DOMAIN"
    echo -e "${BLUE}4.${NC} Vytvořte Nginx virtual host pro vaši aplikaci"
    echo -e "${BLUE}5.${NC} Nastavte environment variables v /var/www/$PROJECT_NAME/shared/.env.production"
    
    echo -e "\n${YELLOW}🔧 UŽITEČNÉ PŘÍKAZY:${NC}"
    echo -e "${BLUE}• Health check:${NC} /usr/local/bin/health-check.sh"
    echo -e "${BLUE}• PM2 monitoring:${NC} pm2 monit"
    echo -e "${BLUE}• Nginx test:${NC} sudo nginx -t"
    echo -e "${BLUE}• Firewall status:${NC} sudo ufw status"
    
    echo -e "\n${YELLOW}📁 PROJEKT STRUKTURA:${NC}"
    echo -e "${BLUE}/var/www/$PROJECT_NAME/${NC}"
    echo -e "├── current/ (symlink na aktuální release)"
    echo -e "├── releases/ (všechny verze)"
    echo -e "├── shared/ (sdílené soubory)"
    echo -e "├── backups/ (zálohy)"
    echo -e "└── logs/ (deployment logy)"
    
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════${NC}\n"
}

main() {
    show_banner
    
    # Kontrola, že běžíme jako root
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "Tento script je nutné spustit jako root (použijte sudo)"
        exit 1
    fi
    
    log "INFO" "Spouštím setup serveru pro $PROJECT_NAME na doméně: $DOMAIN"
    
    check_system
    update_system
    setup_firewall
    install_nodejs
    install_postgresql
    install_nginx
    install_ssl
    create_deploy_user
    setup_project_structure
    optimize_system
    create_monitoring_scripts
    setup_log_rotation
    
    show_summary
    
    log "SUCCESS" "Server je připraven pro deployment! 🚀"
}

main "$@"
