#!/bin/bash

#==============================================================================
# Unified ntfy Monitoring Script for Proxmox/Linux Infrastructure
# Monitors: PVE, SMART, Backups, System Errors, VM Network
#==============================================================================

# Configuration
STATE_DIR="/var/lib/ntfy-monitor"
CONFIG_FILE="/etc/ntfy-monitor.conf"
ERROR_LOG_FILE="/var/log/ntfy-monitor_errors.log"

# Create state directory
mkdir -p "$STATE_DIR"

# Default configuration (can be overridden in config file) in /etc/ntfy-monitor.conf
CPU_TEMP_THRESHOLD=80
MEM_USAGE_THRESHOLD=90
LOAD_THRESHOLD_MULTIPLIER=1.5
SMART_TEMP_THRESHOLD=50
GUEST_PING_TIMEOUT=5
GUEST_PING_RETRY_COUNT=2

NTFY_SERVER=""
NTFY_BASE_TOPIC=""
NTFY_USER=""
NTFY_PASS=""

BACKUP_LOG_PATHS="/var/log/backup*.log"
CHECK_INTERVAL_HOURS=1

ENABLE_BACKUP_MONITORING=true
ENABLE_SYSTEM_MONITORING=true
ENABLE_GUEST_NETWORK_MONITORING=true
ENABLE_HOST_LOGS_MONITORING=true
ENABLE_GUEST_LOGS_MONITORING=true
ENABLE_DISK_HEALTH_MONITORING=true

DEBUG=false

# Load configuration if it exists
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

#==============================================================================
# Utility Functions
#==============================================================================

check_guest_logs() {
    local vmid="$1"
    local last_check="$2"
    local guest_type="$3"  # "ct" or "qemu"
    local name=""
    
    # Get guest name
    if [ "$guest_type" = "ct" ]; then
        name=$(pct list | awk -v id="$vmid" '$1==id {print $3}')
    elif [ "$guest_type" = "qemu" ]; then
        name=$(qm list | awk -v id="$vmid" '$1==id {print $3}')
    else
        echo "Unknown guest type: $guest_type"
        return 1
    fi

    local errors=""
    if [ "$guest_type" = "ct" ]; then
        if pct_command_exists "$vmid" journalctl; then
            errors=$(pct_safe_exec "$vmid" "journalctl --since '$last_check' --priority=err --no-pager -q | head -20")
        else
            for logfile in /var/log/syslog /var/log/messages; do
                if pct_safe_exec "$vmid" "[ -f $logfile ]"; then
                    errors=$(pct_safe_exec "$vmid" "awk -v d='$last_check' '\$0 >= d' $logfile | grep -i 'error\|fail\|abort' | tail -20")
                    [ ! -z "$errors" ] && break
                fi
            done
        fi
    else
        if qm_command_exists "$vmid" journalctl; then
            errors=$(qm_safe_exec "$vmid" "journalctl --since '$last_check' --priority=err --no-pager -q | head -20")
        else
            for logfile in /var/log/syslog /var/log/messages; do
                if qm_safe_exec "$vmid" "[ -f $logfile ]"; then
                    errors=$(qm_safe_exec "$vmid" "awk -v d='$last_check' '\$0 >= d' $logfile | grep -i 'error\|fail\|abort' | tail -20")
                    [ ! -z "$errors" ] && break
                fi
            done
        fi
    fi

    [ ! -z "$errors" ] && send_notification "high" "Guest Log Errors ($name)" "$errors" "guest_logs" "logs,error"
}

check_guest_network() {
    local vmid="$1"
    local guest_type="$2"  # "ct" or "qemu"
    local name=""
    local targets=(1.1.1.1 8.8.8.8)
    local dns_domain="www.google.com"

    # Get guest name
    if [ "$guest_type" = "ct" ]; then
        name=$(pct list | awk -v id="$vmid" '$1==id {print $3}')
    elif [ "$guest_type" = "qemu" ]; then
        name=$(qm list | awk -v id="$vmid" '$1==id {print $3}')
    else
        echo "Unknown guest type: $guest_type"
        return 1
    fi

    # Ping targets
    for target in "${targets[@]}"; do
        if [ "$guest_type" = "ct" ]; then
            pct_safe_exec "$vmid" "ping -c $GUEST_PING_RETRY_COUNT -W $GUEST_PING_TIMEOUT $target" >/dev/null 2>&1 \
                || send_notification "high" "VM Network Unreachable ($name)" "Failed to ping $target" "guest_network" "network,$name"
        else
            qm_safe_exec "$vmid" "ping -c $GUEST_PING_RETRY_COUNT -W $GUEST_PING_TIMEOUT $target" >/dev/null 2>&1 \
                || send_notification "high" "VM Network Unreachable ($name)" "Failed to ping $target" "guest_network" "network,$name"
        fi
    done

    # DNS check
    if [ "$guest_type" = "ct" ]; then
        pct_safe_exec "$vmid" "nslookup $dns_domain" >/dev/null 2>&1 \
                || send_notification "high" "VM DNS Failure ($name)" "DNS lookup failed" "guest_network" "dns,$name"
    else
        qm_safe_exec "$vmid" "nslookup $dns_domain" >/dev/null 2>&1 \
            || send_notification "high" "VM DNS Failure ($name)" "DNS lookup failed" "guest_network" "dns,$name"

    fi
}

error_log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$ERROR_LOG_FILE"
}

debug_log() {
    [ "$DEBUG" = "true" ] && echo "DEBUG: $1"
}

validate_config() {
    if [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_BASE_TOPIC" ]; then
        error_log_message "Missing required configuration: NTFY_SERVER or NTFY_BASE_TOPIC"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "smartctl" "journalctl" "pvesh" "pct" "qm" "zpool" "awk" "grep" "bc" "date" "sensors" "free" "lsblk")
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || {
            error_log_message "Required dependency $dep not found"
            exit 1
        }
    done
}

send_notification() {
    local priority="$1"
    local title="$2"
    local message="$3"
    local topic="$4"
    local tags="${5:-$(hostname)}"
    local click_url="$6"
    
    local full_topic="${NTFY_BASE_TOPIC}-${topic}"
    local headers="Title: $title"
    headers="$headers\nPriority: $priority"
    headers="$headers\nTags: $tags"
    
    [ ! -z "$click_url" ] && headers="$headers\nClick: $click_url"
    
    debug_log "Sending notification: $title"

    if [ ! -z "$NTFY_USER" ] && [ ! -z "$NTFY_PASS" ]; then
        if curl -s -u "$NTFY_USER:$NTFY_PASS" -H "$headers" -d "$message" "http://$NTFY_SERVER/$full_topic" >/dev/null; then
            debug_log "Notification sent: $title"
        else
            error_log_message "Failed to send notification: $title"
        fi
    else 
        if curl -s -H "$headers" -d "$message" "http://$NTFY_SERVER/$full_topic" >/dev/null; then
            debug_log "Notification sent: $title"
        else
            error_log_message "Failed to send notification: $title"
        fi
}

get_timestamp() {
    date --iso-8601=seconds
}

get_last_check() {
    local check_type="$1"
    local state_file="$STATE_DIR/${check_type}.state"
    
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        date --iso-8601=seconds --date="$CHECK_INTERVAL_HOURS hours ago"
    fi
}

update_last_check() {
    local check_type="$1"
    local state_file="$STATE_DIR/${check_type}.state"
    get_timestamp > "$state_file"
}

pct_command_exists() {
    local vmid="$1"
    local cmd="$2"
    pct exec "$vmid" -- sh -c "command -v $cmd >/dev/null 2>&1"
}

qm_command_exists() {
    local vmid="$1"
    local cmd="$2"
    qm guest exec "$vmid" -- sh -c "command -v $cmd >/dev/null 2>&1"
}

pct_safe_exec() {
    local vmid="$1"
    shift
    local cmd="$*"
    pct_command_exists "$vmid" "$(echo $cmd | awk '{print $1}')" && pct exec "$vmid" -- sh -c "$cmd"
}

qm_safe_exec() {
    local vmid="$1"
    shift
    local cmd="$*"
    qm_command_exists "$vmid" "$(echo $cmd | awk '{print $1}')" && qm guest exec "$vmid" -- sh -c "$cmd"
}

#==============================================================================
# Monitoring Functions
#==============================================================================

monitor_host_logs() {
    [ "$ENABLE_HOST_LOGS_MONITORING" != "true" ] && return
    debug_log "Starting host logs monitoring"

    local last_check=$(get_last_check "host_logs")
    local errors=$(journalctl --since "$last_check" --priority=err --no-pager -q | head -20)
    [ ! -z "$errors" ] && send_notification "high" "Host System Errors" "$errors" "system" "logs,error"

    debug_log "Host logs monitoring completed"
    update_last_check "host_logs"
}


monitor_guest_logs() {
    [ "$ENABLE_GUEST_LOGS_MONITORING" != "true" ] && return
    debug_log "Starting guest logs monitoring"

    last_check=$(get_last_check "guest_logs")

    # LXC containers in parallel
    for vmid in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
        check_guest_logs "$vmid" "$last_check" "ct" &
    done

    # QEMU guests in parallel
    for vmid in $(qm list | awk 'NR>1 && $2=="running" {print $1}'); do
        check_guest_logs "$vmid" "$last_check" "qemu" &
    done

    wait

    update_last_check "guest_logs"
    debug_log "Guest logs monitoring completed"
}


monitor_system() {
    [ "$ENABLE_SYSTEM_MONITORING" != "true" ] && return
    
    debug_log "Starting system monitoring"
    local last_check=$(get_last_check "system")
    
    # Load average
    local load_avg=$(awk '{print $1}' /proc/loadavg)
    local cpu_cores=$(nproc)
    local load_threshold=$(echo "$cpu_cores * $LOAD_THRESHOLD_MULTIPLIER" | bc)
    
    if (( $(echo "$load_avg > $load_threshold" | bc -l) )); then
        send_notification "high" "High System Load" "Load average: $load_avg (cores: $cpu_cores)" "system" "performance,load"
    fi
    
    # CPU Temperature
    if command -v sensors >/dev/null 2>&1; then
        cpu_temp=$(sensors | awk '
            /^Core [0-9]+:/ || /^Package id [0-9]+:/ {
                gsub(/\+|°C/, "", $3); if ($3 > max) max=$3
            } END {print max}
        ')
        if [ ! -z "$cpu_temp" ] && [ "$cpu_temp" -gt "$CPU_TEMP_THRESHOLD" ]; then
            send_notification "high" "High CPU Temperature" "CPU temperature: ${cpu_temp}°C" "system" "temperature,cpu"
        fi
    fi
    
    # Memory usage
    local mem_usage=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')
    if [ "$mem_usage" -gt "$MEM_USAGE_THRESHOLD" ]; then
        send_notification "default" "High Memory Usage" "Memory usage: ${mem_usage}%" "system" "memory,performance"
    fi
    
    # Disk temperature (all SMART disks)
    for drive in $(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        local device="/dev/$drive"

        # Get temperature from multiple possible fields
        temp=$(smartctl -A "$device" 2>/dev/null | awk '
            /Temperature_Celsius/ || /Airflow_Temperature_Cel/ || /Temperature_Internal/ {print $10}
        ' | head -1)

        if [ ! -z "$temp" ] && [ "$temp" -gt 50 ]; then
            send_notification "default" "High Drive Temperature" "Drive $device: ${temp}°C" "storage" "temperature,disk,$drive"
        fi
    done
    
    debug_log "System monitoring completed"

    update_last_check "system"
}

monitor_disk_health() {
    [ "$ENABLE_DISK_HEALTH_MONITORING" != "true" ] && return

    debug_log "Starting disk health monitoring"
    
    for drive in $(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
        local device="/dev/$drive"
        [ -z "$(smartctl -i $device 2>/dev/null | grep 'SMART support is: Available')" ] && continue
        
        local health=$(smartctl -H $device 2>/dev/null | awk '/SMART overall-health/ {print $6}')
        if [ "$health" != "PASSED" ]; then
            send_notification "max" "Disk Health Failure" "Drive $device failed SMART health check ($health)" "storage" "disk,health,$drive"
        fi
        
        # Reallocated, pending, uncorrectable
        for attr in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable; do
            local val=$(smartctl -A $device 2>/dev/null | awk -v a="$attr" '$2==a {print $10}')
            if [ ! -z "$val" ] && [ "$val" -gt 0 ]; then
                send_notification "high" "Disk Alert: $attr" "Drive $device: $attr=$val" "storage" "disk,$attr,$drive"
            fi
        done
    done

    for pool in $(zpool list -H -o name); do
        status=$(zpool status -x $pool)
        [ "$status" != "all pools are healthy" ] && send_notification "high" "ZFS Pool Issue" "$status" "storage" "zfs,$pool"
    done

    debug_log "Disk health monitoring completed"
    
    update_last_check "disk_health"
}

monitor_backups() {
    [ "$ENABLE_BACKUP_MONITORING" != "true" ] && return
    
    debug_log "Starting backup monitoring"
    local last_check=$(get_last_check "backups")
    
    # Monitor PVE backup tasks
    if command -v pvesh >/dev/null 2>&1; then
        # Check recent backup tasks for failures
        local failed_backups=$(journalctl --since "$last_check" --no-pager -q | grep -i "backup.*\(error\|failed\|abort\)")
        
        if [ ! -z "$failed_backups" ]; then
            send_notification "high" "PVE Backup Failure" "$failed_backups" "backups" "proxmox,backup,failure"
        fi
    fi
    
    # Monitor custom backup logs
    for log_pattern in $BACKUP_LOG_PATHS; do
        for backup_log in $log_pattern; do
            [ ! -f "$backup_log" ] && continue
            errors=$(tail -n 50 "$backup_log" | grep -iE "error|failed|abort")
            [ ! -z "$errors" ] && send_notification "high" "Backup Error - $(basename $backup_log)" "$errors" "backups" "backup,failure"
        done
    done

    debug_log "Backup monitoring completed"
    
    update_last_check "backups"
}

monitor_guest_networking() {
    [ "$ENABLE_GUEST_NETWORK_MONITORING" != "true" ] && return
    debug_log "Starting guest networking monitoring"

    # LXC
    for vmid in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
        check_guest_network "$vmid" "ct" &
    done

    # QEMU
    for vmid in $(qm list | awk 'NR>1 && $2=="running" {print $1}'); do
        check_guest_network "$vmid" "qemu" &
    done

    wait

    update_last_check "guest_networking"
    debug_log "Guest networking monitoring completed"
}

#==============================================================================
# Main Execution
#==============================================================================

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --host-logs         Run only host logs monitoring"
    echo "  --guest-logs        Run only guest logs monitoring"
    echo "  --backup            Run only backup monitoring"
    echo "  --disk-health       Run only disk health monitoring"
    echo "  --system            Run only system monitoring"
    echo "  --guest-networking  Run only guest network monitoring"
    echo "  --test              Send test notification"
    echo "  --debug             Enable debug logging"
    echo "  --help              Show this help"
    echo ""
    echo "Configuration file: $CONFIG_FILE"
    echo "Error log file: $ERROR_LOG_FILE"
}

# Parse command line arguments
RUN_SPECIFIC=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --host-logs)
            RUN_SPECIFIC="host_logs"
            shift
            ;;
        --guest-logs)
            RUN_SPECIFIC="guest_logs"
            shift
            ;;
        --backup)
            RUN_SPECIFIC="backup"
            shift
            ;;
        --disk-health)
            RUN_SPECIFIC="disk_health"
            shift
            ;;
        --system)
            RUN_SPECIFIC="system"
            shift
            ;;
        --guest-networking)
            RUN_SPECIFIC="guest_networking"
            shift
            ;;
        --test)
            send_notification "default" "Test Notification" "This is a test notification from $(hostname) at $(date)" "test" "test,$(hostname)"
            exit 0
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
debug_log "Starting ntfy monitoring run"

check_dependencies
validate_config

if [ -z "$RUN_SPECIFIC" ]; then
    # Run all monitoring functions
    monitor_host_logs
    monitor_guest_logs
    monitor_disk_health
    monitor_backups
    monitor_system
    monitor_guest_networking
else
    # Run specific monitoring function
    case $RUN_SPECIFIC in
        host_logs)
            monitor_host_logs
            ;;
        guest_logs)
            monitor_guest_logs
            ;;
        backup)
            monitor_backups
            ;;
        disk_health)
            monitor_disk_health
            ;;
        system)
            monitor_system
            ;;
        guest_networking)
            monitor_guest_networking
            ;;
    esac
fi

debug_log "Monitoring run completed"