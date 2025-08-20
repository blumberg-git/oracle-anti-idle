#!/bin/bash

# Oracle Anti-Idle System - Enhanced Edition
# Build: 5.0.0
# Build Time: 2025-08-20 04:00:00
# Description: Ultra-reliable 24/7 stress testing with enhanced monitoring and recovery

set -euo pipefail

# Configuration
SCRIPT_VERSION="5.0.0"
BUILD_TIME="2025-08-20 04:00:00"
LOG_DIR="/var/log/oracle-anti-idle"
LOG_FILE="$LOG_DIR/anti-idle.log"
ERROR_LOG="$LOG_DIR/error.log"
HEALTH_LOG="$LOG_DIR/health.log"
SUPERVISOR_CONF="/etc/supervisor/conf.d/oracle-anti-idle.conf"
SYSTEMD_SERVICE="/etc/systemd/system/oracle-anti-idle-monitor.service"
STATE_FILE="/var/lib/oracle-anti-idle/state"
LOCK_FILE="/var/run/oracle-anti-idle.lock"
BACKUP_DIR="/var/backups/oracle-anti-idle"
DEFAULT_CPU_COUNT=4
DEFAULT_CPU_LOAD=15
DEFAULT_MEMORY_PERCENT=15
MIN_FREE_MEMORY_MB=100
MAX_RETRIES=3
HEALTH_CHECK_INTERVAL=300
LOG_LEVEL="INFO"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
BLINK='\033[5m'
NC='\033[0m'

# Unicode characters
CHECK="✓"
CROSS="✗"
ARROW="➜"
DOT="●"
STAR="★"
WARNING="⚠"
INFO="ℹ"
GEAR="⚙"
ROCKET="🚀"
SHIELD="🛡"
HEART="❤"
FIRE="🔥"

# Prevent multiple instances
acquire_lock() {
    local timeout=10
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo $$ > "$LOCK_FILE/pid"
            trap 'release_lock' EXIT
            return 0
        fi
        
        # Check if the process holding the lock is still running
        if [[ -f "$LOCK_FILE/pid" ]]; then
            local pid=$(cat "$LOCK_FILE/pid" 2>/dev/null)
            if ! kill -0 "$pid" 2>/dev/null; then
                # Process is dead, remove stale lock
                rm -rf "$LOCK_FILE"
                continue
            fi
        fi
        
        sleep 1
        ((elapsed++))
    done
    
    echo -e "${RED}${CROSS} Another instance is already running${NC}"
    exit 1
}

release_lock() {
    rm -rf "$LOCK_FILE" 2>/dev/null || true
}

# Initialize logging with rotation
init_logging() {
    if [[ -w /var/log ]] 2>/dev/null; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        
        # Rotate logs if they're too large (>50MB)
        for log in "$LOG_FILE" "$ERROR_LOG" "$HEALTH_LOG"; do
            if [[ -f "$log" ]] && [[ $(stat -f%z "$log" 2>/dev/null || stat -c%s "$log" 2>/dev/null) -gt 52428800 ]]; then
                mv "$log" "$log.$(date +%Y%m%d_%H%M%S)"
                gzip "$log."* 2>/dev/null || true
            fi
        done
        
        touch "$LOG_FILE" "$ERROR_LOG" "$HEALTH_LOG" 2>/dev/null || true
    fi
}

# Enhanced logging
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="${timestamp} [${level}] ${message}"
    
    # Write to appropriate log file
    case "$level" in
        ERROR)
            echo "$log_entry" >> "$ERROR_LOG" 2>/dev/null || true
            echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
            ;;
        HEALTH)
            echo "$log_entry" >> "$HEALTH_LOG" 2>/dev/null || true
            echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
            ;;
        *)
            echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
            ;;
    esac
    
    # Console output based on log level
    local show_output=false
    case "$LOG_LEVEL" in
        DEBUG) show_output=true ;;
        INFO) [[ "$level" != "DEBUG" ]] && show_output=true ;;
        WARN) [[ "$level" == "WARN" || "$level" == "ERROR" || "$level" == "HEALTH" ]] && show_output=true ;;
        ERROR) [[ "$level" == "ERROR" ]] && show_output=true ;;
    esac
    
    if [[ "$show_output" == true ]] && [[ "${SILENT_MODE:-false}" != true ]]; then
        case "$level" in
            DEBUG) echo -e "${GRAY}[DEBUG]${NC} ${message}" >&2 ;;
            INFO) echo -e "${BLUE}[INFO]${NC} ${message}" >&2 ;;
            WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
            ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
            HEALTH) echo -e "${GREEN}[HEALTH]${NC} ${message}" >&2 ;;
        esac
    fi
}

# Display ASCII art banner
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
   ____                 _        _          _   _     ___    _ _      
  / __ \               | |      | |   /\   | | (_)   |_ _|  | | |     
 | |  | |_ __ __ _  ___| | ___  | |  /  \  | |_ _     | |  __| | | ___ 
 | |  | | '__/ _` |/ __| |/ _ \ | | / /\ \ | __| |    | | / _` | |/ _ \
 | |__| | | | (_| | (__| |  __| | |/ ____ \| |_| |   _| || (_| | |  __/
  \____/|_|  \__,_|\___|_|\___| |_/_/    \_\\__|_|  |_____\__,_|_|\___|
EOF
    echo -e "${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}        Never Let Your Oracle Cloud Instance Go Idle!${NC}"
    echo -e "${GRAY}          Enhanced Edition v${SCRIPT_VERSION} | Build: ${BUILD_TIME}${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════${NC}\n"
}

# Loading animation
show_loading() {
    local message="${1:-Loading}"
    local duration="${2:-2}"
    local spinners=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local end_time=$((SECONDS + duration))
    
    while [ $SECONDS -lt $end_time ]; do
        for spinner in "${spinners[@]}"; do
            echo -ne "\r${CYAN}${spinner}${NC} ${message}..."
            sleep 0.1
        done
    done
    echo -ne "\r${GREEN}${CHECK}${NC} ${message}... Done!   \n"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}${CROSS} Error: Root privileges required${NC}"
        echo -e "${YELLOW}${INFO} Please run with: ${WHITE}sudo $0${NC}\n"
        log "ERROR" "Script run without root privileges by user $(whoami)"
        exit 1
    fi
}

# Enhanced platform detection
check_platform() {
    local os_name="Unknown"
    local os_version="Unknown"
    local is_ubuntu=false
    local kernel_version=$(uname -r)
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        os_name="${NAME:-Unknown}"
        os_version="${VERSION:-Unknown}"
        
        if [[ "$ID" == "ubuntu" ]] || [[ "$ID_LIKE" == *"ubuntu"* ]] || [[ "$ID" == "debian" ]] || [[ "$ID_LIKE" == *"debian"* ]]; then
            is_ubuntu=true
        fi
    fi
    
    echo -e "${CYAN}${INFO} System Detection:${NC}"
    echo -e "  ${DOT} OS: ${WHITE}${os_name}${NC}"
    echo -e "  ${DOT} Version: ${WHITE}${os_version}${NC}"
    echo -e "  ${DOT} Kernel: ${WHITE}${kernel_version}${NC}"
    echo -e "  ${DOT} Architecture: ${WHITE}$(uname -m)${NC}"
    echo -e "  ${DOT} CPUs: ${WHITE}$(nproc)${NC}"
    echo -e "  ${DOT} Memory: ${WHITE}$(free -h | grep ^Mem | awk '{print $2}')${NC}"
    echo -e "  ${DOT} Uptime: ${WHITE}$(uptime -p 2>/dev/null || uptime)${NC}"
    
    # Check if running in Oracle Cloud
    if [[ -f /sys/devices/virtual/dmi/id/chassis_asset_tag ]]; then
        local asset_tag=$(cat /sys/devices/virtual/dmi/id/chassis_asset_tag 2>/dev/null)
        if [[ "$asset_tag" == *"OracleCloud"* ]]; then
            echo -e "  ${DOT} Platform: ${WHITE}Oracle Cloud${NC} ${GREEN}${CHECK}${NC}"
        fi
    fi
    
    if [[ "$is_ubuntu" == false ]]; then
        echo -e "\n${RED}${CROSS} Error: This script is designed for Ubuntu/Debian systems only${NC}"
        log "ERROR" "Unsupported OS detected: $os_name $os_version"
        exit 1
    else
        echo -e "\n${GREEN}${CHECK} Ubuntu/Debian system detected - Compatible${NC}"
        log "INFO" "Running on supported system: $os_name $os_version"
    fi
}

# System health check
check_system_health() {
    local health_status="healthy"
    local issues=()
    
    echo -e "\n${CYAN}${HEART} Performing System Health Check...${NC}\n"
    
    # Check CPU temperature if available
    if command -v sensors &>/dev/null; then
        local temp=$(sensors 2>/dev/null | grep -E "Core|CPU" | grep -oE "[0-9]+\.[0-9]°C" | head -1)
        if [[ -n "$temp" ]]; then
            echo -e "  ${DOT} CPU Temperature: ${WHITE}${temp}${NC}"
        fi
    fi
    
    # Check available memory
    local free_mem=$(free -m | grep ^Mem | awk '{print $4}')
    if [[ $free_mem -lt $MIN_FREE_MEMORY_MB ]]; then
        issues+=("Low memory: ${free_mem}MB free")
        health_status="degraded"
        echo -e "  ${YELLOW}${WARNING}${NC} Free Memory: ${YELLOW}${free_mem}MB${NC} (Low)"
    else
        echo -e "  ${DOT} Free Memory: ${GREEN}${free_mem}MB${NC}"
    fi
    
    # Check disk space
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        issues+=("High disk usage: ${disk_usage}%")
        health_status="degraded"
        echo -e "  ${YELLOW}${WARNING}${NC} Disk Usage: ${YELLOW}${disk_usage}%${NC} (High)"
    else
        echo -e "  ${DOT} Disk Usage: ${GREEN}${disk_usage}%${NC}"
    fi
    
    # Check load average
    local load_1min=$(uptime | awk '{print $(NF-2)}' | sed 's/,//')
    local cpu_count=$(nproc)
    if (( $(echo "$load_1min > $cpu_count" | bc -l 2>/dev/null || echo 0) )); then
        issues+=("High load: ${load_1min}")
        health_status="degraded"
        echo -e "  ${YELLOW}${WARNING}${NC} Load Average: ${YELLOW}${load_1min}${NC} (High)"
    else
        echo -e "  ${DOT} Load Average: ${GREEN}${load_1min}${NC}"
    fi
    
    # Check network connectivity
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        echo -e "  ${DOT} Network: ${GREEN}Connected${NC}"
    else
        echo -e "  ${YELLOW}${WARNING}${NC} Network: ${YELLOW}No Internet${NC}"
        issues+=("No internet connectivity")
    fi
    
    # Check supervisor status
    if pgrep -x "supervisord" > /dev/null; then
        echo -e "  ${DOT} Supervisor: ${GREEN}Running${NC}"
    else
        echo -e "  ${YELLOW}${WARNING}${NC} Supervisor: ${YELLOW}Not Running${NC}"
        health_status="degraded"
        issues+=("Supervisor not running")
    fi
    
    # Log health status
    if [[ "$health_status" == "healthy" ]]; then
        echo -e "\n${GREEN}${CHECK} System Health: Optimal${NC}"
        log "HEALTH" "System health check: HEALTHY"
    else
        echo -e "\n${YELLOW}${WARNING} System Health: Degraded${NC}"
        echo -e "${YELLOW}Issues: ${issues[*]}${NC}"
        log "HEALTH" "System health check: DEGRADED - ${issues[*]}"
    fi
    
    return $([ "$health_status" == "healthy" ] && echo 0 || echo 1)
}

# Auto-install dependencies with retry logic
auto_install_dependencies() {
    local needs_install=false
    local missing_deps=()
    local retry_count=0
    
    echo -e "\n${CYAN}${GEAR} Checking Required Components...${NC}\n"
    
    # Check each dependency
    for dep in stress-ng supervisor bc curl net-tools; do
        if ! command -v $dep &>/dev/null; then
            echo -e "  ${YELLOW}${WARNING}${NC} $dep: ${YELLOW}Not installed${NC}"
            missing_deps+=("$dep")
            needs_install=true
        else
            echo -e "  ${GREEN}${CHECK}${NC} $dep: ${GREEN}Installed${NC}"
        fi
    done
    
    if [[ "$needs_install" == true ]]; then
        echo -e "\n${YELLOW}${INFO} Installing missing components...${NC}\n"
        
        while [[ $retry_count -lt $MAX_RETRIES ]]; do
            echo -e "${CYAN}${ARROW}${NC} Updating package lists (attempt $((retry_count + 1))/${MAX_RETRIES})..."
            
            if apt-get update 2>&1 | tee -a "$LOG_FILE" | grep -E "^(Get:|Hit:|Ign:)" | head -5; then
                echo -e "${GREEN}${CHECK}${NC} Package lists updated\n"
                break
            else
                ((retry_count++))
                if [[ $retry_count -lt $MAX_RETRIES ]]; then
                    echo -e "${YELLOW}${WARNING}${NC} Update failed, retrying in 5 seconds..."
                    sleep 5
                else
                    echo -e "${RED}${CROSS}${NC} Failed to update package lists after ${MAX_RETRIES} attempts"
                    log "ERROR" "apt-get update failed after ${MAX_RETRIES} attempts"
                    return 1
                fi
            fi
        done
        
        # Install packages
        for dep in "${missing_deps[@]}"; do
            echo -e "  Installing ${WHITE}$dep${NC}..."
            retry_count=0
            
            while [[ $retry_count -lt $MAX_RETRIES ]]; do
                if DEBIAN_FRONTEND=noninteractive apt-get install -y "$dep" 2>&1 | tee -a "$LOG_FILE" | tail -3; then
                    echo -e "  ${GREEN}${CHECK}${NC} $dep installed successfully"
                    break
                else
                    ((retry_count++))
                    if [[ $retry_count -lt $MAX_RETRIES ]]; then
                        echo -e "  ${YELLOW}${WARNING}${NC} Installation failed, retrying..."
                        sleep 3
                    else
                        echo -e "  ${RED}${CROSS}${NC} Failed to install $dep"
                        log "ERROR" "Failed to install $dep after ${MAX_RETRIES} attempts"
                        
                        if [[ "$dep" == "supervisor" ]] || [[ "$dep" == "stress-ng" ]]; then
                            return 1
                        fi
                    fi
                fi
            done
        done
        
        # Configure supervisor
        if [[ " ${missing_deps[@]} " =~ " supervisor " ]]; then
            echo -e "\n${CYAN}${ARROW}${NC} Configuring supervisor service..."
            
            if command -v systemctl &>/dev/null; then
                systemctl enable supervisor 2>/dev/null && echo -e "  ${GREEN}${CHECK}${NC} Supervisor enabled"
                systemctl start supervisor 2>/dev/null && echo -e "  ${GREEN}${CHECK}${NC} Supervisor started"
            elif command -v service &>/dev/null; then
                service supervisor start 2>/dev/null && echo -e "  ${GREEN}${CHECK}${NC} Supervisor started"
            else
                supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null && echo -e "  ${GREEN}${CHECK}${NC} Supervisord started"
            fi
        fi
        
        echo -e "\n${GREEN}${CHECK} All required components installed!${NC}"
    else
        echo -e "\n${GREEN}${CHECK} All required components already installed${NC}"
    fi
}

# Create systemd monitoring service
create_monitoring_service() {
    echo -e "\n${CYAN}${SHIELD} Creating Monitoring Service...${NC}"
    
    cat > "$SYSTEMD_SERVICE" << 'EOF'
[Unit]
Description=Oracle Anti-Idle Monitor
After=network.target supervisor.service
Wants=supervisor.service

[Service]
Type=simple
User=root
ExecStart=/bin/bash -c 'while true; do \
    if ! pgrep -x "supervisord" > /dev/null; then \
        systemctl restart supervisor; \
        sleep 10; \
    fi; \
    if ! supervisorctl status oracle_anti_idle:* | grep -q RUNNING; then \
        supervisorctl start oracle_anti_idle:*; \
    fi; \
    sleep 60; \
done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload 2>/dev/null
    systemctl enable oracle-anti-idle-monitor 2>/dev/null
    systemctl start oracle-anti-idle-monitor 2>/dev/null
    
    echo -e "${GREEN}${CHECK}${NC} Monitoring service created"
    log "INFO" "Monitoring service created and started"
}

# Backup configuration
backup_configuration() {
    local backup_name="backup_$(date +%Y%m%d_%H%M%S)"
    
    echo -e "\n${CYAN}${ARROW}${NC} Creating backup..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Create backup
    if tar -czf "$BACKUP_DIR/${backup_name}.tar.gz" \
        "$STATE_FILE" \
        "$SUPERVISOR_CONF" \
        "$LOG_DIR" \
        2>/dev/null; then
        
        echo -e "${GREEN}${CHECK}${NC} Backup created: $BACKUP_DIR/${backup_name}.tar.gz"
        log "INFO" "Configuration backed up to $BACKUP_DIR/${backup_name}.tar.gz"
        
        # Keep only last 5 backups
        ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
        
        return 0
    else
        echo -e "${RED}${CROSS}${NC} Backup failed"
        log "ERROR" "Backup creation failed"
        return 1
    fi
}

# Restore configuration
restore_configuration() {
    echo -e "\n${CYAN}${INFO} Available Backups:${NC}"
    
    local backups=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${YELLOW}${WARNING}${NC} No backups found"
        return 1
    fi
    
    for i in "${!backups[@]}"; do
        local backup_file=$(basename "${backups[$i]}")
        local backup_date=$(echo "$backup_file" | sed 's/backup_//;s/.tar.gz//')
        echo -e "  $((i+1))) $backup_date"
    done
    
    read -p "Select backup to restore (1-${#backups[@]}): " choice
    
    if [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((choice-1))]}"
        
        echo -e "\n${YELLOW}${WARNING} This will overwrite current configuration. Continue? (y/n)${NC}"
        read -p "  > " confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            # Stop services
            supervisorctl stop oracle_anti_idle:* 2>/dev/null
            
            # Extract backup
            if tar -xzf "$selected_backup" -C / 2>/dev/null; then
                echo -e "${GREEN}${CHECK}${NC} Configuration restored"
                log "INFO" "Configuration restored from $selected_backup"
                
                # Reload supervisor
                supervisorctl reread
                supervisorctl update
                
                return 0
            else
                echo -e "${RED}${CROSS}${NC} Restore failed"
                log "ERROR" "Failed to restore from $selected_backup"
                return 1
            fi
        fi
    else
        echo -e "${RED}${CROSS}${NC} Invalid selection"
        return 1
    fi
}

# Enhanced state management
save_state() {
    local enabled="$1"
    local cpu_count="${2:-$DEFAULT_CPU_COUNT}"
    local cpu_load="${3:-$DEFAULT_CPU_LOAD}"
    local memory_percent="${4:-$DEFAULT_MEMORY_PERCENT}"
    
    # Validate inputs
    [[ ! "$cpu_count" =~ ^[0-9]+$ ]] && cpu_count=$DEFAULT_CPU_COUNT
    [[ ! "$cpu_load" =~ ^[0-9]+$ ]] && cpu_load=$DEFAULT_CPU_LOAD
    [[ ! "$memory_percent" =~ ^[0-9]+$ ]] && memory_percent=$DEFAULT_MEMORY_PERCENT
    
    # Ensure values are within bounds
    local max_cpus=$(nproc)
    [[ $cpu_count -gt $max_cpus ]] && cpu_count=$max_cpus
    [[ $cpu_load -gt 100 ]] && cpu_load=100
    [[ $memory_percent -gt 100 ]] && memory_percent=100
    
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    
    cat > "$STATE_FILE" << EOF
ENABLED="$enabled"
CPU_COUNT="$cpu_count"
CPU_LOAD="$cpu_load"
MEMORY_PERCENT="$memory_percent"
LAST_MODIFIED="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_ACTION="$(date '+%Y-%m-%d %H:%M:%S'): State changed to $enabled"
SCRIPT_VERSION="$SCRIPT_VERSION"
EOF
    
    log "INFO" "State saved: enabled=$enabled, cpu=$cpu_count@$cpu_load%, mem=$memory_percent%"
}

# Load state
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null || {
            log "WARN" "Failed to load state file"
            echo "false"
            return
        }
        echo "${ENABLED:-false}"
    else
        echo "false"
    fi
}

# Get status display
get_status_display() {
    local state=$(load_state)
    if [[ "$state" == "true" ]]; then
        echo -e "${GREEN}${DOT} ACTIVE${NC}"
    else
        echo -e "${RED}${DOT} INACTIVE${NC}"
    fi
}

# Create supervisor configuration with enhanced settings
create_supervisor_config() {
    local cpu_count="${1:-$DEFAULT_CPU_COUNT}"
    local cpu_load="${2:-$DEFAULT_CPU_LOAD}"
    local memory_percent="${3:-$DEFAULT_MEMORY_PERCENT}"
    
    echo -e "\n${CYAN}${GEAR} Creating Enhanced Configuration...${NC}\n"
    
    # Ensure supervisor is running
    if ! pgrep -x "supervisord" > /dev/null; then
        echo -e "${YELLOW}${INFO} Starting supervisor service...${NC}"
        if command -v systemctl &>/dev/null; then
            systemctl start supervisor 2>/dev/null || service supervisor start 2>/dev/null
        else
            supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null
        fi
        sleep 2
    fi
    
    # Backup existing config
    if [[ -f "$SUPERVISOR_CONF" ]]; then
        backup_configuration
    fi
    
    # Create directories
    mkdir -p "$(dirname "$SUPERVISOR_CONF")"
    mkdir -p "$LOG_DIR"
    
    # Create enhanced configuration
    cat > "$SUPERVISOR_CONF" << EOF
; Oracle Anti-Idle Enhanced Configuration
; Version: ${SCRIPT_VERSION}
; Generated: $(date '+%Y-%m-%d %H:%M:%S')
; CPU: ${cpu_count} cores @ ${cpu_load}% | Memory: ${memory_percent}%

[program:oracle_anti_idle_cpu]
command=/usr/bin/stress-ng --cpu ${cpu_count} --cpu-load ${cpu_load} --cpu-method all --verify --timeout 0
directory=/usr/bin/
user=root
autostart=true
autorestart=unexpected
exitcodes=0
redirect_stderr=true
stdout_logfile=${LOG_DIR}/cpu_stress.log
stderr_logfile=${LOG_DIR}/cpu_stress_error.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
priority=100
stopasgroup=true
killasgroup=true
startsecs=10
startretries=999999
stopsignal=TERM
stopwaitsecs=10
environment=STRESS_NG_CPU_LOAD="${cpu_load}",STRESS_NG_CPU_COUNT="${cpu_count}"

[program:oracle_anti_idle_memory]
command=/usr/bin/stress-ng --vm 1 --vm-bytes ${memory_percent}%% --vm-hang 0 --verify --timeout 0
directory=/usr/bin/
user=root
autostart=true
autorestart=unexpected
exitcodes=0
redirect_stderr=true
stdout_logfile=${LOG_DIR}/memory_stress.log
stderr_logfile=${LOG_DIR}/memory_stress_error.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
priority=100
stopasgroup=true
killasgroup=true
startsecs=10
startretries=999999
stopsignal=TERM
stopwaitsecs=10
environment=STRESS_NG_VM_BYTES="${memory_percent}%%"

[program:oracle_anti_idle_watchdog]
command=/bin/bash -c 'while true; do if ! pgrep -f "stress-ng.*cpu" > /dev/null; then echo "CPU stress not running, will be restarted by supervisor"; fi; if ! pgrep -f "stress-ng.*vm" > /dev/null; then echo "Memory stress not running, will be restarted by supervisor"; fi; sleep 30; done'
directory=/tmp
user=root
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=${LOG_DIR}/watchdog.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=1
priority=90

[group:oracle_anti_idle]
programs=oracle_anti_idle_cpu,oracle_anti_idle_memory,oracle_anti_idle_watchdog
priority=100

[eventlistener:oracle_anti_idle_listener]
command=/usr/bin/python3 -c "
import sys
import subprocess
from supervisor import childutils

def main():
    while True:
        headers, payload = childutils.listener.wait(sys.stdin, sys.stdout)
        eventname = headers['eventname']
        if eventname.startswith('PROCESS_STATE'):
            pheaders, pdata = childutils.eventdata(payload)
            processname = pheaders['processname']
            if 'oracle_anti_idle' in processname:
                with open('${LOG_DIR}/events.log', 'a') as f:
                    f.write(f'{eventname}: {processname}\\n')
        childutils.listener.ok(sys.stdout)

if __name__ == '__main__':
    main()
"
events=PROCESS_STATE_STOPPED,PROCESS_STATE_EXITED,PROCESS_STATE_FATAL
redirect_stderr=true
stdout_logfile=${LOG_DIR}/listener.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=1
autostart=true
autorestart=true
EOF
    
    echo -e "${GREEN}${CHECK} Enhanced configuration created${NC}"
    log "INFO" "Enhanced supervisor configuration created"
    
    # Reload supervisor
    echo -e "\n${CYAN}${ARROW}${NC} Reloading supervisor..."
    
    if command -v supervisorctl &>/dev/null; then
        supervisorctl reread 2>&1 | tee -a "$LOG_FILE"
        sleep 1
        supervisorctl update 2>&1 | tee -a "$LOG_FILE"
        echo -e "${GREEN}${CHECK}${NC} Configuration reloaded"
    fi
    
    save_state "false" "$cpu_count" "$cpu_load" "$memory_percent"
    
    echo -e "\n${GREEN}${CHECK} Configuration applied successfully!${NC}"
    sleep 2
}

# Toggle anti-idle with health check
toggle_anti_idle() {
    local current_state=$(load_state)
    
    echo -e "\n${CYAN}${GEAR} Toggle Anti-Idle System${NC}\n"
    
    # Perform health check first
    if ! check_system_health; then
        echo -e "\n${YELLOW}${WARNING} System health is degraded. Continue anyway? (y/n)${NC}"
        read -p "  > " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}${INFO} Operation cancelled${NC}"
            return 1
        fi
    fi
    
    if [[ "$current_state" == "true" ]]; then
        echo -e "Current Status: ${GREEN}${DOT} ACTIVE${NC}"
        echo -e "\n${YELLOW}${ARROW}${NC} Stopping anti-idle system..."
        
        if command -v supervisorctl &>/dev/null; then
            supervisorctl stop oracle_anti_idle:* 2>&1 | tee -a "$LOG_FILE"
        else
            pkill -f stress-ng 2>/dev/null && echo -e "${GREEN}${CHECK}${NC} Killed stress processes"
        fi
        
        save_state "false"
        echo -e "\n${GREEN}${CHECK} Anti-idle system ${RED}STOPPED${NC}"
        log "INFO" "Anti-idle system stopped"
    else
        echo -e "Current Status: ${RED}${DOT} INACTIVE${NC}"
        
        if [[ ! -f "$SUPERVISOR_CONF" ]]; then
            echo -e "\n${YELLOW}${WARNING} System not configured. Using default settings...${NC}"
            create_supervisor_config
        fi
        
        echo -e "\n${YELLOW}${ARROW}${NC} Starting anti-idle system..."
        
        if command -v supervisorctl &>/dev/null; then
            supervisorctl start oracle_anti_idle:* 2>&1 | tee -a "$LOG_FILE"
        else
            echo -e "${RED}${CROSS}${NC} supervisorctl not found"
            return 1
        fi
        
        save_state "true"
        echo -e "\n${GREEN}${CHECK} Anti-idle system ${GREEN}STARTED${NC}"
        log "INFO" "Anti-idle system started"
        
        # Create monitoring service if not exists
        if [[ ! -f "$SYSTEMD_SERVICE" ]]; then
            create_monitoring_service
        fi
    fi
    
    sleep 2
}

# Configure parameters with validation
configure_parameters() {
    echo -e "\n${CYAN}${GEAR} Configure Anti-Idle Parameters${NC}\n"
    
    local total_cpus=$(nproc)
    local total_mem=$(free -m | grep ^Mem | awk '{print $2}')
    local free_mem=$(free -m | grep ^Mem | awk '{print $4}')
    
    # Load current config
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null
    fi
    
    echo -e "${INFO} System Resources:"
    echo -e "  ${DOT} Total CPUs: ${WHITE}${total_cpus}${NC}"
    echo -e "  ${DOT} Total Memory: ${WHITE}${total_mem}MB${NC}"
    echo -e "  ${DOT} Free Memory: ${WHITE}${free_mem}MB${NC}\n"
    
    echo -e "${INFO} Current Configuration:"
    echo -e "  ${DOT} CPU Cores: ${WHITE}${CPU_COUNT:-$DEFAULT_CPU_COUNT}${NC}"
    echo -e "  ${DOT} CPU Load: ${WHITE}${CPU_LOAD:-$DEFAULT_CPU_LOAD}%${NC}"
    echo -e "  ${DOT} Memory Usage: ${WHITE}${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}%${NC}\n"
    
    # Recommendations based on system resources
    echo -e "${CYAN}${STAR} Recommendations:${NC}"
    if [[ $free_mem -lt 500 ]]; then
        echo -e "  ${YELLOW}${WARNING}${NC} Low free memory - recommend using ≤10% memory"
    fi
    if [[ $total_cpus -le 2 ]]; then
        echo -e "  ${YELLOW}${INFO}${NC} Limited CPUs - recommend using 1-2 cores at ≤20% load"
    fi
    
    echo -e "\n${MAGENTA}────────────────────────────────────────${NC}\n"
    
    # CPU cores
    while true; do
        echo -e "${CYAN}${ARROW}${NC} Enter number of CPU cores (1-$total_cpus):"
        echo -e "  ${GRAY}[Current: ${CPU_COUNT:-$DEFAULT_CPU_COUNT}, Press Enter to keep]${NC}"
        read -p "  > " cpu_count
        cpu_count=${cpu_count:-${CPU_COUNT:-$DEFAULT_CPU_COUNT}}
        
        if [[ $cpu_count -gt $total_cpus ]]; then
            echo -e "  ${YELLOW}${WARNING} Adjusting to maximum: $total_cpus cores${NC}"
            cpu_count=$total_cpus
        fi
        
        if [[ "$cpu_count" =~ ^[0-9]+$ ]] && [[ $cpu_count -ge 1 ]]; then
            break
        else
            echo -e "  ${RED}${CROSS} Invalid input${NC}\n"
        fi
    done
    
    # CPU load
    while true; do
        echo -e "\n${CYAN}${ARROW}${NC} Enter CPU load percentage (1-100):"
        echo -e "  ${GRAY}[Current: ${CPU_LOAD:-$DEFAULT_CPU_LOAD}, Press Enter to keep]${NC}"
        read -p "  > " cpu_load
        cpu_load=${cpu_load:-${CPU_LOAD:-$DEFAULT_CPU_LOAD}}
        
        if [[ "$cpu_load" =~ ^[0-9]+$ ]] && [[ $cpu_load -ge 1 ]] && [[ $cpu_load -le 100 ]]; then
            break
        else
            echo -e "  ${RED}${CROSS} Invalid input${NC}"
        fi
    done
    
    # Memory percentage
    while true; do
        echo -e "\n${CYAN}${ARROW}${NC} Enter memory usage percentage (1-100):"
        echo -e "  ${GRAY}[Current: ${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}, Press Enter to keep]${NC}"
        read -p "  > " memory_percent
        memory_percent=${memory_percent:-${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}}
        
        local mem_mb=$((total_mem * memory_percent / 100))
        if [[ $mem_mb -gt $((free_mem - MIN_FREE_MEMORY_MB)) ]]; then
            echo -e "  ${YELLOW}${WARNING} This would use ${mem_mb}MB, leaving only $((free_mem - mem_mb))MB free${NC}"
            echo -e "  ${YELLOW}Continue anyway? (y/n)${NC}"
            read -p "  > " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        
        if [[ "$memory_percent" =~ ^[0-9]+$ ]] && [[ $memory_percent -ge 1 ]] && [[ $memory_percent -le 100 ]]; then
            break
        else
            echo -e "  ${RED}${CROSS} Invalid input${NC}"
        fi
    done
    
    echo -e "\n${MAGENTA}────────────────────────────────────────${NC}\n"
    echo -e "${INFO} New Configuration:"
    echo -e "  ${DOT} CPU: ${WHITE}${cpu_count}${NC} cores @ ${WHITE}${cpu_load}%${NC}"
    echo -e "  ${DOT} Memory: ${WHITE}${memory_percent}%${NC} (≈${WHITE}$((total_mem * memory_percent / 100))MB${NC})"
    
    echo -e "\n${YELLOW}${ARROW}${NC} Apply configuration? (y/n)"
    read -p "  > " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        create_supervisor_config "$cpu_count" "$cpu_load" "$memory_percent"
        
        local current_state=$(load_state)
        if [[ "$current_state" == "true" ]]; then
            echo -e "\n${CYAN}${ARROW}${NC} Restarting with new configuration..."
            supervisorctl restart oracle_anti_idle:* 2>&1 | tee -a "$LOG_FILE"
            save_state "true" "$cpu_count" "$cpu_load" "$memory_percent"
        fi
        
        echo -e "\n${GREEN}${CHECK} Configuration updated!${NC}"
    else
        echo -e "\n${YELLOW}${INFO} Configuration cancelled${NC}"
    fi
    
    sleep 2
}

# Enhanced status display
show_detailed_status() {
    echo -e "\n${CYAN}${INFO} System Status Report${NC}\n"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}\n"
    
    # Anti-idle status
    local state=$(load_state)
    if [[ "$state" == "true" ]]; then
        echo -e "${GREEN}${STAR} Anti-Idle: ACTIVE ${BLINK}${GREEN}●${NC}"
    else
        echo -e "${RED}${STAR} Anti-Idle: INACTIVE ${RED}●${NC}"
    fi
    
    # Configuration
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null
        echo -e "\n${WHITE}Configuration:${NC}"
        echo -e "  ${DOT} CPU: ${WHITE}${CPU_COUNT:-N/A}${NC} cores @ ${WHITE}${CPU_LOAD:-N/A}%${NC}"
        echo -e "  ${DOT} Memory: ${WHITE}${MEMORY_PERCENT:-N/A}%${NC}"
        echo -e "  ${DOT} Last Modified: ${WHITE}${LAST_MODIFIED:-N/A}${NC}"
    fi
    
    # Service status
    echo -e "\n${WHITE}Services:${NC}"
    if command -v supervisorctl &>/dev/null; then
        supervisorctl status 2>/dev/null | grep oracle_anti_idle | while read line; do
            if echo "$line" | grep -q RUNNING; then
                echo -e "  ${GREEN}${CHECK}${NC} $line"
            elif echo "$line" | grep -q STOPPED; then
                echo -e "  ${RED}${CROSS}${NC} $line"
            else
                echo -e "  ${YELLOW}${WARNING}${NC} $line"
            fi
        done || echo -e "  ${GRAY}No services configured${NC}"
    fi
    
    # Monitoring service
    if systemctl is-active oracle-anti-idle-monitor &>/dev/null; then
        echo -e "  ${GREEN}${CHECK}${NC} Monitoring service: ${GREEN}Active${NC}"
    else
        echo -e "  ${YELLOW}${WARNING}${NC} Monitoring service: ${YELLOW}Inactive${NC}"
    fi
    
    # Resource usage
    echo -e "\n${WHITE}Resources:${NC}"
    
    local cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print $1}')
    local cpu_usage=$(echo "100 - $cpu_idle" | bc 2>/dev/null || echo "N/A")
    echo -e "  ${DOT} CPU: ${WHITE}${cpu_usage}%${NC}"
    
    local mem_info=$(free -m | grep ^Mem)
    local mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_total=$(echo "$mem_info" | awk '{print $2}')
    local mem_percent=$((mem_used * 100 / mem_total))
    echo -e "  ${DOT} Memory: ${WHITE}${mem_used}/${mem_total}MB (${mem_percent}%)${NC}"
    
    local load_avg=$(uptime | awk -F'load average:' '{print $2}')
    echo -e "  ${DOT} Load:${WHITE}${load_avg}${NC}"
    
    # Stress processes
    echo -e "\n${WHITE}Processes:${NC}"
    local stress_count=$(pgrep -c stress-ng 2>/dev/null || echo "0")
    echo -e "  ${DOT} Active stress processes: ${WHITE}${stress_count}${NC}"
    
    if [[ $stress_count -gt 0 ]]; then
        ps aux | grep -E "stress-ng" | grep -v grep | head -3 | while read line; do
            echo -e "  ${GRAY}$(echo "$line" | awk '{printf "  PID:%s CPU:%.1f%% MEM:%.1f%%", $2, $3, $4}')${NC}"
        done
    fi
    
    # Recent events
    echo -e "\n${WHITE}Recent Events:${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -3 "$LOG_FILE" | while read line; do
            echo -e "  ${GRAY}$line${NC}"
        done
    fi
    
    echo -e "\n${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read
}

# Advanced settings menu
advanced_settings() {
    while true; do
        echo -e "\n${CYAN}${GEAR} Advanced Settings${NC}\n"
        echo -e "${MAGENTA}════════════════════════════════════════${NC}\n"
        
        echo -e "  ${WHITE}1)${NC} System Health Check"
        echo -e "  ${WHITE}2)${NC} Create/Update Monitoring Service"
        echo -e "  ${WHITE}3)${NC} Backup Configuration"
        echo -e "  ${WHITE}4)${NC} Restore Configuration"
        echo -e "  ${WHITE}5)${NC} Change Log Level (Current: ${WHITE}$LOG_LEVEL${NC})"
        echo -e "  ${WHITE}6)${NC} View Logs"
        echo -e "  ${WHITE}7)${NC} Clear Logs"
        echo -e "  ${WHITE}8)${NC} Reset to Defaults"
        echo -e "  ${WHITE}9)${NC} Uninstall System"
        echo -e "  ${WHITE}0)${NC} Back"
        
        echo -e "\n${MAGENTA}════════════════════════════════════════${NC}"
        echo -e -n "\n${CYAN}${ARROW}${NC} Select: "
        read choice
        
        case $choice in
            1) check_system_health; read -p "Press Enter..." ;;
            2) create_monitoring_service; sleep 2 ;;
            3) backup_configuration; sleep 2 ;;
            4) restore_configuration; sleep 2 ;;
            5)
                echo -e "\n${INFO} Select log level:"
                echo -e "  1) DEBUG"
                echo -e "  2) INFO"
                echo -e "  3) WARN"
                echo -e "  4) ERROR"
                read -p "  > " level
                case $level in
                    1) LOG_LEVEL="DEBUG" ;;
                    2) LOG_LEVEL="INFO" ;;
                    3) LOG_LEVEL="WARN" ;;
                    4) LOG_LEVEL="ERROR" ;;
                esac
                echo -e "${GREEN}${CHECK}${NC} Log level: ${WHITE}$LOG_LEVEL${NC}"
                sleep 1
                ;;
            6)
                echo -e "\n${WHITE}=== Recent Logs ===${NC}"
                tail -20 "$LOG_FILE" 2>/dev/null | less
                ;;
            7)
                echo -e "\n${YELLOW}${WARNING} Clear all logs? (y/n)${NC}"
                read -p "  > " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    > "$LOG_FILE"
                    > "$ERROR_LOG"
                    > "$HEALTH_LOG"
                    find "$LOG_DIR" -name "*.log" -exec truncate -s 0 {} \;
                    echo -e "${GREEN}${CHECK}${NC} Logs cleared"
                fi
                ;;
            8)
                echo -e "\n${YELLOW}${WARNING} Reset to defaults? (y/n)${NC}"
                read -p "  > " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    supervisorctl stop oracle_anti_idle:* 2>/dev/null
                    rm -f "$STATE_FILE" "$SUPERVISOR_CONF"
                    echo -e "${GREEN}${CHECK}${NC} Reset complete"
                    sleep 2
                fi
                ;;
            9)
                echo -e "\n${RED}${WARNING} Type 'UNINSTALL' to confirm:${NC}"
                read -p "  > " confirm
                if [[ "$confirm" == "UNINSTALL" ]]; then
                    supervisorctl stop oracle_anti_idle:* 2>/dev/null
                    systemctl stop oracle-anti-idle-monitor 2>/dev/null
                    systemctl disable oracle-anti-idle-monitor 2>/dev/null
                    rm -f "$SUPERVISOR_CONF" "$SYSTEMD_SERVICE"
                    rm -rf "$STATE_FILE" "$(dirname "$STATE_FILE")"
                    rm -rf "$LOG_DIR"
                    supervisorctl reread && supervisorctl update
                    echo -e "${GREEN}${CHECK}${NC} Uninstalled"
                    exit 0
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}${CROSS}${NC} Invalid option" ;;
        esac
    done
}

# Quick setup wizard
quick_setup() {
    echo -e "\n${CYAN}${ROCKET} Quick Setup Wizard${NC}\n"
    echo -e "${MAGENTA}════════════════════════════════════════${NC}\n"
    
    check_system_health || true
    
    echo -e "\n${CYAN}Select Profile:${NC}\n"
    echo -e "  ${WHITE}1)${NC} ${GREEN}Light${NC} (10% CPU, 10% Memory)"
    echo -e "  ${WHITE}2)${NC} ${YELLOW}Standard${NC} (15% CPU, 15% Memory) ${GREEN}[Recommended]${NC}"
    echo -e "  ${WHITE}3)${NC} ${RED}Heavy${NC} (25% CPU, 25% Memory)"
    echo -e "  ${WHITE}4)${NC} Custom"
    
    read -p "  > " preset
    
    case $preset in
        1) create_supervisor_config 2 10 10 ;;
        2)
            local cpus=$(nproc)
            [[ $cpus -gt 4 ]] && cpus=4
            create_supervisor_config "$cpus" 15 15
            ;;
        3)
            local cpus=$(nproc)
            [[ $cpus -gt 4 ]] && cpus=4
            create_supervisor_config "$cpus" 25 25
            ;;
        4) configure_parameters; return ;;
        *)
            local cpus=$(nproc)
            [[ $cpus -gt 4 ]] && cpus=4
            create_supervisor_config "$cpus" 15 15
            ;;
    esac
    
    echo -e "\n${CYAN}Starting anti-idle system...${NC}"
    supervisorctl start oracle_anti_idle:* 2>&1 | tee -a "$LOG_FILE"
    save_state "true"
    
    create_monitoring_service
    
    echo -e "\n${GREEN}${STAR} Setup Complete!${NC}"
    echo -e "\n${INFO} The system will:"
    echo -e "  ${CHECK} Keep your instance active 24/7"
    echo -e "  ${CHECK} Auto-restart if stopped"
    echo -e "  ${CHECK} Resume after reboot"
    echo -e "  ${CHECK} Monitor and recover from failures"
    
    echo -e "\n${CYAN}Press Enter...${NC}"
    read
}

# Main menu
main_menu() {
    while true; do
        show_banner
        
        local status_display=$(get_status_display)
        echo -e "${WHITE}Status:${NC} $status_display"
        
        if [[ -f "$STATE_FILE" ]]; then
            source "$STATE_FILE" 2>/dev/null
            echo -e "${WHITE}Config:${NC} CPU: ${CPU_COUNT:-N/A}@${CPU_LOAD:-N/A}% | Mem: ${MEMORY_PERCENT:-N/A}%"
        fi
        
        echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}         ${WHITE}MAIN MENU${NC}                     ${CYAN}║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}1)${NC} ${GREEN}▶${NC} Toggle Anti-Idle              ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}2)${NC} ${GEAR} Configure Parameters         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}3)${NC} ${INFO} Show Status                 ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}4)${NC} ${ROCKET} Quick Setup                 ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}5)${NC} ${SHIELD} Advanced Settings           ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}6)${NC} ${HEART} Health Check                ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}7)${NC} ❓ Help                         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${WHITE}0)${NC} ${RED}✗${NC} Exit                         ${CYAN}║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
        
        echo -e -n "\n${CYAN}${ARROW}${NC} Select: "
        read choice
        
        case $choice in
            1) toggle_anti_idle ;;
            2) configure_parameters ;;
            3) show_detailed_status ;;
            4) quick_setup ;;
            5) advanced_settings ;;
            6) check_system_health; read -p "Press Enter..." ;;
            7)
                echo -e "\n${WHITE}Oracle Anti-Idle Enhanced v${SCRIPT_VERSION}${NC}"
                echo -e "\nPrevents Oracle Cloud instance termination"
                echo -e "Features: Auto-recovery, health monitoring,"
                echo -e "backup/restore, systemd integration\n"
                read -p "Press Enter..."
                ;;
            0|q|Q)
                echo -e "\n${GREEN}${CHECK}${NC} Goodbye!"
                log "INFO" "User exited"
                release_lock
                exit 0
                ;;
            *) echo -e "${RED}${CROSS}${NC} Invalid option"; sleep 1 ;;
        esac
    done
}

# Main execution
main() {
    # Initialize
    init_logging
    log "INFO" "Oracle Anti-Idle Enhanced v${SCRIPT_VERSION} started"
    
    # Acquire lock
    acquire_lock
    
    # Check privileges
    check_root
    
    # Check platform
    echo -e "\n${CYAN}${INFO} Initializing...${NC}\n"
    check_platform
    
    # Auto-install dependencies
    auto_install_dependencies
    
    show_loading "Starting" 1
    
    # Start menu
    main_menu
}

# Run
main "$@"