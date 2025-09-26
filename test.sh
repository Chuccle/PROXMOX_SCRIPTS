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
GUEST_PING_COUNT=2
CHECK_LOG_INTERVAL_HOURS=1  # Time window for log checks
PING_TARGETS="8.8.8.8 1.1.1.1"
NSLOOKUP_TARGET="google.com"

# Log files to monitor (space-separated)
LOG_FILES_TO_MONITOR="/var/log/syslog /var/log/auth.log /var/log/kern.log"
# Error patterns to search for
LOG_ERROR_PATTERNS="error|fail|panic|segfault|oops|warning|critical|alert|emergency"

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
        flock -u $LOCK_FD 2>/dev/null
        exec {LOCK_FD}>&- 2>/dev/null
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
        # Windows has ping and nslookup built-in, so just return success
        return 0
    fi

    # Check for ping
    if [ "$TYPE" = "vm" ]; then
        PING_CHECK=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $ID -- sh -c "command -v ping" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$PING_CHECK" ]; then
            PING_EXIT=$(echo "$PING_CHECK" | jq -r '.exitcode // 1')
        else
            PING_EXIT=1
        fi
    else
        timeout $TIMEOUT_GUEST_OPERATIONS pct exec $ID -- sh -c "command -v ping" >/dev/null 2>&1
        PING_EXIT=$?
    fi
    
    if [ "$PING_EXIT" -ne 0 ]; then
        error_log_message "$TYPE $ID: ping not found"
        send_notification "urgent" "$TYPE $ID Tool Missing" "$TYPE $ID: ping not found." "guest-network" "error,$TYPE"
        return $PING_EXIT
    fi

    # Check for nslookup
    if [ "$TYPE" = "vm" ]; then
        NSLOOKUP_CHECK=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $ID -- sh -c "command -v nslookup || command -v dig" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$NSLOOKUP_CHECK" ]; then
            NSLOOKUP_EXIT=$(echo "$NSLOOKUP_CHECK" | jq -r '.exitcode // 1')
        else
            NSLOOKUP_EXIT=1
        fi
    else
        timeout $TIMEOUT_GUEST_OPERATIONS pct exec $ID -- sh -c "command -v nslookup || command -v dig" >/dev/null 2>&1
        NSLOOKUP_EXIT=$?
    fi
    
    if [ "$NSLOOKUP_EXIT" -ne 0 ]; then
        error_log_message "$TYPE $ID: nslookup/dig not found"
        send_notification "urgent" "$TYPE $ID Tool Missing" "$TYPE $ID: nslookup/dig not found." "guest-network" "error,$TYPE"
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

    # Check for grep, awk, and date
    for tool in grep awk date; do
        if [ "$TYPE" = "vm" ]; then
            TOOL_CHECK=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $ID -- sh -c "command -v $tool" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$TOOL_CHECK" ]; then
                TOOL_EXIT=$(echo "$TOOL_CHECK" | jq -r '.exitcode // 1')
            else
                TOOL_EXIT=1
            fi
        else
            timeout $TIMEOUT_GUEST_OPERATIONS pct exec $ID -- sh -c "command -v $tool" >/dev/null 2>&1
            TOOL_EXIT=$?
        fi
        
        if [ "$TOOL_EXIT" -ne 0 ]; then
            error_log_message "$TYPE $ID: $tool not found"
            send_notification "urgent" "$TYPE $ID Tool Missing" "$TYPE $ID: $tool not found." "guest-logs" "error,$TYPE"
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
        return
    fi

    # For VMs, check guest agent
    if [ "$TYPE" = "vm" ]; then
        if ! timeout $TIMEOUT_GUEST_OPERATIONS qm agent $VMID ping >/dev/null 2>&1; then
            debug_log_message "  $TYPE $VMID: QEMU Guest Agent unavailable - skipping log checks."
            send_notification "urgent" "$TYPE $VMID Agent Unavailable" "$TYPE $VMID ($NAME): QEMU Guest Agent unavailable for log checks." "guest-logs" "error,$TYPE"
            return
        fi
    fi

    # Check log tools
    check_log_tools "$VMID" "$TYPE" "$IS_WINDOWS" || return

    local ERRORS=""
    local ERROR_COUNT=0
    local TOTAL_ERRORS=""

    # Convert last check time to timestamp for comparison
    local LAST_CHECK_TIMESTAMP
    if [ "$TYPE" = "vm" ]; then
        LAST_CHECK_TIMESTAMP=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- date -d "$LAST_CHECK" '+%s' 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$LAST_CHECK_TIMESTAMP" ]; then
            LAST_CHECK_TIMESTAMP=$(echo "$LAST_CHECK_TIMESTAMP" | jq -r '.["out-data"] // empty' | head -n1)
        else
            debug_log_message "  $TYPE $VMID: Could not convert timestamp, checking last hour"
            LAST_CHECK_TIMESTAMP=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- date -d "1 hour ago" '+%s' 2>/dev/null | jq -r '.["out-data"] // empty' | head -n1)
        fi
    else
        LAST_CHECK_TIMESTAMP=$(timeout $TIMEOUT_GUEST_OPERATIONS pct exec $VMID -- date -d "$LAST_CHECK" '+%s' 2>/dev/null || timeout $TIMEOUT_GUEST_OPERATIONS pct exec $VMID -- date -d "1 hour ago" '+%s' 2>/dev/null)
    fi

    # Check each log file
    for log_file in $LOG_FILES_TO_MONITOR; do
        debug_log_message "  $TYPE $VMID: Checking $log_file..."
        
        # Check if log file exists
        local FILE_EXISTS
        if [ "$TYPE" = "vm" ]; then
            FILE_EXISTS=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- test -f "$log_file" 2>/dev/null)
            FILE_EXISTS=$(echo "$FILE_EXISTS" | jq -r '.exitcode // 1')
        else
            timeout $TIMEOUT_GUEST_OPERATIONS pct exec $VMID -- test -f "$log_file" >/dev/null 2>&1
            FILE_EXISTS=$?
        fi
        
        if [ "$FILE_EXISTS" -ne 0 ]; then
            debug_log_message "  $TYPE $VMID: $log_file does not exist, skipping"
            continue
        fi

        # Search for recent errors in the log file
        local LOG_ERRORS=""
        if [ "$TYPE" = "vm" ]; then
            LOG_ERRORS=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- sh -c "
                awk -v since=\"$LAST_CHECK_TIMESTAMP\" '
                {
                    # Try to parse timestamp from log line (basic syslog format)
                    cmd = \"date -d \\\"\" \$1 \" \" \$2 \" \" \$3 \"\\\" +%s 2>/dev/null\"
                    cmd | getline ts
                    close(cmd)
                    if (ts >= since && \$0 ~ /$LOG_ERROR_PATTERNS/i) {
                        print \$0
                    }
                }' \"$log_file\" 2>/dev/null | head -10
            " 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$LOG_ERRORS" ]; then
                LOG_ERRORS=$(echo "$LOG_ERRORS" | jq -r '.["out-data"] // empty')
            fi
        else
            LOG_ERRORS=$(timeout $TIMEOUT_GUEST_OPERATIONS pct exec $VMID -- sh -c "
                awk -v since=\"$LAST_CHECK_TIMESTAMP\" '
                {
                    # Try to parse timestamp from log line (basic syslog format)
                    cmd = \"date -d \\\"\" \$1 \" \" \$2 \" \" \$3 \"\\\" +%s 2>/dev/null\"
                    cmd | getline ts
                    close(cmd)
                    if (ts >= since && \$0 ~ /$LOG_ERROR_PATTERNS/i) {
                        print \$0
                    }
                }' \"$log_file\" 2>/dev/null | head -10
            " 2>/dev/null)
        fi

        if [ -n "$LOG_ERRORS" ]; then
            local FILE_ERROR_COUNT=$(echo "$LOG_ERRORS" | wc -l)
            ERROR_COUNT=$((ERROR_COUNT + FILE_ERROR_COUNT))
            TOTAL_ERRORS="$TOTAL_ERRORS\n--- $log_file ($FILE_ERROR_COUNT errors) ---\n$LOG_ERRORS"
        fi
    done

    # Report errors if found
    if [ $ERROR_COUNT -gt 0 ]; then
        debug_log_message "  $TYPE $VMID: $ERROR_COUNT issues found in logs since $LAST_CHECK."
        local MESSAGE="$ERROR_COUNT issues found in $TYPE $VMID ($NAME) logs since $LAST_CHECK:$TOTAL_ERRORS"
        send_notification "urgent" "$TYPE $VMID Log Issues" "$MESSAGE" "guest-logs" "warning,$TYPE"
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
        if ! timeout $TIMEOUT_GUEST_OPERATIONS qm agent $VMID ping >/dev/null 2>&1; then
            debug_log_message "  $TYPE $VMID: QEMU Guest Agent unavailable - skipping network checks."
            send_notification "urgent" "$TYPE $VMID Agent Unavailable" "$TYPE $VMID ($NAME): QEMU Guest Agent unavailable for network checks." "guest-network" "error,$TYPE"
            return
        fi
    fi

    # Check and install tools (skip for Windows)
    check_network_tools "$VMID" "$TYPE" "$IS_WINDOWS" || return

    # Ping check with multiple targets
    local PING_SUCCESS=0
    local target
    local PING_FAILURES=""
    
    for target in $PING_TARGETS; do
        debug_log_message "  $TYPE $VMID: Pinging $target..."
        local PING_RESULT=""
        local PING_EXIT=0

        if [ "$TYPE" = "vm" ] && [ "$IS_WINDOWS" -eq 1 ]; then
            # Windows: Use ping -n
            PING_RESULT=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- cmd /c "ping -n $GUEST_PING_COUNT -w $((GUEST_PING_TIMEOUT*1000)) $target" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$PING_RESULT" ]; then
                local PING_OUTPUT=$(echo "$PING_RESULT" | jq -r '.["out-data"] // empty')
                if echo "$PING_OUTPUT" | grep -q "Reply from\|Received = $GUEST_PING_COUNT"; then
                    PING_SUCCESS=1
                    debug_log_message "  $TYPE $VMID: Ping SUCCESS to $target"
                    break
                else
                    PING_FAILURES="$PING_FAILURES\n$target: $(echo "$PING_OUTPUT" | head -2 | tail -1)"
                fi
            else
                PING_FAILURES="$PING_FAILURES\n$target: Command failed or timed out"
            fi
        else
            # Linux: Use ping -c
            if [ "$TYPE" = "vm" ]; then
                PING_RESULT=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- ping -c $GUEST_PING_COUNT -W $GUEST_PING_TIMEOUT $target 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$PING_RESULT" ]; then
                    PING_EXIT=$(echo "$PING_RESULT" | jq -r '.exitcode // 1')
                    if [ $PING_EXIT -eq 0 ]; then
                        PING_SUCCESS=1
                        debug_log_message "  $TYPE $VMID: Ping SUCCESS to $target"
                        break
                    else
                        local PING_OUTPUT=$(echo "$PING_RESULT" | jq -r '.["out-data"] // "No output"')
                        PING_FAILURES="$PING_FAILURES\n$target: $PING_OUTPUT"
                    fi
                else
                    PING_FAILURES="$PING_FAILURES\n$target: Command failed or timed out"
                fi
            else
                if timeout $TIMEOUT_GUEST_OPERATIONS pct exec $VMID -- ping -c $GUEST_PING_COUNT -W $GUEST_PING_TIMEOUT $target >/dev/null 2>&1; then
                    PING_SUCCESS=1
                    debug_log_message "  $TYPE $VMID: Ping SUCCESS to $target"
                    break
                else
                    PING_FAILURES="$PING_FAILURES\n$target: Ping failed"
                fi
            fi
        fi
    done

    if [ $PING_SUCCESS -eq 0 ]; then
        debug_log_message "  $TYPE $VMID: Ping FAILED to all targets ($PING_TARGETS)"
        send_notification "urgent" "$TYPE $VMID Ping Failed" "$TYPE $VMID ($NAME): Ping to all targets failed:$PING_FAILURES" "guest-network" "error,$TYPE"
    fi

    # Nslookup/DNS check
    local DNS_SUCCESS=0
    local NSLOOKUP_RESULT=""
    
    if [ "$TYPE" = "vm" ]; then
        if [ "$IS_WINDOWS" -eq 1 ]; then
            NSLOOKUP_RESULT=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- cmd /c "nslookup $NSLOOKUP_TARGET" 2>/dev/null)
        else
            NSLOOKUP_RESULT=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- sh -c "nslookup $NSLOOKUP_TARGET 2>/dev/null || dig $NSLOOKUP_TARGET +short" 2>/dev/null)
        fi
        
        if [ $? -eq 0 ] && [ -n "$NSLOOKUP_RESULT" ]; then
            local DNS_OUTPUT=$(echo "$NSLOOKUP_RESULT" | jq -r '.["out-data"] // empty')
            if echo "$DNS_OUTPUT" | grep -q "$NSLOOKUP_TARGET\|Address:\|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"; then
                DNS_SUCCESS=1
                debug_log_message "  $TYPE $VMID: DNS resolution SUCCESS"
            else
                debug_log_message "  $TYPE $VMID: DNS resolution FAILED - $DNS_OUTPUT"
            fi
        else
            debug_log_message "  $TYPE $VMID: DNS command failed or timed out"
        fi
    else
        NSLOOKUP_RESULT=$(timeout $TIMEOUT_GUEST_OPERATIONS pct exec $VMID -- sh -c "nslookup $NSLOOKUP_TARGET 2>/dev/null || dig $NSLOOKUP_TARGET +short" 2>/dev/null)
        if [ $? -eq 0 ] && echo "$NSLOOKUP_RESULT" | grep -q "$NSLOOKUP_TARGET\|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"; then
            DNS_SUCCESS=1
            debug_log_message "  $TYPE $VMID: DNS resolution SUCCESS"
        else
            debug_log_message "  $TYPE $VMID: DNS resolution FAILED - $NSLOOKUP_RESULT"
        fi
    fi

    if [ $DNS_SUCCESS -eq 0 ]; then
        send_notification "urgent" "$TYPE $VMID DNS Failed" "$TYPE $VMID ($NAME): DNS resolution of $NSLOOKUP_TARGET failed" "guest-network" "error,$TYPE"
    fi
}

log_message() {
    echo "$(get_timestamp) - $1" | tee -a "$ERROR_LOG_FILE"
}

error_log_message() {
    echo "[$(get_timestamp)] ERROR: $1" | tee -a "$ERROR_LOG_FILE" >&2
}

debug_log_message() {
    [ "$DEBUG" = "true" ] && echo "DEBUG: $(date '+%H:%M:%S') $1"
}

validate_config() {
    if [ -z "$NTFY_SERVER" ] || [ -z "$NTFY_BASE_TOPIC" ]; then
        error_log_message "Missing required configuration: NTFY_SERVER or NTFY_BASE_TOPIC"
        echo "Please set NTFY_SERVER and NTFY_BASE_TOPIC in $CONFIG_FILE"
        echo "Example configuration:"
        echo "NTFY_SERVER='ntfy.example.com'"
        echo "NTFY_BASE_TOPIC='proxmox-alerts'"
        echo "NTFY_USER='username'  # optional"
        echo "NTFY_PASS='password'  # optional"
        exit 1
    fi
    
    # Validate ntfy server connectivity
    if ! curl -s --max-time 5 "http://$NTFY_SERVER" >/dev/null 2>&1; then
        error_log_message "Cannot reach ntfy server: $NTFY_SERVER"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "jq" "awk" "grep" "date" "pvesh" "pct" "qm" "flock" "timeout")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_log_message "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install missing dependencies and try again."
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
    
    # Clean topic name
    topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
    local full_topic="${NTFY_BASE_TOPIC}-${topic}"
    
    # Truncate message if too long
    if [ ${#message} -gt 1000 ]; then
        message="${message:0:997}..."
    fi
    
    local curl_args=(-s -f --max-time 10)
    local headers="Title: $title"$'\n'"Priority: $priority"$'\n'"Tags: $tags"
    [ -n "$click_url" ] && headers+=$'\n'"Click: $click_url"
    
    debug_log_message "Sending notification: $title (topic: $full_topic)"

    local auth_args=()
    [ -n "$NTFY_USER" ] && [ -n "$NTFY_PASS" ] && auth_args+=(-u "$NTFY_USER:$NTFY_PASS")
    
    if curl "${curl_args[@]}" "${auth_args[@]}" \
        -H "$(echo -e "$headers")" \
        -d "$message" \
        "http://$NTFY_SERVER/$full_topic" >/dev/null 2>&1; then
        debug_log_message "Notification sent successfully: $title"
        return 0
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
        wait -n 2>/dev/null || sleep 1
    done
}

detect_windows_vm() {
    local VMID=$1
    
    # Try to detect Windows by checking guest agent OS info
    local OS_INFO
    OS_INFO=$(timeout $TIMEOUT_GUEST_OPERATIONS qm guest exec $VMID -- cmd /c ver 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$OS_INFO" ]; then
        if echo "$OS_INFO" | grep -qi "microsoft windows"; then
            return 0  # Is Windows
        fi
    fi
    
    # Alternative: check guest agent info
    OS_INFO=$(timeout $TIMEOUT_GUEST_OPERATIONS qm agent $VMID get-osinfo 2>/dev/null)
    if [ $? -eq 0 ] && echo "$OS_INFO" | grep -qi "windows"; then
        return 0  # Is Windows
    fi
    
    return 1  # Not Windows or cannot determine
}

main() {
    # Handle command line arguments
    case "${1:-}" in
        --debug)
            DEBUG=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--debug] [--help]"
            echo "Options:"
            echo "  --debug    Enable debug output"
            echo "  --help     Show this help message"
            exit 0
            ;;
    esac

    log_message "Starting monitoring for running VMs and CTs..."

    check_dependencies
    validate_config
    acquire_lock

    log_message "Querying cluster resources..."
    RESOURCES=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)

    if [ $? -ne 0 ]; then
        error_log_message "Failed to query resources. Ensure pvesh is available and run as root."
        exit 1
    fi

    if echo "$RESOURCES" | jq -e '.data' >/dev/null 2>&1; then
        JQ_FILTER='.data[]'
    else
        JQ_FILTER='.[]'
    fi

    LAST_LOG_CHECK=$(get_last_check "guest_logs")
    log_message "Checking logs since: $LAST_LOG_CHECK"

    log_message "Processing VMs..."
    local vm_count=0
    echo "$RESOURCES" | jq -r "$JQ_FILTER | select(.status == \"running\" and .type == \"qemu\" and (.template // 0) != 1) | \"\(.vmid)|\(.node)|\(.name // \"VM-\" + (.vmid|tostring))\"" | while IFS='|' read -r VMID NODE NAME; do
        [ -z "$VMID" ] && continue
        vm_count=$((vm_count + 1))
        
        # Detect Windows
        IS_WINDOWS=0
        if detect_windows_vm "$VMID"; then
            IS_WINDOWS=1
            debug_log_message "Detected Windows VM: $VMID ($NAME)"
        fi

        (
            check_guest_network "$VMID" "$NODE" "$NAME" "vm" "$IS_WINDOWS"
            check_guest_logs "$VMID" "$NODE" "$NAME" "vm" "$IS_WINDOWS" "$LAST_LOG_CHECK"
        ) &
        manage_parallel_jobs "$MAX_PARALLEL_JOBS"
    done

    log_message "Processing CTs..."
    local ct_count=0
    echo "$RESOURCES" | jq -r "$JQ_FILTER | select(.status == \"running\" and .type == \"lxc\" and (.template // 0) != 1) | \"\(.vmid)|\(.node)|\(.name // \"CT-\" + (.vmid|tostring))\"" | while IFS='|' read -r CTID NODE NAME; do
        [ -z "$CTID" ] && continue
        ct_count=$((ct_count + 1))
        
        (
            check_guest_network "$CTID" "$NODE" "$NAME" "ct" 0
            check_guest_logs "$CTID" "$NODE" "$NAME" "ct" 0 "$LAST_LOG_CHECK"
        ) &
        manage_parallel_jobs "$MAX_PARALLEL_JOBS"
    done

    debug_log_message "Waiting for all monitoring jobs to complete..."
    wait

    update_last_check "guest_logs"
    
    log_message "Monitoring completed successfully."
    
    # Send summary notification if debug mode
    if [ "$DEBUG" = "true" ]; then
        send_notification "default" "Monitoring Complete" "Proxmox monitoring completed for $(echo "$RESOURCES" | jq -r "$JQ_FILTER | select(.status == \"running\" and (.template // 0) != 1)" | wc -l) guests" "monitor-summary" "info,$(hostname)"
    fi
}

# Only run main if script is executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi