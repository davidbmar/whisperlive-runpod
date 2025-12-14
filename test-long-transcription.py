#!/usr/bin/env python3
"""
Long transcription test for RunPod WhisperLive deployment.
Sends a large audio file and saves the transcription results.
"""

import asyncio
import websockets
import json
import wave
import time
import sys
import os
from datetime import datetime

# Configuration
POD_ID = os.environ.get('RUNPOD_POD_ID', 'g13ueotnboqg8f')
WS_URI = f"wss://{POD_ID}-9090.proxy.runpod.net"
AUDIO_FILE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/audio2.wav"
RUN_NUMBER = int(sys.argv[2]) if len(sys.argv) > 2 else 1

# Audio chunk settings - match WhisperLive expectations
CHUNK_DURATION_MS = 100  # 100ms chunks
SAMPLE_RATE = 16000

async def run_transcription():
    """Send audio and collect transcription results."""

    # Load audio file
    print(f"Loading audio file: {AUDIO_FILE}")
    with wave.open(AUDIO_FILE, 'rb') as wf:
        sample_rate = wf.getframerate()
        n_frames = wf.getnframes()
        duration = n_frames / sample_rate
        audio_data = wf.readframes(n_frames)

    print(f"  Duration: {duration:.1f}s ({duration/60:.1f} min)")
    print(f"  Sample rate: {sample_rate} Hz")
    print(f"  Size: {len(audio_data) / 1024 / 1024:.1f} MB")
    print()

    # Convert to float32
    import numpy as np
    audio_int16 = np.frombuffer(audio_data, dtype=np.int16)
    audio_float32 = audio_int16.astype(np.float32) / 32768.0

    # Chunk size in samples (100ms at 16kHz = 1600 samples)
    chunk_samples = int(SAMPLE_RATE * CHUNK_DURATION_MS / 1000)

    results = []
    last_text = ""
    start_time = time.time()

    print(f"Connecting to {WS_URI}...")

    try:
        async with websockets.connect(
            WS_URI,
            ping_interval=20,
            ping_timeout=60,
            close_timeout=10,
            max_size=2**24
        ) as ws:
            print("Connected!")

            # Send config
            config = {
                "uid": f"long-test-{RUN_NUMBER}",
                "language": "en",
                "task": "transcribe",
                "model": "small.en",
                "use_vad": True
            }
            await ws.send(json.dumps(config))
            print(f"Sent config: {json.dumps(config)}")
            print()

            # Track progress
            total_chunks = len(audio_float32) // chunk_samples
            chunks_sent = 0
            receive_done = asyncio.Event()

            async def sender():
                nonlocal chunks_sent
                # Send audio in 100ms chunks with real-time pacing
                for i in range(0, len(audio_float32), chunk_samples):
                    chunk = audio_float32[i:i+chunk_samples]
                    chunk_bytes = chunk.tobytes()
                    try:
                        await ws.send(chunk_bytes)
                        chunks_sent += 1

                        # Progress update every 10%
                        progress = chunks_sent * 100 // total_chunks
                        if chunks_sent % (total_chunks // 10 + 1) == 0:
                            elapsed = time.time() - start_time
                            print(f"  [{elapsed:.0f}s] Sent {progress}%...")

                        # Pace the sending - stream at 2x real-time
                        # (50ms sleep for 100ms chunks = 2x speed)
                        await asyncio.sleep(CHUNK_DURATION_MS / 1000 / 2)
                    except websockets.exceptions.ConnectionClosed:
                        print(f"\nConnection closed after {chunks_sent} chunks")
                        break

                print(f"\nFinished sending audio ({chunks_sent} chunks)")
                # Wait for final transcriptions
                await asyncio.sleep(10)
                receive_done.set()

            async def receiver():
                nonlocal last_text
                segment_count = 0
                while not receive_done.is_set():
                    try:
                        msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                        data = json.loads(msg)

                        if "segments" in data:
                            for seg in data["segments"]:
                                results.append(seg)
                                text = seg.get("text", "").strip()
                                if text and text != last_text:
                                    segment_count += 1
                                    elapsed = time.time() - start_time
                                    # Print every 5th segment to reduce output
                                    if segment_count % 5 == 1:
                                        print(f"    [{elapsed:.1f}s] #{segment_count}: {text[:60]}...")
                                    last_text = text
                        elif "message" in data:
                            if "error" in data["message"].lower():
                                print(f"Server error: {data['message']}")

                    except asyncio.TimeoutError:
                        continue
                    except websockets.exceptions.ConnectionClosed:
                        break
                    except Exception as e:
                        print(f"Receiver error: {e}")
                        break

            # Run sender and receiver concurrently
            await asyncio.gather(
                sender(),
                receiver()
            )

    except Exception as e:
        print(f"Connection error: {e}")

    end_time = time.time()
    total_time = end_time - start_time

    return results, total_time, duration

async def main():
    print("=" * 70)
    print(f"Long Transcription Test - Run #{RUN_NUMBER}")
    print("=" * 70)
    print(f"Started: {datetime.now().isoformat()}")
    print()

    results, total_time, audio_duration = await run_transcription()

    # Compile final transcript - deduplicate overlapping segments
    seen_texts = set()
    transcript_lines = []
    for seg in results:
        text = seg.get("text", "").strip()
        if text and text not in seen_texts:
            seen_texts.add(text)
            start = float(seg.get("start", 0))
            end = float(seg.get("end", 0))
            transcript_lines.append(f"[{start:.1f}s - {end:.1f}s] {text}")

    transcript = "\n".join(transcript_lines)

    # Save results
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    results_file = f"/home/ubuntu/event-b/whisperlive-runpod/artifacts/transcription-run{RUN_NUMBER}-{timestamp}.txt"
    os.makedirs(os.path.dirname(results_file), exist_ok=True)

    with open(results_file, 'w') as f:
        f.write(f"Transcription Results - Run #{RUN_NUMBER}\n")
        f.write(f"{'=' * 70}\n")
        f.write(f"Audio file: {AUDIO_FILE}\n")
        f.write(f"Audio duration: {audio_duration:.1f}s ({audio_duration/60:.1f} min)\n")
        f.write(f"Processing time: {total_time:.1f}s ({total_time/60:.1f} min)\n")
        f.write(f"Real-time factor: {total_time/audio_duration:.2f}x\n")
        f.write(f"Unique segments: {len(transcript_lines)}\n")
        f.write(f"{'=' * 70}\n\n")
        f.write(transcript)

    print()
    print("=" * 70)
    print("Results Summary")
    print("=" * 70)
    print(f"  Audio duration:   {audio_duration:.1f}s ({audio_duration/60:.1f} min)")
    print(f"  Processing time:  {total_time:.1f}s ({total_time/60:.1f} min)")
    print(f"  Real-time factor: {total_time/audio_duration:.2f}x")
    print(f"  Unique segments:  {len(transcript_lines)}")
    print(f"  Results saved to: {results_file}")
    print()

    return total_time, audio_duration, results_file

if __name__ == "__main__":
    asyncio.run(main())
