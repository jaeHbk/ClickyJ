#!/usr/bin/env python3
"""
Kokoro TTS sidecar for ClickyJ.

Replaces the paid ElevenLabs text-to-speech service with the open-source
Kokoro-82M model (Apache-2.0) running fully locally via kokoro-onnx (MIT).

The macOS app POSTs JSON {"text": "..."} to http://127.0.0.1:8757/tts and
gets back WAV (PCM signed 16-bit, mono, 24000 Hz) which AVAudioPlayer(data:)
decodes directly. No API key, no cloud, no per-character cost.

Design notes:
- The Kokoro model is loaded ONCE at process startup (model load dominates
  latency — loading per request would make every utterance slow).
- onnxruntime inference on a single session is not safe to call concurrently
  from multiple threads, so synthesis is serialized behind a lock even though
  the HTTP server is threaded.
- The server binds to 127.0.0.1 only so the endpoint is never network-exposed.

Run:
    python3 kokoro_tts_server.py            # uses ./kokoro-v1.0.int8.onnx + ./voices-v1.0.bin
    KOKORO_MODEL=kokoro-v1.0.onnx python3 kokoro_tts_server.py   # full-quality f32 model
    KOKORO_PORT=8757 KOKORO_VOICE=af_heart python3 kokoro_tts_server.py

See README.md for one-time model-file download instructions.
"""

import io
import json
import os
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

try:
    from kokoro_onnx import Kokoro
except ImportError:
    sys.stderr.write(
        "ERROR: kokoro-onnx is not installed. Run:  pip install -U kokoro-onnx numpy\n"
    )
    sys.exit(1)


# ---- Configuration (overridable via environment variables) ----

# Default to the int8 model: ~88 MB, noticeably faster/smaller than the f32
# model with only minor quality loss — a good fit for a lightweight sidecar.
# Set KOKORO_MODEL=kokoro-v1.0.onnx for best quality (310 MB f32).
MODEL_PATH = os.environ.get("KOKORO_MODEL", "kokoro-v1.0.int8.onnx")
VOICES_PATH = os.environ.get("KOKORO_VOICES", "voices-v1.0.bin")

# af_heart is the highest-rated American-English female voice (grade A).
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEFAULT_LANG = os.environ.get("KOKORO_LANG", "en-us")

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("KOKORO_PORT", "8757"))

# Kokoro always outputs 24000 Hz mono. AVAudioPlayer handles this sample rate
# fine, so we do not resample.
KOKORO_SAMPLE_RATE = 24000


def _resolve_model_files():
    """Fail early with a clear message if the model files are missing."""
    here = os.path.dirname(os.path.abspath(__file__))
    model_path = MODEL_PATH if os.path.isabs(MODEL_PATH) else os.path.join(here, MODEL_PATH)
    voices_path = VOICES_PATH if os.path.isabs(VOICES_PATH) else os.path.join(here, VOICES_PATH)

    missing = [path for path in (model_path, voices_path) if not os.path.exists(path)]
    if missing:
        sys.stderr.write(
            "ERROR: missing Kokoro model file(s):\n  "
            + "\n  ".join(missing)
            + "\n\nDownload them once (see tts-sidecar/README.md):\n"
            "  curl -L -o kokoro-v1.0.int8.onnx https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx\n"
            "  curl -L -o voices-v1.0.bin       https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin\n"
        )
        sys.exit(1)
    return model_path, voices_path


print(f"[kokoro] loading model {MODEL_PATH} + voices {VOICES_PATH} ...", flush=True)
_model_path, _voices_path = _resolve_model_files()
_kokoro = Kokoro(_model_path, _voices_path)
_synthesis_lock = threading.Lock()
print(f"[kokoro] ready. default voice={DEFAULT_VOICE} lang={DEFAULT_LANG}", flush=True)


def synthesize_to_wav_bytes(text, voice=DEFAULT_VOICE, speed=1.0, lang=DEFAULT_LANG):
    """Synthesize `text` and return WAV (PCM16 mono 24kHz) bytes.

    Kokoro returns float32 samples in [-1.0, 1.0]; AVAudioPlayer cannot decode
    raw float PCM, so we clip and convert to little-endian int16 and wrap the
    samples in a standard 44-byte WAV header via the stdlib `wave` module.
    """
    with _synthesis_lock:
        samples, sample_rate = _kokoro.create(text, voice=voice, speed=speed, lang=lang)

    pcm16 = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2")

    wav_buffer = io.BytesIO()
    with wave.open(wav_buffer, "wb") as wav_file:
        wav_file.setnchannels(1)         # mono
        wav_file.setsampwidth(2)         # 16-bit
        wav_file.setframerate(sample_rate)  # 24000
        wav_file.writeframes(pcm16.tobytes())
    return wav_buffer.getvalue()


class KokoroRequestHandler(BaseHTTPRequestHandler):
    def _send_bytes(self, status, content_type, payload):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        # Lightweight health check so the app can detect whether the sidecar
        # is running before attempting synthesis (and fall back to AVSpeech).
        if self.path == "/health":
            body = json.dumps({"status": "ok", "voice": DEFAULT_VOICE}).encode("utf-8")
            self._send_bytes(200, "application/json", body)
            return
        self._send_bytes(404, "text/plain", b"Not found")

    def do_POST(self):
        if self.path != "/tts":
            self._send_bytes(404, "text/plain", b"Not found")
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length else b"{}"

        try:
            request_json = json.loads(raw_body or b"{}")
        except json.JSONDecodeError:
            self._send_bytes(400, "text/plain", b"Invalid JSON body")
            return

        text = (request_json.get("text") or "").strip()
        if not text:
            self._send_bytes(400, "text/plain", b"Missing 'text'")
            return

        voice = request_json.get("voice", DEFAULT_VOICE)
        lang = request_json.get("lang", DEFAULT_LANG)
        try:
            speed = float(request_json.get("speed", 1.0))
        except (TypeError, ValueError):
            speed = 1.0

        try:
            wav_bytes = synthesize_to_wav_bytes(text, voice=voice, speed=speed, lang=lang)
        except Exception as synthesis_error:  # noqa: BLE001 — report any synth failure to the client
            message = f"TTS synthesis failed: {synthesis_error}".encode("utf-8")
            self._send_bytes(500, "text/plain", message)
            return

        self._send_bytes(200, "audio/wav", wav_bytes)

    def log_message(self, format, *args):
        # Quiet by default; uncomment to debug request flow.
        # sys.stderr.write("[kokoro] " + (format % args) + "\n")
        pass


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), KokoroRequestHandler)
    print(f"[kokoro] serving on http://{LISTEN_HOST}:{LISTEN_PORT}/tts", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[kokoro] shutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
