#!/bin/bash
#===============================================================================
# 295-RUNPOD--list-available-gpus.sh
# List available RunPod GPUs sorted by price
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Queries RunPod's GraphQL API to find all available GPUs in Community Cloud,
# sorted by price from cheapest to most expensive. This helps you:
#   - Find the cheapest GPU for your workload
#   - See what's actually IN STOCK right now
#   - Choose between Community and Secure cloud options
#
# WHAT YOU'LL SEE:
# ----------------
#   ============================================================================
#   Available RunPod GPUs (Community Cloud)
#   ============================================================================
#
#   Price   | GPU Name                    | VRAM   | Stock
#   --------|-----------------------------| -------|-------
#   $0.12/hr | NVIDIA GeForce RTX 3070    | 8 GB   | High
#   $0.14/hr | NVIDIA GeForce RTX 3080    | 10 GB  | Medium
#   $0.19/hr | NVIDIA GeForce RTX 3090    | 24 GB  | Low
#   ...
#
# USAGE:
#   ./scripts/295-RUNPOD--list-available-gpus.sh              # List community GPUs
#   ./scripts/295-RUNPOD--list-available-gpus.sh --secure     # List secure cloud
#   ./scripts/295-RUNPOD--list-available-gpus.sh --all        # List all GPUs
#   ./scripts/295-RUNPOD--list-available-gpus.sh --cheapest   # Show only cheapest
#
# PREREQUISITES:
#   - RUNPOD_API_KEY in .env
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="295-RUNPOD--list-available-gpus"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Default settings
CLOUD_TYPE="COMMUNITY"
SHOW_ALL=false
SHOW_CHEAPEST=false
MIN_VRAM=8  # Minimum 8GB VRAM for Whisper

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --secure)
            CLOUD_TYPE="SECURE"
            shift
            ;;
        --all)
            SHOW_ALL=true
            shift
            ;;
        --cheapest)
            SHOW_CHEAPEST=true
            shift
            ;;
        --min-vram)
            MIN_VRAM="$2"
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

# Load environment
if ! load_env_or_fail 2>/dev/null; then
    print_status "error" "No .env file found"
    exit 1
fi

if [ -z "${RUNPOD_API_KEY:-}" ]; then
    print_status "error" "RUNPOD_API_KEY not set in .env"
    exit 1
fi

echo "============================================================================"
if [ "$SHOW_ALL" = true ]; then
    echo "Available RunPod GPUs (All Clouds)"
else
    echo "Available RunPod GPUs ($CLOUD_TYPE Cloud)"
fi
echo "============================================================================"
echo ""

# Query RunPod GraphQL API for GPU types
GRAPHQL_QUERY='query GpuTypes {
  gpuTypes {
    id
    displayName
    memoryInGb
    communityCloud {
      minBidPerGpu
      minBidPerGpu
      stockStatus
    }
    secureCloud {
      minBidPerGpu
      stockStatus
    }
  }
}'

RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -d "{\"query\": \"$(echo $GRAPHQL_QUERY | tr '\n' ' ' | sed 's/"/\\"/g')\"}" \
    "https://api.runpod.io/graphql" 2>/dev/null)

# Check for errors
ERROR=$(echo "$RESPONSE" | jq -r '.errors[0].message // empty' 2>/dev/null)
if [ -n "$ERROR" ]; then
    print_status "error" "API error: $ERROR"
    exit 1
fi

# Parse and display GPUs
echo "Querying available GPUs (min ${MIN_VRAM}GB VRAM)..."
echo ""

if [ "$SHOW_CHEAPEST" = true ]; then
    # Just show the single cheapest option
    if [ "$CLOUD_TYPE" = "COMMUNITY" ]; then
        CHEAPEST=$(echo "$RESPONSE" | jq -r '
            .data.gpuTypes
            | map(select(.communityCloud.stockStatus != "unavailable" and .memoryInGb >= '"$MIN_VRAM"'))
            | sort_by(.communityCloud.minBidPerGpu)
            | .[0]
            | "\(.id)|\(.displayName)|\(.memoryInGb)|\(.communityCloud.minBidPerGpu)|\(.communityCloud.stockStatus)"
        ' 2>/dev/null)
    else
        CHEAPEST=$(echo "$RESPONSE" | jq -r '
            .data.gpuTypes
            | map(select(.secureCloud.stockStatus != "unavailable" and .memoryInGb >= '"$MIN_VRAM"'))
            | sort_by(.secureCloud.minBidPerGpu)
            | .[0]
            | "\(.id)|\(.displayName)|\(.memoryInGb)|\(.secureCloud.minBidPerGpu)|\(.secureCloud.stockStatus)"
        ' 2>/dev/null)
    fi

    if [ -n "$CHEAPEST" ] && [ "$CHEAPEST" != "null" ]; then
        IFS='|' read -r GPU_ID GPU_NAME GPU_MEM GPU_PRICE GPU_STOCK <<< "$CHEAPEST"
        echo -e "${GREEN}Cheapest Available GPU:${NC}"
        echo ""
        echo "  GPU ID:     $GPU_ID"
        echo "  Name:       $GPU_NAME"
        echo "  VRAM:       ${GPU_MEM}GB"
        echo "  Price:      \$${GPU_PRICE}/hr"
        echo "  Stock:      $GPU_STOCK"
        echo ""
        echo "To deploy with this GPU:"
        echo "  1. Update .env: RUNPOD_GPU_TYPE=\"$GPU_ID\""
        echo "  2. Run: ./scripts/300-RUNPOD--deploy-pod.sh --slim"
    else
        print_status "warn" "No GPUs available with ${MIN_VRAM}GB+ VRAM"
    fi
else
    # Show full table
    printf "%-8s | %-35s | %-6s | %-10s\n" "Price" "GPU Name" "VRAM" "Stock"
    printf "%-8s-+-%-35s-+-%-6s-+-%-10s\n" "--------" "-----------------------------------" "------" "----------"

    if [ "$CLOUD_TYPE" = "COMMUNITY" ] || [ "$SHOW_ALL" = true ]; then
        echo "$RESPONSE" | jq -r '
            .data.gpuTypes
            | map(select(.communityCloud.stockStatus != null and .memoryInGb >= '"$MIN_VRAM"'))
            | sort_by(.communityCloud.minBidPerGpu)
            | .[]
            | "$\(.communityCloud.minBidPerGpu)/hr | \(.displayName) | \(.memoryInGb) GB | \(.communityCloud.stockStatus)"
        ' 2>/dev/null | while read line; do
            # Color code stock status
            if echo "$line" | grep -q "High"; then
                echo -e "${GREEN}$line${NC}"
            elif echo "$line" | grep -q "Medium"; then
                echo -e "${YELLOW}$line${NC}"
            elif echo "$line" | grep -q "Low"; then
                echo -e "${RED}$line${NC}"
            else
                echo "$line"
            fi
        done
    fi
fi

echo ""
echo "============================================================================"
echo ""
echo "Notes:"
echo "  - Stock status: High (readily available), Medium (may wait), Low (limited)"
echo "  - 'unavailable' GPUs are not shown"
echo "  - Minimum ${MIN_VRAM}GB VRAM required for Whisper models"
echo ""
echo "To update your GPU choice:"
echo "  1. Edit .env and set RUNPOD_GPU_TYPE=\"<GPU ID>\""
echo "  2. Or re-run: ./scripts/010-SETUP--interactive-configuration.sh"
echo ""
