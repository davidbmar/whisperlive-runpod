#!/bin/bash
# =============================================================================
# Cleanup EC2 Test Instance
# =============================================================================
#
# PLAIN ENGLISH:
#   This script shuts down and deletes your EC2 test instance to stop
#   charges. Run this when you're done testing. The instance also has a
#   90-minute auto-shutdown as a safety net, but don't rely on that.
#
# WHAT HAPPENS WHEN YOU RUN THIS:
#   1. Terminates the EC2 instance (stops billing)
#   2. Cleans up the state file (artifacts/ec2-test-instance.json)
#   3. Optionally keeps the security group for faster next launch
#
# Usage: ./scripts/220-EC2--terminate-and-cleanup.sh [--keep-sg]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="220-EC2--terminate-and-cleanup"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Options
KEEP_SG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-sg) KEEP_SG=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "============================================================================"
echo "Cleaning Up EC2 Test Instance"
echo "============================================================================"
echo ""

# ============================================================================
# Load configuration
# ============================================================================
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"

if [ ! -f "$EC2_STATE_FILE" ]; then
    print_status "warn" "No EC2 state file found"
    echo "Nothing to clean up."
    exit 0
fi

INSTANCE_ID=$(jq -r '.instance_id // empty' "$EC2_STATE_FILE")
SECURITY_GROUP_ID=$(jq -r '.security_group_id // empty' "$EC2_STATE_FILE")
REGION=$(jq -r '.region // "us-east-2"' "$EC2_STATE_FILE")

echo -e "${BLUE}Found test instance:${NC}"
echo "  Instance ID:     $INSTANCE_ID"
echo "  Security Group:  $SECURITY_GROUP_ID"
echo "  Region:          $REGION"
echo ""

# ============================================================================
# Terminate instance
# ============================================================================
echo -e "${BLUE}[1/2] Terminating instance...${NC}"

if [ -n "$INSTANCE_ID" ]; then
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "not-found")

    if [ "$INSTANCE_STATE" = "terminated" ] || [ "$INSTANCE_STATE" = "not-found" ]; then
        print_status "ok" "Instance already terminated"
    else
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
        print_status "ok" "Termination initiated for: $INSTANCE_ID"

        echo "Waiting for termination..."
        aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
        print_status "ok" "Instance terminated"
    fi
else
    print_status "warn" "No instance ID found"
fi
echo ""

# ============================================================================
# Cleanup security group (optional)
# ============================================================================
echo -e "${BLUE}[2/2] Cleaning up security group...${NC}"

if [ "$KEEP_SG" = true ]; then
    print_status "ok" "Keeping security group (--keep-sg)"
elif [ -n "$SECURITY_GROUP_ID" ]; then
    # Wait a moment for instance termination to release the SG
    sleep 5

    if aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" --region "$REGION" 2>/dev/null; then
        print_status "ok" "Security group deleted: $SECURITY_GROUP_ID"
    else
        print_status "warn" "Could not delete security group (may be in use)"
        echo "  You can delete it manually later or use --keep-sg to preserve it"
    fi
else
    print_status "ok" "No security group to clean up"
fi
echo ""

# ============================================================================
# Remove state file
# ============================================================================
rm -f "$EC2_STATE_FILE"
print_status "ok" "State file removed"

echo ""
echo "============================================================================"
echo -e "${GREEN}Cleanup Complete!${NC}"
echo "============================================================================"
echo ""
echo "EC2 test instance has been terminated."
echo "No ongoing costs from this test session."
echo ""
