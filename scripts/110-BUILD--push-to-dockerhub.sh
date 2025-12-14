#!/bin/bash
# =============================================================================
# Push WhisperLive Docker Image to Docker Hub
# =============================================================================
#
# PLAIN ENGLISH:
#   This script uploads your Docker image to Docker Hub so that EC2 and
#   RunPod can download it. Think of Docker Hub as a cloud storage for
#   Docker images - you push once, pull from anywhere.
#
#   Before pushing, it verifies the image has all required packages
#   (PyTorch, faster_whisper) so you don't push a broken image.
#
# WHAT HAPPENS WHEN YOU RUN THIS:
#   1. Verifies the image exists locally
#   2. Checks that PyTorch and faster_whisper are installed (won't push broken image)
#   3. Logs into Docker Hub with your credentials
#   4. Pushes the image (uploads to cloud)
#
# PREREQUISITES:
#   - Docker image built (./scripts/100-BUILD--docker-image-local.sh --slim)
#   - Docker Hub account
#   - DOCKER_PASSWORD set: export DOCKER_PASSWORD='your-token'
#
# Usage: ./scripts/110-BUILD--push-to-dockerhub.sh [--slim]
#
# Options:
#   --slim    Push slim image variant (recommended)
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="110-BUILD--push-to-dockerhub"
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
    head -25 "$0" | tail -20
    exit 0
fi

echo "============================================================================"
echo "Pushing WhisperLive Docker Image to Docker Hub"
echo "============================================================================"
echo ""

# ============================================================================
# [1/3] Load environment and validate
# ============================================================================
echo -e "${BLUE}[1/3] Loading environment and validating...${NC}"

if ! load_env_or_fail; then
    exit 1
fi

# Check Docker Hub username
if [ -z "${DOCKER_HUB_USERNAME:-}" ]; then
    print_status "error" "DOCKER_HUB_USERNAME not set in .env"
    exit 1
fi

# Check for Docker password
if [ -z "${DOCKER_PASSWORD:-}" ]; then
    print_status "error" "DOCKER_PASSWORD environment variable not set"
    echo ""
    echo "Set your Docker Hub password or access token:"
    echo "  export DOCKER_PASSWORD='your-password-or-token'"
    echo ""
    echo "Get an access token from: https://hub.docker.com/settings/security"
    exit 1
fi

print_status "ok" "Credentials configured"
echo "  Docker Hub User: $DOCKER_HUB_USERNAME"
echo ""

# ============================================================================
# [2/3] Login to Docker Hub
# ============================================================================
echo -e "${BLUE}[2/3] Logging into Docker Hub...${NC}"

if echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_HUB_USERNAME" --password-stdin; then
    print_status "ok" "Docker Hub login successful"
else
    print_status "error" "Docker Hub login failed"
    exit 1
fi
echo ""

# ============================================================================
# [3/3] Push image to Docker Hub
# ============================================================================
echo -e "${BLUE}[3/3] Pushing image to Docker Hub...${NC}"

IMAGE_TAG="${DOCKER_IMAGE:-whisperlive-runpod}:${DOCKER_TAG:-latest}${TAG_SUFFIX}"
FULL_IMAGE_TAG="${DOCKER_HUB_USERNAME}/$IMAGE_TAG"

# Verify image exists locally
if ! docker images -q "$IMAGE_TAG" &>/dev/null; then
    print_status "error" "Image not found locally: $IMAGE_TAG"
    echo "Run: ./scripts/100-BUILD--docker-image-local.sh"
    exit 1
fi

# Verify critical packages are installed before pushing
echo "Verifying image contents before push..."
VERIFY_FAILED=false

if ! docker run --rm --entrypoint python3 "$IMAGE_TAG" -c "import torch" 2>/dev/null; then
    print_status "error" "PyTorch NOT installed - image is broken"
    VERIFY_FAILED=true
fi

if ! docker run --rm --entrypoint python3 "$IMAGE_TAG" -c "import faster_whisper" 2>/dev/null; then
    print_status "error" "faster_whisper NOT installed - image is broken"
    VERIFY_FAILED=true
fi

if [ "$VERIFY_FAILED" = true ]; then
    echo ""
    print_status "error" "Image verification failed! Not pushing broken image."
    echo "Rebuild with: ./scripts/100-BUILD--docker-image-local.sh --slim --no-cache"
    exit 1
fi

print_status "ok" "Image verified (torch, faster_whisper present)"
echo ""

echo "Pushing: $FULL_IMAGE_TAG"
echo ""

PUSH_START=$(date +%s)

docker push "$FULL_IMAGE_TAG"

PUSH_END=$(date +%s)
PUSH_DURATION=$((PUSH_END - PUSH_START))

print_status "ok" "Image pushed in $(format_duration $PUSH_DURATION)"
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}Docker Image Pushed Successfully!${NC}"
echo "============================================================================"
echo ""
echo "  Image:      $FULL_IMAGE_TAG"
echo "  Push Time:  $(format_duration $PUSH_DURATION)"
echo ""
echo "Docker Hub URL:"
echo "  https://hub.docker.com/r/${DOCKER_HUB_USERNAME}/${DOCKER_IMAGE:-whisperlive-runpod}"
echo ""
echo "Next Steps:"
echo "  1. Deploy to RunPod: ./scripts/300-RUNPOD--deploy-pod.sh"
echo ""
