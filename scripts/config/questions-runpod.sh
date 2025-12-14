#!/bin/bash
# =============================================================================
# RunPod Questions Module
# =============================================================================
# RunPod-specific configuration questions for GPU Pod deployment.
# This module is sourced by 010-SETUP--interactive-configuration.sh.
#
# Variables set by this module:
#   - RUNPOD_API_KEY, RUNPOD_POD_NAME
#   - RUNPOD_GPU_TYPE, RUNPOD_GPU_COUNT
#   - RUNPOD_CLOUD_TYPE, RUNPOD_INTERRUPTIBLE
#   - RUNPOD_CONTAINER_DISK_GB, RUNPOD_VOLUME_GB
#   - DOCKER_HUB_USERNAME
# =============================================================================

# Guard against direct execution
if [ -z "$SCRIPT_NAME" ]; then
    echo "Error: This script should be sourced by 010-SETUP--interactive-configuration.sh, not run directly."
    exit 1
fi

# =============================================================================
# RunPod Configuration Questions
# =============================================================================

echo ""
echo -e "${CYAN}RunPod Configuration${NC}"
echo "============================================================================"
echo -e "${YELLOW}Get your RunPod API key from: https://www.runpod.io/console/user/settings${NC}"
echo ""

# API Key (required)
RUNPOD_API_KEY=$(ask_question "RUNPOD_API_KEY" "RunPod API Key")
update_env_var "RUNPOD_API_KEY" "$RUNPOD_API_KEY"

# Pod name (include time for uniqueness)
DEFAULT_POD_NAME="whisperlive-$(date +%Y%m%d-%H%M)"
RUNPOD_POD_NAME=$(ask_question "RUNPOD_POD_NAME" "Pod Name" "$DEFAULT_POD_NAME")
update_env_var "RUNPOD_POD_NAME" "$RUNPOD_POD_NAME"

# Pod ID and networking (discovered after deployment)
update_env_var "RUNPOD_POD_ID" ""
update_env_var "RUNPOD_POD_IP" ""
update_env_var "RUNPOD_WS_PORT" ""
update_env_var "RUNPOD_HEALTH_PORT" ""

# =============================================================================
# GPU Configuration
# =============================================================================

echo ""
echo -e "${CYAN}GPU Configuration${NC}"
echo "============================================================================"
echo -e "${YELLOW}Available GPU types (Community Cloud pricing):${NC}"
echo "  - NVIDIA GeForce RTX 3070 (~\$0.12/hr) - Cheapest option, 8GB VRAM"
echo "  - NVIDIA GeForce RTX 3080 (~\$0.14/hr) - 10GB VRAM"
echo "  - NVIDIA GeForce RTX 3090 (~\$0.22/hr) - 24GB VRAM, good for medium models"
echo "  - NVIDIA GeForce RTX 4090 (~\$0.34/hr) - Best performance"
echo ""
echo -e "${GREEN}RTX 3070 is the cheapest option and works well for small.en model${NC}"
echo ""

RUNPOD_GPU_TYPE=$(ask_question "RUNPOD_GPU_TYPE" "GPU Type" "NVIDIA GeForce RTX 3070")
update_env_var "RUNPOD_GPU_TYPE" "$RUNPOD_GPU_TYPE"

RUNPOD_GPU_COUNT=$(ask_question "RUNPOD_GPU_COUNT" "GPU Count" "1")
update_env_var "RUNPOD_GPU_COUNT" "$RUNPOD_GPU_COUNT"

echo ""
echo -e "${YELLOW}Cloud Type:${NC}"
echo "  - COMMUNITY: Lower cost, contributed GPUs (recommended for cost savings)"
echo "  - SECURE: Enterprise-grade, higher availability, higher cost"
echo ""

RUNPOD_CLOUD_TYPE=$(ask_question "RUNPOD_CLOUD_TYPE" "Cloud Type (COMMUNITY or SECURE)" "COMMUNITY")
update_env_var "RUNPOD_CLOUD_TYPE" "$RUNPOD_CLOUD_TYPE"

echo ""
echo -e "${YELLOW}Interruptible (Spot):${NC}"
echo "  - false: Dedicated pod, won't be interrupted"
echo "  - true: Spot pricing (~50% cheaper), may be interrupted"
echo ""

RUNPOD_INTERRUPTIBLE=$(ask_question "RUNPOD_INTERRUPTIBLE" "Interruptible/Spot (true or false)" "false")
update_env_var "RUNPOD_INTERRUPTIBLE" "$RUNPOD_INTERRUPTIBLE"

# =============================================================================
# Storage Configuration
# =============================================================================

echo ""
echo -e "${CYAN}Storage Configuration${NC}"
echo "============================================================================"

RUNPOD_CONTAINER_DISK_GB=$(ask_question "RUNPOD_CONTAINER_DISK_GB" "Container Disk Size (GB)" "50")
update_env_var "RUNPOD_CONTAINER_DISK_GB" "$RUNPOD_CONTAINER_DISK_GB"

RUNPOD_VOLUME_GB=$(ask_question "RUNPOD_VOLUME_GB" "Persistent Volume Size (GB)" "20")
update_env_var "RUNPOD_VOLUME_GB" "$RUNPOD_VOLUME_GB"

# =============================================================================
# Docker Hub Configuration
# =============================================================================

echo ""
echo -e "${CYAN}Docker Hub Configuration${NC}"
echo "============================================================================"
echo -e "${YELLOW}RunPod pulls images from Docker Hub. You need a Docker Hub account.${NC}"
echo ""

DOCKER_HUB_USERNAME=$(ask_question "DOCKER_HUB_USERNAME" "Docker Hub Username")
update_env_var "DOCKER_HUB_USERNAME" "$DOCKER_HUB_USERNAME"

echo ""
echo -e "${YELLOW}Note: You'll need to set DOCKER_PASSWORD environment variable${NC}"
echo -e "${YELLOW}      when running push-to-registry.sh:${NC}"
echo -e "${CYAN}      export DOCKER_PASSWORD='your-password'${NC}"
echo ""

# =============================================================================
# RunPod Cost Estimate
# =============================================================================

show_runpod_cost_estimate() {
    echo ""
    echo -e "${YELLOW}RunPod Cost Estimate (Community Cloud - cheapest):${NC}"
    echo -e "   RTX 3060:  ~\$0.10/hour  ${GREEN}<-- Best value for small.en${NC}"
    echo -e "   RTX 3070:  ~\$0.12/hour"
    echo -e "   RTX 3080:  ~\$0.14/hour"
    echo -e "   RTX 3090:  ~\$0.22/hour"
    echo -e "   RTX 4090:  ~\$0.34/hour"
    echo ""
    echo -e "${GREEN}Spot/Interruptible pricing can be even cheaper (~50% off).${NC}"
    echo -e "${GREEN}RunPod bills per-second while pod is running.${NC}"
    echo ""
}

# Show cost estimate
show_runpod_cost_estimate

# =============================================================================
# RunPod Next Steps
# =============================================================================

show_runpod_next_steps() {
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo -e "   ${YELLOW}1.${NC} Review .env file: ${CYAN}cat .env${NC}"
    echo -e "   ${YELLOW}2.${NC} Build Docker image: ${CYAN}./scripts/100-BUILD--docker-image-local.sh${NC}"
    echo -e "   ${YELLOW}3.${NC} Push to Docker Hub: ${CYAN}./scripts/110-BUILD--push-to-dockerhub.sh${NC}"
    echo -e "   ${YELLOW}4.${NC} Test on EC2 first: ${CYAN}./scripts/200-EC2--launch-gpu-test-instance.sh${NC}"
    echo -e "   ${YELLOW}5.${NC} Deploy to RunPod: ${CYAN}./scripts/300-RUNPOD--deploy-pod.sh${NC}"
    echo ""
}
