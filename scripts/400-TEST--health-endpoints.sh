#!/bin/bash
# =============================================================================
# Test WhisperLive Health Endpoints on RunPod
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Tests /health endpoint (liveness check)
#   2. Tests /ready endpoint (readiness check)
#   3. Tests /status endpoint (detailed status with GPU info)
#
# PREREQUISITES:
#   - Pod deployed to RunPod (run 300-RUNPOD--deploy-pod.sh first)
#
# Usage: ./scripts/400-TEST--health-endpoints.sh [--help]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="400-TEST--health-endpoints"
SCRIPT_VERSION="1.0.0"

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
echo "Testing WhisperLive Health Endpoints on RunPod"
echo "============================================================================"
echo ""

# ============================================================================
# Load environment
# ============================================================================
echo -e "${BLUE}[1/4] Loading environment...${NC}"

if ! load_env_or_fail; then
    exit 1
fi

POD_ID=$(get_pod_id)

if [ -z "$POD_ID" ]; then
    print_status "error" "No pod ID found. Deploy first with: ./scripts/300-RUNPOD--deploy-pod.sh"
    exit 1
fi

# Build proxy URLs
HEALTH_BASE_URL="https://${POD_ID}-9999.proxy.runpod.net"

print_status "ok" "Pod ID: $POD_ID"
echo "  Health URL: $HEALTH_BASE_URL"
echo ""

# ============================================================================
# Test /health endpoint
# ============================================================================
echo -e "${BLUE}[2/4] Testing /health endpoint (liveness)...${NC}"

HEALTH_URL="${HEALTH_BASE_URL}/health"
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null || echo -e "\n000")
HEALTH_BODY=$(echo "$HEALTH_RESPONSE" | head -n -1)
HEALTH_CODE=$(echo "$HEALTH_RESPONSE" | tail -n 1)

if [ "$HEALTH_CODE" = "200" ]; then
    print_status "ok" "Health check passed (HTTP $HEALTH_CODE)"
    echo "$HEALTH_BODY" | jq '.' 2>/dev/null || echo "$HEALTH_BODY"
else
    print_status "error" "Health check failed (HTTP $HEALTH_CODE)"
    echo "$HEALTH_BODY"
fi
echo ""

# ============================================================================
# Test /ready endpoint
# ============================================================================
echo -e "${BLUE}[3/4] Testing /ready endpoint (readiness)...${NC}"

READY_URL="${HEALTH_BASE_URL}/ready"
READY_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 "$READY_URL" 2>/dev/null || echo -e "\n000")
READY_BODY=$(echo "$READY_RESPONSE" | head -n -1)
READY_CODE=$(echo "$READY_RESPONSE" | tail -n 1)

if [ "$READY_CODE" = "200" ]; then
    print_status "ok" "Readiness check passed (HTTP $READY_CODE)"
    echo "$READY_BODY" | jq '.' 2>/dev/null || echo "$READY_BODY"
elif [ "$READY_CODE" = "503" ]; then
    print_status "warn" "Not ready yet (HTTP $READY_CODE) - WhisperLive may still be starting"
    echo "$READY_BODY" | jq '.' 2>/dev/null || echo "$READY_BODY"
else
    print_status "error" "Readiness check failed (HTTP $READY_CODE)"
    echo "$READY_BODY"
fi
echo ""

# ============================================================================
# Test /status endpoint
# ============================================================================
echo -e "${BLUE}[4/4] Testing /status endpoint (detailed status)...${NC}"

STATUS_URL="${HEALTH_BASE_URL}/status"
STATUS_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 "$STATUS_URL" 2>/dev/null || echo -e "\n000")
STATUS_BODY=$(echo "$STATUS_RESPONSE" | head -n -1)
STATUS_CODE=$(echo "$STATUS_RESPONSE" | tail -n 1)

if [ "$STATUS_CODE" = "200" ]; then
    print_status "ok" "Status check passed (HTTP $STATUS_CODE)"
    echo "$STATUS_BODY" | jq '.' 2>/dev/null || echo "$STATUS_BODY"

    # Extract and display key info
    echo ""
    echo "--- Parsed Status ---"
    GPU_NAME=$(echo "$STATUS_BODY" | jq -r '.gpu.name // "N/A"' 2>/dev/null)
    GPU_MEM=$(echo "$STATUS_BODY" | jq -r '.gpu.memory_used_mb // "N/A"' 2>/dev/null)
    GPU_TOTAL=$(echo "$STATUS_BODY" | jq -r '.gpu.memory_total_mb // "N/A"' 2>/dev/null)
    UPTIME=$(echo "$STATUS_BODY" | jq -r '.uptime_seconds // "N/A"' 2>/dev/null)
    WL_READY=$(echo "$STATUS_BODY" | jq -r '.whisperlive.ready // "N/A"' 2>/dev/null)

    echo "  GPU:            $GPU_NAME"
    echo "  GPU Memory:     ${GPU_MEM}MB / ${GPU_TOTAL}MB"
    echo "  Uptime:         ${UPTIME}s"
    echo "  WhisperLive:    $WL_READY"
else
    print_status "error" "Status check failed (HTTP $STATUS_CODE)"
    echo "$STATUS_BODY"
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "============================================================================"
if [ "$HEALTH_CODE" = "200" ] && [ "$READY_CODE" = "200" ]; then
    echo -e "${GREEN}All Health Checks Passed!${NC}"
    echo "============================================================================"
    echo ""
    echo "WhisperLive is ready to accept connections."
    echo ""
    echo "WebSocket URL: wss://${POD_ID}-9090.proxy.runpod.net"
    echo ""
    echo "Next Steps:"
    echo "  1. Test transcription: ./scripts/410-TEST--websocket-transcription.sh"
else
    echo -e "${YELLOW}Some Health Checks Failed${NC}"
    echo "============================================================================"
    echo ""
    echo "The pod may still be starting. Wait a minute and try again."
    echo ""
    echo "Check pod status: ./scripts/900-OPS--runpod-status.sh"
fi
echo ""
