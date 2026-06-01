# ClickyJ Migration Plan — Paid APIs → Open Source

**Source of truth for design:** `docs/superpowers/specs/2026-06-01-clickyj-open-source-migration-design.md`
**Progress + tradeoffs log:** `docs/migration/PROGRESS.md`
**Upstream base:** `farzaa/clicky@a80fa80` (MIT)

This file is the **playbook for the Claude agents** executing the migration. It
defines who does what, in what order, with what contracts, and how each swap is
validated. Because Xcode is unavailable here, every Swift change is validated at
the **source/contract level** locally and **compile/run-validated on a separate
Xcode machine** using the per-swap checklists below.

---

## Goal (current)

Replace **every paid-API feature** in Clicky with an open-source model or
free-hosted equivalent, **without significantly degrading features or
performance**. Keep capabilities that have a real free cloud host; otherwise go
fully local.

## Replacement matrix

| # | Capability | From (paid) | To (open / free) | Hosting |
|---|---|---|---|---|
| 1 | Vision + `[POINT]` | Claude (Anthropic) | Gemini 2.x Flash | Free cloud tier, via slim CF Worker |
| 2 | Speech-to-text | AssemblyAI + OpenAI | WhisperKit (CoreML) | On-device; Apple Speech fallback |
| 3 | Text-to-speech | ElevenLabs | Kokoro TTS (ONNX) | Local sidecar; AVSpeech fallback |
| 4 | Analytics | PostHog | (stripped, no-op shim) | None |

---

## Agent workstreams (parallel-safe)

Each swap touches a disjoint set of files, so they run as independent subagents
on separate `feature/*` branches and merge to `main` per milestone. Shared files
(`CompanionManager.swift`, `project.pbxproj`, `Info.plist`, `AGENTS.md`) are
edited in a **final integration pass** to avoid merge conflicts.

### Swap A — Strip PostHog analytics  (lowest risk; land first)
- **Files:** `ClickyAnalytics.swift` (→ no-op shim), `project.pbxproj` +
  `Package.resolved` (remove `posthog-ios`), remove embedded key.
- **Contract:** keep `ClickyAnalytics`' public API identical (event enums +
  `track`-style calls) so the ~dozen call sites compile unchanged.
- **Keep:** Sparkle (open-source updater, not paid).

### Swap B — Speech-to-text → WhisperKit
- **New:** `WhisperKitTranscriptionProvider.swift` conforming to
  `BuddyTranscriptionProvider` + `BuddyStreamingTranscriptionSession`.
- **Delete:** `AssemblyAIStreamingTranscriptionProvider.swift`,
  `OpenAIAudioTranscriptionProvider.swift`.
- **Keep:** `AppleSpeechTranscriptionProvider.swift` (automatic fallback).
- **Edit:** `BuddyTranscriptionProviderFactory` (provider enum →
  `whisperkit | apple`); `Info.plist` `VoiceTranscriptionProvider` → `whisperkit`.
- **SPM:** add `argmaxinc/WhisperKit`.
- **Contract:** preserve the `onTranscriptUpdate` / `onFinalTranscriptReady` /
  `onError` callbacks and PCM16 buffer feed from `BuddyDictationManager`.

### Swap C — Text-to-speech → Kokoro
- **New:** `KokoroTTSClient.swift` (drop-in shape: `speakText(_:) async throws`,
  `isPlaying`, `stopPlayback()`), and `tts-sidecar/` (Python `kokoro-onnx`
  localhost server + README + launch script).
- **Delete:** `ElevenLabsTTSClient.swift` (replaced).
- **Fallback:** sidecar unreachable → `AVSpeechSynthesizer` (never mute).
- **Contract:** `CompanionManager` keeps calling `speakText` / `isPlaying` /
  `stopPlayback` exactly as it does for ElevenLabs today.

### Swap D — Vision → Gemini  (highest risk; land last)
- **New:** `GeminiAPI.swift` with the **same method signatures** as `ClaudeAPI`
  (`analyzeImageStreaming` + `analyzeImage`).
- **Delete:** `ClaudeAPI.swift`, `OpenAIAPI.swift`.
- **Edit:** `CompanionManager` lazy `claudeAPI` → `geminiAPI`, model picker
  remap (Claude model IDs → Gemini model IDs, with persisted-key migration),
  `[POINT]` system prompt to normalized 0–1000 space if tactic (A) wins.
- **Worker:** `/chat` re-pointed to Gemini; `/tts` + `/transcribe-token` deleted.
- **`[POINT]`:** parser regex UNCHANGED. Coordinate scaling resolved by Xcode-side
  accuracy test — see spec §2. Record the winning tactic in PROGRESS.md.

### Integration pass (after A–D)
- Reconcile `CompanionManager.swift`, `project.pbxproj`, `Info.plist`.
- Rewrite `AGENTS.md` / `CLAUDE.md` to the new open-source architecture.
- Slim the Worker to a single `/chat` route.

---

## Per-swap validation checklists (for the Xcode machine)

> Run on the machine with Xcode. Open `leanring-buddy.xcodeproj`, set signing,
> Cmd+R. **Do NOT run `xcodebuild` from terminal** (invalidates TCC permissions).

**Swap A (analytics):**
- [ ] Project builds with `posthog-ios` removed (no missing-symbol errors).
- [ ] App launches; no analytics network calls in Console.
- [ ] No crash on any former analytics call site.

**Swap B (WhisperKit):**
- [ ] WhisperKit model downloads on first run; subsequent runs use cache.
- [ ] Push-to-talk shows live partial transcript; final transcript on key-up.
- [ ] Latency acceptable vs. AssemblyAI (record ms in PROGRESS.md).
- [ ] Apple Speech fallback engages if WhisperKit unavailable.

**Swap C (Kokoro):**
- [ ] Sidecar starts via launch script; `POST /tts` returns playable audio.
- [ ] Spoken response plays via `AVAudioPlayer`; `stopPlayback` interrupts.
- [ ] Sidecar-down → `AVSpeechSynthesizer` fallback speaks (no silence).
- [ ] Latency to first audio acceptable vs. ElevenLabs (record in PROGRESS.md).

**Swap D (Gemini + `[POINT]`):**
- [ ] Streaming text renders progressively (SSE works end-to-end).
- [ ] Conversation history preserved across turns.
- [ ] **`[POINT]` accuracy:** cursor lands on the named element across ≥10
      varied prompts, single- and multi-monitor. Record hit-rate + winning
      coordinate tactic (A or B) in PROGRESS.md.
- [ ] `[POINT:none]` suppresses pointing correctly.
- [ ] Model picker switches between the two Gemini models.

---

## Git / milestone protocol

- Branch per swap: `feature/migrate-analytics`, `feature/migrate-stt`,
  `feature/migrate-tts`, `feature/migrate-vision`.
- Merge to `main` per landed+self-reviewed swap; **push milestone to ClickyJ**.
- Commit messages: imperative, explain the "why".
- Update PROGRESS.md at every milestone (progress + tradeoffs).
- `/loop` checkpoint: after each swap, re-read goal, confirm no feature
  regressed at the contract level, log status, push.

## Open-source attribution / licensing

- Upstream Clicky: MIT (LICENSE preserved, import commit credits farzaa).
- WhisperKit: MIT (Argmax). Kokoro: Apache-2.0. kokoro-onnx: MIT.
  Gemini: free-tier API (key, not bundled). Record license notes in PROGRESS.md.
