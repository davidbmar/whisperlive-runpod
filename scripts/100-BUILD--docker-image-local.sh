#!/bin/bash
# =============================================================================
# Build WhisperLive Docker Image Locally (for RunPod Deployment)
# =============================================================================
#
# PLAIN ENGLISH:
#   This script builds the Docker image that will run WhisperLive on a GPU.
#   It packages all the code, dependencies (PyTorch, faster-whisper, etc),
#   and configuration into a single image that can run anywhere with a GPU.
#
#   Use --slim for transcription only (faster, smaller, recommended).
#   Use --no-cache if you changed requirements and Docker isn't picking it up.
#
# WHAT HAPPENS WHEN YOU RUN THIS:
#   1. Loads your .env configuration
#   2. Selects the Dockerfile (slim or full)
#   3. Builds the image with all dependencies
#   4. Verifies critical packages are installed (torch, faster_whisper, etc)
#   5. Tags the image for Docker Hub
#
# VERIFICATION:
#   After building, the script automatically checks that PyTorch and other
#   critical packages are installed. If verification fails, it tells you
#   to rebuild with --no-cache.
#
# PREREQUISITES:
#   - .env file configured (./scripts/010-SETUP--interactive-configuration.sh)
#   - Docker installed and running
#
# Usage: ./scripts/100-BUILD--docker-image-local.sh [--slim] [--no-cache]
#
# Options:
#   --slim        Build slim image (~5GB) - transcription only (recommended)
#   --no-cache    Force clean rebuild (use if dependencies changed)
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="100-BUILD--docker-image-local"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Default options
NO_CACHE=""
SHOW_HELP=false
IMAGE_VARIANT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --slim)
            IMAGE_VARIANT="slim"
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
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

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    head -25 "$0" | tail -20
    exit 0
fi

echo "============================================================================"
echo "Building WhisperLive Docker Image Locally (for RunPod)"
echo "============================================================================"
echo ""

# ============================================================================
# Image variant selection
# ============================================================================
if [ -z "$IMAGE_VARIANT" ]; then
    echo "Select image variant:"
    echo ""
    echo "  1. slim - Transcription only (~3-4GB, faster deploy, recommended)"
    echo "  2. full - Includes speaker diarization (~9GB)"
    echo ""
    read -p "Choose variant (1 or 2) [1]: " -n 1 -r
    echo
    case $REPLY in
        2) IMAGE_VARIANT="full" ;;
        *) IMAGE_VARIANT="slim" ;;
    esac
fi

echo "Building $IMAGE_VARIANT variant"
echo ""

# ============================================================================
# [1/4] Load environment and validate
# ============================================================================
echo -e "${BLUE}[1/4] Loading environment and validating...${NC}"

if ! load_env_or_fail; then
    exit 1
fi

# Check Docker is available
if ! command -v docker &>/dev/null; then
    print_status "error" "Docker is not installed or not in PATH"
    exit 1
fi

# Check Docker daemon is running
if ! docker info &>/dev/null; then
    print_status "error" "Docker daemon is not running"
    exit 1
fi

print_status "ok" "Environment validated"
echo "  Image:       ${DOCKER_IMAGE:-whisperlive-runpod}:${DOCKER_TAG:-latest}"
echo "  Docker Hub:  ${DOCKER_HUB_USERNAME:-not set}"
echo ""

# ============================================================================
# [2/4] Check prerequisites
# ============================================================================
echo -e "${BLUE}[2/4] Checking prerequisites...${NC}"

# Select Dockerfile based on variant
if [ "$IMAGE_VARIANT" = "slim" ]; then
    DOCKERFILE="$PROJECT_ROOT/runpod/Dockerfile.runpod-slim"
    REQUIREMENTS_FILE="requirements/server-runpod.txt"
else
    DOCKERFILE="$PROJECT_ROOT/runpod/Dockerfile.runpod"
    REQUIREMENTS_FILE="requirements/server.txt"
fi

if [ ! -f "$DOCKERFILE" ]; then
    print_status "error" "Dockerfile not found: $DOCKERFILE"
    exit 1
fi
print_status "ok" "Dockerfile: $(basename $DOCKERFILE)"

# Check for required files
REQUIRED_FILES="run_server.py $REQUIREMENTS_FILE runpod/entrypoint.sh runpod/healthcheck.py"
if [ "$IMAGE_VARIANT" = "full" ]; then
    REQUIRED_FILES="$REQUIRED_FILES requirements/diarization.txt"
fi

for required_file in $REQUIRED_FILES; do
    if [ ! -f "$PROJECT_ROOT/$required_file" ]; then
        print_status "error" "Required file not found: $required_file"
        exit 1
    fi
done
print_status "ok" "All required files present"

# Check disk space (need at least 10GB for build)
AVAILABLE_SPACE=$(df -BG "$PROJECT_ROOT" | tail -1 | awk '{print $4}' | sed 's/G//')
if [ "$AVAILABLE_SPACE" -lt 10 ]; then
    print_status "error" "Insufficient disk space: ${AVAILABLE_SPACE}GB available (need 10GB+)"
    exit 1
fi
print_status "ok" "Disk space: ${AVAILABLE_SPACE}GB available"
echo ""

# ============================================================================
# [3/4] Prepare model cache (full variant only)
# ============================================================================
echo -e "${BLUE}[3/4] Preparing model cache...${NC}"

CACHE_DIR="$PROJECT_ROOT/huggingface-cache"

if [ "$IMAGE_VARIANT" = "slim" ]; then
    # Slim variant doesn't need model cache
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR/hub"
    print_status "ok" "Skipped model cache (slim variant)"
else
    # Full variant - check if we have model cache
    if [ -d "$CACHE_DIR/hub" ] && [ "$(ls -A $CACHE_DIR/hub 2>/dev/null)" ]; then
        MODEL_COUNT=$(ls "$CACHE_DIR/hub" 2>/dev/null | grep -c models-- || echo 0)
        print_status "ok" "Using existing model cache ($MODEL_COUNT models)"
    else
        print_status "warn" "No model cache found - diarization models will download at runtime"
        echo "  You'll need HF_TOKEN environment variable for pyannote models"
        mkdir -p "$CACHE_DIR/hub"
    fi
fi
echo ""

# ============================================================================
# [4/4] Build Docker image
# ============================================================================
echo -e "${BLUE}[4/4] Building Docker image locally...${NC}"

# Add variant suffix to tag
if [ "$IMAGE_VARIANT" = "slim" ]; then
    TAG_SUFFIX="-slim"
else
    TAG_SUFFIX=""
fi

IMAGE_TAG="${DOCKER_IMAGE:-whisperlive-runpod}:${DOCKER_TAG:-latest}${TAG_SUFFIX}"
FULL_IMAGE_TAG="${DOCKER_HUB_USERNAME:-local}/$IMAGE_TAG"

echo "Building image: $FULL_IMAGE_TAG"
if [ -n "$NO_CACHE" ]; then
    echo "Build mode: no-cache (clean rebuild)"
fi
echo ""

# Build the image
BUILD_START=$(date +%s)

docker build \
    $NO_CACHE \
    -f "$DOCKERFILE" \
    -t "$IMAGE_TAG" \
    -t "$FULL_IMAGE_TAG" \
    "$PROJECT_ROOT"

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

# Clean up model cache if we created an empty one
if [ "$IMAGE_VARIANT" = "slim" ]; then
    rm -rf "$CACHE_DIR"
fi

# Get image details
IMAGE_SIZE=$(docker images "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo "unknown")

print_status "ok" "Docker image built in $(format_duration $BUILD_DURATION)"
echo ""

# ============================================================================
# Verify critical packages are installed
# ============================================================================
echo -e "${BLUE}[5/5] Verifying image contents...${NC}"

VERIFY_FAILED=false

# Check for torch (required for VAD)
if ! docker run --rm --entrypoint python3 "$IMAGE_TAG" -c "import torch; print(f'torch {torch.__version__}')" 2>/dev/null; then
    print_status "error" "PyTorch NOT installed in image"
    VERIFY_FAILED=true
else
    TORCH_VERSION=$(docker run --rm --entrypoint python3 "$IMAGE_TAG" -c "import torch; print(torch.__version__)" 2>/dev/null)
    print_status "ok" "PyTorch installed: $TORCH_VERSION"
fi

# Check for faster_whisper
if ! docker run --rm --entrypoint python3 "$IMAGE_TAG" -c "import faster_whisper; print('faster_whisper ok')" 2>/dev/null; then
    print_status "error" "faster_whisper NOT installed in image"
    VERIFY_FAILED=true
else
    print_status "ok" "faster_whisper installed"
fi

# Check for websockets
if ! docker run --rm --entrypoint python3 "$IMAGE_TAG" -c "import websockets; print('websockets ok')" 2>/dev/null; then
    print_status "error" "websockets NOT installed in image"
    VERIFY_FAILED=true
else
    print_status "ok" "websockets installed"
fi

if [ "$VERIFY_FAILED" = true ]; then
    echo ""
    print_status "error" "Image verification failed!"
    echo ""
    echo "Docker used cached layers that are missing dependencies."
    echo "Rebuild with --no-cache to fix:"
    echo ""
    echo "  ./scripts/100-BUILD--docker-image-local.sh --slim --no-cache"
    echo ""
    exit 1
fi

echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}Docker Image Built Successfully!${NC}"
echo "============================================================================"
echo ""
echo "  Variant:       $IMAGE_VARIANT"
echo "  Local Tag:     $IMAGE_TAG"
echo "  Full Tag:      $FULL_IMAGE_TAG"
echo "  Size:          $IMAGE_SIZE"
echo "  Build Time:    $(format_duration $BUILD_DURATION)"
echo ""
echo "Next Steps:"
if [ "$IMAGE_VARIANT" = "slim" ]; then
    echo "  1. Push to Docker Hub:  ./scripts/110-BUILD--push-to-dockerhub.sh --slim"
else
    echo "  1. Push to Docker Hub:  ./scripts/110-BUILD--push-to-dockerhub.sh"
fi
echo "  2. Deploy to RunPod:    ./scripts/300-RUNPOD--deploy-pod.sh"
echo ""
