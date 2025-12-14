#!/bin/bash
#===============================================================================
# 310-RUNPOD--wait-for-ready.sh
# Wait for RunPod pod to be fully ready and healthy
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Waits for your RunPod pod to be fully operational after deployment.
# "Running" status doesn't mean the container is ready - this script waits
# until the WhisperLive server is actually accepting connections.
#
# THE PROBLEM IT SOLVES:
# ----------------------
# After 300-RUNPOD--deploy-pod.sh creates a pod, it takes time for:
#   1. RunPod to allocate a GPU machine
#   2. Docker to pull the image (first time can take 2-5 min)
#   3. WhisperLive to load the Whisper model into GPU memory
#
# This script polls until /health returns HTTP 200, meaning you can connect.
#
# WHAT YOU'LL SEE:
# ----------------
#   [0s]   Status: RUNNING | GPU: NVIDIA RTX 3090 | Waiting for runtime...
#   [10s]  Status: RUNNING | GPU: NVIDIA RTX 3090 | Waiting for runtime...
#   [20s]  Status: RUNNING | GPU: NVIDIA RTX 3090 | Runtime: Ready!
#   Testing health endpoint: https://abc123-9999.proxy.runpod.net/health
#     Health check attempt 1: HTTP 200
#   Pod is fully ready!
#
# USAGE:
#   ./scripts/310-RUNPOD--wait-for-ready.sh
#   ./scripts/310-RUNPOD--wait-for-ready.sh --timeout 600
#
# PREREQUISITES:
#   - Pod deployed via 300-RUNPOD--deploy-pod.sh
#   - RUNPOD_POD_ID set in .env
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="310-RUNPOD--wait-for-ready"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Default timeout
TIMEOUT=300

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            head -40 "$0" | tail -35
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================================"
echo "Waiting for RunPod Pod to be Ready"
echo "============================================================================"
echo ""

# Load environment
echo -e "${BLUE}[1/3] Loading environment...${NC}"
if ! load_env_or_fail; then
    exit 1
fi

POD_ID="${RUNPOD_POD_ID:-}"
if [ -z "$POD_ID" ]; then
    print_status "error" "No pod ID found in .env"
    echo "Deploy a pod first: ./scripts/300-RUNPOD--deploy-pod.sh"
    exit 1
fi

print_status "ok" "Pod ID: $POD_ID"
echo ""

# Wait for health endpoint (this is the reliable way to check if container is ready)
# Note: The RunPod API "runtime" field is not reliably populated, so we skip
# directly to checking the health endpoint which tells us the container is actually running.
echo -e "${BLUE}[2/2] Waiting for container to be ready...${NC}"
echo "  Timeout: ${TIMEOUT}s"
echo ""

HEALTH_URL="https://${POD_ID}-9999.proxy.runpod.net/health"
echo "  Health URL: $HEALTH_URL"
echo ""

ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")

    if [ "$HEALTH_CODE" = "200" ]; then
        print_status "ok" "Health check passed (HTTP 200)"
        break
    fi

    echo "  [${ELAPSED}s] HTTP $HEALTH_CODE - waiting..."
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$HEALTH_CODE" != "200" ]; then
    print_status "warn" "Health endpoint not responding after ${TIMEOUT}s (HTTP $HEALTH_CODE)"
    echo "  Container may still be loading the model. Try again in a minute."
    echo "  Check logs: ./scripts/910-OPS--runpod-logs.sh"
    exit 1
fi
echo ""

# Get status details
echo -e "${BLUE}Fetching status details...${NC}"
STATUS_URL="https://${POD_ID}-9999.proxy.runpod.net/status"
STATUS_RESPONSE=$(curl -s --max-time 10 "$STATUS_URL" 2>/dev/null || echo "{}")

if [ -n "$STATUS_RESPONSE" ] && [ "$STATUS_RESPONSE" != "{}" ]; then
    GPU_NAME=$(echo "$STATUS_RESPONSE" | jq -r '.gpu.name // "unknown"')
    GPU_MEM=$(echo "$STATUS_RESPONSE" | jq -r '.gpu.memory_total_mb // 0')
    MODEL=$(echo "$STATUS_RESPONSE" | jq -r '.environment.WHISPER_MODEL // "unknown"')

    echo "  GPU: $GPU_NAME (${GPU_MEM}MB)"
    echo "  Model: $MODEL"
fi
echo ""

# Success summary
echo "============================================================================"
echo -e "${GREEN}RunPod Pod is Fully Ready!${NC}"
echo "============================================================================"
echo ""
echo "  Pod ID:       $POD_ID"
echo "  Ready in:     ${ELAPSED}s"
echo ""
echo "Connection URLs:"
echo "  WebSocket:    wss://${POD_ID}-9090.proxy.runpod.net"
echo "  Health:       https://${POD_ID}-9999.proxy.runpod.net/health"
echo "  Status:       https://${POD_ID}-9999.proxy.runpod.net/status"
echo ""
echo "Next Steps:"
echo "  Test health:    ./scripts/400-TEST--health-endpoints.sh --runpod"
echo "  Test transcribe: ./scripts/430-TEST--runpod-transcription.sh"
echo "  Check status:   ./scripts/900-OPS--runpod-status.sh"
echo ""
