#!/bin/bash
#===============================================================================
# 425-TEST--long-transcription.sh
# Tests long audio transcription with proper segment collection
#===============================================================================
#
# PROBLEM THIS SCRIPT SOLVES:
# ---------------------------
# The previous test sent audio at 29x realtime (56 min in ~2 min) with only
# 0.001s timeout between chunks to check for responses. This caused the test
# to MISS most transcription segments - the server was transcribing correctly,
# but the client wasn't listening!
#
# Result: 56 minutes of audio -> only 45 segments captured (should be ~500+)
#
# HOW THIS SCRIPT FIXES IT:
# -------------------------
# Uses async websockets with TWO TASKS running simultaneously:
#
#   Task 1 (Sender):    Sends audio chunks at 2x realtime
#                       (controlled rate so server can keep up)
#
#   Task 2 (Receiver):  Continuously listens for transcription segments
#                       in the background, capturing EVERYTHING
#
# After all audio is sent, we wait for final segments to arrive.
#
# This ensures we capture ALL transcription segments, even for hour-long files.
#
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library (optional - script can work standalone)
if [ -f "$SCRIPT_DIR/000-LIB--common-functions.sh" ]; then
    source "$SCRIPT_DIR/000-LIB--common-functions.sh"
fi

# Parse arguments
AUDIO_FILE=""
HOST=""
OUTPUT_FILE=""
MODEL="small.en"

usage() {
    echo "Usage: $0 --audio <file> --host <host> [--output <file>] [--model <model>]"
    echo ""
    echo "Options:"
    echo "  --audio FILE    Audio file to transcribe (MP3, WAV, etc.)"
    echo "  --host HOST     Server host (IP or hostname)"
    echo "  --output FILE   Output file for transcript (default: /tmp/transcript.txt)"
    echo "  --model MODEL   Whisper model (default: small.en)"
    echo ""
    echo "Examples:"
    echo "  $0 --audio podcast.mp3 --host 3.144.156.55"
    echo "  $0 --audio podcast.mp3 --host 3.144.156.55 --output transcript.txt"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --audio)
            AUDIO_FILE="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$AUDIO_FILE" ]; then
    echo "Error: --audio is required"
    usage
    exit 1
fi

if [ -z "$HOST" ]; then
    echo "Error: --host is required"
    usage
    exit 1
fi

# Default output file
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="/tmp/whisperlive-test/long_transcript.txt"
fi

# Create output directory
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Get audio file (download if S3 URL)
LOCAL_AUDIO="$AUDIO_FILE"
if [[ "$AUDIO_FILE" == s3://* ]]; then
    echo "Downloading from S3: $AUDIO_FILE"
    LOCAL_AUDIO="/tmp/whisperlive-test/$(basename "$AUDIO_FILE")"
    mkdir -p /tmp/whisperlive-test
    aws s3 cp "$AUDIO_FILE" "$LOCAL_AUDIO"
fi

# Get audio duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$LOCAL_AUDIO" 2>/dev/null | cut -d. -f1)
echo "Audio file: $LOCAL_AUDIO"
echo "Duration: ${DURATION}s (~$((DURATION / 60)) minutes)"

# Run Python test script
echo ""
echo "Starting long transcription test..."
echo "Host: $HOST:9090"
echo "Model: $MODEL"
echo "Output: $OUTPUT_FILE"
echo ""

python3 << 'PYTHON_SCRIPT' - "$LOCAL_AUDIO" "$HOST" "$OUTPUT_FILE" "$MODEL"
import sys
import json
import time
import asyncio
import subprocess
from pathlib import Path

# Parse arguments
audio_file = sys.argv[1]
host = sys.argv[2]
output_file = sys.argv[3]
model = sys.argv[4]

print(f"=== Long Transcription Test ===")
print(f"Audio: {audio_file}")
print(f"Server: ws://{host}:9090")
print(f"Model: {model}")

# Convert audio to raw PCM using ffmpeg
print("\nConverting audio to PCM format...")
pcm_file = "/tmp/whisperlive-test/audio.pcm"
result = subprocess.run([
    "ffmpeg", "-y", "-i", audio_file,
    "-ar", "16000",      # 16kHz sample rate
    "-ac", "1",          # Mono
    "-f", "f32le",       # Float32 little-endian
    pcm_file
], capture_output=True, text=True)

if result.returncode != 0:
    print(f"FFmpeg error: {result.stderr}")
    sys.exit(1)

# Get PCM file size
pcm_size = Path(pcm_file).stat().st_size
audio_seconds = pcm_size / (16000 * 4)  # 16kHz * 4 bytes per float32
print(f"PCM size: {pcm_size / 1024 / 1024:.1f} MB")
print(f"Audio duration: {audio_seconds:.1f}s ({audio_seconds/60:.1f} minutes)")

# Install websockets if needed
try:
    import websockets
except ImportError:
    print("Installing websockets...")
    subprocess.run([sys.executable, "-m", "pip", "install", "websockets>=12.0"],
                   capture_output=True)
    import websockets

# Shared state
segments = []
send_complete = asyncio.Event()

async def receive_messages(ws, segments):
    """Continuously receive transcription segments."""
    last_segment_time = time.time()

    print("Receiver task started")
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
                            print(f"  [{len(segments):4d}] {text[:70]}{'...' if len(text) > 70 else ''}")

                elif "message" in data:
                    msg = data.get("message", "")
                    if msg == "SERVER_READY":
                        print(f"Server ready (backend: {data.get('backend', 'unknown')})")
                    elif msg == "DISCONNECT":
                        print("Server sent disconnect")
                        break

            except asyncio.TimeoutError:
                # Check if we should stop (all audio sent + no segments for 15s)
                if send_complete.is_set() and time.time() - last_segment_time > 15:
                    print("No new segments for 15s after send complete, finishing")
                    break
                continue

    except websockets.exceptions.ConnectionClosed as e:
        print(f"Connection closed: {e}")
    except Exception as e:
        print(f"Receiver error: {e}")
    finally:
        print(f"Receiver done. Total segments: {len(segments)}")

async def send_audio(ws, pcm_file, pcm_size):
    """Send audio chunks at controlled rate."""
    CHUNK_SIZE = 16000 * 4  # 1 second of audio
    SEND_RATE = 2  # Send at 2x realtime (more reliable)

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
            expected_time = bytes_sent / (16000 * 4) / SEND_RATE
            if expected_time > elapsed:
                await asyncio.sleep(expected_time - elapsed)

            # Progress update every 5%
            progress = int(bytes_sent / pcm_size * 100)
            if progress >= last_progress + 5:
                elapsed = time.time() - start_time
                print(f"Progress: {progress}% ({bytes_sent/1024/1024:.1f}MB) - {elapsed:.0f}s - {len(segments)} segments")
                last_progress = progress

    send_time = time.time() - start_time
    print(f"\nAll audio sent ({bytes_sent/1024/1024:.1f}MB in {send_time:.1f}s)")
    send_complete.set()

async def main():
    global segments

    uri = f"ws://{host}:9090"
    print(f"\nConnecting to {uri}...")

    async with websockets.connect(uri, ping_interval=30, ping_timeout=30) as ws:
        print("Connected!")

        # Send configuration
        config = {
            "uid": "long-test",
            "language": "en",
            "task": "transcribe",
            "model": model,
            "use_vad": True
        }
        await ws.send(json.dumps(config))
        print(f"Sent config (model: {model})")

        # Wait for server ready
        response = await asyncio.wait_for(ws.recv(), timeout=30)
        data = json.loads(response)
        print(f"Server: {data}")

        if data.get("status") == "ERROR":
            print(f"Server error: {data.get('message')}")
            return

        start_time = time.time()

        # Run sender and receiver concurrently
        receiver_task = asyncio.create_task(receive_messages(ws, segments))
        sender_task = asyncio.create_task(send_audio(ws, pcm_file, pcm_size))

        # Wait for sender to complete
        await sender_task

        # Wait additional time for final segments
        print("Waiting for final transcriptions (up to 60s)...")
        await asyncio.sleep(5)  # Give some time for final segments

        # Wait for receiver to finish (with timeout)
        try:
            await asyncio.wait_for(receiver_task, timeout=60)
        except asyncio.TimeoutError:
            print("Receiver timeout, continuing...")
            receiver_task.cancel()

        total_time = time.time() - start_time
        processing_ratio = audio_seconds / total_time if total_time > 0 else 0

        print(f"\n{'='*50}")
        print(f"=== TEST COMPLETE ===")
        print(f"Total time: {total_time:.1f} seconds ({total_time/60:.1f} minutes)")
        print(f"Audio duration: {audio_seconds/60:.1f} minutes")
        print(f"Processing ratio: {processing_ratio:.1f}x realtime")
        print(f"Transcription segments: {len(segments)}")

        # Save transcript
        sorted_segments = sorted(segments, key=lambda x: x.get("start", 0))

        with open(output_file, "w") as f:
            for seg in sorted_segments:
                text = seg.get("text", "").strip()
                start = seg.get("start", 0)
                end = seg.get("end", 0)
                f.write(f"[{start:.1f}s - {end:.1f}s] {text}\n")

        # Also save raw JSON
        json_file = output_file.replace(".txt", ".json")
        with open(json_file, "w") as jf:
            json.dump(sorted_segments, jf, indent=2)

        # Estimate transcript coverage
        if sorted_segments:
            max_end = max(s.get("end", 0) for s in sorted_segments)
            coverage = max_end / audio_seconds * 100 if audio_seconds > 0 else 0
            print(f"Audio coverage: {coverage:.1f}% (transcribed up to {max_end:.1f}s)")

        print(f"\nTranscript saved to: {output_file}")
        print(f"JSON saved to: {json_file}")

        # Show first and last segments
        if sorted_segments:
            print(f"\nFirst segment:")
            s = sorted_segments[0]
            print(f"  [{s.get('start', 0):.1f}s] {s.get('text', '')[:100]}")

            print(f"\nLast segment:")
            s = sorted_segments[-1]
            print(f"  [{s.get('start', 0):.1f}s] {s.get('text', '')[:100]}")

# Run async main
asyncio.run(main())
PYTHON_SCRIPT

echo ""
echo "Test complete. Transcript saved to: $OUTPUT_FILE"
