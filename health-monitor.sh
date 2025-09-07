#!/bin/bash

# 🔍 COMPREHENSIVE HEALTH MONITORING SYSTEM
# Pokročilý monitoring s alerting, metrics collection a auto-healing
# Spouštět každých 5 minut přes cron: */5 * * * * /path/to/health-monitor.sh

set -euo pipefail

# Barevný výstup
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Emoji
HEART="💓"
CHECK="✅"
CROSS="❌"
WARNING="⚠️"
INFO="ℹ️"
FIRE="🔥"
ROCKET="🚀"

# Konfigurace
PROJECT_NAME="trader-app"
DOMAIN="${DOMAIN:-your-domain.com}"
PROJECT_DIR="/var/www/${PROJECT_NAME}"
MONITORING_DIR="/var/www/monitoring"
METRICS_DIR="${MONITORING_DIR}/metrics"
ALERTS_DIR="${MONITORING_DIR}/alerts"

# Thresholdy pro alerting
CPU_THRESHOLD=80        # % CPU využití
MEMORY_THRESHOLD=85     # % RAM využití
DISK_THRESHOLD=90       # % disk využití
LOAD_THRESHOLD=2.0      # Load average
RESPONSE_TIME_THRESHOLD=5000  # ms
ERROR_RATE_THRESHOLD=5  # % error rate

# Notification settings
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
EMAIL_TO="${EMAIL_TO:-admin@${DOMAIN}}"

# Timestamp pro logy
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    local level=$1
    shift
    local message="$*"
    
    case $level in
        "INFO")  echo -e "${BLUE}${INFO}${NC} ${CURRENT_TIME} - ${message}" ;;
        "SUCCESS") echo -e "${GREEN}${CHECK}${NC} ${CURRENT_TIME} - ${message}" ;;
        "WARN")  echo -e "${YELLOW}${WARNING}${NC} ${CURRENT_TIME} - ${message}" ;;
        "ERROR") echo -e "${RED}${CROSS}${NC} ${CURRENT_TIME} - ${message}" ;;
        "CRITICAL") echo -e "${RED}${FIRE}${NC} ${CURRENT_TIME} - ${message}" ;;
    esac
    
    # Log do souboru
    echo "${CURRENT_TIME} [${level}] ${message}" >> "${MONITORING_DIR}/health.log"
}

setup_monitoring_dirs() {
    mkdir -p "$MONITORING_DIR"/{metrics,alerts,reports,history}
    chmod 755 "$MONITORING_DIR"
}

# ===============================
# SYSTEM METRICS COLLECTION
# ===============================

collect_system_metrics() {
    local metrics_file="${METRICS_DIR}/system_${TIMESTAMP}.json"
    
    # CPU usage
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    
    # Memory usage
    local mem_info=$(free | grep Mem)
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_used=$(echo $mem_info | awk '{print $3}')
    local mem_usage=$((mem_used * 100 / mem_total))
    
    # Disk usage
    local disk_info=$(df -h / | tail -1)
    local disk_usage=$(echo $disk_info | awk '{print $5}' | cut -d'%' -f1)
    local disk_available=$(echo $disk_info | awk '{print $4}')
    
    # Load average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    
    # Network connections
    local connections=$(netstat -an 2>/dev/null | wc -l || echo "0")
    
    # Process count
    local processes=$(ps aux | wc -l)
    
    # System uptime
    local uptime_seconds=$(cat /proc/uptime | awk '{print $1}')
    
    # Create JSON metrics
    cat > "$metrics_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "system": {
        "cpu_usage": ${cpu_usage},
        "memory": {
            "usage_percent": ${mem_usage},
            "total_mb": $((mem_total / 1024)),
            "used_mb": $((mem_used / 1024))
        },
        "disk": {
            "usage_percent": ${disk_usage},
            "available": "${disk_available}"
        },
        "load_average": ${load_avg},
        "connections": ${connections},
        "processes": ${processes},
        "uptime_seconds": ${uptime_seconds}
    }
}
EOF
    
    echo "$metrics_file"
}

collect_application_metrics() {
    local metrics_file="${METRICS_DIR}/app_${TIMESTAMP}.json"
    local app_status="unknown"
    local pm2_status="unknown"
    local response_time=0
    local error_count=0
    
    # PM2 status check
    if pm2 list 2>/dev/null | grep -q "$PROJECT_NAME"; then
        if pm2 list | grep -q "online.*$PROJECT_NAME"; then
            pm2_status="online"
            app_status="running"
        else
            pm2_status="stopped"
            app_status="down"
        fi
    else
        pm2_status="not_found"
        app_status="not_deployed"
    fi
    
    # Response time check
    if [ "$app_status" = "running" ]; then
        local start_time=$(date +%s%N)
        if curl -sf "https://${DOMAIN}/health" > /dev/null 2>&1; then
            local end_time=$(date +%s%N)
            response_time=$(( (end_time - start_time) / 1000000 )) # Convert to ms
            app_status="healthy"
        elif curl -sf "http://localhost:3000/health" > /dev/null 2>&1; then
            local end_time=$(date +%s%N)
            response_time=$(( (end_time - start_time) / 1000000 ))
            app_status="local_only"
        else
            app_status="unhealthy"
            response_time=9999
        fi
    fi
    
    # Error count from logs
    local error_log="${PROJECT_DIR}/shared/logs/error.log"
    if [ -f "$error_log" ]; then
        error_count=$(tail -100 "$error_log" | grep -i error | wc -l)
    fi
    
    # Get PM2 memory usage if available
    local memory_usage=0
    if command -v pm2 &> /dev/null && pm2 list | grep -q "$PROJECT_NAME"; then
        memory_usage=$(pm2 show "$PROJECT_NAME" 2>/dev/null | grep "memory usage" | awk '{print $4}' | sed 's/M//' || echo "0")
    fi
    
    cat > "$metrics_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "application": {
        "status": "${app_status}",
        "pm2_status": "${pm2_status}",
        "response_time_ms": ${response_time},
        "memory_usage_mb": ${memory_usage},
        "error_count_recent": ${error_count}
    }
}
EOF
    
    echo "$metrics_file"
}

collect_service_metrics() {
    local metrics_file="${METRICS_DIR}/services_${TIMESTAMP}.json"
    
    # Check individual services
    local nginx_status="unknown"
    local postgres_status="unknown"
    local redis_status="unknown"
    
    # Nginx
    if systemctl is-active --quiet nginx; then
        nginx_status="active"
    else
        nginx_status="inactive"
    fi
    
    # PostgreSQL
    if systemctl is-active --quiet postgresql; then
        postgres_status="active"
    else
        postgres_status="inactive"
    fi
    
    # Redis (optional)
    if systemctl is-active --quiet redis 2>/dev/null; then
        redis_status="active"
    elif systemctl is-active --quiet redis-server 2>/dev/null; then
        redis_status="active"
    else
        redis_status="inactive"
    fi
    
    cat > "$metrics_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "services": {
        "nginx": "${nginx_status}",
        "postgresql": "${postgres_status}",
        "redis": "${redis_status}"
    }
}
EOF
    
    echo "$metrics_file"
}

# ===============================
# HEALTH CHECKS
# ===============================

check_system_health() {
    local health_status="healthy"
    local issues=()
    
    # Collect current metrics
    local system_metrics=$(collect_system_metrics)
    local cpu_usage=$(jq -r '.system.cpu_usage' < "$system_metrics")
    local mem_usage=$(jq -r '.system.memory.usage_percent' < "$system_metrics")
    local disk_usage=$(jq -r '.system.disk.usage_percent' < "$system_metrics")
    local load_avg=$(jq -r '.system.load_average' < "$system_metrics")
    
    # CPU check
    if (( $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) )); then
        issues+=("High CPU usage: ${cpu_usage}%")
        health_status="warning"
    fi
    
    # Memory check
    if [ "$mem_usage" -gt "$MEMORY_THRESHOLD" ]; then
        issues+=("High memory usage: ${mem_usage}%")
        health_status="warning"
    fi
    
    # Disk check
    if [ "$disk_usage" -gt "$DISK_THRESHOLD" ]; then
        issues+=("High disk usage: ${disk_usage}%")
        if [ "$disk_usage" -gt 95 ]; then
            health_status="critical"
        fi
    fi
    
    # Load average check
    if (( $(echo "$load_avg > $LOAD_THRESHOLD" | bc -l) )); then
        issues+=("High load average: ${load_avg}")
        health_status="warning"
    fi
    
    # Report results
    if [ "$health_status" = "healthy" ]; then
        log "SUCCESS" "System health: All metrics within normal ranges"
    else
        log "WARN" "System health: ${health_status} - Issues: ${issues[*]}"
    fi
    
    echo "$health_status"
}

check_application_health() {
    local app_metrics=$(collect_application_metrics)
    local app_status=$(jq -r '.application.status' < "$app_metrics")
    local response_time=$(jq -r '.application.response_time_ms' < "$app_metrics")
    local error_count=$(jq -r '.application.error_count_recent' < "$app_metrics")
    
    case "$app_status" in
        "healthy")
            if [ "$response_time" -gt "$RESPONSE_TIME_THRESHOLD" ]; then
                log "WARN" "Application response time high: ${response_time}ms"
                echo "slow"
            else
                log "SUCCESS" "Application health: Healthy (${response_time}ms)"
                echo "healthy"
            fi
            ;;
        "local_only")
            log "WARN" "Application accessible only locally"
            echo "degraded"
            ;;
        "unhealthy")
            log "ERROR" "Application health check failed"
            echo "unhealthy"
            ;;
        "down"|"not_deployed")
            log "CRITICAL" "Application is down or not deployed"
            echo "down"
            ;;
        *)
            log "ERROR" "Unknown application status: $app_status"
            echo "unknown"
            ;;
    esac
}

check_services_health() {
    local service_metrics=$(collect_service_metrics)
    local nginx_status=$(jq -r '.services.nginx' < "$service_metrics")
    local postgres_status=$(jq -r '.services.postgresql' < "$service_metrics")
    
    local health_status="healthy"
    local issues=()
    
    if [ "$nginx_status" != "active" ]; then
        issues+=("Nginx: $nginx_status")
        health_status="critical"
    fi
    
    if [ "$postgres_status" != "active" ]; then
        issues+=("PostgreSQL: $postgres_status")
        health_status="critical"
    fi
    
    if [ "$health_status" = "healthy" ]; then
        log "SUCCESS" "Services health: All services running"
    else
        log "ERROR" "Services health: ${health_status} - Issues: ${issues[*]}"
    fi
    
    echo "$health_status"
}

# ===============================
# AUTO-HEALING
# ===============================

attempt_auto_healing() {
    local issue_type=$1
    log "INFO" "Attempting auto-healing for: $issue_type"
    
    case "$issue_type" in
        "application_down")
            log "INFO" "Attempting to restart application..."
            if pm2 list | grep -q "$PROJECT_NAME"; then
                pm2 restart "$PROJECT_NAME"
                sleep 10
                if pm2 list | grep -q "online.*$PROJECT_NAME"; then
                    log "SUCCESS" "Application restarted successfully"
                    return 0
                fi
            fi
            log "ERROR" "Failed to restart application"
            return 1
            ;;
        "nginx_down")
            log "INFO" "Attempting to restart Nginx..."
            if systemctl restart nginx; then
                log "SUCCESS" "Nginx restarted successfully"
                return 0
            fi
            log "ERROR" "Failed to restart Nginx"
            return 1
            ;;
        "postgres_down")
            log "INFO" "Attempting to restart PostgreSQL..."
            if systemctl restart postgresql; then
                log "SUCCESS" "PostgreSQL restarted successfully"
                return 0
            fi
            log "ERROR" "Failed to restart PostgreSQL"
            return 1
            ;;
        "high_memory")
            log "INFO" "Attempting to clear system caches..."
            sync && echo 3 > /proc/sys/vm/drop_caches
            log "SUCCESS" "System caches cleared"
            return 0
            ;;
        *)
            log "WARN" "No auto-healing available for: $issue_type"
            return 1
            ;;
    esac
}

# ===============================
# ALERTING SYSTEM
# ===============================

send_slack_alert() {
    local level=$1
    local message=$2
    
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        local color="good"
        local emoji="✅"
        
        case "$level" in
            "WARNING") color="warning"; emoji="⚠️" ;;
            "CRITICAL"|"ERROR") color="danger"; emoji="🚨" ;;
        esac
        
        local payload=$(cat <<EOF
{
    "attachments": [
        {
            "color": "$color",
            "pretext": "${emoji} ${PROJECT_NAME} Alert",
            "title": "$level: Health Monitor",
            "text": "$message",
            "fields": [
                {
                    "title": "Server",
                    "value": "$(hostname)",
                    "short": true
                },
                {
                    "title": "Time",
                    "value": "$CURRENT_TIME",
                    "short": true
                }
            ]
        }
    ]
}
EOF
)
        
        curl -X POST -H 'Content-type: application/json' \
            --data "$payload" \
            "$SLACK_WEBHOOK_URL" &>/dev/null || true
    fi
}

send_discord_alert() {
    local level=$1
    local message=$2
    
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        local emoji="✅"
        
        case "$level" in
            "WARNING") emoji="⚠️" ;;
            "CRITICAL"|"ERROR") emoji="🚨" ;;
        esac
        
        local payload=$(cat <<EOF
{
    "embeds": [
        {
            "title": "${emoji} ${PROJECT_NAME} Health Alert",
            "description": "$message",
            "color": 15258703,
            "fields": [
                {
                    "name": "Level",
                    "value": "$level",
                    "inline": true
                },
                {
                    "name": "Server",
                    "value": "$(hostname)",
                    "inline": true
                },
                {
                    "name": "Time",
                    "value": "$CURRENT_TIME",
                    "inline": true
                }
            ]
        }
    ]
}
EOF
)
        
        curl -X POST -H 'Content-type: application/json' \
            --data "$payload" \
            "$DISCORD_WEBHOOK_URL" &>/dev/null || true
    fi
}

send_email_alert() {
    local level=$1
    local message=$2
    
    if command -v mail &> /dev/null && [ -n "$EMAIL_TO" ]; then
        cat <<EOF | mail -s "${PROJECT_NAME} Alert: $level" "$EMAIL_TO"
Health Monitor Alert

Level: $level
Server: $(hostname)
Time: $CURRENT_TIME
Domain: $DOMAIN

Message: $message

--
Automated Health Monitor
EOF
    fi
}

send_alert() {
    local level=$1
    local message=$2
    
    log "$level" "ALERT: $message"
    
    # Prevent spam - check if similar alert was sent recently
    local alert_hash=$(echo "$level:$message" | md5sum | cut -d' ' -f1)
    local alert_file="${ALERTS_DIR}/${alert_hash}"
    
    if [ -f "$alert_file" ]; then
        local last_sent=$(cat "$alert_file")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_sent))
        
        # Only send alert if last one was sent more than 30 minutes ago
        if [ $time_diff -lt 1800 ]; then
            return
        fi
    fi
    
    # Send notifications
    send_slack_alert "$level" "$message"
    send_discord_alert "$level" "$message"
    send_email_alert "$level" "$message"
    
    # Record alert sent time
    echo $(date +%s) > "$alert_file"
}

# ===============================
# REPORTING
# ===============================

generate_health_report() {
    local report_file="${MONITORING_DIR}/reports/health_report_${TIMESTAMP}.html"
    
    # Collect all metrics
    local system_metrics=$(collect_system_metrics)
    local app_metrics=$(collect_application_metrics)
    local service_metrics=$(collect_service_metrics)
    
    # Generate HTML report
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Health Report - ${PROJECT_NAME}</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { text-align: center; margin-bottom: 30px; }
        .metric-card { display: inline-block; width: 300px; margin: 10px; padding: 15px; border: 1px solid #ddd; border-radius: 5px; vertical-align: top; }
        .healthy { border-color: #28a745; background-color: #d4edda; }
        .warning { border-color: #ffc107; background-color: #fff3cd; }
        .critical { border-color: #dc3545; background-color: #f8d7da; }
        .metric-title { font-weight: bold; margin-bottom: 10px; }
        .metric-value { font-size: 24px; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔍 Health Report</h1>
            <h2>${PROJECT_NAME}</h2>
            <p>Generated: ${CURRENT_TIME}</p>
        </div>
        
        <div class="metrics">
            <div class="metric-card">
                <div class="metric-title">CPU Usage</div>
                <div class="metric-value">$(jq -r '.system.cpu_usage' < "$system_metrics")%</div>
            </div>
            
            <div class="metric-card">
                <div class="metric-title">Memory Usage</div>
                <div class="metric-value">$(jq -r '.system.memory.usage_percent' < "$system_metrics")%</div>
            </div>
            
            <div class="metric-card">
                <div class="metric-title">Disk Usage</div>
                <div class="metric-value">$(jq -r '.system.disk.usage_percent' < "$system_metrics")%</div>
            </div>
            
            <div class="metric-card">
                <div class="metric-title">Application Status</div>
                <div class="metric-value">$(jq -r '.application.status' < "$app_metrics")</div>
            </div>
            
            <div class="metric-card">
                <div class="metric-title">Response Time</div>
                <div class="metric-value">$(jq -r '.application.response_time_ms' < "$app_metrics")ms</div>
            </div>
        </div>
    </div>
</body>
</html>
EOF
    
    log "INFO" "Health report generated: $report_file"
}

# ===============================
# MAIN MONITORING LOOP
# ===============================

main() {
    setup_monitoring_dirs
    
    log "INFO" "Starting health monitoring cycle"
    
    # Collect all metrics
    local system_health=$(check_system_health)
    local app_health=$(check_application_health)
    local services_health=$(check_services_health)
    
    # Determine overall health
    local overall_health="healthy"
    local issues=()
    
    case "$system_health" in
        "warning"|"critical")
            overall_health="warning"
            issues+=("System: $system_health")
            ;;
    esac
    
    case "$app_health" in
        "slow"|"degraded")
            if [ "$overall_health" = "healthy" ]; then
                overall_health="warning"
            fi
            issues+=("Application: $app_health")
            ;;
        "unhealthy"|"down")
            overall_health="critical"
            issues+=("Application: $app_health")
            
            # Attempt auto-healing
            attempt_auto_healing "application_down"
            ;;
    esac
    
    case "$services_health" in
        "critical")
            overall_health="critical"
            issues+=("Services: $services_health")
            
            # Attempt service healing
            attempt_auto_healing "nginx_down"
            attempt_auto_healing "postgres_down"
            ;;
    esac
    
    # Send alerts if needed
    if [ "$overall_health" = "critical" ]; then
        send_alert "CRITICAL" "System health critical: ${issues[*]}"
    elif [ "$overall_health" = "warning" ]; then
        send_alert "WARNING" "System health warning: ${issues[*]}"
    fi
    
    # Generate report (every hour)
    local minute=$(date +%M)
    if [ "$minute" = "00" ]; then
        generate_health_report
    fi
    
    # Cleanup old files (keep last 7 days)
    find "$METRICS_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null || true
    find "${MONITORING_DIR}/reports" -name "*.html" -mtime +7 -delete 2>/dev/null || true
    
    log "INFO" "Health monitoring cycle completed - Overall health: $overall_health"
}

# Ensure required tools are available
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Aborting." >&2; exit 1; }
command -v bc >/dev/null 2>&1 || { echo "bc is required but not installed. Aborting." >&2; exit 1; }

main "$@"
