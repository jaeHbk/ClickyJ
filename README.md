# ClickyJ

ClickyJ is an open-source restart of [Clicky](https://github.com/farzaa/clicky) — an AI buddy that lives next to your cursor on macOS. It can see your screen, talk to you, and point at things. Push-to-talk (Control + Option), it transcribes your voice, looks at a screenshot, answers out loud, and flies a little blue cursor to whatever it's referring to.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

## Why ClickyJ 

The goal of this fork is simple: **replace every paid API with an open-source or free-hosted equivalent, without losing features or performance.** Speech and voice now run fully on your Mac; only the vision/chat call leaves the device, and it uses a free tier.

| Capability | Original Clicky (paid) | ClickyJ |
|---|---|---|
| Vision + chat | Claude (Anthropic) | **Google Gemini** `gemini-2.5-flash` (free tier) |
| Speech-to-text | AssemblyAI + OpenAI | **WhisperKit** — on-device CoreML (Apple Speech fallback) |
| Text-to-speech | ElevenLabs | **Kokoro** — local sidecar (Apple voice fallback) |
| Analytics | PostHog | **Removed** — no telemetry |

The element-pointing feature (`[POINT]` tags) is preserved; it uses Gemini's native spatial grounding.

## Status

**Code-complete; pending build verification on a machine with Xcode.** All four migrations are done and merged. Logic that can be checked without Xcode has been (worker typecheck, `[POINT]` coordinate conversion, audio encoding). Compile/run plus accuracy and latency checks remain — see `docs/migration/PROGRESS.md` for the validation checklist.

## Setup

### Prerequisites
- macOS 14+ and Xcode 16+
- A free [Google AI Studio](https://aistudio.google.com/app/apikey) API key (for vision)
- A [Cloudflare](https://cloudflare.com) account (free tier) for the proxy
- Node.js 18+ and Python 3.10–3.12

### 1. Vision proxy (Cloudflare Worker)
The Worker holds your Gemini key so it never ships in the app.
```bash
cd worker
npm install
npx wrangler secret put GEMINI_API_KEY   # paste your AI Studio key
npx wrangler deploy                       # prints your worker URL
```
Then set that URL as `workerBaseURL` in `leanring-buddy/CompanionManager.swift`
(replace `your-worker-name.your-subdomain.workers.dev`). For local dev,
`npx wrangler dev` with a `worker/.dev.vars` file containing `GEMINI_API_KEY=...`.

### 2. Text-to-speech sidecar (Kokoro)
Runs locally; downloads the model on first launch.
```bash
cd tts-sidecar
./setup_and_run.sh        # venv + deps + model, serves on 127.0.0.1:8757
```
Leave it running while you use Clicky. If it isn't running, the app falls back
to Apple's built-in voice automatically. Details in `tts-sidecar/README.md`.

### 3. Build and run
```bash
open leanring-buddy.xcodeproj
```
- Xcode resolves the Swift packages (Sparkle + WhisperKit) on first open.
- Pick the `leanring-buddy` scheme (the typo is intentional/legacy), set your signing team, and press **Cmd + R**.
- The app lives in the menu bar (no dock icon). Speech-to-text downloads its model on first run.

Grant the permissions it requests: **Microphone**, **Accessibility** (global hotkey), **Screen Recording**, and **Screen Content**.

## Architecture

Menu-bar app (no dock icon) with two `NSPanel`s — the control-panel dropdown and a full-screen transparent cursor overlay. Push-to-talk captures audio, **WhisperKit** transcribes it on-device, the transcript + a screenshot go to **Gemini** over streaming SSE (via the Worker), and the reply is spoken by the local **Kokoro** sidecar. Gemini embeds `[POINT:y,x:label:screenN]` tags (normalized 0–1000) that the cursor flies to across monitors. Full breakdown in `CLAUDE.md` / `AGENTS.md`.

```
leanring-buddy/                          # Swift source
  CompanionManager.swift                   # Central state machine + [POINT] coordinate mapping
  GeminiAPI.swift                          # Gemini streaming vision client
  WhisperKitTranscriptionProvider.swift    # On-device speech-to-text
  KokoroTTSClient.swift                    # Local TTS client (+ Apple fallback)
  OverlayWindow.swift                      # Blue cursor overlay
worker/src/index.ts                      # Cloudflare Worker — single /chat route (Gemini)
tts-sidecar/                             # Local Kokoro TTS server
docs/migration/                          # Migration plan, progress + tradeoffs
```

## Credit

ClickyJ is a fork of **[Clicky](https://github.com/farzaa/clicky) by [Farza](https://x.com/farzatv)**, released under the MIT license. The original app, design, and the clever cursor-pointing idea are all his — this fork only swaps the backing services for open-source ones. Huge thanks to Farza for open-sourcing it. The latest official Clicky lives at [heyclicky.com](https://www.heyclicky.com/).

## License

MIT (inherited from upstream). See `LICENSE`.
