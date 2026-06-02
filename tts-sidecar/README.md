# ClickyJ Kokoro TTS Sidecar

This replaces the paid **ElevenLabs** text-to-speech service with the
open-source **Kokoro-82M** model running fully locally — no API key, no cloud,
no per-character cost.

The macOS app (`KokoroTTSClient.swift`) POSTs `{"text": "..."}` to
`http://127.0.0.1:8757/tts` and receives WAV audio (PCM16, mono, 24 kHz) that
`AVAudioPlayer` plays directly. If this sidecar is **not running**, the app
automatically falls back to Apple's built-in `AVSpeechSynthesizer`, so Clicky
is never mute.

## Quick start

```bash
cd tts-sidecar
./setup_and_run.sh
```

That script creates a virtualenv, installs dependencies, downloads the model
files once, and starts the server. Leave it running while you use Clicky.

## Manual setup

```bash
cd tts-sidecar
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Download model files once (int8 = ~88 MB, recommended):
curl -L -o kokoro-v1.0.int8.onnx \
  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx
curl -L -o voices-v1.0.bin \
  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin

python3 kokoro_tts_server.py
```

For best quality use the full f32 model instead (~310 MB):

```bash
curl -L -o kokoro-v1.0.onnx \
  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
KOKORO_MODEL=kokoro-v1.0.onnx python3 kokoro_tts_server.py
```

## Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `KOKORO_MODEL` | `kokoro-v1.0.int8.onnx` | ONNX model file |
| `KOKORO_VOICES` | `voices-v1.0.bin` | Voice style-vector pack |
| `KOKORO_VOICE` | `af_heart` | Default voice (grade-A American-English female) |
| `KOKORO_LANG` | `en-us` | `en-us` for `af_*`/`am_*`, `en-gb` for `bf_*`/`bm_*` |
| `KOKORO_PORT` | `8757` | Localhost port |

## Endpoints

- `POST /tts` — body `{"text": "...", "voice": "af_heart", "speed": 1.0, "lang": "en-us"}` → `audio/wav`.
- `GET /health` — `{"status":"ok"}` so the app can detect the sidecar before synthesizing.

## Voices

26 voices ship in `voices-v1.0.bin`. Naming: first letter = accent
(`a`=American English, `b`=British English, …), second letter = gender
(`f`=female, `m`=male). Strong picks: `af_heart` (default), `af_bella`,
`am_michael`, `bf_emma`, `bm_george`. The server logs the loaded set; call
`kokoro.get_voices()` to enumerate.

## Licenses

- **kokoro-onnx** (Python package): MIT.
- **Kokoro-82M** (model weights): Apache-2.0.
- The runtime g2p backend (espeak-ng, loaded dynamically by `espeakng-loader`)
  is GPLv3 but loaded as a separate dynamic library, not statically linked.

Both MIT and Apache-2.0 are permissive. See the upstream repos for full terms:
<https://github.com/thewh1teagle/kokoro-onnx>, <https://huggingface.co/hexgrad/Kokoro-82M>.

## Notes

- The model loads **once** at startup (load dominates latency); the first
  synthesis after launch may be slightly slower as ONNX warms up.
- The server binds to `127.0.0.1` only — it is never exposed to the network.
- Model files are gitignored; they are downloaded on demand, not committed.
