#!/bin/bash
#===============================================================================
# 930-OPS--runpod-stop-terminate.sh
# Stop or permanently terminate your RunPod pod
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# By default: STOPS the pod (can be restarted later, no charges while stopped)
# With --terminate: PERMANENTLY DELETES the pod (cannot be recovered)
#
# IMPORTANT COST INFO:
# --------------------
# - STOPPED pods: No GPU charges, but volume storage still incurs small cost
# - TERMINATED pods: Completely removed, no ongoing charges
#
# WHAT YOU'LL SEE:
# ----------------
#   ============================================================================
#   Stopping RunPod Pod
#   ============================================================================
#
#   Pod ID: abc123xyz
#   Current status: RUNNING
#
#   Are you sure you want to stop the pod? (y/N) y
#
#   Stopping pod...
#   Waiting for pod to stop......
#
#   ============================================================================
#   Pod stopped successfully!
#   ============================================================================
#
#   The pod is stopped but can be restarted.
#   Note: You are NOT charged while the pod is stopped.
#
#   To restart: ./scripts/920-OPS--runpod-restart.sh
#
# USAGE:
#   ./scripts/930-OPS--runpod-stop-terminate.sh              # Stop (pause)
#   ./scripts/930-OPS--runpod-stop-terminate.sh --terminate  # Delete permanently
#   ./scripts/930-OPS--runpod-stop-terminate.sh --force      # Skip confirmation
#
# PREREQUISITES:
#   - .env configured with RUNPOD_API_KEY and RUNPOD_POD_ID
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="930-OPS--runpod-stop-terminate"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Default options
TERMINATE=false
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --terminate)
            TERMINATE=true
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --help|-h)
            head -18 "$0" | tail -13
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$TERMINATE" = true ]; then
    ACTION="Terminating"
    ACTION_PAST="terminated"
else
    ACTION="Stopping"
    ACTION_PAST="stopped"
fi

echo "============================================================================"
echo "$ACTION RunPod Pod"
echo "============================================================================"
echo ""

# Load environment
if ! load_env_or_fail; then
    exit 1
fi

POD_ID=$(get_pod_id)

if [ -z "$POD_ID" ]; then
    print_status "warn" "No pod found"
    exit 0
fi

# Get current status
CURRENT_STATUS=$(get_runpod_pod_status "$POD_ID" 2>/dev/null || echo "unknown")

echo "Pod ID: $POD_ID"
echo "Current status: $CURRENT_STATUS"
echo ""

# Check if already stopped/terminated
if [ "$CURRENT_STATUS" = "EXITED" ] || [ "$CURRENT_STATUS" = "STOPPED" ]; then
    if [ "$TERMINATE" = false ]; then
        print_status "ok" "Pod is already stopped"
        echo ""
        echo "To restart: ./scripts/920-OPS--runpod-restart.sh"
        echo "To terminate permanently: ./scripts/930-OPS--runpod-stop-terminate.sh --terminate"
        exit 0
    fi
fi

if [ "$CURRENT_STATUS" = "TERMINATED" ] || [ "$CURRENT_STATUS" = "unknown" ] || [ "$CURRENT_STATUS" = "error" ]; then
    print_status "warn" "Pod appears to be already terminated or not found"
    rm -f "$POD_FILE"
    exit 0
fi

# Confirmation
if [ "$FORCE" = false ]; then
    if [ "$TERMINATE" = true ]; then
        echo -e "${RED}WARNING: This will PERMANENTLY DELETE the pod.${NC}"
        echo "The pod cannot be recovered after termination."
        echo ""
    fi

    read -p "Are you sure you want to ${ACTION,,} the pod? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        exit 0
    fi
    echo ""
fi

# ============================================================================
# Stop or Terminate
# ============================================================================
echo -e "${BLUE}${ACTION} pod...${NC}"

if [ "$TERMINATE" = true ]; then
    if terminate_runpod_pod "$POD_ID" &>/dev/null; then
        print_status "ok" "Terminate command sent"
        # Remove local state
        rm -f "$POD_FILE"
        update_env_file "RUNPOD_POD_ID" ""
        update_env_file "RUNPOD_POD_IP" ""
        update_env_file "RUNPOD_WS_PORT" ""
        update_env_file "RUNPOD_HEALTH_PORT" ""
    else
        print_status "error" "Failed to terminate pod"
        exit 1
    fi
else
    if stop_runpod_pod "$POD_ID" &>/dev/null; then
        print_status "ok" "Stop command sent"
    else
        print_status "error" "Failed to stop pod"
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
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}Pod ${ACTION_PAST} successfully!${NC}"
echo "============================================================================"
echo ""

if [ "$TERMINATE" = true ]; then
    echo "The pod has been permanently deleted."
    echo ""
    echo "To deploy a new pod: ./scripts/300-RUNPOD--deploy-pod.sh"
else
    echo "The pod is stopped but can be restarted."
    echo "Note: You are NOT charged while the pod is stopped."
    echo ""
    echo "To restart: ./scripts/920-OPS--runpod-restart.sh"
    echo "To terminate permanently: ./scripts/930-OPS--runpod-stop-terminate.sh --terminate"
fi
echo ""
