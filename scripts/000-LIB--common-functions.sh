#!/bin/bash
# Common Functions for WhisperLive RunPod Deployment
# Shared library for RunPod management scripts
# Version: 1.0.0

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$PROJECT_ROOT/artifacts}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"

# Ensure directories exist
mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"

# State files
POD_FILE="$ARTIFACTS_DIR/pod.json"
STATE_FILE="$ARTIFACTS_DIR/state.json"

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# JSON Logging
# ============================================================================

json_log() {
    local script="${1:-unknown}"
    local step="${2:-unknown}"
    local status="${3:-ok}"
    local details="${4:-}"
    shift 4 || true

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Build JSON object
    local json='{'
    json+='"ts":"'$timestamp'"'
    json+=',"script":"'$script'"'
    json+=',"step":"'$step'"'
    json+=',"status":"'$status'"'
    json+=',"details":"'$(echo "$details" | sed 's/"/\\"/g')'"'

    # Parse additional key=value pairs
    while [ $# -gt 0 ]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        if [ "$key" != "$1" ]; then
            if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                json+=',"'$key'":'$value
            else
                json+=',"'$key'":"'$(echo "$value" | sed 's/"/\\"/g')'"'
            fi
        fi
        shift
    done

    json+='}'

    # Print to console with color coding
    local color="$NC"
    case "$status" in
        ok) color="$GREEN" ;;
        warn) color="$YELLOW" ;;
        error) color="$RED" ;;
    esac

    echo -e "${color}[$step] $details${NC}" >&2
}

# ============================================================================
# File Logging
# ============================================================================

# Global to track if logging has been started
_LOGGING_STARTED="${_LOGGING_STARTED:-false}"
_LOG_FILE=""

start_logging() {
    local script_name="${1:-${SCRIPT_NAME:-unknown}}"

    # Don't start logging twice
    if [ "$_LOGGING_STARTED" = "true" ]; then
        return 0
    fi

    # Create log filename
    local timestamp=$(date +%Y%m%d-%H%M%S)
    _LOG_FILE="$LOGS_DIR/${script_name}-${timestamp}.log"

    # Redirect stdout and stderr to both console and log file
    exec > >(tee -a "$_LOG_FILE") 2>&1

    _LOGGING_STARTED="true"

    # Log header
    echo "============================================================================"
    echo "Log started: $(date)"
    echo "Script: $script_name"
    echo "Log file: $_LOG_FILE"
    echo "============================================================================"
    echo ""
}

get_log_file() {
    echo "$_LOG_FILE"
}

# ============================================================================
# Environment Management
# ============================================================================

load_env_or_fail() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Configuration file not found: $ENV_FILE${NC}"
        echo "Run: ./scripts/010-SETUP--interactive-configuration.sh"
        return 1
    fi

    source "$ENV_FILE"
    json_log "${SCRIPT_NAME:-common}" "load_env" "ok" "Environment loaded from $ENV_FILE"
}

update_env_file() {
    local key="$1"
    local value="$2"
    local temp_file="${ENV_FILE}.tmp.$$"

    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$temp_file"
    else
        cp "$ENV_FILE" "$temp_file"
        echo "${key}=${value}" >> "$temp_file"
    fi

    # Update ENV_VERSION
    if grep -q "^ENV_VERSION=" "$temp_file"; then
        local current_version=$(grep "^ENV_VERSION=" "$temp_file" | cut -d= -f2)
        local new_version=$((current_version + 1))
        sed -i "s|^ENV_VERSION=.*|ENV_VERSION=${new_version}|" "$temp_file"
    fi

    mv -f "$temp_file" "$ENV_FILE"
}

# ============================================================================
# Utility Functions
# ============================================================================

format_duration() {
    local seconds="${1}"

    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

print_status() {
    local status="${1}"
    local message="${2}"

    case "$status" in
        ok|success)
            echo -e "${GREEN}$message${NC}"
            ;;
        warn|warning)
            echo -e "${YELLOW}$message${NC}"
            ;;
        error|fail)
            echo -e "${RED}$message${NC}"
            ;;
        info)
            echo -e "${BLUE}$message${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Wait for HTTP endpoint to return expected status
# Usage: wait_for_http_endpoint <url> [expected_status] [timeout_seconds]
# Returns: 0 on success, 1 on timeout
wait_for_http_endpoint() {
    local url="${1}"
    local expected="${2:-200}"
    local timeout="${3:-60}"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
        if [ "$status" = "$expected" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    return 1
}

# ============================================================================
# RunPod API Functions
# ============================================================================

RUNPOD_API_BASE="https://api.runpod.io/v2"
RUNPOD_REST_BASE="https://rest.runpod.io/v1"

# Make authenticated API call to RunPod REST API
# Usage: runpod_api_call <METHOD> <ENDPOINT> [DATA]
# Returns: JSON response on stdout
runpod_api_call() {
    local method="${1}"
    local endpoint="${2}"
    local data="${3:-}"

    local url="${RUNPOD_REST_BASE}${endpoint}"

    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        echo '{"error": "RUNPOD_API_KEY not set"}' >&2
        return 1
    fi

    local curl_args=(
        -s
        -X "$method"
        -H "Authorization: Bearer ${RUNPOD_API_KEY}"
        -H "Content-Type: application/json"
    )

    if [ -n "$data" ]; then
        curl_args+=(-d "$data")
    fi

    curl "${curl_args[@]}" "$url"
}

# Get pod status from RunPod
# Usage: get_runpod_pod_status [pod_id]
# Returns: status string (RUNNING, EXITED, PENDING, etc.)
get_runpod_pod_status() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"

    if [ -z "$pod_id" ]; then
        echo "unknown"
        return 1
    fi

    local response=$(runpod_api_call "GET" "/pods/${pod_id}")

    if [ $? -ne 0 ]; then
        echo "error"
        return 1
    fi

    # Check for error response
    local error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$error" ]; then
        echo "error"
        return 1
    fi

    local status=$(echo "$response" | jq -r '.desiredStatus // "unknown"' 2>/dev/null)
    echo "$status"
}

# Get pod details from RunPod
# Usage: get_runpod_pod_details [pod_id]
# Returns: full JSON response
get_runpod_pod_details() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"

    if [ -z "$pod_id" ]; then
        echo '{"error": "No pod ID"}'
        return 1
    fi

    runpod_api_call "GET" "/pods/${pod_id}"
}

# Get pod public IP and port mappings
# Usage: get_runpod_pod_networking [pod_id]
# Returns: JSON with publicIp and ports
get_runpod_pod_networking() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"
    local response=$(get_runpod_pod_details "$pod_id")

    if [ $? -ne 0 ]; then
        echo '{"error": "Failed to get pod details"}'
        return 1
    fi

    # Extract networking info
    local public_ip=$(echo "$response" | jq -r '.runtime.ports[0].ip // empty' 2>/dev/null)
    local ports=$(echo "$response" | jq -c '.runtime.ports // []' 2>/dev/null)

    echo "{\"publicIp\": \"$public_ip\", \"ports\": $ports}"
}

# Create a new RunPod pod
# Usage: create_runpod_pod <json_payload>
# Returns: JSON response with pod details
create_runpod_pod() {
    local payload="${1}"

    runpod_api_call "POST" "/pods" "$payload"
}

# Start a stopped pod
# Usage: start_runpod_pod [pod_id]
# Returns: 0 on success
start_runpod_pod() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"

    if [ -z "$pod_id" ]; then
        return 1
    fi

    runpod_api_call "POST" "/pods/${pod_id}/start"
}

# Stop a running pod
# Usage: stop_runpod_pod [pod_id]
# Returns: 0 on success
stop_runpod_pod() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"

    if [ -z "$pod_id" ]; then
        return 1
    fi

    runpod_api_call "POST" "/pods/${pod_id}/stop"
}

# Terminate (delete) a pod
# Usage: terminate_runpod_pod [pod_id]
# Returns: 0 on success
terminate_runpod_pod() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"

    if [ -z "$pod_id" ]; then
        return 1
    fi

    runpod_api_call "DELETE" "/pods/${pod_id}"
}

# Wait for pod to reach running state
# Usage: wait_for_runpod_pod [timeout_seconds]
# Returns: 0 on success, 1 on timeout/error
wait_for_runpod_pod() {
    local timeout="${1:-300}"
    local elapsed=0

    echo -n "Waiting for pod to start"

    while [ $elapsed -lt $timeout ]; do
        local status=$(get_runpod_pod_status)

        case "$status" in
            "RUNNING")
                echo ""
                return 0
                ;;
            "EXITED"|"TERMINATED"|"error")
                echo ""
                echo "Pod failed with status: $status"
                return 1
                ;;
            *)
                echo -n "."
                sleep 5
                elapsed=$((elapsed + 5))
                ;;
        esac
    done

    echo ""
    echo "Timeout waiting for pod (${timeout}s)"
    return 1
}

# List all pods
# Usage: list_runpod_pods
# Returns: JSON array of pods
list_runpod_pods() {
    runpod_api_call "GET" "/pods"
}

# Get pod logs (limited functionality via REST API)
# Usage: get_runpod_pod_logs [pod_id]
# Note: Full logs require SSH or websocket connection
get_runpod_pod_logs() {
    local pod_id="${1:-${RUNPOD_POD_ID:-}}"

    if [ -z "$pod_id" ]; then
        echo "No pod ID specified"
        return 1
    fi

    # The REST API doesn't have a direct logs endpoint
    # Logs are typically accessed via SSH or the web console
    echo "Logs not directly available via REST API."
    echo "Access logs via:"
    echo "  - RunPod Web Console: https://www.runpod.io/console/pods"
    echo "  - SSH to pod (if SSH port exposed)"

    return 0
}

# ============================================================================
# State Management
# ============================================================================

# Write pod state to cache file
# Usage: write_pod_state <pod_id> <status> [public_ip] [ws_port] [health_port]
write_pod_state() {
    local pod_id="${1}"
    local status="${2}"
    local public_ip="${3:-}"
    local ws_port="${4:-}"
    local health_port="${5:-}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$POD_FILE" <<EOF
{
  "pod_id": "$pod_id",
  "status": "$status",
  "public_ip": "$public_ip",
  "ws_port": "$ws_port",
  "health_port": "$health_port",
  "last_updated": "$timestamp",
  "pod_name": "${RUNPOD_POD_NAME:-}",
  "gpu_type": "${RUNPOD_GPU_TYPE:-}"
}
EOF
}

# Read pod ID from state file or env
# Usage: get_pod_id
# Returns: pod ID string
get_pod_id() {
    local pod_id=""

    if [ -f "$POD_FILE" ]; then
        pod_id=$(jq -r '.pod_id // empty' "$POD_FILE" 2>/dev/null || true)
    fi

    if [ -z "$pod_id" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
        pod_id="$RUNPOD_POD_ID"
    fi

    echo "$pod_id"
}

# ============================================================================
# Cost Tracking (RunPod)
# ============================================================================

get_runpod_hourly_rate() {
    local gpu_type="${1:-${RUNPOD_GPU_TYPE:-}}"
    local cloud_type="${2:-${RUNPOD_CLOUD_TYPE:-COMMUNITY}}"

    # Community Cloud pricing (approximate)
    if [ "$cloud_type" = "COMMUNITY" ]; then
        case "$gpu_type" in
            *"RTX 3060"*) echo "0.10" ;;
            *"RTX 3070"*) echo "0.12" ;;
            *"RTX 3080"*) echo "0.14" ;;
            *"RTX 3090"*) echo "0.22" ;;
            *"RTX 4090"*) echo "0.34" ;;
            *"A40"*) echo "0.39" ;;
            *) echo "0.15" ;;
        esac
    else
        # Secure Cloud pricing (approximate)
        case "$gpu_type" in
            *"RTX 3060"*) echo "0.20" ;;
            *"RTX 3070"*) echo "0.24" ;;
            *"RTX 3080"*) echo "0.29" ;;
            *"RTX 3090"*) echo "0.44" ;;
            *"RTX 4090"*) echo "0.69" ;;
            *"A40"*) echo "0.79" ;;
            *) echo "0.30" ;;
        esac
    fi
}

# ============================================================================
# Self Test
# ============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "WhisperLive RunPod Common Functions Library v1.0.0"
    echo "==================================================="
    echo ""
    echo "Available functions:"
    echo "  - Logging: json_log, start_logging, get_log_file"
    echo "  - Environment: load_env_or_fail, update_env_file"
    echo "  - Utility: format_duration, print_status, wait_for_http_endpoint"
    echo "  - RunPod API:"
    echo "      runpod_api_call, get_runpod_pod_status, get_runpod_pod_details"
    echo "      get_runpod_pod_networking, create_runpod_pod"
    echo "      start_runpod_pod, stop_runpod_pod, terminate_runpod_pod"
    echo "      wait_for_runpod_pod, list_runpod_pods, get_runpod_pod_logs"
    echo "  - State: write_pod_state, get_pod_id"
    echo "  - Cost: get_runpod_hourly_rate"
    echo ""
    echo "To use in your script:"
    echo '  source "$(dirname "$0")/000-LIB--common-functions.sh"'
fi
