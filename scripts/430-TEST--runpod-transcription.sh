#!/bin/bash
#===============================================================================
# 430-TEST--runpod-transcription.sh
# Test transcription on your RunPod deployment
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Tests your RunPod WhisperLive deployment by:
#   1. Checking pod status and health
#   2. Downloading a test audio file from S3 (or using a local file)
#   3. Sending audio to the WhisperLive WebSocket endpoint
#   4. Receiving and displaying transcription results
#   5. Saving the transcript to a file
#
# THE PROBLEM IT SOLVES:
# ----------------------
# After deploying to RunPod, you need to verify that:
#   - The WebSocket endpoint is accessible through RunPod's proxy
#   - GPU transcription is working correctly
#   - The model is loaded and processing audio
#
# WHAT YOU'LL SEE:
# ----------------
#   ============================================================================
#   Testing RunPod Transcription
#   ============================================================================
#
#   [1/4] Checking pod status...
#   Pod ID: abc123xyz
#   Status: RUNNING
#   Health: healthy
#
#   [2/4] Preparing test audio...
#   Using: s3://dbm-cf-2-web/integration-test/test-validation.wav
#   Duration: 61s (~1 minute)
#
#   [3/4] Running transcription test...
#   Connecting to wss://abc123xyz-9090.proxy.runpod.net...
#   Connected!
#   Server: faster_whisper backend
#   Sending audio at 2x realtime...
#     [   1] Hello and welcome to this test...
#     [   2] This is a sample transcription...
#
#   [4/4] Results
#   Segments received: 12
#   Transcript saved to: /tmp/runpod-transcript.txt
#
# USAGE:
#   ./scripts/430-TEST--runpod-transcription.sh                    # Use default test audio
#   ./scripts/430-TEST--runpod-transcription.sh --audio file.wav   # Use custom audio
#   ./scripts/430-TEST--runpod-transcription.sh --quick            # Quick 30s test
#
# PREREQUISITES:
#   - Pod deployed and running (./scripts/300-RUNPOD--deploy-pod.sh)
#   - RUNPOD_POD_ID in .env
#
#===============================================================================

set -euo pipefail

SCRIPT_NAME="430-TEST--runpod-transcription"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/000-LIB--common-functions.sh"
start_logging "$SCRIPT_NAME"

# Default settings
AUDIO_SOURCE="s3://dbm-cf-2-web/integration-test/test-validation.wav"
OUTPUT_FILE="/tmp/whisperlive-test/runpod_transcript.txt"
QUICK_TEST=false
MODEL="small.en"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --audio)
            AUDIO_SOURCE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --quick)
            QUICK_TEST=true
            shift
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --help|-h)
            head -55 "$0" | tail -50
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================================"
echo "Testing RunPod Transcription"
echo "============================================================================"
echo ""

# ============================================================================
# [1/4] Check pod status
# ============================================================================
echo -e "${BLUE}[1/4] Checking pod status...${NC}"

if ! load_env_or_fail 2>/dev/null; then
    print_status "error" "No .env file found"
    echo "Run: ./scripts/010-SETUP--interactive-configuration.sh"
    exit 1
fi

POD_ID="${RUNPOD_POD_ID:-}"
if [ -z "$POD_ID" ]; then
    print_status "error" "No pod ID found in .env"
    echo "Deploy a pod first: ./scripts/300-RUNPOD--deploy-pod.sh"
    exit 1
fi

echo "  Pod ID: $POD_ID"

# Check pod is running
STATUS=$(curl -s -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    "https://rest.runpod.io/v1/pods/${POD_ID}" 2>/dev/null | jq -r '.desiredStatus // "unknown"')

if [ "$STATUS" != "RUNNING" ]; then
    print_status "error" "Pod is not running (status: $STATUS)"
    echo "Start the pod: ./scripts/920-OPS--runpod-restart.sh"
    exit 1
fi
echo "  Status: $STATUS"

# Check health
HEALTH_URL="https://${POD_ID}-9999.proxy.runpod.net/health"
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")

if [ "$HEALTH_CODE" != "200" ]; then
    print_status "warn" "Health check returned HTTP $HEALTH_CODE"
    echo "  Container may still be loading. Wait a minute and try again."
    echo "  Check status: ./scripts/900-OPS--runpod-status.sh"
    exit 1
fi

print_status "ok" "Pod is healthy"
echo ""

# ============================================================================
# [2/4] Prepare test audio
# ============================================================================
echo -e "${BLUE}[2/4] Preparing test audio...${NC}"

mkdir -p /tmp/whisperlive-test
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Download if S3 URL
LOCAL_AUDIO="$AUDIO_SOURCE"
if [[ "$AUDIO_SOURCE" == s3://* ]]; then
    LOCAL_AUDIO="/tmp/whisperlive-test/$(basename "$AUDIO_SOURCE")"
    echo "  Downloading from S3: $AUDIO_SOURCE"
    aws s3 cp "$AUDIO_SOURCE" "$LOCAL_AUDIO" --quiet
fi

# Get duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$LOCAL_AUDIO" 2>/dev/null | cut -d. -f1)
echo "  Audio file: $(basename "$LOCAL_AUDIO")"
echo "  Duration: ${DURATION}s (~$((DURATION / 60)) minutes)"

# For quick test, truncate to 30 seconds
if [ "$QUICK_TEST" = true ] && [ "$DURATION" -gt 30 ]; then
    echo "  Quick test mode: using first 30 seconds only"
    DURATION=30
fi

print_status "ok" "Audio ready"
echo ""

# ============================================================================
# [3/4] Run transcription test
# ============================================================================
echo -e "${BLUE}[3/4] Running transcription test...${NC}"
echo ""

WS_URL="wss://${POD_ID}-9090.proxy.runpod.net"
echo "  WebSocket: $WS_URL"
echo "  Model: $MODEL"
echo ""

# Run Python transcription test
python3 << PYTHON_SCRIPT - "$LOCAL_AUDIO" "$WS_URL" "$OUTPUT_FILE" "$MODEL" "$QUICK_TEST"
import sys
import json
import time
import asyncio
import subprocess
from pathlib import Path

# Parse arguments
audio_file = sys.argv[1]
ws_url = sys.argv[2]
output_file = sys.argv[3]
model = sys.argv[4]
quick_test = sys.argv[5] == "true"

print(f"=== RunPod Transcription Test ===")
print(f"Audio: {audio_file}")
print(f"Server: {ws_url}")

# Convert audio to PCM
print("\nConverting audio to PCM format...")
pcm_file = "/tmp/whisperlive-test/test_audio.pcm"

# For quick test, limit to 30 seconds
if quick_test:
    cmd = ["ffmpeg", "-y", "-i", audio_file, "-t", "30",
           "-ar", "16000", "-ac", "1", "-f", "f32le", pcm_file]
else:
    cmd = ["ffmpeg", "-y", "-i", audio_file,
           "-ar", "16000", "-ac", "1", "-f", "f32le", pcm_file]

result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    print(f"FFmpeg error: {result.stderr}")
    sys.exit(1)

pcm_size = Path(pcm_file).stat().st_size
audio_seconds = pcm_size / (16000 * 4)
print(f"PCM size: {pcm_size / 1024 / 1024:.1f} MB ({audio_seconds:.0f}s)")

# Install websockets if needed
try:
    import websockets
except ImportError:
    print("Installing websockets...")
    subprocess.run([sys.executable, "-m", "pip", "install", "websockets>=12.0"],
                   capture_output=True)
    import websockets

segments = []
send_complete = asyncio.Event()

async def receive_messages(ws, segments):
    last_segment_time = time.time()
    try:
        while True:
            try:
                message = await asyncio.wait_for(ws.recv(), timeout=1.0)
                data = json.loads(message)

                if "segments" in data:
                    for seg in data["segments"]:
                        text = seg.get("text", "").strip()
                        if text and text not in [s.get("text") for s in segments]:
                            segments.append(seg)
                            last_segment_time = time.time()
                            display = text[:65] + "..." if len(text) > 65 else text
                            print(f"  [{len(segments):4d}] {display}")

                elif "message" in data:
                    msg = data.get("message", "")
                    if msg == "SERVER_READY":
                        print(f"Server ready (backend: {data.get('backend', 'unknown')})")

            except asyncio.TimeoutError:
                if send_complete.is_set() and time.time() - last_segment_time > 10:
                    break
                continue
    except websockets.exceptions.ConnectionClosed:
        pass

async def send_audio(ws, pcm_file, pcm_size):
    CHUNK_SIZE = 16000 * 4  # 1 second
    SEND_RATE = 2  # 2x realtime

    print(f"\nSending audio at {SEND_RATE}x realtime...")
    start_time = time.time()

    with open(pcm_file, "rb") as f:
        bytes_sent = 0
        last_progress = 0

        while True:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break

            await ws.send(chunk)
            bytes_sent += len(chunk)

            # Rate limiting
            elapsed = time.time() - start_time
            expected = bytes_sent / (16000 * 4) / SEND_RATE
            if expected > elapsed:
                await asyncio.sleep(expected - elapsed)

            # Progress every 25%
            progress = int(bytes_sent / pcm_size * 100)
            if progress >= last_progress + 25:
                print(f"Progress: {progress}% ({bytes_sent/1024/1024:.1f}MB)")
                last_progress = progress

    print(f"\nAll audio sent ({bytes_sent/1024/1024:.1f}MB)")
    send_complete.set()

async def main():
    global segments

    print(f"\nConnecting to {ws_url}...")

    try:
        async with websockets.connect(ws_url, ping_interval=30, ping_timeout=30,
                                       additional_headers={"Origin": "https://runpod.io"}) as ws:
            print("Connected!")

            config = {
                "uid": "runpod-test",
                "language": "en",
                "task": "transcribe",
                "model": model,
                "use_vad": True
            }
            await ws.send(json.dumps(config))
            print(f"Sent config (model: {model})")

            response = await asyncio.wait_for(ws.recv(), timeout=30)
            data = json.loads(response)
            print(f"Server: {data}")

            if data.get("status") == "ERROR":
                print(f"Server error: {data.get('message')}")
                return

            start_time = time.time()

            receiver_task = asyncio.create_task(receive_messages(ws, segments))
            sender_task = asyncio.create_task(send_audio(ws, pcm_file, pcm_size))

            await sender_task
            print("Waiting for final transcriptions...")
            await asyncio.sleep(5)

            try:
                await asyncio.wait_for(receiver_task, timeout=30)
            except asyncio.TimeoutError:
                receiver_task.cancel()

            total_time = time.time() - start_time
            print(f"\n{'='*50}")
            print(f"=== TEST COMPLETE ===")
            print(f"Time: {total_time:.1f}s | Segments: {len(segments)}")

            # Save transcript
            sorted_segments = sorted(segments, key=lambda x: x.get("start", 0))
            with open(output_file, "w") as f:
                for seg in sorted_segments:
                    text = seg.get("text", "").strip()
                    start = seg.get("start", 0)
                    end = seg.get("end", 0)
                    f.write(f"[{start:.1f}s - {end:.1f}s] {text}\n")

            print(f"Transcript: {output_file}")

            if sorted_segments:
                print(f"\nFirst: [{sorted_segments[0].get('start', 0):.1f}s] {sorted_segments[0].get('text', '')[:80]}")
                print(f"Last:  [{sorted_segments[-1].get('start', 0):.1f}s] {sorted_segments[-1].get('text', '')[:80]}")

    except Exception as e:
        print(f"Connection error: {e}")
        print("\nTroubleshooting:")
        print("  1. Check pod status: ./scripts/900-OPS--runpod-status.sh")
        print("  2. Check pod logs: ./scripts/910-OPS--runpod-logs.sh")
        print("  3. Try restarting: ./scripts/920-OPS--runpod-restart.sh")
        sys.exit(1)

asyncio.run(main())
PYTHON_SCRIPT

PYTHON_EXIT=$?
echo ""

# ============================================================================
# [4/4] Results
# ============================================================================
echo -e "${BLUE}[4/4] Results${NC}"

if [ $PYTHON_EXIT -eq 0 ]; then
    print_status "ok" "Transcription test completed"
    echo ""
    echo "Transcript saved to: $OUTPUT_FILE"
    echo ""

    # Show word count
    if [ -f "$OUTPUT_FILE" ]; then
        LINES=$(wc -l < "$OUTPUT_FILE")
        WORDS=$(wc -w < "$OUTPUT_FILE")
        echo "  Lines: $LINES"
        echo "  Words: $WORDS"
    fi
else
    print_status "error" "Transcription test failed"
    echo ""
    echo "Check the logs above for error details."
    exit 1
fi

echo ""
echo "============================================================================"
echo -e "${GREEN}RunPod Transcription Test Complete!${NC}"
echo "============================================================================"
echo ""
echo "Your RunPod deployment is working correctly."
echo ""
echo "Next Steps:"
echo "  View transcript:  cat $OUTPUT_FILE"
echo "  Long test:        ./scripts/425-TEST--long-transcription.sh --host \${POD_ID}-9090.proxy.runpod.net"
echo "  Check status:     ./scripts/900-OPS--runpod-status.sh"
echo "  Stop when done:   ./scripts/930-OPS--runpod-stop-terminate.sh"
echo ""
