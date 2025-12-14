#!/bin/bash
# =============================================================================
# Interactive Environment Configuration Script for WhisperLive on RunPod
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Asks RunPod-specific configuration questions
#   2. Asks common WhisperLive configuration questions
#   3. Generates .env file from .env.template
#
# PREREQUISITES:
#   - .env.template file must exist
#   - RunPod API key from runpod.io console
#
# Usage: ./scripts/010-SETUP--interactive-configuration.sh
#
# =============================================================================

set -e

SCRIPT_NAME="010-SETUP--interactive-configuration"
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$SCRIPT_DIR/config"
cd "$PROJECT_ROOT"

TEMPLATE_FILE=".env.template"
ENV_FILE=".env"
BACKUP_FILE=".env.backup-$(date +%Y%m%d-%H%M%S)"

# =============================================================================
# Setup Logging
# =============================================================================

LOGS_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================================"
echo "Log started: $(date)"
echo "Script: $SCRIPT_NAME v$SCRIPT_VERSION"
echo "Log file: $LOG_FILE"
echo "============================================================================"
echo ""

# =============================================================================
# Colors for Output
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

ask_question() {
    local var_name=$1
    local prompt=$2
    local default=$3
    local value

    if [ -n "$default" ]; then
        echo -e "${BLUE}$prompt ${NC}[${GREEN}$default${NC}]: \c" >&2
        read value
        value=${value:-$default}
    else
        echo -e "${BLUE}$prompt: ${NC}\c" >&2
        read value
        while [ -z "$value" ]; do
            echo -e "${RED}   This field is required.${NC}" >&2
            echo -e "${BLUE}$prompt: ${NC}\c" >&2
            read value
        done
    fi

    echo "$value"
}

generate_deployment_id() {
    echo "whisperlive-$(date +%Y%m%d-%H%M%S)"
}

update_env_var() {
    local var_name=$1
    local value=$2

    # Escape special characters for sed
    value=$(echo "$value" | sed 's/[&/\]/\\&/g')

    # Update .env file
    sed -i "s|{{$var_name}}|$value|g" "$ENV_FILE"
}

# =============================================================================
# Main Script
# =============================================================================

echo "============================================================================"
echo -e "${CYAN}WhisperLive RunPod GPU Deployment - Environment Configuration${NC}"
echo "============================================================================"
echo ""
echo -e "${YELLOW}WARNING: Do not commit .env or .env.backup* files to git!${NC}"
echo -e "${YELLOW}         They contain deployment-specific configuration and secrets.${NC}"
echo ""

# =============================================================================
# Clear Previous Artifacts
# =============================================================================

ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"
if [ -d "$ARTIFACTS_DIR" ] && [ "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ]; then
    echo ""
    echo -e "${YELLOW}Clearing previous deployment artifacts:${NC}"
    for f in "$ARTIFACTS_DIR"/*.json; do
        if [ -f "$f" ]; then
            echo -e "  - Removing: $(basename "$f")"
            rm -f "$f"
        fi
    done
fi

# =============================================================================
# Backup Existing .env
# =============================================================================

if [ -f "$ENV_FILE" ]; then
    echo ""
    echo -e "${YELLOW}Backing up existing .env to $BACKUP_FILE${NC}"
    cp "$ENV_FILE" "$BACKUP_FILE"
fi

# =============================================================================
# Copy Template
# =============================================================================

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE not found${NC}"
    exit 1
fi

cp "$TEMPLATE_FILE" "$ENV_FILE"

# =============================================================================
# Source RunPod-Specific Questions
# =============================================================================

if [ -f "$CONFIG_DIR/questions-runpod.sh" ]; then
    source "$CONFIG_DIR/questions-runpod.sh"
else
    echo -e "${RED}Error: $CONFIG_DIR/questions-runpod.sh not found${NC}"
    exit 1
fi

# =============================================================================
# Source Common Questions
# =============================================================================

if [ -f "$CONFIG_DIR/questions-common.sh" ]; then
    source "$CONFIG_DIR/questions-common.sh"
else
    echo -e "${RED}Error: $CONFIG_DIR/questions-common.sh not found${NC}"
    exit 1
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "============================================================================"
echo -e "${GREEN}Configuration Complete!${NC}"
echo "============================================================================"
echo ""
echo -e "Platform:          ${CYAN}RunPod GPU Pods${NC}"
echo -e "Configuration:     ${CYAN}$ENV_FILE${NC}"
if [ -f "$BACKUP_FILE" ]; then
    echo -e "Previous backup:   ${CYAN}$BACKUP_FILE${NC}"
fi
echo ""

# Show next steps
show_runpod_next_steps
