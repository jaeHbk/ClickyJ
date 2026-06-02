#!/usr/bin/env bash
#
# One-shot setup + launch for the ClickyJ Kokoro TTS sidecar.
#
# - Creates a local virtualenv (./.venv) and installs kokoro-onnx + numpy.
# - Downloads the Kokoro model + voices files once (skipped if already present).
# - Starts the local TTS server on 127.0.0.1:8757.
#
# Usage:
#   ./setup_and_run.sh                 # int8 model (default, ~88MB)
#   KOKORO_MODEL=kokoro-v1.0.onnx ./setup_and_run.sh   # full f32 model (~310MB)
#
set -euo pipefail
cd "$(dirname "$0")"

MODEL_FILE="${KOKORO_MODEL:-kokoro-v1.0.int8.onnx}"
VOICES_FILE="${KOKORO_VOICES:-voices-v1.0.bin}"
RELEASE_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"

echo "==> Setting up Python virtualenv (.venv)"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

download_if_missing() {
  local filename="$1"
  if [ -f "$filename" ]; then
    echo "==> $filename already present, skipping download"
  else
    echo "==> Downloading $filename ..."
    curl -L --fail -o "$filename" "$RELEASE_BASE/$filename"
  fi
}

download_if_missing "$MODEL_FILE"
download_if_missing "$VOICES_FILE"

echo "==> Launching Kokoro TTS sidecar on http://127.0.0.1:${KOKORO_PORT:-8757}/tts"
KOKORO_MODEL="$MODEL_FILE" KOKORO_VOICES="$VOICES_FILE" exec python3 kokoro_tts_server.py
