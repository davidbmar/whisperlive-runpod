#!/bin/bash
# =============================================================================
# Common Questions Module
# =============================================================================
# Shared WhisperLive configuration questions.
# This module is sourced by 010-SETUP--interactive-configuration.sh after RunPod configuration.
#
# Variables set by this module:
#   - WHISPER_MODEL, WHISPER_COMPUTE_TYPE
#   - WHISPERLIVE_PORT, HEALTH_CHECK_PORT
#   - MAX_CLIENTS, MAX_CONNECTION_TIME
#   - DOCKER_IMAGE, DOCKER_TAG
#   - DEPLOYMENT_ID, DEPLOYMENT_TIMESTAMP
# =============================================================================

# Guard against direct execution
if [ -z "$SCRIPT_NAME" ]; then
    echo "Error: This script should be sourced by 010-SETUP--interactive-configuration.sh, not run directly."
    exit 1
fi

# =============================================================================
# WhisperLive Configuration
# =============================================================================

echo ""
echo -e "${CYAN}WhisperLive Configuration${NC}"
echo "============================================================================"

WHISPER_MODEL=$(ask_question "WHISPER_MODEL" "Whisper Model (tiny.en, base.en, small.en, medium.en)" "small.en")
update_env_var "WHISPER_MODEL" "$WHISPER_MODEL"

WHISPER_COMPUTE_TYPE=$(ask_question "WHISPER_COMPUTE_TYPE" "Compute Type (int8, float16, float32)" "int8")
update_env_var "WHISPER_COMPUTE_TYPE" "$WHISPER_COMPUTE_TYPE"

WHISPERLIVE_PORT=$(ask_question "WHISPERLIVE_PORT" "WhisperLive WebSocket Port" "9090")
update_env_var "WHISPERLIVE_PORT" "$WHISPERLIVE_PORT"

HEALTH_CHECK_PORT=$(ask_question "HEALTH_CHECK_PORT" "Health Check HTTP Port" "9999")
update_env_var "HEALTH_CHECK_PORT" "$HEALTH_CHECK_PORT"

MAX_CLIENTS=$(ask_question "MAX_CLIENTS" "Maximum Concurrent Clients" "4")
update_env_var "MAX_CLIENTS" "$MAX_CLIENTS"

MAX_CONNECTION_TIME=$(ask_question "MAX_CONNECTION_TIME" "Max Connection Time (seconds)" "600")
update_env_var "MAX_CONNECTION_TIME" "$MAX_CONNECTION_TIME"

# =============================================================================
# Docker Configuration
# =============================================================================

echo ""
echo -e "${CYAN}Docker Configuration${NC}"
echo "============================================================================"

DOCKER_IMAGE=$(ask_question "DOCKER_IMAGE" "Docker Image Name" "whisperlive-runpod")
update_env_var "DOCKER_IMAGE" "$DOCKER_IMAGE"

DOCKER_TAG=$(ask_question "DOCKER_TAG" "Docker Tag" "latest")
update_env_var "DOCKER_TAG" "$DOCKER_TAG"

# =============================================================================
# Deployment Metadata (Auto-Generated)
# =============================================================================

echo ""
echo -e "${CYAN}Generating deployment metadata...${NC}"

DEPLOYMENT_ID=$(generate_deployment_id)
update_env_var "DEPLOYMENT_ID" "$DEPLOYMENT_ID"

DEPLOYMENT_TIMESTAMP=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
update_env_var "DEPLOYMENT_TIMESTAMP" "$DEPLOYMENT_TIMESTAMP"
