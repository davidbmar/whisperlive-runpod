#!/bin/bash
#===============================================================================
# 910-OPS--runpod-logs.sh
# View RunPod pod logs and status information
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Shows you how to access container logs from your RunPod pod.
# Note: RunPod's REST API doesn't provide direct log streaming, so this
# script shows you the available options and fetches status info.
#
# WHAT YOU'LL SEE:
# ----------------
#   Pod ID: abc123xyz
#   Status: RUNNING
#
#   How to Access Logs:
#   1. RunPod Web Console (Recommended):
#      https://www.runpod.io/console/pods
#
#   2. Via Health Check Status Endpoint:
#      curl -s https://abc123xyz-9999.proxy.runpod.net/status | jq
#
#   --- Current Status ---
#   {
#     "status": "healthy",
#     "uptime_seconds": 3600,
#     "gpu": { "name": "NVIDIA RTX 3090", ... }
#   }
#
# USAGE:
#   ./scripts/910-OPS--runpod-logs.sh
#
# PREREQUISITES:
#   - .env configured with RUNPOD_API_KEY and RUNPOD_POD_ID
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="910-OPS--runpod-logs"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
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

echo "============================================================================"
echo "RunPod Pod Logs"
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

# Check pod status
STATUS=$(get_runpod_pod_status "$POD_ID" 2>/dev/null || echo "unknown")

echo "Pod ID: $POD_ID"
echo "Status: $STATUS"
echo ""

echo "============================================================================"
echo "How to Access Logs"
echo "============================================================================"
echo ""
echo "1. RunPod Web Console (Recommended):"
echo "   https://www.runpod.io/console/pods"
echo "   - Click on your pod"
echo "   - Select 'Logs' tab"
echo ""
echo "2. Via SSH (if SSH port exposed):"
echo "   ssh root@<pod-ip> -p <ssh-port>"
echo "   docker logs whisperlive  # or container name"
echo ""
echo "3. Via Health Check Status Endpoint:"
echo "   The /status endpoint provides runtime info:"
echo ""

# Try to get status info
if [ "$STATUS" = "RUNNING" ]; then
    HEALTH_URL="https://${POD_ID}-9999.proxy.runpod.net"
    echo "   curl -s ${HEALTH_URL}/status | jq"
    echo ""

    echo "Fetching current status..."
    STATUS_RESPONSE=$(curl -s --max-time 10 "${HEALTH_URL}/status" 2>/dev/null || echo "{}")

    if [ -n "$STATUS_RESPONSE" ] && [ "$STATUS_RESPONSE" != "{}" ]; then
        echo ""
        echo "--- Current Status ---"
        echo "$STATUS_RESPONSE" | jq '.' 2>/dev/null || echo "$STATUS_RESPONSE"
    fi
fi
echo ""

# Open console if xdg-open is available
if command -v xdg-open &>/dev/null; then
    echo ""
    read -p "Open RunPod console in browser? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        xdg-open "https://www.runpod.io/console/pods" &>/dev/null &
    fi
fi
