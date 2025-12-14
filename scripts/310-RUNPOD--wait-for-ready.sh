#!/bin/bash
# Wait for RunPod pod to be fully ready

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"

# Load environment
if ! load_env_or_fail 2>/dev/null; then
    echo "No .env file found"
    exit 1
fi

POD_ID="${RUNPOD_POD_ID:-}"
if [ -z "$POD_ID" ]; then
    echo "No pod ID found in .env"
    exit 1
fi

echo "Waiting for pod $POD_ID to be fully ready..."
echo ""

TIMEOUT=300
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    RESPONSE=$(curl -s -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        "https://rest.runpod.io/v1/pods/${POD_ID}")

    STATUS=$(echo "$RESPONSE" | jq -r '.desiredStatus // "unknown"')
    MACHINE=$(echo "$RESPONSE" | jq -r '.machine.gpuDisplayName // empty')
    RUNTIME=$(echo "$RESPONSE" | jq -r '.runtime // empty')

    echo -n "[$ELAPSED s] Status: $STATUS"

    if [ -n "$MACHINE" ]; then
        echo -n " | GPU: $MACHINE"
    fi

    if [ -n "$RUNTIME" ] && [ "$RUNTIME" != "null" ]; then
        echo " | Runtime: Ready!"
        echo ""
        echo "Pod is fully running!"
        echo ""

        # Try the health endpoint
        HEALTH_URL="https://${POD_ID}-9999.proxy.runpod.net/health"
        echo "Testing health endpoint: $HEALTH_URL"

        for i in {1..10}; do
            HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null || echo "000")
            if [ "$HEALTH_CODE" = "200" ]; then
                echo "Health check passed! (HTTP 200)"
                echo ""
                echo "WebSocket URL: wss://${POD_ID}-9090.proxy.runpod.net"
                exit 0
            fi
            echo "  Health check attempt $i: HTTP $HEALTH_CODE (waiting...)"
            sleep 5
        done

        echo "Health endpoint not responding yet. Container may still be loading model."
        exit 0
    fi

    echo ""
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "Timeout waiting for pod to be ready"
exit 1
