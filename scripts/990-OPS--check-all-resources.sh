#!/bin/bash
# =============================================================================
# Check All Running Resources (Cost Control)
# =============================================================================
#
# PLAIN ENGLISH:
#   This script checks if you have any GPU resources running that are
#   costing you money. Run this before going to bed or leaving your desk!
#
#   It checks both RunPod pods and EC2 GPU instances, and tells you how
#   to shut them down if any are running.
#
# Usage: ./scripts/990-OPS--check-all-resources.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"

echo "============================================================================"
echo "Checking All Running GPU Resources"
echo "============================================================================"
echo ""

FOUND_RESOURCES=false

# ============================================================================
# Check RunPod
# ============================================================================
echo -e "${BLUE}[RunPod]${NC}"

if load_env_or_fail 2>/dev/null; then
    PODS=$(runpod_api_call "GET" "/pods" 2>/dev/null || echo "[]")
    POD_COUNT=$(echo "$PODS" | jq 'length' 2>/dev/null || echo "0")

    if [ "$POD_COUNT" -gt 0 ]; then
        FOUND_RESOURCES=true
        print_status "warn" "Found $POD_COUNT RunPod pod(s) running!"
        echo "$PODS" | jq -r '.[] | "  - \(.id): \(.name) (\(.desiredStatus)) - $\(.costPerHr)/hr"' 2>/dev/null || true
        echo ""
        echo "  To terminate: ./scripts/930-OPS--runpod-stop-terminate.sh --terminate"
    else
        print_status "ok" "No RunPod pods running"
    fi
else
    print_status "warn" "Could not check RunPod (no .env or API error)"
fi
echo ""

# ============================================================================
# Check EC2 GPU Instances
# ============================================================================
echo -e "${BLUE}[EC2 GPU Instances]${NC}"

AWS_REGION="${AWS_REGION:-us-east-2}"

# Look for GPU instances (g4dn, p3, p4d, etc.)
GPU_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[*].Instances[?contains(InstanceType, `g4`) || contains(InstanceType, `p3`) || contains(InstanceType, `p4`)][].[InstanceId,Tags[?Key==`Name`].Value|[0],InstanceType,LaunchTime]' \
    --output json \
    --region "$AWS_REGION" 2>/dev/null || echo "[]")

GPU_COUNT=$(echo "$GPU_INSTANCES" | jq 'length' 2>/dev/null || echo "0")

if [ "$GPU_COUNT" -gt 0 ]; then
    FOUND_RESOURCES=true
    print_status "warn" "Found $GPU_COUNT EC2 GPU instance(s) running!"
    echo "$GPU_INSTANCES" | jq -r '.[] | "  - \(.[0]): \(.[1] // "unnamed") (\(.[2]))"' 2>/dev/null || true
    echo ""
    echo "  To terminate: ./scripts/220-EC2--terminate-and-cleanup.sh"
    echo "  Or manually:  aws ec2 terminate-instances --instance-ids <id>"
else
    print_status "ok" "No EC2 GPU instances running"
fi
echo ""

# ============================================================================
# Check for test instance state file
# ============================================================================
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"
if [ -f "$EC2_STATE_FILE" ]; then
    SAVED_ID=$(jq -r '.instance_id // empty' "$EC2_STATE_FILE" 2>/dev/null || true)
    if [ -n "$SAVED_ID" ]; then
        STATE=$(aws ec2 describe-instances \
            --instance-ids "$SAVED_ID" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "unknown")

        if [ "$STATE" = "running" ] || [ "$STATE" = "pending" ]; then
            print_status "warn" "Test instance from state file still running: $SAVED_ID"
        elif [ "$STATE" = "terminated" ]; then
            echo "Note: State file references terminated instance. Cleaning up..."
            rm -f "$EC2_STATE_FILE"
        fi
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo "============================================================================"
if [ "$FOUND_RESOURCES" = true ]; then
    echo -e "${YELLOW}WARNING: GPU resources are running and incurring costs!${NC}"
    echo ""
    echo "Quick cleanup commands:"
    echo "  RunPod:  ./scripts/930-OPS--runpod-stop-terminate.sh --terminate"
    echo "  EC2:     ./scripts/220-EC2--terminate-and-cleanup.sh"
else
    echo -e "${GREEN}All clear! No GPU resources running.${NC}"
fi
echo "============================================================================"
