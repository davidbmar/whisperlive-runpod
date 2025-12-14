# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperLive is a real-time speech-to-text transcription application using OpenAI's Whisper model. This repository is specifically configured for deployment on RunPod GPU Pods.

## Script Organization

Scripts follow the naming convention `NUM-CLASS--descriptive-name.sh`:
- **0xx** = Setup & Configuration
- **1xx** = Build & Registry (Docker)
- **2xx** = EC2 Validation (cheap testing before RunPod)
- **3xx** = RunPod Deployment (production)
- **4xx** = Testing & Validation
- **9xx** = Operations & Utilities

## Build & Run Commands

### Configuration
```bash
./scripts/010-SETUP--interactive-configuration.sh  # Interactive setup generating .env
```

### Build Docker Image
```bash
./scripts/100-BUILD--docker-image-local.sh --slim     # Slim image (~3-4GB)
./scripts/100-BUILD--docker-image-local.sh            # Full image with diarization (~9GB)
```

### Validate on EC2 (Recommended Before RunPod)
```bash
./scripts/200-EC2--launch-gpu-test-instance.sh        # Launch g4dn.xlarge (~$0.52/hr)
./scripts/210-EC2--run-container-and-test.sh --pull   # Pull image and test
./scripts/400-TEST--health-endpoints.sh               # Verify health endpoints
./scripts/220-EC2--terminate-and-cleanup.sh           # Terminate when done
```

### Deploy to RunPod
```bash
export DOCKER_PASSWORD='your-token'
./scripts/110-BUILD--push-to-dockerhub.sh --slim      # Push to Docker Hub
./scripts/300-RUNPOD--deploy-pod.sh                   # Deploy pod
./scripts/310-RUNPOD--wait-for-ready.sh               # Wait for ready state
```

### Test Deployment
```bash
./scripts/400-TEST--health-endpoints.sh               # Test health endpoints
./scripts/410-TEST--websocket-transcription.sh        # Test transcription
```

### Operations
```bash
./scripts/900-OPS--runpod-status.sh                   # Show pod status
./scripts/910-OPS--runpod-logs.sh                     # Access logs
./scripts/920-OPS--runpod-restart.sh                  # Restart pod
./scripts/930-OPS--runpod-stop-terminate.sh           # Stop pod
./scripts/930-OPS--runpod-stop-terminate.sh --terminate  # Delete pod permanently
./scripts/990-OPS--check-all-resources.sh             # Check all running GPU resources
```

### Running the Server (local/dev)
```bash
python3 run_server.py --port 9090 --backend faster_whisper --max_clients 4
```

### Running the Client
```bash
python3 run_client.py --host localhost --port 9090 --model small.en --lang en
```

## Recommended Workflow

```
1. SETUP
   ./scripts/010-SETUP--interactive-configuration.sh
                         ↓
2. BUILD
   ./scripts/100-BUILD--docker-image-local.sh --slim
   ./scripts/110-BUILD--push-to-dockerhub.sh --slim
                         ↓
3. VALIDATE ON EC2 (cheap, ~$0.52/hr, auto-terminates after 90min)
   ./scripts/200-EC2--launch-gpu-test-instance.sh
   ./scripts/210-EC2--run-container-and-test.sh --pull
   ./scripts/400-TEST--health-endpoints.sh
   ./scripts/220-EC2--terminate-and-cleanup.sh
                         ↓
       EC2 tests pass? → Yes → Continue
                       → No  → Fix & rebuild
                         ↓
4. DEPLOY TO RUNPOD (production)
   ./scripts/300-RUNPOD--deploy-pod.sh --slim
   ./scripts/310-RUNPOD--wait-for-ready.sh
   ./scripts/400-TEST--health-endpoints.sh
                         ↓
5. OPERATIONS
   ./scripts/900-OPS--runpod-status.sh
   ./scripts/930-OPS--runpod-stop-terminate.sh
```

## Architecture

### Core Components

**Server (`whisper_live/server.py`)**
- `TranscriptionServer`: Main WebSocket server handling client connections
- Manages client lifecycle, timeouts, and capacity limits

**Client (`whisper_live/client.py`)**
- `Client`: Low-level WebSocket client for audio streaming
- `TranscriptionClient`: High-level interface for file/microphone transcription

**Backends (`whisper_live/backend/`)**
All backends extend `ServeClientBase` from `base.py`:
- `faster_whisper_backend.py`: Default CPU/GPU inference using CTranslate2

**VAD (`whisper_live/vad.py`)**
Voice Activity Detection using Silero VAD (ONNX) to filter silence.

### RunPod-Specific Components

**Container Files (`runpod/`)**
- `Dockerfile.runpod`: Full image with diarization
- `Dockerfile.runpod-slim`: Lightweight image without diarization
- `entrypoint.sh`: Container startup with GPU detection and logging
- `healthcheck.py`: HTTP health check server on port 9999

**Scripts (`scripts/`)**
- `000-LIB--common-functions.sh`: Shared functions including RunPod REST API calls
- `010-SETUP--interactive-configuration.sh`: Configuration wizard
- `1xx-BUILD-*.sh`: Build and push scripts
- `2xx-EC2-*.sh`: EC2 validation scripts
- `3xx-RUNPOD-*.sh`: RunPod deployment scripts
- `4xx-TEST-*.sh`: Testing scripts
- `9xx-OPS-*.sh`: Operations scripts

### Message Protocol (JSON over WebSocket)

Client → Server:
```json
{"uid": "client-id", "language": "en", "task": "transcribe", "model": "small", "use_vad": true}
```

Server → Client:
```json
{"uid": "client-id", "result": [{"start": 0.0, "end": 1.5, "text": "Hello"}], "language": "en"}
```

### Audio Specifications
- Sample Rate: 16,000 Hz
- Format: Float32
- Channels: Mono

## Directory Structure

```
whisperlive-runpod/
├── whisper_live/           # Core Python package
│   ├── backend/            # Backend implementations
│   ├── client.py           # Client implementation
│   ├── server.py           # Server implementation
│   └── vad.py              # Voice Activity Detection
├── runpod/                 # RunPod deployment files
│   ├── Dockerfile.runpod   # Full container image
│   ├── Dockerfile.runpod-slim
│   ├── entrypoint.sh       # Container startup
│   └── healthcheck.py      # Health check server
├── scripts/                # Deployment scripts
│   ├── config/             # Configuration modules
│   ├── 000-LIB--common-functions.sh
│   ├── 010-SETUP--interactive-configuration.sh
│   ├── 1xx-BUILD-*.sh      # Build/push scripts
│   ├── 2xx-EC2-*.sh        # EC2 validation scripts
│   ├── 3xx-RUNPOD-*.sh     # RunPod deployment scripts
│   ├── 4xx-TEST-*.sh       # Testing scripts
│   └── 9xx-OPS-*.sh        # Operations scripts
├── requirements/           # Python dependencies
├── run_server.py           # Server entry point
├── run_client.py           # Client entry point
├── .env.template           # Configuration template
└── .env                    # Active configuration (gitignored)
```

## RunPod API

The `000-LIB--common-functions.sh` includes functions for RunPod REST API:

```bash
runpod_api_call "GET" "/pods"                    # List pods
runpod_api_call "GET" "/pods/{id}"               # Get pod details
runpod_api_call "POST" "/pods" "$payload"        # Create pod
runpod_api_call "POST" "/pods/{id}/start"        # Start pod
runpod_api_call "POST" "/pods/{id}/stop"         # Stop pod
runpod_api_call "DELETE" "/pods/{id}"            # Terminate pod
```

## Key Environment Variables

| Variable | Description |
|----------|-------------|
| `RUNPOD_API_KEY` | RunPod API authentication |
| `RUNPOD_POD_ID` | Current pod ID |
| `RUNPOD_GPU_TYPE` | GPU type (e.g., "NVIDIA GeForce RTX 3090") |
| `RUNPOD_CLOUD_TYPE` | COMMUNITY or SECURE |
| `DOCKER_HUB_USERNAME` | Docker Hub account |
| `WHISPER_MODEL` | Whisper model to use |
| `WHISPER_COMPUTE_TYPE` | Precision (int8, float16, float32) |

## Health Check Endpoints

Port 9999:
- `GET /health` - Basic liveness (200 OK if running)
- `GET /ready` - Readiness (200 if WhisperLive accepting connections)
- `GET /status` - Detailed JSON with GPU info, uptime, configuration

## Connection URLs

After deployment:
- WebSocket: `wss://{POD_ID}-9090.proxy.runpod.net`
- Health: `https://{POD_ID}-9999.proxy.runpod.net/health`
