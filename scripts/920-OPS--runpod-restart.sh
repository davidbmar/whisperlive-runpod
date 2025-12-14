#!/bin/bash
#===============================================================================
# 920-OPS--runpod-restart.sh
# Restart your RunPod pod
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Gracefully restarts your RunPod pod by stopping and starting it.
# This is useful when:
#   - The container is in a bad state
#   - You want to reload the model
#   - You've updated the Docker image and want to pull the latest
#
# WHAT YOU'LL SEE:
# ----------------
#   ============================================================================
#   Restarting RunPod Pod
#   ============================================================================
#
#   Pod ID: abc123xyz
#   Current status: RUNNING
#
#   [1/3] Stopping pod...
#   Waiting for pod to stop......
#   Pod stopped
#
#   [2/3] Starting pod...
#   Start command sent
#
#   [3/3] Waiting for pod to be running...
#   Pod is running
#
#   ============================================================================
#   Pod Restarted Successfully!
#   ============================================================================
#
# USAGE:
#   ./scripts/920-OPS--runpod-restart.sh
#
# PREREQUISITES:
#   - .env configured with RUNPOD_API_KEY and RUNPOD_POD_ID
#   - Pod must exist (can be running or stopped)
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="920-OPS--runpod-restart"

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
echo "Restarting RunPod Pod"
echo "============================================================================"
echo ""

# Load environment
if ! load_env_or_fail; then
    exit 1
fi

POD_ID=$(get_pod_id)

if [ -z "$POD_ID" ]; then
    print_status "error" "No pod found to restart"
    echo "Deploy with: ./scripts/300-RUNPOD--deploy-pod.sh"
    exit 1
fi

echo "Pod ID: $POD_ID"
echo ""

# Get current status
CURRENT_STATUS=$(get_runpod_pod_status "$POD_ID" 2>/dev/null || echo "unknown")
echo "Current status: $CURRENT_STATUS"
echo ""

# ============================================================================
# Stop pod
# ============================================================================
echo -e "${BLUE}[1/3] Stopping pod...${NC}"

if [ "$CURRENT_STATUS" = "RUNNING" ]; then
    if stop_runpod_pod "$POD_ID" &>/dev/null; then
        print_status "ok" "Stop command sent"
    else
        print_status "error" "Failed to send stop command"
        exit 1
    fi

    # Wait for stop
    echo -n "Waiting for pod to stop"
    for i in {1..30}; do
        sleep 2
        echo -n "."
        STATUS=$(get_runpod_pod_status "$POD_ID" 2>/dev/null || echo "unknown")
        if [ "$STATUS" = "EXITED" ] || [ "$STATUS" = "STOPPED" ]; then
            break
        fi
    done
    echo ""
    print_status "ok" "Pod stopped"
else
    print_status "ok" "Pod already stopped"
fi
echo ""

# ============================================================================
# Start pod
# ============================================================================
echo -e "${BLUE}[2/3] Starting pod...${NC}"

if start_runpod_pod "$POD_ID" &>/dev/null; then
    print_status "ok" "Start command sent"
else
    print_status "error" "Failed to send start command"
    exit 1
fi
echo ""

# ============================================================================
# Wait for running
# ============================================================================
echo -e "${BLUE}[3/3] Waiting for pod to be running...${NC}"

export RUNPOD_POD_ID="$POD_ID"

if wait_for_runpod_pod 300; then
    print_status "ok" "Pod is running"
else
    print_status "error" "Pod did not reach running state"
    exit 1
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}Pod Restarted Successfully!${NC}"
echo "============================================================================"
echo ""
echo "Pod ID: $POD_ID"
echo ""
echo "Connection URLs:"
echo "  WebSocket:    wss://${POD_ID}-9090.proxy.runpod.net"
echo "  Health:       https://${POD_ID}-9999.proxy.runpod.net/health"
echo ""
echo "Next Steps:"
echo "  Check health: ./scripts/400-TEST--health-endpoints.sh"
echo "  View status:  ./scripts/900-OPS--runpod-status.sh"
echo ""
