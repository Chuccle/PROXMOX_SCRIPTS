#!/bin/bash

#==============================================================================
# Unified ntfy Monitoring Script for Proxmox/Linux Infrastructure
# Monitors: Guest networking and log files
#==============================================================================

# Configuration
STATE_DIR="/var/lib/ntfy-monitor"
CONFIG_FILE="/etc/ntfy-monitor.conf"
ERROR_LOG_FILE="/var/log/ntfy-monitor_errors.log"
LOCK_FILE="/var/run/ntfy-monitor.lock"

# Create state directory
mkdir -p "$STATE_DIR"

# Default configuration (can be overridden in config file)
GUEST_PING_TIMEOUT=5
GUEST_PING_RETRY_COUNT=2
CHECK_LOG_INTERVAL_HOURS=1  # Time window for log checks
PING_TARGETS="8.8.8.8 1.1.1.1"
NSLOOKUP_TARGET="google.com"

NTFY_SERVER=""
NTFY_BASE_TOPIC=""
NTFY_USER=""
NTFY_PASS=""

DEBUG=false
TIMEOUT_GUEST_OPERATIONS=30
MAX_PARALLEL_JOBS=10

# Load configuration if it exists
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

#==============================================================================
# Lock Management
#==============================================================================

acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n $LOCK_FD; then
        error_log_message "Another instance is running"
        exit 1
    fi
    echo $$ >&$LOCK_FD
}

release_lock() {
    if [ -n "$LOCK_FD" ]; then
        flock -u $LOCK_FD
        exec {LOCK_FD}>&-
    fi
    rm -f "$LOCK_FILE" 2>/dev/null
}

# Ensure lock is released on exit
trap release_lock EXIT

#==============================================================================
# Utility Functions
#==============================================================================

check_network_tools() {
    local ID=$1
    local TYPE=$2 # vm or ct
    local IS_WINDOWS=$3 # 1 for Windows, 0 for Linux

    if [ "$IS_WINDOWS" -eq 1 ]; then
        error_log_message "$TYPE $ID: Windows VM - network checks not supported."
        send_notification "default" "$TYPE $ID Skipped" "$TYPE $ID ($NAME): Windows VM - network checks not supported." "guest-network" "warning,$TYPE,$NAME"
        return 1
    fi

    # Check for ping
    if [ "$TYPE" = "vm" ]; then
        PING_CHECK=$(qm guest exec $ID -- sh -c "command -v ping" 2>/dev/null)
        PING_EXIT=$?
    else
        PING_CHECK=$(pct exec $ID -- sh -c "command -v ping" 2>/dev/null)
        PING_EXIT=$?
    fi
    
    if [ $PING_EXIT -ne 0 ] || [ -z "$PING_CHECK" ]; then
        error_log_message "$TYPE $ID: ping not found"
        send_notification "urgent" "$TYPE $ID Tool Missing" "$TYPE $ID ($NAME): ping not found." "guest-network" "error,$TYPE,$NAME"
        return $PING_EXIT
    fi

    # Check for nslookup
    if [ "$TYPE" = "vm" ]; then
        NSLOOKUP_CHECK=$(qm guest exec $ID -- sh -c "command -v nslookup" 2>/dev/null)
        NSLOOKUP_EXIT=$?
    else
        NSLOOKUP_CHECK=$(pct exec $ID -- sh -c "command -v nslookup" 2>/dev/null)
        NSLOOKUP_EXIT=$?
    fi
    
    if [ $NSLOOKUP_EXIT -ne 0 ] || [ -z "$NSLOOKUP_CHECK" ]; then
        error_log_message "$TYPE $ID: nslookup not found"
        send_notification "urgent" "$TYPE $ID Tool Missing" "$TYPE $ID ($NAME): nslookup not found." "guest-network" "error,$TYPE,$NAME"
        return $NSLOOKUP_EXIT
    fi
    
    return 0
}

check_log_tools() {
    local ID=$1
    local TYPE=$2 # vm or ct
    local IS_WINDOWS=$3 # 1 for Windows, 0 for Linux

    if [ "$IS_WINDOWS" -eq 1 ]; then
        return 1  # Handled in check_guest_logs
    fi

    # Check for grep and awk
    for tool in grep awk; do
        if [ "$TYPE" = "vm" ]; then
            TOOL_CHECK=$(qm guest exec $ID -- sh -c "command -v $tool" 2>/dev/null)
            TOOL_EXIT=$?
        else
            TOOL_CHECK=$(pct exec $ID -- sh -c "command -v $tool" 2>/dev/null)
            TOOL_EXIT=$?
        fi
        
        if [ $TOOL_EXIT -ne 0 ] || [ -z "$TOOL_CHECK" ]; then
            error_log_message "$TYPE $ID: $tool not found"
            send_notification "urgent" "$TYPE $ID Tool Missing" "$TYPE $ID ($NAME): $tool not found." "guest-logs" "error,$TYPE,$NAME"
            return 1
        fi
    done
    
    return 0
}

check_guest_logs() {
    local VMID=$1
    local NODE=$2
    local NAME=$3
    local TYPE=$4 # vm or ct
    local IS_WINDOWS=$5
    local LAST_CHECK=$6

    debug_log_message "Checking logs for $TYPE $VMID ($NAME) on node $NODE..."

    # Skip Windows VMs
    if [ "$IS_WINDOWS" -eq 1 ]; then
        debug_log_message "  $TYPE $VMID: Windows guest - log checking not supported."
        send_notification "default" "$TYPE $VMID Skipped" "$TYPE $VMID ($NAME): Windows guest - log checking not supported." "guest-logs" "warning,$TYPE,$NAME"
        return
    fi

    # For VMs, check guest agent
    if [ "$TYPE" = "vm" ]; then
        AGENT_PING=$(qm agent $VMID ping 2>/dev/null)
        if [ $? -ne 0 ]; then
            debug_log_message "  $TYPE $VMID: QEMU Guest Agent unavailable - skipping checks."
            send_notification "urgent" "$TYPE $VMID Agent Unavailable" "$TYPE $VMID ($NAME): QEMU Guest Agent unavailable." "guest-logs" "error,$TYPE,$NAME"
            return
        fi
    fi

    # Check log tools
    check_log_tools "$VMID" "$TYPE" "$IS_WINDOWS" || return

    # Define log files to check (syslog or messages)
    local LOG_FILES="/var/log/syslog /var/log/messages"
    local LOG_FILE=""
    local CHECK_CMD=""

    # Find an existing log file
    for file in $LOG_FILES; do
        if [ "$TYPE" = "vm" ]; then
            CHECK_CMD=$(qm guest exec $VMID -- [ -f $file ] && echo exists 2>/dev/null)
            if echo "$CHECK_CMD" | grep -q "exists"; then
                LOG_FILE=$file
                break
            fi
        else
            CHECK_CMD=$(pct exec $VMID -- [ -f $file ] && echo exists 2>/dev/null)
            if echo "$CHECK_CMD" | grep -q "exists"; then
                LOG_FILE=$file
                break
            fi
        fi
    done

    if [ -z "$LOG_FILE" ]; then
        debug_log_message "  $TYPE $VMID: No supported log file found ($LOG_FILES)."
        send_notification "urgent" "$TYPE $VMID Log Missing" "$TYPE $VMID ($NAME): No supported log file found ($LOG_FILES)." "guest-logs" "error,$TYPE,$NAME"
        return
    fi

    debug_log_message "  $TYPE $VMID: Checking $LOG_FILE since $LAST_CHECK..."

    # Convert LAST_CHECK to epoch for comparison
    LAST_CHECK_EPOCH=$(date -d "$LAST_CHECK" +%s 2>/dev/null || echo 0)
    if [ "$LAST_CHECK_EPOCH" -eq 0 ]; then
        error_log_message "$TYPE $VMID: Invalid LAST_CHECK timestamp ($LAST_CHECK)"
        return
    fi

    # Grep for errors and filter by timestamp
    local ERROR_PATTERNS="error|failed|failure|crash|critical|panic"
    local LOG_CHECK=""
    if [ "$TYPE" = "vm" ]; then
        LOG_CHECK=$(qm guest exec $VMID -- grep -i -E $ERROR_PATTERNS $LOG_FILE 2>&1)
    else
        LOG_CHECK=$(pct exec $VMID -- grep -i -E $ERROR_PATTERNS $LOG_FILE 2>&1)
    fi
    local LOG_EXIT=$?

    if [ $LOG_EXIT -ne 0 ]; then
        debug_log_message "  $TYPE $VMID: Failed to read logs - $LOG_CHECK"
        send_notification "urgent" "$TYPE $VMID Log Access Error" "$TYPE $VMID ($NAME): Failed to read $LOG_FILE - $LOG_CHECK" "guest-logs" "error,$TYPE,$NAME"
        return
    fi

    # Filter logs by timestamp
    local ERRORS=""
    if [ -n "$LOG_CHECK" ]; then
        ERRORS=$(echo "$LOG_CHECK" | while IFS= read -r line; do
            LOG_TIME=$(echo "$line" | awk '{print $1 " " $2 " " $3}' | grep -E "[A-Za-z]{3} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}")
            if [ -n "$LOG_TIME" ]; then
                LOG_TIMESTAMP=$(date -d "$LOG_TIME" '+%s' 2>/dev/null)
                if [ -n "$LOG_TIMESTAMP" ] && [ "$LOG_TIMESTAMP" -gt "$LAST_CHECK_EPOCH" ]; then
                    echo "$line"
                fi
            fi
        done)
    fi

    # Report errors if found
    if [ -n "$ERRORS" ]; then
        debug_log_message "  $TYPE $VMID: Issues found in logs since $LAST_CHECK."
        local ERROR_COUNT=$(echo "$ERRORS" | wc -l)
        local MESSAGE="Issues in $TYPE $VMID ($NAME) logs ($LOG_FILE, $ERROR_COUNT errors):\n$ERRORS"
        send_notification "urgent" "$TYPE $VMID Log Issues" "$MESSAGE" "guest-logs" "warning,$TYPE,$NAME"
    else
        debug_log_message "  $TYPE $VMID: No issues found in logs since $LAST_CHECK."
    fi
}

check_guest_network() {
    local VMID=$1
    local NODE=$2
    local NAME=$3
    local TYPE=$4 # vm or ct
    local IS_WINDOWS=$5 # 1 for Windows, 0 for Linux

    debug_log_message "Checking $TYPE $VMID ($NAME) on node $NODE..."

    # For VMs, check guest agent
    if [ "$TYPE" = "vm" ]; then
        AGENT_PING=$(qm agent $VMID ping 2>/dev/null)
        if [ $? -ne 0 ]; then
            debug_log_message "  $TYPE $VMID: QEMU Guest Agent unavailable - skipping checks."
            send_notification "urgent" "$TYPE $VMID Agent Unavailable" "$TYPE $VMID ($NAME): QEMU Guest Agent unavailable." "guest-network" "error,$TYPE,$NAME"
            return
        fi
    fi

    # Check and install tools (skip for Windows)
    check_network_tools "$VMID" "$TYPE" "$IS_WINDOWS" || return

    # Ping check with multiple targets
    local PING_SUCCESS=0
    local target
    
    for target in $PING_TARGETS; do
        debug_log_message "  $TYPE $VMID: Pinging $target..."
        local PING_RESULT=""
        local PING_EXIT=0

        if [ "$TYPE" = "vm" ] && [ "$IS_WINDOWS" -eq 1 ]; then
            # Windows: Use loop for ping -n
            local attempt=0
            while [ $attempt -lt $GUEST_PING_RETRY_COUNT ]; do
                PING_RESULT=$(qm guest exec $VMID -- cmd /c ping -n 1 -w $((GUEST_PING_TIMEOUT*1000)) $target 2>&1)
                PING_EXIT=$?
                if [ $PING_EXIT -eq 0 ] && echo "$PING_RESULT" | grep -q "Reply from"; then
                    PING_SUCCESS=1
                    break
                fi
                attempt=$((attempt + 1))
                debug_log_message "  $TYPE $VMID: Ping attempt $attempt to $target failed - $PING_RESULT"
                sleep 1
            done
        else
            # Linux: Use ping -c
            if [ "$TYPE" = "vm" ]; then
                PING_RESULT=$(qm guest exec $VMID -- ping -c $GUEST_PING_RETRY_COUNT -W $GUEST_PING_TIMEOUT $target 2>&1)
                PING_EXIT=$?
            else
                PING_RESULT=$(pct exec $VMID -- ping -c $GUEST_PING_RETRY_COUNT -W $GUEST_PING_TIMEOUT $target 2>&1)
                PING_EXIT=$?
            fi
            if [ $PING_EXIT -eq 0 ] && echo "$PING_RESULT" | grep -q "1 packets transmitted, 1 received\|[1-9][0-9]* received"; then
                PING_SUCCESS=1
            else
                debug_log_message "  $TYPE $VMID: Ping to $target failed - $PING_RESULT"
            fi
        fi

        if [ $PING_SUCCESS -eq 1 ]; then
            debug_log_message "  $TYPE $VMID: Ping SUCCESS to $target"
            break
        fi
    done

    if [ $PING_SUCCESS -eq 0 ]; then
        debug_log_message "  $TYPE $VMID: Ping FAILED to all targets ($PING_TARGETS)"
        send_notification "urgent" "$TYPE $VMID Ping Failed" "$TYPE $VMID ($NAME): Ping to all targets ($PING_TARGETS) failed - $PING_RESULT" "guest-network" "error,$TYPE,$NAME"
    fi

    # Nslookup check
    if [ "$TYPE" = "vm" ]; then
        if [ "$IS_WINDOWS" -eq 1 ]; then
            NSLOOKUP_RESULT=$(qm guest exec $VMID -- cmd /c nslookup $NSLOOKUP_TARGET 2>&1)
        else
            NSLOOKUP_RESULT=$(qm guest exec $VMID -- nslookup $NSLOOKUP_TARGET 2>&1)
        fi
        NSLOOKUP_EXIT=$?
    else
        NSLOOKUP_RESULT=$(pct exec $VMID -- nslookup $NSLOOKUP_TARGET 2>&1)
        NSLOOKUP_EXIT=$?
    fi

    if [ $NSLOOKUP_EXIT -eq 0 ] && echo "$NSLOOKUP_RESULT" | grep -q "Name:.*$NSLOOKUP_TARGET"; then
        debug_log_message "  $TYPE $VMID: Nslookup SUCCESS"
    else
        debug_log_message "  $TYPE $VMID: Nslookup FAILED - $NSLOOKUP_RESULT"
        send_notification "urgent" "$TYPE $VMID Nslookup Failed" "$TYPE $VMID ($NAME): Nslookup of $NSLOOKUP_TARGET failed - $NSLOOKUP_RESULT" "guest-network" "error,$TYPE,$NAME"
    fi
}

log_message() {
    echo "$(get_timestamp) - $1" | tee -a "$ERROR_LOG_FILE"
}

error_log_message() {
    echo "[$(get_timestamp)] $1" | tee -a "$ERROR_LOG_FILE"
}

debug_log_message() {
    [ "$DEBUG" = "true" ] && echo "DEBUG: $(date '+%H:%M:%S') $1"
}

validate_config() {
    if [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_BASE_TOPIC" ]; then
        error_log_message "Missing required configuration: NTFY_SERVER or NTFY_BASE_TOPIC"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "jq" "awk" "grep" "date" "pvesh" "pct" "qm")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing_deps+=("$dep")
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_log_message "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

send_notification() {
    local priority="$1"
    local title="$2"
    local message="$3"
    local topic="$4"
    local tags="${5:-$(hostname)}"
    local click_url="$6"
    
    topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
    local full_topic="${NTFY_BASE_TOPIC}-${topic}"
    
    if [ ${#message} -gt 1000 ]; then
        message="${message:0:997}..."
    fi
    
    local curl_args=(-s -f --max-time 10)
    local headers="Title: $title"$'\n'"Priority: $priority"$'\n'"Tags: $tags"
    [ -n "$click_url" ] && headers=$'\n'"Click: $click_url"
    
    debug_log_message "Sending notification: $title (topic: $full_topic)"

    local auth_args=()
    [ -n "$NTFY_USER" ] && [ -n "$NTFY_PASS" ] && auth_args+=(-u "$NTFY_USER:$NTFY_PASS")
    
    if curl "${curl_args[@]}" "${auth_args[@]}" \
        -H "$(echo -e "$headers")" \
        -d "$message" \
        "http://$NTFY_SERVER/$full_topic" >/dev/null 2>&1; then
        debug_log_message "Notification sent successfully: $title"
    else
        error_log_message "Failed to send notification: $title (topic: $full_topic)"
        return 1
    fi
}

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

get_last_check() {
    local check_type="$1"
    local state_file="$STATE_DIR/${check_type}.state"
    
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        date '+%Y-%m-%d %H:%M:%S' --date="$CHECK_LOG_INTERVAL_HOURS hours ago"
    fi
}

update_last_check() {
    local check_type="$1"
    local state_file="$STATE_DIR/${check_type}.state"
    get_timestamp > "$state_file"
}

manage_parallel_jobs() {
    local max_jobs="$1"
    while [ $(jobs -r | wc -l) -ge "$max_jobs" ]; do
        wait -n
    done
}

main() {
    log_message "Starting monitoring for running VMs and CTs..."

    check_dependencies
    validate_config
    acquire_lock

    log_message "Querying cluster resources..."
    RESOURCES=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)

    if [ $? -ne 0 ]; then
        error_log_message "ERROR: Failed to query resources. Ensure pvesh is available and run as root."
        exit 1
    fi

    if echo "$RESOURCES" | jq -e '.data' >/dev/null 2>&1; then
        JQ_FILTER='.data[]'
    else
        JQ_FILTER='.[]'
    fi

    LAST_LOG_CHECK=$(get_last_check "guest_logs")

    log_message "Processing VMs..."
    echo "$RESOURCES" | jq -r "$JQ_FILTER | select(.status == \"running\" and .type == \"qemu\" and .template != 1) | \"\(.vmid)|\(.node)|\(.name)\"" | while IFS='|' read -r VMID NODE NAME; do
        [ "$TEMPLATE" = "1" ] && continue

        IS_WINDOWS=0

        if qm agent $VMID ping >/dev/null 2>&1; then
            OS_CHECK=$(qm guest exec $VMID -- cmd /c ver 2>/dev/null)
            if echo "$OS_CHECK" | grep -q "Microsoft Windows"; then
                IS_WINDOWS=1
            fi
        fi

        (
            check_guest_network "$VMID" "$NODE" "$NAME" "vm" "$IS_WINDOWS"
            check_guest_logs "$VMID" "$NODE" "$NAME" "vm" "$IS_WINDOWS" "$LAST_LOG_CHECK"
        ) &
        manage_parallel_jobs "$MAX_PARALLEL_JOBS"
    done

    log_message "Processing CTs..."
    echo "$RESOURCES" | jq -r "$JQ_FILTER | select(.status == \"running\" and .type == \"lxc\" and .template != 1) | \"\(.vmid)|\(.node)|\(.name)\"" | while IFS='|' read -r CTID NODE NAME; do
        (
            check_guest_network "$CTID" "$NODE" "$NAME" "ct" 0
            check_guest_logs "$CTID" "$NODE" "$NAME" "ct" 0 "$LAST_LOG_CHECK"
        ) &
        manage_parallel_jobs "$MAX_PARALLEL_JOBS"
    done

    wait
    update_last_check "guest_logs"
    log_message "Monitoring completed."
}

main