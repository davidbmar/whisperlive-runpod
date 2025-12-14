#!/bin/bash
# =============================================================================
# Launch EC2 GPU Instance for Testing WhisperLive
# =============================================================================
#
# PLAIN ENGLISH:
#   This script creates a temporary AWS EC2 instance with a GPU so you can
#   test your Docker image before deploying to RunPod. It's like renting a
#   GPU computer for an hour to make sure everything works.
#
#   The instance auto-terminates after 90 minutes as a safety net so you
#   don't accidentally leave it running and get charged.
#
# WHAT HAPPENS WHEN YOU RUN THIS:
#   1. Creates a g4dn.xlarge instance (NVIDIA T4 GPU, ~$0.52/hour)
#   2. Uses Ubuntu 22.04 with NVIDIA drivers pre-installed
#   3. Installs Docker and nvidia-container-toolkit automatically
#   4. Sets up security group to allow SSH (22), WebSocket (9090), Health (9999)
#   5. Saves instance details to artifacts/ec2-test-instance.json
#   6. Starts 90-minute auto-shutdown timer (safety net)
#
# PREREQUISITES:
#   - AWS CLI configured (aws configure)
#   - SSH key pair in ~/.ssh/
#
# COST: ~$0.52/hour while running. Auto-terminates after 90 minutes.
#
# Usage: ./scripts/200-EC2--launch-gpu-test-instance.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="200-EC2--launch-gpu-test-instance"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

echo "============================================================================"
echo "Launching EC2 GPU Instance for Testing"
echo "============================================================================"
echo ""

# ============================================================================
# Configuration
# ============================================================================

# AWS Region
AWS_REGION="${AWS_REGION:-us-east-2}"

# Instance type - g4dn.xlarge has 1x T4 GPU, 4 vCPUs, 16GB RAM
INSTANCE_TYPE="g4dn.xlarge"

# Deep Learning AMI (Ubuntu 22.04) - has NVIDIA drivers pre-installed
# This AMI ID is for us-east-2, adjust for other regions
AMI_ID="${EC2_AMI_ID:-ami-0c6e48dc21a1583af}"  # Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)

# Security group (will create if needed)
SECURITY_GROUP_NAME="whisperlive-test-sg"

# Key pair name
KEY_NAME="${EC2_KEY_NAME:-}"

# Instance name tag
INSTANCE_NAME="whisperlive-test-$(date +%Y%m%d-%H%M%S)"

# State file
EC2_STATE_FILE="$ARTIFACTS_DIR/ec2-test-instance.json"

echo -e "${BLUE}Configuration:${NC}"
echo "  Region:        $AWS_REGION"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI:           $AMI_ID"
echo ""

# ============================================================================
# [1/5] Check for existing test instance
# ============================================================================
echo -e "${BLUE}[1/5] Checking for existing test instance...${NC}"

if [ -f "$EC2_STATE_FILE" ]; then
    EXISTING_ID=$(jq -r '.instance_id // empty' "$EC2_STATE_FILE" 2>/dev/null || true)
    if [ -n "$EXISTING_ID" ]; then
        EXISTING_STATE=$(aws ec2 describe-instances \
            --instance-ids "$EXISTING_ID" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "terminated")

        if [ "$EXISTING_STATE" != "terminated" ] && [ "$EXISTING_STATE" != "None" ]; then
            print_status "warn" "Existing test instance found: $EXISTING_ID (state: $EXISTING_STATE)"
            echo ""
            echo "Options:"
            echo "  1. Terminate existing and create new"
            echo "  2. Use existing instance"
            echo "  3. Cancel"
            echo ""
            read -p "Choose option (1, 2, or 3): " -n 1 -r
            echo

            case $REPLY in
                1)
                    echo "Terminating existing instance..."
                    aws ec2 terminate-instances --instance-ids "$EXISTING_ID" --region "$AWS_REGION" >/dev/null
                    rm -f "$EC2_STATE_FILE"
                    sleep 5
                    ;;
                2)
                    print_status "ok" "Using existing instance: $EXISTING_ID"
                    PUBLIC_IP=$(jq -r '.public_ip // empty' "$EC2_STATE_FILE")
                    echo ""
                    echo "Instance: $EXISTING_ID"
                    echo "Public IP: $PUBLIC_IP"
                    echo ""
                    echo "Next: ./scripts/210-EC2--run-container-and-test.sh"
                    exit 0
                    ;;
                *)
                    echo "Cancelled"
                    exit 0
                    ;;
            esac
        fi
    fi
fi

print_status "ok" "No existing test instance"
echo ""

# ============================================================================
# [2/5] Get or create key pair
# ============================================================================
echo -e "${BLUE}[2/5] Checking SSH key pair...${NC}"

if [ -z "$KEY_NAME" ]; then
    # List available key pairs
    KEYS=$(aws ec2 describe-key-pairs --query 'KeyPairs[*].KeyName' --output text --region "$AWS_REGION")

    if [ -z "$KEYS" ]; then
        print_status "error" "No SSH key pairs found in $AWS_REGION"
        echo "Create a key pair first:"
        echo "  aws ec2 create-key-pair --key-name mykey --query 'KeyMaterial' --output text > ~/.ssh/mykey.pem"
        exit 1
    fi

    # Use first available key
    KEY_NAME=$(echo "$KEYS" | awk '{print $1}')
    print_status "ok" "Using key pair: $KEY_NAME"
else
    print_status "ok" "Using configured key: $KEY_NAME"
fi
echo ""

# ============================================================================
# [3/5] Get or create security group
# ============================================================================
echo -e "${BLUE}[3/5] Setting up security group...${NC}"

# Check if security group exists
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    echo "Creating security group: $SECURITY_GROUP_NAME"

    # Get default VPC
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")

    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SECURITY_GROUP_NAME" \
        --description "WhisperLive test instance security group" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text \
        --region "$AWS_REGION")

    # Add SSH access
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null

    # Add WhisperLive WebSocket port
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 9090 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null

    # Add health check port
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 9999 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null

    print_status "ok" "Created security group: $SG_ID"
else
    print_status "ok" "Using existing security group: $SG_ID"
fi
echo ""

# ============================================================================
# [4/5] Launch instance
# ============================================================================
echo -e "${BLUE}[4/5] Launching EC2 instance...${NC}"
echo "  Instance Type: $INSTANCE_TYPE (T4 GPU)"
echo "  AMI: $AMI_ID"
echo ""

# Auto-termination after 90 minutes (safety net)
AUTO_TERMINATE_MINUTES=90

# User data script to set up Docker with auto-shutdown
USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -e

# ============================================================
# SAFETY: Auto-terminate after ${AUTO_TERMINATE_MINUTES} minutes
# ============================================================
echo "Setting up auto-termination in ${AUTO_TERMINATE_MINUTES} minutes..."
(
    sleep $((${AUTO_TERMINATE_MINUTES} * 60))
    echo "Auto-termination timer reached. Shutting down..."
    shutdown -h now
) &
echo \$! > /tmp/auto-shutdown.pid

# Install Docker if not present (Deep Learning AMI may not have it)
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get update
    apt-get install -y docker.io
fi

# Start Docker
systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Install nvidia-container-toolkit for GPU support in Docker
if ! dpkg -l | grep -q nvidia-container-toolkit; then
    echo "Installing nvidia-container-toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# Signal ready
touch /tmp/instance-ready
echo "Instance ready. Auto-shutdown in ${AUTO_TERMINATE_MINUTES} minutes."
USERDATA
)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Purpose,Value=whisperlive-test}]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "$AWS_REGION")

print_status "ok" "Instance launched: $INSTANCE_ID"
echo ""

# ============================================================================
# [5/5] Wait for instance to be ready
# ============================================================================
echo -e "${BLUE}[5/5] Waiting for instance to be running...${NC}"

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
print_status "ok" "Instance is running"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region "$AWS_REGION")

print_status "ok" "Public IP: $PUBLIC_IP"
echo ""

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..30}; do
    if nc -z -w 2 "$PUBLIC_IP" 22 2>/dev/null; then
        print_status "ok" "SSH is ready"
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

# Save state
cat > "$EC2_STATE_FILE" <<EOF
{
    "instance_id": "$INSTANCE_ID",
    "instance_name": "$INSTANCE_NAME",
    "instance_type": "$INSTANCE_TYPE",
    "public_ip": "$PUBLIC_IP",
    "key_name": "$KEY_NAME",
    "ssh_user": "ubuntu",
    "security_group_id": "$SG_ID",
    "region": "$AWS_REGION",
    "created_at": "$(date -Iseconds)",
    "auto_terminate_minutes": $AUTO_TERMINATE_MINUTES
}
EOF

print_status "ok" "Instance state saved to: $EC2_STATE_FILE"
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}EC2 GPU Test Instance Ready!${NC}"
echo "============================================================================"
echo ""
echo "  Instance ID:   $INSTANCE_ID"
echo "  Instance Type: $INSTANCE_TYPE (T4 GPU)"
echo "  Public IP:     $PUBLIC_IP"
echo "  SSH Key:       $KEY_NAME"
echo ""
echo "SSH Access:"
echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
echo ""
echo "Cost: ~\$0.52/hour (on-demand)"
echo ""
echo -e "${YELLOW}SAFETY: Instance will auto-terminate in 90 minutes!${NC}"
echo ""
echo "Next Steps:"
echo "  1. Wait 1-2 min for Docker setup to complete"
echo "  2. Run tests: ./scripts/210-EC2--run-container-and-test.sh"
echo "  3. Cleanup:   ./scripts/220-EC2--terminate-and-cleanup.sh"
echo ""
