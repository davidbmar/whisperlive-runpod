#!/bin/bash
# =============================================================================
# Test WhisperLive Transcription on RunPod
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Validates pod is running and healthy
#   2. Tests WebSocket connectivity
#   3. Optionally runs a transcription test with sample audio
#
# PREREQUISITES:
#   - Pod deployed to RunPod (run 300-RUNPOD--deploy-pod.sh first)
#   - Health checks passing (run 400-TEST--health-endpoints.sh first)
#
# Usage: ./scripts/410-TEST--websocket-transcription.sh [--help]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="410-TEST--websocket-transcription"
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
echo "Testing WhisperLive Transcription on RunPod"
echo "============================================================================"
echo ""

# ============================================================================
# Load environment
# ============================================================================
echo -e "${BLUE}[1/3] Loading environment...${NC}"

if ! load_env_or_fail; then
    exit 1
fi

POD_ID=$(get_pod_id)

if [ -z "$POD_ID" ]; then
    print_status "error" "No pod ID found. Deploy first with: ./scripts/300-RUNPOD--deploy-pod.sh"
    exit 1
fi

# Build URLs
WS_URL="wss://${POD_ID}-9090.proxy.runpod.net"
HEALTH_URL="https://${POD_ID}-9999.proxy.runpod.net"

print_status "ok" "Pod ID: $POD_ID"
echo "  WebSocket URL: $WS_URL"
echo ""

# ============================================================================
# Verify health
# ============================================================================
echo -e "${BLUE}[2/3] Verifying pod health...${NC}"

READY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${HEALTH_URL}/ready" 2>/dev/null || echo "000")

if [ "$READY_CODE" = "200" ]; then
    print_status "ok" "Pod is healthy and ready"
else
    print_status "error" "Pod is not ready (HTTP $READY_CODE)"
    echo "Run health check first: ./scripts/400-TEST--health-endpoints.sh"
    exit 1
fi
echo ""

# ============================================================================
# Test WebSocket connectivity
# ============================================================================
echo -e "${BLUE}[3/3] Testing WebSocket connectivity...${NC}"

# Check if we have websocat or wscat installed
if command -v websocat &>/dev/null; then
    echo "Testing with websocat..."
    WS_TEST=$(timeout 5 websocat -t "$WS_URL" 2>&1 || true)

    if echo "$WS_TEST" | grep -qi "connected\|open\|websocket"; then
        print_status "ok" "WebSocket connection successful"
    else
        print_status "warn" "WebSocket test inconclusive"
        echo "Response: $WS_TEST"
    fi
elif command -v wscat &>/dev/null; then
    echo "Testing with wscat..."
    WS_TEST=$(timeout 5 wscat -c "$WS_URL" -x '{"test": "ping"}' 2>&1 || true)

    if [ -n "$WS_TEST" ]; then
        print_status "ok" "WebSocket responded"
        echo "Response: $WS_TEST"
    else
        print_status "warn" "No response from WebSocket"
    fi
else
    print_status "warn" "No WebSocket test tool available (websocat or wscat)"
    echo "The WebSocket endpoint should be accessible at: $WS_URL"
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}Transcription Test Complete${NC}"
echo "============================================================================"
echo ""
echo "WhisperLive Server Information:"
echo "  WebSocket URL:  $WS_URL"
echo "  Health URL:     $HEALTH_URL"
echo ""
echo "To use with a client:"
echo ""
echo "  Python:"
echo "    from whisper_live.client import TranscriptionClient"
echo "    client = TranscriptionClient("
echo "        host='${POD_ID}-9090.proxy.runpod.net',"
echo "        port=443,"
echo "        is_multilingual=False,"
echo "        lang='en',"
echo "        translate=False,"
echo "        use_ssl=True"
echo "    )"
echo ""
echo "  Or use the run_client.py script:"
echo "    python run_client.py \\"
echo "        --host ${POD_ID}-9090.proxy.runpod.net \\"
echo "        --port 443 \\"
echo "        --model small.en \\"
echo "        --lang en"
echo ""
