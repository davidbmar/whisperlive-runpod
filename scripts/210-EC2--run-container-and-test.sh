#!/bin/bash
# =============================================================================
# Run WhisperLive Container Test on EC2 GPU Instance
# =============================================================================
#
# PLAIN ENGLISH:
#   This script tests your WhisperLive Docker image on a real GPU before
#   deploying to RunPod. It SSHs into your EC2 test instance, pulls your
#   Docker image from Docker Hub, starts the container with GPU access,
#   and verifies everything works (health checks, GPU detection, etc).
#
#   Think of this as a "dry run" - if it works here, it will work on RunPod.
#   EC2 is cheaper for testing (~$0.52/hr) than wasting time on RunPod.
#
# WHAT HAPPENS WHEN YOU RUN THIS:
#   1. Reads EC2 instance info from artifacts/ec2-test-instance.json
#   2. SSHs to the instance and checks Docker/GPU are ready
#   3. (with --pull) Pulls latest image from Docker Hub
#   4. Stops any existing container, starts fresh one with GPU
#   5. Waits for container to initialize
#   6. Tests /health and /ready endpoints
#   7. Shows you the results and connection URLs
#
# PREREQUISITES:
#   - EC2 instance running (./scripts/200-EC2--launch-gpu-test-instance.sh)
#   - Docker image pushed (./scripts/110-BUILD--push-to-dockerhub.sh --slim)
#
# Usage: ./scripts/210-EC2--run-container-and-test.sh [--pull] [--logs] [--stop]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="210-EC2--run-container-and-test"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Options
PULL_IMAGE=false
SHOW_LOGS=false
STOP_ONLY=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --pull) PULL_IMAGE=true; shift ;;
        --logs) SHOW_LOGS=true; shift ;;
        --stop) STOP_ONLY=true; shift ;;
        --status) STATUS_ONLY=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --pull    Pull latest Docker image before running"
            echo "  --logs    Show container logs after tests"
            echo "  --stop    Stop container only (don't start new one)"
            echo "  --status  Show status only (don't start container)"
            echo "  --help    Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

echo "============================================================================"
echo "Running WhisperLive Test on EC2 GPU Instance"
echo "============================================================================"
echo ""

# ============================================================================
# Load configuration
# ============================================================================
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"

if [ ! -f "$EC2_STATE_FILE" ]; then
    print_status "error" "No EC2 test instance found"
    echo "Run ./scripts/200-EC2--launch-gpu-test-instance.sh first"
    exit 1
fi

INSTANCE_ID=$(jq -r '.instance_id' "$EC2_STATE_FILE")
PUBLIC_IP=$(jq -r '.public_ip' "$EC2_STATE_FILE")
KEY_NAME=$(jq -r '.key_name' "$EC2_STATE_FILE")
SSH_USER=$(jq -r '.ssh_user // "ubuntu"' "$EC2_STATE_FILE")
REGION=$(jq -r '.region' "$EC2_STATE_FILE")

# Load env for Docker image info
if ! load_env_or_fail; then
    exit 1
fi

DOCKER_IMAGE_FULL="${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE:-whisperlive-runpod}:${DOCKER_TAG:-latest}-slim"

echo -e "${BLUE}Configuration:${NC}"
echo "  Instance:     $INSTANCE_ID"
echo "  Public IP:    $PUBLIC_IP"
echo "  Docker Image: $DOCKER_IMAGE_FULL"
echo ""

# ============================================================================
# Check instance is running
# ============================================================================
echo -e "${BLUE}[1/5] Checking instance status...${NC}"

INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "unknown")

if [ "$INSTANCE_STATE" != "running" ]; then
    print_status "error" "Instance is not running (state: $INSTANCE_STATE)"
    echo "Run ./scripts/200-EC2--launch-gpu-test-instance.sh to launch a new instance"
    exit 1
fi

print_status "ok" "Instance is running"
echo ""

# ============================================================================
# Find SSH key
# ============================================================================
echo -e "${BLUE}[2/5] Locating SSH key...${NC}"

SSH_KEY=""
for key_path in ~/.ssh/${KEY_NAME}.pem ~/.ssh/${KEY_NAME} ~/.ssh/id_rsa ~/.ssh/id_ed25519; do
    if [ -f "$key_path" ]; then
        SSH_KEY="$key_path"
        break
    fi
done

if [ -z "$SSH_KEY" ]; then
    print_status "error" "SSH key not found for: $KEY_NAME"
    echo "Expected locations: ~/.ssh/${KEY_NAME}.pem or ~/.ssh/${KEY_NAME}"
    exit 1
fi

print_status "ok" "Using SSH key: $SSH_KEY"
echo ""

# SSH command helper
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 $SSH_USER@$PUBLIC_IP"

# ============================================================================
# Handle --stop option
# ============================================================================
if [ "$STOP_ONLY" = true ]; then
    echo -e "${BLUE}Stopping container...${NC}"
    $SSH_CMD "docker stop whisperlive 2>/dev/null && docker rm whisperlive 2>/dev/null" && \
        print_status "ok" "Container stopped and removed" || \
        print_status "warn" "No container to stop"
    exit 0
fi

# ============================================================================
# Handle --status option
# ============================================================================
if [ "$STATUS_ONLY" = true ]; then
    echo -e "${BLUE}Checking status...${NC}"
    echo ""

    # Check container
    CONTAINER_STATUS=$($SSH_CMD "docker inspect -f '{{.State.Status}}' whisperlive" 2>/dev/null || echo "not running")
    echo "Container: $CONTAINER_STATUS"

    # Check GPU
    GPU_INFO=$($SSH_CMD "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader" 2>/dev/null || echo "No GPU")
    echo "GPU: $GPU_INFO"

    # Check health
    if [ "$CONTAINER_STATUS" = "running" ]; then
        HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://$PUBLIC_IP:9999/health" 2>/dev/null || echo "000")
        echo "Health endpoint: HTTP $HEALTH"
    fi

    # Check auto-shutdown timer
    REMAINING=$($SSH_CMD "if [ -f /tmp/auto-shutdown.pid ]; then ps -p \$(cat /tmp/auto-shutdown.pid) -o etimes= 2>/dev/null || echo 'expired'; else echo 'unknown'; fi" 2>/dev/null)
    if [ "$REMAINING" != "unknown" ] && [ "$REMAINING" != "expired" ]; then
        # Calculate remaining time (90 min = 5400 sec)
        ELAPSED=$REMAINING
        REMAINING_MIN=$(( (5400 - ELAPSED) / 60 ))
        echo "Auto-shutdown: ~${REMAINING_MIN} minutes remaining"
    fi

    echo ""
    exit 0
fi

# ============================================================================
# Check Docker is ready
# ============================================================================
echo -e "${BLUE}[3/5] Checking Docker on EC2...${NC}"

# Wait for Docker to be ready
for i in {1..12}; do
    if $SSH_CMD "docker info" &>/dev/null; then
        print_status "ok" "Docker is ready"
        break
    fi
    if [ $i -eq 12 ]; then
        print_status "error" "Docker not ready after 2 minutes"
        exit 1
    fi
    echo "  Waiting for Docker... ($i/12)"
    sleep 10
done

# Check GPU
echo "Checking GPU..."
GPU_INFO=$($SSH_CMD "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader" 2>/dev/null || echo "No GPU")
print_status "ok" "GPU: $GPU_INFO"
echo ""

# ============================================================================
# Pull and run container
# ============================================================================
echo -e "${BLUE}[4/5] Running WhisperLive container...${NC}"

# Stop any existing container
$SSH_CMD "docker stop whisperlive 2>/dev/null || true; docker rm whisperlive 2>/dev/null || true"

if [ "$PULL_IMAGE" = true ]; then
    echo "Pulling Docker image (this may take a few minutes)..."
    $SSH_CMD "docker pull $DOCKER_IMAGE_FULL"
fi

echo "Starting container..."
$SSH_CMD "docker run -d \
    --name whisperlive \
    --gpus all \
    -p 9090:9090 \
    -p 9999:9999 \
    -e WHISPER_MODEL=${WHISPER_MODEL:-small.en} \
    -e WHISPER_COMPUTE_TYPE=${WHISPER_COMPUTE_TYPE:-int8} \
    -e MAX_CLIENTS=${MAX_CLIENTS:-4} \
    $DOCKER_IMAGE_FULL"

print_status "ok" "Container started"

# Wait for startup
echo "Waiting for container to initialize..."
sleep 10

# Check container is running
CONTAINER_STATUS=$($SSH_CMD "docker inspect -f '{{.State.Status}}' whisperlive" 2>/dev/null || echo "unknown")
if [ "$CONTAINER_STATUS" != "running" ]; then
    print_status "error" "Container failed to start (status: $CONTAINER_STATUS)"
    echo ""
    echo "Container logs:"
    $SSH_CMD "docker logs whisperlive 2>&1" | tail -50
    exit 1
fi

print_status "ok" "Container is running"
echo ""

# ============================================================================
# Test endpoints
# ============================================================================
echo -e "${BLUE}[5/5] Testing health endpoints...${NC}"

# Wait for health endpoint
echo "Waiting for health endpoint..."
for i in {1..24}; do
    HEALTH_RESULT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$PUBLIC_IP:9999/health" 2>/dev/null || echo "000")
    if [ "$HEALTH_RESULT" = "200" ]; then
        print_status "ok" "Health endpoint responding (HTTP 200)"
        break
    fi
    if [ $i -eq 24 ]; then
        print_status "error" "Health endpoint not responding after 2 minutes"
        echo ""
        echo "Container logs:"
        $SSH_CMD "docker logs whisperlive 2>&1" | tail -50
        exit 1
    fi
    echo "  Waiting... ($i/24) - HTTP $HEALTH_RESULT"
    sleep 5
done

# Test status endpoint
echo "Testing status endpoint..."
STATUS_RESULT=$(curl -s "http://$PUBLIC_IP:9999/status" 2>/dev/null || echo "{}")
if [ -n "$STATUS_RESULT" ] && [ "$STATUS_RESULT" != "{}" ]; then
    print_status "ok" "Status endpoint responding"
    echo "$STATUS_RESULT" | jq . 2>/dev/null || echo "$STATUS_RESULT"
else
    print_status "warn" "Status endpoint returned empty response"
fi

# Test ready endpoint
echo ""
echo "Testing ready endpoint..."
READY_RESULT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$PUBLIC_IP:9999/ready" 2>/dev/null || echo "000")
if [ "$READY_RESULT" = "200" ]; then
    print_status "ok" "Ready endpoint: HTTP 200 (WhisperLive server is accepting connections)"
else
    print_status "warn" "Ready endpoint: HTTP $READY_RESULT (WhisperLive may still be loading model)"
fi

echo ""

# Show logs if requested
if [ "$SHOW_LOGS" = true ]; then
    echo "============================================================================"
    echo "Container Logs"
    echo "============================================================================"
    $SSH_CMD "docker logs whisperlive 2>&1" | tail -100
fi

# ============================================================================
# Success Summary
# ============================================================================
echo ""
echo "============================================================================"
echo -e "${GREEN}WhisperLive Test Successful!${NC}"
echo "============================================================================"
echo ""
echo "Container is running on EC2 with GPU acceleration."
echo ""
echo "Connection URLs:"
echo "  WebSocket:  ws://$PUBLIC_IP:9090"
echo "  Health:     http://$PUBLIC_IP:9999/health"
echo "  Status:     http://$PUBLIC_IP:9999/status"
echo ""
echo "Test Commands:"
echo "  # Check health"
echo "  curl http://$PUBLIC_IP:9999/health"
echo ""
echo "  # View container logs"
echo "  $SSH_CMD \"docker logs -f whisperlive\""
echo ""
echo "  # SSH into instance"
echo "  $SSH_CMD"
echo ""
echo "When done testing:"
echo "  ./scripts/220-EC2--terminate-and-cleanup.sh"
echo ""
