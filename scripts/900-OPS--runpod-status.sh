#!/bin/bash
#===============================================================================
# 900-OPS--runpod-status.sh
# Show detailed RunPod pod status
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Queries the RunPod API and health endpoints to show you:
#   - Pod state (RUNNING, STOPPED, EXITED)
#   - GPU type and allocation
#   - Container health and WhisperLive readiness
#   - Connection URLs
#   - Estimated costs
#
# WHAT YOU'LL SEE:
# ----------------
#   ============================================================================
#   RunPod Pod Status
#   ============================================================================
#
#   --- Pod Information ---
#     Status:         RUNNING
#     Pod ID:         abc123xyz
#     GPU Type:       NVIDIA GeForce RTX 3090
#
#   --- Health Status ---
#     Liveness:       Healthy
#     Readiness:      Ready
#
#   --- Connection URLs ---
#     WebSocket:      wss://abc123xyz-9090.proxy.runpod.net
#     Health Check:   https://abc123xyz-9999.proxy.runpod.net/health
#
# USAGE:
#   ./scripts/900-OPS--runpod-status.sh        # Show status
#   ./scripts/900-OPS--runpod-status.sh --help # Show help
#
# PREREQUISITES:
#   - .env configured with RUNPOD_API_KEY and RUNPOD_POD_ID
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="900-OPS--runpod-status"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            head -15 "$0" | tail -10
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================================"
echo "RunPod Pod Status"
echo "============================================================================"
echo ""

# Load environment
if ! load_env_or_fail 2>/dev/null; then
    print_status "error" "Configuration not found. Run: ./scripts/010-SETUP--interactive-configuration.sh"
    exit 1
fi

POD_ID=$(get_pod_id)

if [ -z "$POD_ID" ]; then
    print_status "warn" "No pod deployed"
    echo ""
    echo "Deploy with: ./scripts/300-RUNPOD--deploy-pod.sh"
    exit 0
fi

echo "Fetching pod status..."
echo ""

# Get pod details
POD_DETAILS=$(get_runpod_pod_details "$POD_ID" 2>/dev/null)

if [ -z "$POD_DETAILS" ] || echo "$POD_DETAILS" | jq -e '.error' &>/dev/null; then
    print_status "error" "Could not get pod details"
    echo "Pod ID: $POD_ID"
    echo ""
    echo "The pod may have been terminated. Check RunPod console:"
    echo "  https://www.runpod.io/console/pods"
    exit 1
fi

# Parse pod details
STATUS=$(echo "$POD_DETAILS" | jq -r '.desiredStatus // "unknown"')
POD_NAME=$(echo "$POD_DETAILS" | jq -r '.name // "unknown"')
GPU_TYPE=$(echo "$POD_DETAILS" | jq -r '.machine.gpuDisplayName // .gpuId // "unknown"')
GPU_COUNT=$(echo "$POD_DETAILS" | jq -r '.gpuCount // 1')
VCPU=$(echo "$POD_DETAILS" | jq -r '.vcpuCount // "N/A"')
MEMORY=$(echo "$POD_DETAILS" | jq -r '.memoryInGb // "N/A"')
CONTAINER_DISK=$(echo "$POD_DETAILS" | jq -r '.containerDiskInGb // "N/A"')
VOLUME_SIZE=$(echo "$POD_DETAILS" | jq -r '.volumeInGb // "N/A"')

# Display status with color
case "$STATUS" in
    "RUNNING")
        STATUS_COLOR="${GREEN}$STATUS${NC}"
        ;;
    "EXITED"|"TERMINATED")
        STATUS_COLOR="${RED}$STATUS${NC}"
        ;;
    *)
        STATUS_COLOR="${YELLOW}$STATUS${NC}"
        ;;
esac

echo "--- Pod Information ---"
echo -e "  Status:         $STATUS_COLOR"
echo "  Pod ID:         $POD_ID"
echo "  Pod Name:       $POD_NAME"
echo ""
echo "--- GPU & Resources ---"
echo "  GPU Type:       $GPU_TYPE"
echo "  GPU Count:      $GPU_COUNT"
echo "  vCPU:           $VCPU"
echo "  Memory:         ${MEMORY}GB"
echo "  Container Disk: ${CONTAINER_DISK}GB"
echo "  Volume:         ${VOLUME_SIZE}GB"
echo ""

# Connection info (if running)
if [ "$STATUS" = "RUNNING" ]; then
    WS_URL="wss://${POD_ID}-9090.proxy.runpod.net"
    HEALTH_URL="https://${POD_ID}-9999.proxy.runpod.net"

    echo "--- Connection URLs ---"
    echo "  WebSocket:      $WS_URL"
    echo "  Health Check:   ${HEALTH_URL}/health"
    echo "  Status:         ${HEALTH_URL}/status"
    echo ""

    # Get current health
    echo "--- Health Status ---"
    HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${HEALTH_URL}/health" 2>/dev/null || echo "000")
    READY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${HEALTH_URL}/ready" 2>/dev/null || echo "000")

    if [ "$HEALTH_CODE" = "200" ]; then
        echo -e "  Liveness:       ${GREEN}Healthy${NC}"
    else
        echo -e "  Liveness:       ${RED}Unhealthy (HTTP $HEALTH_CODE)${NC}"
    fi

    if [ "$READY_CODE" = "200" ]; then
        echo -e "  Readiness:      ${GREEN}Ready${NC}"
    else
        echo -e "  Readiness:      ${YELLOW}Not Ready (HTTP $READY_CODE)${NC}"
    fi
    echo ""
fi

# Cost estimate
HOURLY_RATE=$(get_runpod_hourly_rate "$GPU_TYPE" "${RUNPOD_CLOUD_TYPE:-COMMUNITY}")
echo "--- Cost Estimate ---"
echo "  Hourly Rate:    \$${HOURLY_RATE}/hour (${RUNPOD_CLOUD_TYPE:-COMMUNITY})"
echo ""

echo "--- Management ---"
echo "  RunPod Console: https://www.runpod.io/console/pods"
echo ""
echo "Commands:"
echo "  Health check:   ./scripts/400-TEST--health-endpoints.sh"
echo "  Restart pod:    ./scripts/920-OPS--runpod-restart.sh"
echo "  Stop pod:       ./scripts/930-OPS--runpod-stop-terminate.sh"
echo ""
