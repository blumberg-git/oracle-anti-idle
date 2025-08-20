#!/bin/bash

# Oracle Anti-Idle System - Ultra-Reliable Edition
# Author: Matt Blumberg
# Version: 6.0.0
# Description: Extremely reliable Oracle Cloud anti-idle system with automatic recovery

set -euo pipefail

# Configuration
SCRIPT_VERSION="6.0.0"
BUILD_TIME="2025-08-20 07:00:00"
LOG_DIR="/var/log/oracle-anti-idle"
LOG_FILE="$LOG_DIR/oracle-anti-idle.log"
SUPERVISOR_CONF="/etc/supervisor/conf.d/oracle-anti-idle.conf"
STATE_FILE="/var/lib/oracle-anti-idle/state"
LOCK_FILE="/var/run/oracle-anti-idle.lock"

# Default settings (15% as requested)
DEFAULT_CPU_PERCENT=15
DEFAULT_MEMORY_PERCENT=15

# Auto-detect CPU count (max 4 for Oracle free tier)
CPU_COUNT=$(nproc)
[[ $CPU_COUNT -gt 4 ]] && CPU_COUNT=4

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Logging with automatic directory creation
log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null || true
}

# Error handler
handle_error() {
    local line_number=$1
    log "ERROR at line $line_number"
    echo -e "${RED}An error occurred. Check $LOG_FILE for details.${NC}"
}

trap 'handle_error $LINENO' ERR

# Display banner
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
   ____                 _        _          _   _     ___    _ _      
  / __ \               | |      | |   /\   | | (_)   |_ _|  | | |     
 | |  | |_ __ __ _  ___| | ___  | |  /  \  | |_ _     | |  __| | | ___ 
 | |  | | '__/ _` |/ __| |/ _ \ | | / /\ \ | __| |    | | / _` | |/ _ \
 | |__| | | | (_| | (__| |  __/ | |/ ____ \| |_| |   _| || (_| | |  __/
  \____/|_|  \__,_|\___|_|\___| |_/_/    \_\\__|_|  |_____\__,_|_|\___|
EOF
    echo -e "${NC}"
    echo -e "${WHITE}Never Let Your Oracle Cloud Instance Go Idle!${NC}"
    echo -e "${CYAN}Ultra-Reliable v${SCRIPT_VERSION} | Build: ${BUILD_TIME}${NC}\n"
    echo -e "════════════════════════════════════════════════════════════\n"
}

# Check root with automatic elevation attempt
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}This script requires root privileges.${NC}"
        echo -e "${CYAN}Attempting to restart with sudo...${NC}\n"
        exec sudo "$0" "$@"
        exit 1
    fi
}

# Comprehensive system check
check_system() {
    echo -e "Checking system compatibility...\n"
    
    # Check if Ubuntu/Debian
    if [[ ! -f /etc/debian_version ]]; then
        echo -e "${RED}Error: This script is designed for Ubuntu/Debian systems${NC}"
        echo -e "${YELLOW}Detected: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)${NC}"
        exit 1
    fi
    
    # Check system resources
    local mem_total=$(free -m | grep ^Mem | awk '{print $2}')
    local disk_free=$(df / | tail -1 | awk '{print $4}')
    
    echo -e "${GREEN}✓${NC} Ubuntu/Debian system detected"
    echo -e "${GREEN}✓${NC} CPUs: $(nproc) cores"
    echo -e "${GREEN}✓${NC} Memory: ${mem_total}MB total"
    echo -e "${GREEN}✓${NC} Disk: ${disk_free}KB free"
    
    # Warn if low resources
    if [[ $mem_total -lt 500 ]]; then
        echo -e "${YELLOW}⚠ Warning: Low memory detected. Recommend using lower CPU/memory percentages.${NC}"
    fi
    
    log "System check passed: Ubuntu/Debian, ${CPU_COUNT} CPUs, ${mem_total}MB RAM"
}

# Comprehensive dependency installation with retry
install_dependencies() {
    echo -e "\nChecking and installing dependencies...\n"
    
    local packages_to_install=()
    local all_installed=true
    
    # Check each required package
    for pkg in stress-ng supervisor bc curl net-tools; do
        if ! dpkg -l | grep -q "^ii.*$pkg"; then
            echo -e "  ${YELLOW}◦${NC} $pkg - needs installation"
            packages_to_install+=("$pkg")
            all_installed=false
        else
            echo -e "  ${GREEN}✓${NC} $pkg - installed"
        fi
    done
    
    if [[ "$all_installed" == "true" ]]; then
        echo -e "\n${GREEN}✓${NC} All dependencies are already installed"
    else
        echo -e "\n${CYAN}Installing missing packages...${NC}"
        
        # Update package lists with retry
        local retry_count=0
        local max_retries=3
        
        while [[ $retry_count -lt $max_retries ]]; do
            if apt-get update 2>&1 | grep -E "^(Get:|Hit:|Ign:)" > /dev/null; then
                echo -e "${GREEN}✓${NC} Package lists updated"
                break
            else
                retry_count=$((retry_count + 1))
                if [[ $retry_count -lt $max_retries ]]; then
                    echo -e "${YELLOW}Retrying package update... (attempt $retry_count/$max_retries)${NC}"
                    sleep 2
                else
                    echo -e "${RED}Failed to update package lists after $max_retries attempts${NC}"
                    echo -e "${YELLOW}Continuing anyway...${NC}"
                fi
            fi
        done
        
        # Install packages
        for pkg in "${packages_to_install[@]}"; do
            echo -e "Installing $pkg..."
            retry_count=0
            
            while [[ $retry_count -lt $max_retries ]]; do
                if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" > /dev/null 2>&1; then
                    echo -e "  ${GREEN}✓${NC} $pkg installed successfully"
                    break
                else
                    retry_count=$((retry_count + 1))
                    if [[ $retry_count -lt $max_retries ]]; then
                        echo -e "  ${YELLOW}Retry $retry_count/$max_retries for $pkg...${NC}"
                        sleep 2
                    else
                        echo -e "  ${RED}✗${NC} Failed to install $pkg"
                        if [[ "$pkg" == "stress-ng" ]] || [[ "$pkg" == "supervisor" ]]; then
                            echo -e "${RED}Critical package $pkg failed to install. Exiting.${NC}"
                            exit 1
                        fi
                    fi
                fi
            done
        done
    fi
    
    # Ensure supervisor is running and enabled
    echo -e "\n${CYAN}Configuring supervisor service...${NC}"
    
    # Enable supervisor to start on boot
    if systemctl enable supervisor > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Supervisor enabled for auto-start"
    fi
    
    # Start supervisor if not running
    if ! pgrep -x "supervisord" > /dev/null; then
        if systemctl start supervisor > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Supervisor service started"
        else
            # Fallback: try to start supervisord directly
            supervisord -c /etc/supervisor/supervisord.conf > /dev/null 2>&1 || true
            echo -e "  ${YELLOW}⚠${NC} Started supervisord directly"
        fi
    else
        echo -e "  ${GREEN}✓${NC} Supervisor already running"
    fi
    
    # Verify supervisor is responding
    if supervisorctl version > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Supervisor is responding"
    else
        echo -e "  ${RED}✗${NC} Supervisor not responding properly"
        echo -e "  ${YELLOW}Attempting to restart...${NC}"
        systemctl restart supervisor > /dev/null 2>&1 || true
        sleep 2
    fi
    
    log "Dependencies check/install completed"
}

# Save state with validation
save_state() {
    local enabled="$1"
    local cpu_percent="${2:-$DEFAULT_CPU_PERCENT}"
    local mem_percent="${3:-$DEFAULT_MEMORY_PERCENT}"
    
    # Validate inputs
    [[ ! "$cpu_percent" =~ ^[0-9]+$ ]] && cpu_percent=$DEFAULT_CPU_PERCENT
    [[ ! "$mem_percent" =~ ^[0-9]+$ ]] && mem_percent=$DEFAULT_MEMORY_PERCENT
    [[ $cpu_percent -lt 1 || $cpu_percent -gt 100 ]] && cpu_percent=$DEFAULT_CPU_PERCENT
    [[ $mem_percent -lt 1 || $mem_percent -gt 100 ]] && mem_percent=$DEFAULT_MEMORY_PERCENT
    
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    cat > "$STATE_FILE" << EOF
ENABLED="$enabled"
CPU_PERCENT="$cpu_percent"
MEMORY_PERCENT="$mem_percent"
LAST_UPDATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    log "State saved: enabled=$enabled, cpu=$cpu_percent%, mem=$mem_percent%"
}

# Load state safely
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null || {
            echo "false"
            return
        }
        echo "${ENABLED:-false}"
    else
        echo "false"
    fi
}

# Get current config
get_config() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null || {
            echo "CPU: ${DEFAULT_CPU_PERCENT}% | Memory: ${DEFAULT_MEMORY_PERCENT}% (defaults)"
            return
        }
        echo "CPU: ${CPU_PERCENT:-$DEFAULT_CPU_PERCENT}% | Memory: ${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}%"
    else
        echo "CPU: ${DEFAULT_CPU_PERCENT}% | Memory: ${DEFAULT_MEMORY_PERCENT}% (defaults)"
    fi
}

# Create supervisor config with enhanced reliability
create_config() {
    local cpu_percent="${1:-$DEFAULT_CPU_PERCENT}"
    local mem_percent="${2:-$DEFAULT_MEMORY_PERCENT}"
    
    echo -e "\nCreating configuration..."
    
    # Backup existing config if present
    if [[ -f "$SUPERVISOR_CONF" ]]; then
        cp "$SUPERVISOR_CONF" "${SUPERVISOR_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        log "Backed up existing configuration"
    fi
    
    mkdir -p "$(dirname "$SUPERVISOR_CONF")"
    mkdir -p "$LOG_DIR"
    
    # Create robust supervisor configuration
    cat > "$SUPERVISOR_CONF" << EOF
; Oracle Anti-Idle Configuration
; Version: ${SCRIPT_VERSION}
; CPU: ${cpu_percent}% | Memory: ${mem_percent}%

[program:oracle_anti_idle_cpu]
command=/usr/bin/stress-ng --cpu ${CPU_COUNT} --cpu-load ${cpu_percent} --timeout 0
autostart=true
autorestart=true
startretries=999999
exitcodes=0
stopsignal=TERM
stopwaitsecs=10
stderr_logfile=${LOG_DIR}/cpu_error.log
stdout_logfile=${LOG_DIR}/cpu.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
user=root
priority=100

[program:oracle_anti_idle_memory]
command=/usr/bin/stress-ng --vm 1 --vm-bytes ${mem_percent}%% --vm-hang 0 --timeout 0
autostart=true
autorestart=true
startretries=999999
exitcodes=0
stopsignal=TERM
stopwaitsecs=10
stderr_logfile=${LOG_DIR}/memory_error.log
stdout_logfile=${LOG_DIR}/memory.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
user=root
priority=100

[program:oracle_anti_idle_monitor]
command=/bin/bash -c 'while true; do date >> ${LOG_DIR}/monitor.log; if ! pgrep -f "stress-ng.*cpu" > /dev/null; then echo "CPU stress not running" >> ${LOG_DIR}/monitor.log; fi; if ! pgrep -f "stress-ng.*vm" > /dev/null; then echo "Memory stress not running" >> ${LOG_DIR}/monitor.log; fi; sleep 60; done'
autostart=true
autorestart=true
stderr_logfile=${LOG_DIR}/monitor_error.log
stdout_logfile=${LOG_DIR}/monitor.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=1
user=root
priority=90

[group:oracle_anti_idle]
programs=oracle_anti_idle_cpu,oracle_anti_idle_memory,oracle_anti_idle_monitor
EOF
    
    # Reload supervisor configuration
    echo -e "Applying configuration..."
    
    if supervisorctl reread 2>&1 | grep -v "ERROR"; then
        echo -e "  ${GREEN}✓${NC} Configuration loaded"
    else
        echo -e "  ${YELLOW}⚠${NC} Configuration reload had issues"
    fi
    
    if supervisorctl update 2>&1 | grep -v "ERROR"; then
        echo -e "  ${GREEN}✓${NC} Configuration applied"
    else
        echo -e "  ${YELLOW}⚠${NC} Configuration update had issues"
    fi
    
    save_state "false" "$cpu_percent" "$mem_percent"
    
    echo -e "${GREEN}✓${NC} Configuration created successfully"
    log "Config created: CPU=$cpu_percent%, Memory=$mem_percent%"
}

# Enable anti-idle with verification
enable_antidle() {
    echo -e "\n${CYAN}Enabling anti-idle system...${NC}"
    
    # Create config if doesn't exist
    if [[ ! -f "$SUPERVISOR_CONF" ]]; then
        create_config
    fi
    
    # Start services
    echo -e "Starting services..."
    if supervisorctl start oracle_anti_idle:* 2>&1 | grep -E "started|RUNNING"; then
        echo -e "  ${GREEN}✓${NC} Services started"
    else
        echo -e "  ${YELLOW}⚠${NC} Some services may not have started properly"
    fi
    
    # Verify services are actually running
    sleep 2
    local cpu_running=$(pgrep -f "stress-ng.*cpu" > /dev/null && echo "yes" || echo "no")
    local mem_running=$(pgrep -f "stress-ng.*vm" > /dev/null && echo "yes" || echo "no")
    
    if [[ "$cpu_running" == "yes" ]] && [[ "$mem_running" == "yes" ]]; then
        echo -e "  ${GREEN}✓${NC} Verified: stress processes are running"
    else
        echo -e "  ${YELLOW}⚠${NC} Warning: Some stress processes may not be running"
        echo -e "  ${CYAN}Attempting restart...${NC}"
        supervisorctl restart oracle_anti_idle:* > /dev/null 2>&1
    fi
    
    # Update state
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null || true
        save_state "true" "${CPU_PERCENT:-$DEFAULT_CPU_PERCENT}" "${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}"
    else
        save_state "true"
    fi
    
    echo -e "\n${GREEN}✓ Anti-idle system ENABLED${NC}"
    echo -e "${CYAN}Your Oracle instance is now protected from idle termination!${NC}"
    log "Anti-idle enabled and verified"
}

# Disable anti-idle
disable_antidle() {
    echo -e "\n${CYAN}Disabling anti-idle system...${NC}"
    
    # Stop services
    echo -e "Stopping services..."
    supervisorctl stop oracle_anti_idle:* > /dev/null 2>&1
    
    # Kill any remaining stress processes
    pkill -f "stress-ng" 2>/dev/null || true
    
    # Verify stopped
    sleep 1
    if pgrep -f "stress-ng" > /dev/null; then
        echo -e "  ${YELLOW}⚠${NC} Some processes still running, force killing..."
        pkill -9 -f "stress-ng" 2>/dev/null || true
    fi
    
    # Update state
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null || true
        save_state "false" "${CPU_PERCENT:-$DEFAULT_CPU_PERCENT}" "${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}"
    else
        save_state "false"
    fi
    
    echo -e "${RED}✗ Anti-idle system DISABLED${NC}"
    log "Anti-idle disabled"
}

# Toggle anti-idle
toggle_antidle() {
    local current=$(load_state)
    
    if [[ "$current" == "true" ]]; then
        disable_antidle
    else
        enable_antidle
    fi
}

# Show detailed status
show_status() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${WHITE}         SYSTEM STATUS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}\n"
    
    local state=$(load_state)
    if [[ "$state" == "true" ]]; then
        echo -e "Anti-Idle Status: ${GREEN}● ENABLED${NC}"
    else
        echo -e "Anti-Idle Status: ${RED}● DISABLED${NC}"
    fi
    
    echo -e "Configuration: $(get_config)"
    
    # Check supervisor status
    echo -e "\n${WHITE}Supervisor Service:${NC}"
    if pgrep -x "supervisord" > /dev/null; then
        echo -e "  ${GREEN}✓${NC} Supervisor is running"
    else
        echo -e "  ${RED}✗${NC} Supervisor is not running"
    fi
    
    # Check individual processes
    echo -e "\n${WHITE}Stress Processes:${NC}"
    
    local cpu_count=$(pgrep -fc "stress-ng.*cpu" 2>/dev/null || echo "0")
    local mem_count=$(pgrep -fc "stress-ng.*vm" 2>/dev/null || echo "0")
    
    if [[ $cpu_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} CPU stress: $cpu_count processes running"
    else
        echo -e "  ${RED}✗${NC} CPU stress: not running"
    fi
    
    if [[ $mem_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Memory stress: $mem_count processes running"
    else
        echo -e "  ${RED}✗${NC} Memory stress: not running"
    fi
    
    # System resources
    echo -e "\n${WHITE}System Resources:${NC}"
    echo -e "  CPUs: $(nproc) cores"
    echo -e "  Memory: $(free -h | grep ^Mem | awk '{print "Total: " $2 ", Used: " $3 ", Free: " $4}')"
    echo -e "  Load Average:$(uptime | awk -F'load average:' '{print $2}')"
    
    # Recent logs
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "\n${WHITE}Recent Activity:${NC}"
        tail -3 "$LOG_FILE" 2>/dev/null | while read line; do
            echo -e "  ${line}"
        done
    fi
    
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
}

# Customize settings
customize() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${WHITE}       CUSTOMIZE SETTINGS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}\n"
    
    # Load current values
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE" 2>/dev/null || true
    fi
    
    local current_cpu="${CPU_PERCENT:-$DEFAULT_CPU_PERCENT}"
    local current_mem="${MEMORY_PERCENT:-$DEFAULT_MEMORY_PERCENT}"
    
    echo -e "Current Settings:"
    echo -e "  CPU Load: ${WHITE}${current_cpu}%${NC}"
    echo -e "  Memory Usage: ${WHITE}${current_mem}%${NC}"
    echo -e "\nRecommended: 10-25% for both CPU and Memory"
    echo -e "Default: 15% for both (optimal for most cases)\n"
    
    read -p "CPU Load % (1-100) [${current_cpu}]: " new_cpu
    new_cpu=${new_cpu:-$current_cpu}
    
    # Validate CPU
    if ! [[ "$new_cpu" =~ ^[0-9]+$ ]] || [[ $new_cpu -lt 1 ]] || [[ $new_cpu -gt 100 ]]; then
        echo -e "${RED}Invalid CPU value. Using ${current_cpu}%${NC}"
        new_cpu=$current_cpu
    fi
    
    read -p "Memory % (1-100) [${current_mem}]: " new_mem
    new_mem=${new_mem:-$current_mem}
    
    # Validate Memory
    if ! [[ "$new_mem" =~ ^[0-9]+$ ]] || [[ $new_mem -lt 1 ]] || [[ $new_mem -gt 100 ]]; then
        echo -e "${RED}Invalid memory value. Using ${current_mem}%${NC}"
        new_mem=$current_mem
    fi
    
    echo -e "\n${WHITE}New Settings:${NC}"
    echo -e "  CPU: ${new_cpu}%"
    echo -e "  Memory: ${new_mem}%"
    
    read -p "\nApply these settings? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        create_config "$new_cpu" "$new_mem"
        
        # Restart if running
        local state=$(load_state)
        if [[ "$state" == "true" ]]; then
            echo -e "\n${CYAN}Restarting with new settings...${NC}"
            supervisorctl restart oracle_anti_idle:* > /dev/null 2>&1
            save_state "true" "$new_cpu" "$new_mem"
        fi
        
        echo -e "${GREEN}✓ Settings updated successfully${NC}"
    else
        echo -e "${YELLOW}Settings unchanged${NC}"
    fi
}

# Quick setup (one-click with defaults)
quick_setup() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${WHITE}         QUICK SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}\n"
    
    echo -e "This will configure anti-idle with optimal defaults:"
    echo -e "  • CPU: ${DEFAULT_CPU_PERCENT}% load on ${CPU_COUNT} cores"
    echo -e "  • Memory: ${DEFAULT_MEMORY_PERCENT}% usage"
    echo -e "  • Auto-restart on failure"
    echo -e "  • Auto-start on boot"
    
    read -p "\nProceed with setup? (y/n): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}Setting up anti-idle protection...${NC}\n"
        
        # Create config
        create_config
        
        # Enable
        enable_antidle
        
        echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
        echo -e "${GREEN}    ✓ SETUP COMPLETE!${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════${NC}"
        echo -e "\n${WHITE}Your Oracle Cloud instance is now protected!${NC}"
        echo -e "The anti-idle system will:"
        echo -e "  • Keep your instance active 24/7"
        echo -e "  • Automatically restart if stopped"
        echo -e "  • Resume after system reboots"
        
        log "Quick setup completed successfully"
    else
        echo -e "${YELLOW}Setup cancelled${NC}"
    fi
}

# Health check
health_check() {
    echo -e "\n${CYAN}Running health check...${NC}\n"
    
    local issues=0
    
    # Check supervisor
    if ! pgrep -x "supervisord" > /dev/null; then
        echo -e "${RED}✗${NC} Supervisor not running"
        echo -e "  ${YELLOW}→ Attempting to start...${NC}"
        systemctl start supervisor > /dev/null 2>&1 || true
        ((issues++))
    else
        echo -e "${GREEN}✓${NC} Supervisor running"
    fi
    
    # Check config exists
    if [[ ! -f "$SUPERVISOR_CONF" ]]; then
        echo -e "${RED}✗${NC} Configuration missing"
        echo -e "  ${YELLOW}→ Run 'Quick Setup' to create${NC}"
        ((issues++))
    else
        echo -e "${GREEN}✓${NC} Configuration exists"
    fi
    
    # Check if enabled
    local state=$(load_state)
    if [[ "$state" == "true" ]]; then
        # Check if processes are actually running
        if ! pgrep -f "stress-ng" > /dev/null; then
            echo -e "${YELLOW}⚠${NC} Anti-idle enabled but processes not running"
            echo -e "  ${YELLOW}→ Try toggling the system off and on${NC}"
            ((issues++))
        else
            echo -e "${GREEN}✓${NC} Stress processes running"
        fi
    else
        echo -e "${YELLOW}ℹ${NC} Anti-idle currently disabled"
    fi
    
    # Check logs directory
    if [[ ! -d "$LOG_DIR" ]]; then
        echo -e "${YELLOW}⚠${NC} Log directory missing"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        ((issues++))
    else
        echo -e "${GREEN}✓${NC} Log directory exists"
    fi
    
    if [[ $issues -eq 0 ]]; then
        echo -e "\n${GREEN}✓ System health: EXCELLENT${NC}"
    elif [[ $issues -le 2 ]]; then
        echo -e "\n${YELLOW}⚠ System health: GOOD (minor issues detected)${NC}"
    else
        echo -e "\n${RED}✗ System health: NEEDS ATTENTION${NC}"
    fi
    
    log "Health check completed: $issues issues found"
}

# Main menu
main_menu() {
    while true; do
        show_banner
        
        # Show current status inline
        local state=$(load_state)
        if [[ "$state" == "true" ]]; then
            echo -e "Status: ${GREEN}● ACTIVE${NC}  |  $(get_config)\n"
        else
            echo -e "Status: ${RED}● INACTIVE${NC}  |  $(get_config)\n"
        fi
        
        echo -e "${CYAN}══════════════ MAIN MENU ═════════════════${NC}\n"
        echo -e "  ${WHITE}1)${NC} Enable/Disable Anti-Idle"
        echo -e "  ${WHITE}2)${NC} Show Detailed Status"
        echo -e "  ${WHITE}3)${NC} Customize Settings"
        echo -e "  ${WHITE}4)${NC} Quick Setup (Recommended)"
        echo -e "  ${WHITE}5)${NC} Health Check"
        echo -e "  ${WHITE}0)${NC} Exit\n"
        
        read -p "Select option [0-5]: " choice
        
        case $choice in
            1) toggle_antidle; sleep 2 ;;
            2) show_status; read -p "Press Enter to continue..." ;;
            3) customize ;;
            4) quick_setup ;;
            5) health_check; read -p "Press Enter to continue..." ;;
            0) 
                echo -e "\n${GREEN}Thank you for using Oracle Anti-Idle!${NC}"
                echo -e "${CYAN}Your protection remains active even after exiting.${NC}\n"
                exit 0 
                ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# Main execution
main() {
    # Check for help flag
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        echo "Oracle Anti-Idle System v${SCRIPT_VERSION}"
        echo "Usage: sudo $0"
        echo "This script must be run interactively as root."
        exit 0
    fi
    
    show_banner
    check_root "$@"
    check_system
    install_dependencies
    
    log "Script started v${SCRIPT_VERSION}"
    
    # Run a quick health check
    echo -e "${CYAN}Performing system health check...${NC}"
    health_check > /dev/null 2>&1
    
    main_menu
}

# Run
main "$@"