# ClickyJ — Paid-API → Open-Source Migration Design

**Date:** 2026-06-01
**Status:** Approved (design), implementation pending
**Upstream base:** `farzaa/clicky@a80fa80` (MIT)
**Repo:** `jaeHbk/ClickyJ`

## Goal

Restart the ClickyJ project from a clean import of upstream Clicky, then replace
**every paid-API feature** with an open-source model or free-hosted equivalent —
**without significantly degrading features or performance**. Keep capabilities
that have a genuine free cloud host; otherwise prefer fully local/open-source.

Because Xcode is not available on this machine, **all build/run validation is
deferred to a separate machine that has Xcode installed**. This repo ships the
code + a precise validation checklist per swap.

## Paid-API surface (what we are replacing)

| # | Capability | Current paid service | Replacement (approved) |
|---|---|---|---|
| 1 | Vision chat + `[POINT]` grounding | Claude (Anthropic) via CF Worker | **Google Gemini 2.x Flash** (free AI Studio tier) via slim CF Worker |
| 2 | Speech-to-text | AssemblyAI streaming + OpenAI Whisper API | **WhisperKit** (on-device CoreML), Apple Speech as fallback |
| 3 | Text-to-speech | ElevenLabs | **Kokoro TTS** (local ONNX sidecar), `AVSpeechSynthesizer` as fallback |
| 4 | Analytics | PostHog (SaaS) | **Stripped** — no-op shim |

The Cloudflare Worker exists only to hide API keys. After migration it shrinks
from **3 routes → 1** (`/chat` → Gemini). `/tts` and `/transcribe-token` are deleted.

## Architecture after migration

```
Push-to-talk (ctrl+option)
  → AVAudioEngine mic capture
  → WhisperKit on-device transcription   [was AssemblyAI/OpenAI]   (Apple Speech fallback)
  → screenshot (ScreenCaptureKit, unchanged)
  → Gemini 2.x Flash vision + SSE stream  [was Claude]              (via slim CF Worker /chat)
  → [POINT:x,y:label:screenN] tag parsed (contract UNCHANGED)
  → Kokoro TTS localhost sidecar          [was ElevenLabs]          (AVSpeechSynthesizer fallback)
  → blue cursor flies to element (unchanged)
```

Analytics calls remain in code but route to a no-op `ClickyAnalytics` shim so
call sites do not churn.

## Component designs

### 1. Vision: Gemini 2.x Flash (`GeminiAPI.swift`)

**Why Gemini:** Among free-cloud VLMs it is the only one combining a generous
stable free tier, native spatial grounding, and SSE streaming — all three are
required by the `[POINT]` feature.

**Interface preservation (critical):** `GeminiAPI` exposes the **same method
signatures** as `ClaudeAPI` so `CompanionManager` changes minimally:

```swift
func analyzeImageStreaming(
    images: [(data: Data, label: String)],
    systemPrompt: String,
    conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
    userPrompt: String,
    onTextChunk: @MainActor @Sendable (String) -> Void
) async throws -> (text: String, duration: TimeInterval)
// + non-streaming analyzeImage(...) with the same shape
```

**Request mapping (Anthropic Messages → Gemini generateContent):**
- Anthropic `image` block (base64 + media_type) → Gemini `inline_data` part
  (`mime_type` + `data`).
- Anthropic `system` → Gemini `system_instruction`.
- Anthropic `messages[].content` text → Gemini `contents[].parts[].text`.
- `conversationHistory` user/assistant pairs → Gemini `contents` with roles
  `user` / `model`.
- Streaming: call `:streamGenerateContent?alt=sse`; parse SSE `data:` lines;
  extract `candidates[0].content.parts[].text`; accumulate and call
  `onTextChunk` (same progressive-render contract).

**Model selection:** `CompanionManager.selectedModel` currently persists
`"claude-sonnet-4-6"` / Opus. Remap the two picker options to two Gemini models
(e.g. Flash = default, Flash-Pro/Pro = "smarter"). Persisted-key migration:
if a stored value starts with `claude-`, fall back to the Gemini default.

**Worker `/chat`:** re-point from `api.anthropic.com/v1/messages` to the Gemini
`generateContent` endpoint, swap auth header to the Gemini key, and translate
the SSE envelope if the Swift client expects Anthropic-shaped events. **Decision:
do the request/response translation in `GeminiAPI.swift` (Swift), keep the Worker
a thin authenticated pass-through.** This keeps the Worker minimal and testable.

### 2. `[POINT]` coordinate strategy (highest risk)

**Contract unchanged:** the app still parses `[POINT:x,y:label:screenN]` and
`[POINT:none]` with the existing regex at `CompanionManager.swift:786`. **No
parser change.**

**What changes:** the system prompt already (a) labels each image with its exact
pixel dimensions and (b) asks the model for **integer pixel coordinates** in the
screenshot's space (`CompanionManager.swift:566-568`). Gemini's grounding is
trained on a **normalized 0–1000** space.

**Approach:** Prompt Gemini in its native normalized space, then convert to the
pixel coordinates the parser/overlay expect. Two viable tactics; pick during
implementation based on Xcode-side accuracy testing:

- **(A) In-Swift scaling (preferred):** Ask Gemini for normalized `[POINT:nx,ny:...]`
  in 0–1000, and scale `x = nx/1000 * imageWidthPx`, `y = ny/1000 * imageHeightPx`
  **before** building `PointingParseResult`. Pro: plays to Gemini's training. Con:
  requires knowing which screen's dimensions to scale against (already tracked via
  `screenNumber` + per-image dimensions).
- **(B) Prompt-only pixels:** Keep asking for pixels (current prompt), rely on the
  dimension hints. Simpler, zero scaling code, but historically less reliable for
  open VLMs.

**This is the #1 thing the Xcode machine validates.** PROGRESS.md records which
tactic won and the measured accuracy.

### 3. Speech-to-text: WhisperKit (`WhisperKitTranscriptionProvider.swift`)

- New provider conforming to `BuddyTranscriptionProvider` /
  `BuddyStreamingTranscriptionSession` (protocol at
  `BuddyTranscriptionProvider.swift:11-30`).
- SPM dependency: `argmaxinc/WhisperKit`. Default model: a small/base English
  CoreML model auto-downloaded on first run (documented; no key).
- Streaming: feed `AVAudioPCMBuffer`s (already produced by
  `BuddyDictationManager` + `BuddyAudioConversionSupport`); emit partial
  transcripts via `onTranscriptUpdate` and finalize on key-up via
  `onFinalTranscriptReady` — same callback contract AssemblyAI used.
- **Delete** `AssemblyAIStreamingTranscriptionProvider.swift` and
  `OpenAIAudioTranscriptionProvider.swift`. **Keep**
  `AppleSpeechTranscriptionProvider.swift` as the automatic fallback.
- Update `BuddyTranscriptionProviderFactory` (`BuddyTranscriptionProvider.swift:32-100`):
  preferred provider enum becomes `whisperkit` | `apple`; default
  `Info.plist VoiceTranscriptionProvider` → `whisperkit`.

### 4. Text-to-speech: Kokoro (`KokoroTTSClient.swift` + sidecar)

- **Drop-in client:** same shape as `ElevenLabsTTSClient` — `speakText(_:) async throws`,
  `isPlaying`, `stopPlayback()`, plays via `AVAudioPlayer`
  (`ElevenLabsTTSClient.swift:13-81`).
- **Sidecar:** a small local HTTP server (`tts-sidecar/`, Python `kokoro-onnx`)
  exposing `POST /tts {text} → audio/wav|mpeg` on `127.0.0.1`. Shipped with a
  README + launch script. The client POSTs to `http://127.0.0.1:<port>/tts`.
- **Fallback:** if the sidecar is unreachable, `KokoroTTSClient` automatically
  falls back to `AVSpeechSynthesizer` so the app is never mute. This makes the
  TTS swap **degrade gracefully** even before the user installs the sidecar.
- Worker `/tts` route deleted.

### 5. Analytics: strip PostHog

- `ClickyAnalytics.swift` becomes a no-op shim: same public API (`track(...)`,
  event enums) so the ~dozen call sites compile unchanged, but methods do
  nothing.
- Remove the `posthog-ios` SPM package reference from
  `project.pbxproj` + `Package.resolved`. **Sparkle stays** (it is the
  open-source auto-updater, not a paid API).
- Remove the embedded PostHog key (`ClickyAnalytics.swift:18`).

## Repo restart mechanics (DONE before implementation)

1. Verified + created fresh backups (`~/projects/clickyJ-backups-20260601/`):
   `clickyJ-allrefs.bundle` (all 13 refs, complete history) +
   `clickyJ-wip.bundle` (uncommitted WIP). Both `git bundle verify`-clean.
2. Scrapped old local `~/projects/clicky` working tree.
3. Fresh-cloned `farzaa/clicky` (NOT a GitHub fork).
4. Re-init clean history: single import commit
   `Import Clicky upstream from farzaa/clicky@a80fa80`. `origin`→ClickyJ,
   `upstream`→farzaa retained for future cherry-picks. LICENSE preserved.
5. **Remote ClickyJ:** the GitHub token lacks `delete_repo` scope, so the repo
   cannot be deleted. Instead, **force-replace `main`** with the fresh history
   and delete stray remote branches (`feature/visualize-region`,
   `fix/performance`) — a clean restart. Explicit confirmation required
   immediately before the destructive remote push.

## Validation model

- **Verifiable here:** Worker TypeScript (`tsc`/node), sidecar (run Python
  locally), Swift source-level review (signatures, contract preservation),
  docs, git mechanics.
- **Deferred to Xcode machine:** compile, run, TCC permissions, and — most
  importantly — `[POINT]` coordinate accuracy, WhisperKit latency/accuracy, and
  Kokoro voice quality/latency. Each swap ships a checklist in PROGRESS.md.

## Execution & milestones

Implement the four swaps as **parallel subagent fan-out** (independent files),
each on its own feature branch, with milestone pushes to ClickyJ after each swap
lands and passes self-review. Order is independent, but the recommended landing
order is: **(1) strip analytics → (2) STT → (3) TTS → (4) vision**, ending with
the highest-risk vision/`[POINT]` swap so it gets the most attention. PROGRESS.md
is updated at each milestone with progress + tradeoffs; PLAN.md is the agent
playbook.

## Out of scope (YAGNI)

- No new features beyond replacing paid APIs.
- No rename of the `leanring-buddy` scheme/dir (legacy typo is intentional).
- No fix for the known non-blocking Swift 6 / onChange warnings.
- Sparkle auto-update + appcast left as-is (open-source, not paid).
