# ClickyJ - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

> **ClickyJ** is an open-source restart of Clicky (fork of `farzaa/clicky`, MIT).
> Its defining goal: replace every paid-API feature with an open-source model or
> free-hosted equivalent **without degrading features or performance**. See
> `docs/migration/PLAN.md` and `docs/migration/PROGRESS.md` for the migration
> record, and `docs/superpowers/specs/2026-06-01-clickyj-open-source-migration-design.md`
> for the design.

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it **on-device via WhisperKit**, and sends the transcript + a screenshot of the user's screen to **Google Gemini** (free tier). Gemini responds with text (streamed via SSE) and the response is spoken via a **local Kokoro TTS sidecar** (with Apple's `AVSpeechSynthesizer` as an automatic fallback). A blue cursor overlay can fly to and point at UI elements Gemini references on any connected monitor.

Only the vision/chat call leaves the device, and it routes through a Cloudflare Worker proxy so the Gemini key never ships in the app. Speech-to-text and text-to-speech run fully locally. No analytics/telemetry.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Google Gemini (`gemini-2.5-flash` default, `gemini-2.5-flash-lite` optional) via Cloudflare Worker proxy with SSE streaming. Free-tier AI Studio key.
- **Speech-to-Text**: WhisperKit on-device CoreML (`openai_whisper-base.en`), with Apple Speech as a local fallback. No API key, no network.
- **Text-to-Speech**: Kokoro-82M via a local `tts-sidecar/` HTTP server (kokoro-onnx), returning WAV played by `AVAudioPlayer`. Automatic `AVSpeechSynthesizer` fallback if the sidecar isn't running.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Gemini embeds `[POINT:y,x:label:screenN]` tags (coordinates normalized 0-1000, `[y,x]` order — Gemini's native grounding convention). `parsePointingCoordinates` parses the tag unchanged; `screenshotPixelCoordinate(...)` swaps+scales the normalized `[y,x]` into screenshot pixels, then the overlay maps to the correct monitor and animates the blue cursor along a bezier arc.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: None. `ClickyAnalytics.swift` is a no-op shim (PostHog stripped).

### API Proxy (Cloudflare Worker)

The only external call is the Gemini vision/chat request, routed through a Cloudflare Worker (`worker/src/index.ts`) that holds the Gemini key as a secret. STT and TTS are fully local, so the former `/tts` and `/transcribe-token` routes were removed.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse` | Gemini vision + streaming chat |

The app selects the model via an `X-Clicky-Model` header (allowlisted in the Worker) and toggles streaming via `X-Clicky-Stream`. Worker secret: `GEMINI_API_KEY`.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared WhisperKit instance**: A single `WhisperKit` instance is built once and reused across all transcription sessions. Building one is expensive (CoreML compile + prewarm), so creating one per push-to-talk session would add seconds of latency. The model (`openai_whisper-base.en`) downloads from HuggingFace on first run and is cached thereafter. WhisperKit's `AudioStreamTranscriber` owns its own microphone, so the provider instead accumulates the app's externally-fed mic buffers (resampled to 16 kHz mono Float32) and runs `transcribe(audioArray:)` on a debounce for partials plus a final pass on key-up.

**Gemini grounding coordinate swap**: Gemini emits point coordinates in `[y, x]` order normalized to 0-1000 (its native spatial-grounding convention), which is the opposite axis order and scale from raw pixels. The `[POINT]` tag and its parser regex are unchanged; `CompanionManager.screenshotPixelCoordinate(...)` is the single isolated place that swaps `[y,x]` → `[x,y]` and scales 0-1000 → screenshot pixels. If Xcode-side accuracy testing ever reveals a transpose, it's a one-line fix there.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1040 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Gemini API, Kokoro TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Gemini → TTS → pointing pipeline. Includes `screenshotPixelCoordinate(...)` which converts Gemini's normalized `[y,x]` points to screenshot pixels. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Flash/Flash-Lite), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~70 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — WhisperKit (default) or Apple Speech. |
| `WhisperKitTranscriptionProvider.swift` | ~254 | On-device streaming transcription via WhisperKit (CoreML). Accumulates resampled 16 kHz mono Float samples and runs `transcribe(audioArray:)` on a ~0.5s debounce for partials plus a final pass on key-up. Shares one WhisperKit instance across sessions. No key, no network. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~185 | Audio conversion helpers. `BuddyFloat32AudioConverter` resamples mic buffers to 16 kHz mono Float32 for WhisperKit; `BuddyPCM16AudioConverter` + `BuddyWAVFileBuilder` remain for any PCM16/WAV needs. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `GeminiAPI.swift` | ~290 | Google Gemini vision API client with streaming (SSE) and non-streaming modes. Mirrors the former ClaudeAPI interface. Maps Anthropic-shaped inputs to Gemini `generateContent`, parses `candidates[].content.parts[].text`. TLS warmup, image MIME detection, conversation history. |
| `KokoroTTSClient.swift` | ~140 | Local TTS client. POSTs text to the Kokoro sidecar (127.0.0.1) and plays the returned WAV via `AVAudioPlayer`; falls back to `AVSpeechSynthesizer` if the sidecar is down. Exposes `isPlaying` for transient cursor scheduling. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~75 | No-op analytics shim (PostHog stripped). Keeps the original public API so call sites compile unchanged. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~105 | Cloudflare Worker proxy. One route: `/chat` proxies Gemini (`streamGenerateContent?alt=sse`, `x-goog-api-key`, model allowlist). |
| `tts-sidecar/` | — | Local Kokoro TTS server (Python `kokoro-onnx`): `kokoro_tts_server.py`, `setup_and_run.sh`, `requirements.txt`, `README.md`. Returns WAV PCM16/24kHz on `127.0.0.1:8757/tts`. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add the single secret (free-tier Google AI Studio key)
npx wrangler secret put GEMINI_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with GEMINI_API_KEY)
npx wrangler dev
```

## Local TTS Sidecar (Kokoro)

Text-to-speech runs locally. Start the sidecar before using voice playback:

```bash
cd tts-sidecar
./setup_and_run.sh   # creates venv, installs kokoro-onnx, downloads model, serves on 127.0.0.1:8757
```

If the sidecar isn't running, the app automatically falls back to Apple's
`AVSpeechSynthesizer`, so it's never mute. See `tts-sidecar/README.md`.

## Speech-to-Text (WhisperKit)

Added via Swift Package Manager: `https://github.com/argmaxinc/argmax-oss-swift.git`
(the `WhisperKit` product, v1.0.0+). The `openai_whisper-base.en` CoreML model
downloads from HuggingFace on first run and is cached. No key required.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
