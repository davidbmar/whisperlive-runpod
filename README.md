# WhisperLive on RunPod

Real-time speech-to-text transcription using OpenAI's Whisper model, optimized for deployment on RunPod GPU Pods.

## Quick Start

### 1. Configure

```bash
./scripts/000-questions.sh
```

This will prompt for:
- RunPod API key (from https://www.runpod.io/console/user/settings)
- GPU type (default: RTX 3090)
- Cloud type (default: COMMUNITY for lower cost)
- Docker Hub credentials

### 2. Build & Push Docker Image

```bash
# Build slim image (recommended, ~3-4GB)
./scripts/200-build-image-local.sh --slim

# Push to Docker Hub
export DOCKER_PASSWORD='your-docker-hub-token'
./scripts/205-push-to-registry.sh --slim
```

### 3. Deploy to RunPod

```bash
./scripts/210-deploy-to-runpod.sh
```

### 4. Test

```bash
# Check health endpoints
./scripts/215-test-runpod-health.sh

# Test transcription
./scripts/220-test-transcription.sh
```

## Usage

After deployment, connect to WhisperLive via WebSocket:

```python
from whisper_live.client import TranscriptionClient

client = TranscriptionClient(
    host='YOUR_POD_ID-9090.proxy.runpod.net',
    port=443,
    is_multilingual=False,
    lang='en',
    translate=False,
    use_ssl=True
)
```

Or use the CLI client:
```bash
python run_client.py \
    --host YOUR_POD_ID-9090.proxy.runpod.net \
    --port 443 \
    --model small.en \
    --lang en
```

## Scripts Reference

### Configuration
| Script | Description |
|--------|-------------|
| `000-questions.sh` | Interactive configuration wizard |

### Deployment (200-series)
| Script | Description |
|--------|-------------|
| `200-build-image-local.sh` | Build Docker image locally |
| `205-push-to-registry.sh` | Push image to Docker Hub |
| `210-deploy-to-runpod.sh` | Deploy pod to RunPod |
| `215-test-runpod-health.sh` | Test health endpoints |
| `220-test-transcription.sh` | Test transcription |

### Operations (900-series)
| Script | Description |
|--------|-------------|
| `900-runpod-status.sh` | Show pod status |
| `905-runpod-logs.sh` | Access pod logs |
| `910-runpod-restart.sh` | Restart pod |
| `915-runpod-stop.sh` | Stop or terminate pod |

## Cost Estimates

### Community Cloud (Recommended)
| GPU | VRAM | Cost/Hour | Best For |
|-----|------|-----------|----------|
| RTX 3060 | 12GB | ~$0.10 | **small.en (recommended)** |
| RTX 3070 | 8GB | ~$0.12 | tiny/base models |
| RTX 3080 | 10GB | ~$0.14 | small models |
| RTX 3090 | 24GB | ~$0.22 | medium models |
| RTX 4090 | 24GB | ~$0.34 | Best performance |

The RTX 3060 with 12GB VRAM is the best value for the `small.en` model - it only uses ~2-4GB VRAM.

Spot/Interruptible pricing can be ~50% cheaper.

## Configuration Options

Environment variables (set in `.env` or at runtime):

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_MODEL` | `small.en` | Whisper model (tiny.en, base.en, small.en, medium.en) |
| `WHISPER_COMPUTE_TYPE` | `int8` | Compute precision (int8, float16, float32) |
| `MAX_CLIENTS` | `4` | Maximum concurrent connections |
| `MAX_CONNECTION_TIME` | `600` | Connection timeout in seconds |

## Health Endpoints

The container exposes health check endpoints on port 9999:

- `GET /health` - Liveness check (200 if running)
- `GET /ready` - Readiness check (200 if accepting connections)
- `GET /status` - Detailed status with GPU info

## Architecture

```
Client --WSS--> RunPod Proxy --WS--> GPU Pod (WhisperLive:9090)
                                            |
                                            └-- Health Check (HTTP:9999)
```

## Image Variants

- **slim** (~3-4GB): Transcription only, faster deployment
- **full** (~9GB): Includes speaker diarization

## Requirements

- Docker installed locally
- Docker Hub account
- RunPod account with API key

## License

Based on [Collabora's WhisperLive](https://github.com/collabora/WhisperLive).
