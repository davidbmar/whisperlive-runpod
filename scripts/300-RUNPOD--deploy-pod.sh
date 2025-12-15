#!/bin/bash
# =============================================================================
# Deploy WhisperLive Pod to RunPod
# =============================================================================
#
# PLAIN ENGLISH:
#   This script deploys your WhisperLive container to RunPod's GPU cloud.
#   RunPod pulls your Docker image from Docker Hub and runs it on a GPU.
#   Once running, you get WebSocket and health check URLs.
#
#   IMPORTANT: Test on EC2 first! EC2 is cheaper for debugging (~$0.52/hr).
#   Only deploy to RunPod once EC2 tests pass.
#
# WHAT HAPPENS WHEN YOU RUN THIS:
#   1. Validates your RunPod API key and configuration
#   2. Creates a GPU pod via RunPod API
#   3. Waits for the pod to start running
#   4. Saves pod ID and connection URLs to .env and artifacts/
#   5. Shows you the WebSocket URL for connecting clients
#
# PREREQUISITES:
#   - .env configured (./scripts/010-SETUP--interactive-configuration.sh)
#   - Image pushed to Docker Hub (./scripts/110-BUILD--push-to-dockerhub.sh)
#   - Tested on EC2 first (./scripts/210-EC2--run-container-and-test.sh)
#
# COST: Depends on GPU selected (~$0.12-$0.40/hour for Community Cloud)
#
# Usage: ./scripts/300-RUNPOD--deploy-pod.sh [--slim]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="300-RUNPOD--deploy-pod"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Default options
SHOW_HELP=false
USE_SLIM=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --slim)
            USE_SLIM=true
            shift
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Set tag suffix based on variant
if [ "$USE_SLIM" = true ]; then
    TAG_SUFFIX="-slim"
else
    TAG_SUFFIX=""
fi

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    head -30 "$0" | tail -25
    exit 0
fi

echo "============================================================================"
echo "Deploying WhisperLive to RunPod"
echo "============================================================================"
echo ""

# ============================================================================
# [1/5] Load environment and validate
# ============================================================================
echo -e "${BLUE}[1/5] Loading environment and validating...${NC}"

if ! load_env_or_fail; then
    exit 1
fi

# Validate required variables
MISSING_VARS=""
for var in RUNPOD_API_KEY RUNPOD_POD_NAME DOCKER_HUB_USERNAME; do
    if [ -z "${!var:-}" ]; then
        MISSING_VARS="$MISSING_VARS $var"
    fi
done

if [ -n "$MISSING_VARS" ]; then
    print_status "error" "Missing required variables:$MISSING_VARS"
    echo "Run ./scripts/010-SETUP--interactive-configuration.sh to configure"
    exit 1
fi

print_status "ok" "Environment validated"
echo "  Pod Name:    ${RUNPOD_POD_NAME}"
echo "  GPU Type:    ${RUNPOD_GPU_TYPE:-NVIDIA GeForce RTX 3090}"
echo "  Cloud Type:  ${RUNPOD_CLOUD_TYPE:-COMMUNITY}"
echo "  Image:       ${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE:-whisperlive-runpod}:${DOCKER_TAG:-latest}${TAG_SUFFIX}"
if [ "$USE_SLIM" = true ]; then
    echo "  Variant:     slim (no diarization)"
fi
echo ""

# ============================================================================
# [2/5] Check for existing pod
# ============================================================================
echo -e "${BLUE}[2/5] Checking for existing pod...${NC}"

EXISTING_POD_ID=$(get_pod_id)

if [ -n "$EXISTING_POD_ID" ]; then
    EXISTING_STATUS=$(get_runpod_pod_status "$EXISTING_POD_ID" 2>/dev/null || echo "unknown")

    if [ "$EXISTING_STATUS" != "unknown" ] && [ "$EXISTING_STATUS" != "error" ]; then
        print_status "warn" "Existing pod found: $EXISTING_POD_ID (status: $EXISTING_STATUS)"
        echo ""
        echo "Options:"
        echo "  1. Terminate existing and create new pod"
        echo "  2. Cancel deployment"
        echo ""
        read -p "Choose option (1 or 2): " -n 1 -r
        echo

        if [[ $REPLY =~ ^1$ ]]; then
            echo "Terminating existing pod..."
            if terminate_runpod_pod "$EXISTING_POD_ID" &>/dev/null; then
                print_status "ok" "Terminated existing pod"
                rm -f "$POD_FILE"
                sleep 3
            else
                print_status "error" "Failed to terminate existing pod"
                exit 1
            fi
        else
            echo "Deployment cancelled"
            exit 0
        fi
    fi
else
    print_status "ok" "No existing pod found"
fi
echo ""

# ============================================================================
# [3/5] Prepare pod configuration
# ============================================================================
echo -e "${BLUE}[3/5] Preparing pod configuration...${NC}"

FULL_IMAGE="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE:-whisperlive-runpod}:${DOCKER_TAG:-latest}${TAG_SUFFIX}"

# Build GPU type list based on configured type
GPU_TYPE="${RUNPOD_GPU_TYPE:-NVIDIA GeForce RTX 3090}"

# Pod creation payload
POD_PAYLOAD=$(cat <<EOF
{
    "name": "${RUNPOD_POD_NAME}",
    "imageName": "docker.io/${FULL_IMAGE}",
    "gpuTypeIds": ["${GPU_TYPE}"],
    "gpuCount": ${RUNPOD_GPU_COUNT:-1},
    "cloudType": "${RUNPOD_CLOUD_TYPE:-COMMUNITY}",
    "containerDiskInGb": ${RUNPOD_CONTAINER_DISK_GB:-50},
    "volumeInGb": ${RUNPOD_VOLUME_GB:-20},
    "volumeMountPath": "/workspace",
    "ports": ["9090/http", "9999/http"],
    "idleTimeout": ${RUNPOD_IDLE_TIMEOUT:-600},
    "env": {
        "WHISPER_MODEL": "${WHISPER_MODEL:-small.en}",
        "WHISPER_COMPUTE_TYPE": "${WHISPER_COMPUTE_TYPE:-int8}",
        "WHISPERLIVE_PORT": "${WHISPERLIVE_PORT:-9090}",
        "HEALTH_CHECK_PORT": "${HEALTH_CHECK_PORT:-9999}",
        "MAX_CLIENTS": "${MAX_CLIENTS:-4}",
        "MAX_CONNECTION_TIME": "${MAX_CONNECTION_TIME:-600}",
        "LOG_FORMAT": "json",
        "LOG_LEVEL": "INFO"
    }
}
EOF
)

# Save spec to artifacts for debugging
SPEC_FILE="$ARTIFACTS_DIR/runpod-pod-spec.json"
echo "$POD_PAYLOAD" | jq '.' > "$SPEC_FILE"
print_status "ok" "Pod spec saved to: $SPEC_FILE"
echo ""

# ============================================================================
# [4/5] Create pod via API
# ============================================================================
echo -e "${BLUE}[4/5] Creating pod via RunPod API...${NC}"

RESPONSE=$(create_runpod_pod "$POD_PAYLOAD" 2>&1)
RESPONSE_FILE="$ARTIFACTS_DIR/runpod-create-response.json"
echo "$RESPONSE" > "$RESPONSE_FILE"

# Check for errors in response
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null)

if [ -n "$ERROR" ]; then
    print_status "error" "API error: $ERROR"
    echo "Full response saved to: $RESPONSE_FILE"
    exit 1
fi

# Extract pod ID
POD_ID=$(echo "$RESPONSE" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$POD_ID" ]; then
    print_status "error" "Could not get pod ID from response"
    echo "Response saved to: $RESPONSE_FILE"
    cat "$RESPONSE_FILE"
    exit 1
fi

# Update env file with pod ID
update_env_file "RUNPOD_POD_ID" "$POD_ID"
print_status "ok" "Pod created: $POD_ID"
echo ""

# ============================================================================
# [5/5] Wait for pod to be running
# ============================================================================
echo -e "${BLUE}[5/5] Waiting for pod to reach running state...${NC}"
echo ""
echo "Note: RunPod needs to allocate GPU and pull the image."
echo "      This typically takes 2-5 minutes."
echo ""

DEPLOY_START=$(date +%s)

# Set RUNPOD_POD_ID for wait function
export RUNPOD_POD_ID="$POD_ID"

if wait_for_runpod_pod 600; then
    DEPLOY_END=$(date +%s)
    DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))
    print_status "ok" "Pod running in $(format_duration $DEPLOY_DURATION)"
else
    print_status "error" "Pod did not reach running state"
    echo ""
    echo "Check status: ./scripts/900-OPS--runpod-status.sh"
    exit 1
fi
echo ""

# Get pod networking info
echo "Extracting networking information..."
sleep 5  # Give a moment for networking to be ready

POD_DETAILS=$(get_runpod_pod_details "$POD_ID")
DETAILS_FILE="$ARTIFACTS_DIR/runpod-pod-details.json"
echo "$POD_DETAILS" > "$DETAILS_FILE"

# Extract public IP and ports from runtime info
# RunPod uses proxy URLs in format: {pod_id}-{port}.proxy.runpod.net
POD_IP=$(echo "$POD_DETAILS" | jq -r '.runtime.ports[0].ip // empty' 2>/dev/null)

# For proxy access
WS_PROXY_URL="${POD_ID}-9090.proxy.runpod.net"
HEALTH_PROXY_URL="${POD_ID}-9999.proxy.runpod.net"

# Update env file
if [ -n "$POD_IP" ]; then
    update_env_file "RUNPOD_POD_IP" "$POD_IP"
fi
update_env_file "RUNPOD_WS_PORT" "9090"
update_env_file "RUNPOD_HEALTH_PORT" "9999"

# Save pod state
write_pod_state "$POD_ID" "RUNNING" "$POD_IP" "9090" "9999"

print_status "ok" "Networking information saved"
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}WhisperLive Deployed to RunPod!${NC}"
echo "============================================================================"
echo ""
echo "  Pod ID:       $POD_ID"
echo "  Pod Name:     ${RUNPOD_POD_NAME}"
echo "  GPU:          ${RUNPOD_GPU_TYPE}"
echo "  Cloud Type:   ${RUNPOD_CLOUD_TYPE}"
echo "  Deploy Time:  $(format_duration $DEPLOY_DURATION)"
echo ""
echo "Connection URLs (via RunPod Proxy):"
echo "  WebSocket:    wss://${WS_PROXY_URL}"
echo "  Health:       https://${HEALTH_PROXY_URL}/health"
echo "  Status:       https://${HEALTH_PROXY_URL}/status"
echo ""
if [ -n "$POD_IP" ]; then
    echo "Direct Connection (if TCP proxy enabled):"
    echo "  Pod IP:       $POD_IP"
fi
echo ""
echo "RunPod Console:"
echo "  https://www.runpod.io/console/pods"
echo ""
HOURLY_RATE=$(get_runpod_hourly_rate "${RUNPOD_GPU_TYPE}" "${RUNPOD_CLOUD_TYPE}")
echo "Estimated Cost: ~\$${HOURLY_RATE}/hour (${RUNPOD_CLOUD_TYPE})"
echo ""
echo "Next Steps:"
echo "  1. Test health:     ./scripts/400-TEST--health-endpoints.sh"
echo "  2. Check status:    ./scripts/900-OPS--runpod-status.sh"
echo "  3. Stop when done:  ./scripts/930-OPS--runpod-stop-terminate.sh"
echo ""
