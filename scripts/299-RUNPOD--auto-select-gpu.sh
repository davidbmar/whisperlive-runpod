#!/bin/bash
#===============================================================================
# 299-RUNPOD--auto-select-gpu.sh
# Auto-select the cheapest available GPU and update .env
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# 1. Queries RunPod API for available GPUs
# 2. Filters for GPUs with 8GB+ VRAM (required for Whisper)
# 3. Tries to create a test pod with each GPU starting from cheapest
# 4. Updates .env with the first GPU that's actually available
#
# WHY THIS IS NEEDED:
# -------------------
# RunPod shows GPUs as "available" but they may not actually be schedulable.
# This script does a real test by attempting to create a pod with each GPU.
#
# USAGE:
#   ./scripts/299-RUNPOD--auto-select-gpu.sh
#   ./scripts/299-RUNPOD--auto-select-gpu.sh --min-vram 16
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="299-RUNPOD--auto-select-gpu"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

MIN_VRAM=8

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --min-vram)
            MIN_VRAM="$2"
            shift 2
            ;;
        --help|-h)
            head -25 "$0" | tail -20
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load environment
if ! load_env_or_fail 2>/dev/null; then
    print_status "error" "No .env file found"
    exit 1
fi

echo "============================================================================"
echo "Auto-Selecting Cheapest Available GPU"
echo "============================================================================"
echo ""
echo "This will try common GPUs to find one that's actually available."
echo "Minimum VRAM: ${MIN_VRAM}GB"
echo ""

# List of GPUs to try, ordered by typical price (cheapest first)
# These are the most common community cloud GPUs
GPU_LIST=(
    "NVIDIA GeForce RTX 3070"
    "NVIDIA GeForce RTX 3080"
    "NVIDIA RTX A4000"
    "NVIDIA GeForce RTX 4070 Ti"
    "NVIDIA GeForce RTX 3090"
    "NVIDIA RTX A5000"
    "NVIDIA GeForce RTX 4080"
    "NVIDIA GeForce RTX 4090"
    "NVIDIA RTX A6000"
    "NVIDIA L40"
)

FOUND_GPU=""

for GPU in "${GPU_LIST[@]}"; do
    echo -n "Testing: $GPU... "

    # Try to create a minimal test pod
    TEST_PAYLOAD=$(cat <<EOF
{
    "name": "gpu-test-$(date +%s)",
    "imageName": "docker.io/alpine:latest",
    "gpuTypeIds": ["$GPU"],
    "gpuCount": 1,
    "cloudType": "COMMUNITY",
    "containerDiskInGb": 5,
    "volumeInGb": 0,
    "ports": []
}
EOF
)

    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -d "$TEST_PAYLOAD" \
        "https://rest.runpod.io/v1/pods" 2>/dev/null)

    # Check for success
    TEST_POD_ID=$(echo "$RESPONSE" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$TEST_POD_ID" ]; then
        echo -e "${GREEN}Available!${NC}"
        FOUND_GPU="$GPU"

        # Immediately terminate the test pod
        curl -s -X DELETE \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
            "https://rest.runpod.io/v1/pods/${TEST_POD_ID}" &>/dev/null

        break
    else
        ERROR=$(echo "$RESPONSE" | jq -r '.error // "unknown"' 2>/dev/null)
        if echo "$ERROR" | grep -qi "no available"; then
            echo -e "${YELLOW}Not available${NC}"
        else
            echo -e "${RED}Error: $ERROR${NC}"
        fi
    fi

    sleep 1
done

echo ""

if [ -n "$FOUND_GPU" ]; then
    echo "============================================================================"
    echo -e "${GREEN}Found Available GPU: $FOUND_GPU${NC}"
    echo "============================================================================"
    echo ""

    # Update .env
    sed -i "s/RUNPOD_GPU_TYPE=.*/RUNPOD_GPU_TYPE=\"$FOUND_GPU\"/" .env
    print_status "ok" "Updated .env with RUNPOD_GPU_TYPE=\"$FOUND_GPU\""
    echo ""
    echo "You can now deploy with:"
    echo "  ./scripts/300-RUNPOD--deploy-pod.sh --slim"
else
    echo "============================================================================"
    echo -e "${RED}No GPUs Currently Available${NC}"
    echo "============================================================================"
    echo ""
    echo "All tested GPUs are currently unavailable."
    echo "This can happen during high demand periods."
    echo ""
    echo "Options:"
    echo "  1. Try again later"
    echo "  2. Use Secure Cloud (more expensive but more available)"
    echo "  3. Check RunPod console: https://www.runpod.io/console/gpu-cloud"
    exit 1
fi
