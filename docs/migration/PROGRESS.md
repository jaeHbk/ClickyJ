# ClickyJ Migration Progress & Tradeoffs

**Goal:** Replace every paid-API feature in Clicky with open-source / free-hosted
equivalents without significantly degrading features or performance.
**Design:** `docs/superpowers/specs/2026-06-01-clickyj-open-source-migration-design.md`
**Playbook:** `docs/migration/PLAN.md`
**Validation:** build/run + accuracy checks happen on a separate **Xcode machine**
(this machine has no Xcode). Items marked ⏳ XCODE await that machine.

---

## Status board

| Swap | Capability | Target | Code status | Xcode validation |
|---|---|---|---|---|
| Restart | repo reset | clean import of `farzaa/clicky@a80fa80` | ✅ done (pushed) | n/a |
| Docs | spec/plan/progress | written | ✅ done | n/a |
| A | Analytics | strip PostHog | ✅ code done (merged `main`) | ⏳ XCODE |
| B | Speech-to-text | WhisperKit | ✅ code done (merged `main`) | ⏳ XCODE |
| C | Text-to-speech | Kokoro sidecar | ✅ code done (merged `main`) | ⏳ XCODE |
| D | Vision + `[POINT]` | Gemini 2.5 Flash | ✅ code done (merged `main`) | ⏳ XCODE |
| Docs | AGENTS.md rewrite | open-source arch | ✅ done | n/a |

---

## Timeline / log

### 2026-06-01 — Project restart + planning
- Verified no commit existed only locally; created + verified fresh backups in
  `~/projects/clickyJ-backups-20260601/` (`clickyJ-allrefs.bundle` = all 13 refs
  complete history; `clickyJ-wip.bundle` = uncommitted WIP). Both bundle-verified.
- Scrapped old local `~/projects/clicky`; fresh-cloned `farzaa/clicky` (not a fork).
- Re-init clean git history with a single import commit; `origin`→ClickyJ,
  `upstream`→farzaa retained. LICENSE preserved.
- Mapped the full paid-API surface against pristine upstream source (exact files,
  signatures, `[POINT]` parser + system prompt).
- Wrote design spec, PLAN.md, PROGRESS.md.
- **Remote reset DONE:** force-replaced ClickyJ `main` (`d2899fa` → `34fcb60`) with
  clean history; deleted stray remote branches `feature/visualize-region` +
  `fix/performance`. Token lacks `delete_repo`, so force-replace was used instead of
  deleting the repo. Old refs fully recoverable from
  `~/projects/clickyJ-backups-20260601/clickyJ-allrefs.bundle`. Repo description
  updated to the new open-source mission. ClickyJ now: single `main`, 2 commits.

### 2026-06-01 — All four swaps code-complete
- Ran a parallel research workflow (Gemini / WhisperKit / Kokoro + an adversarial
  Gemini-grounding verifier) to pin current API contracts before coding — caught
  the WhisperKit package rename and confirmed Gemini's `[y,x]` 0-1000 grounding.
- Implemented A (analytics), C (TTS), B (STT), D (vision) each on its own branch,
  merged to `main` with a milestone push per swap.
- Integration pass: rewrote AGENTS.md/CLAUDE.md to the open-source architecture.
- **Goal status: code-complete.** Every paid API (Claude, AssemblyAI, OpenAI,
  ElevenLabs, PostHog, + dead Claude Computer Use) is removed. Remaining work is
  **Xcode-machine validation only** (build + the per-swap checklists above).

---

## Decisions (with rationale)

| Decision | Choice | Rationale |
|---|---|---|
| Vision provider | Gemini 2.x Flash (free cloud) | Only free-cloud VLM combining stable free tier + native spatial grounding + SSE streaming (all required by `[POINT]`). |
| `[POINT]` coords | Prompt in Gemini's 0–1000 space, scale to px in Swift (parser unchanged) | Plays to Gemini's grounding training; keeps the app-side contract stable. Final tactic confirmed by Xcode accuracy test. |
| STT | WhisperKit on-device | Closest quality match to AssemblyAI, fully local, Swift-native, MIT. |
| TTS | Kokoro local sidecar + AVSpeech fallback | Near-commercial quality, Apache-2.0; fallback means never-mute even pre-install. |
| Analytics | Strip to no-op shim | Telemetry, not a user feature; cleanest for a privacy-respecting open fork. |
| Worker | Keep, slim to 1 route (`/chat`) | Preserves "no key ships in app"; everything else now local. |

---

## Tradeoffs ledger (to be filled as swaps land)

> Each entry records what we gained, what we gave up, and the measured delta.
> Empty until the corresponding swap is implemented + Xcode-validated.

### A — Analytics (PostHog → none) ✅ code complete 2026-06-01
- **Gained:** no telemetry/phone-home; removed the `posthog-ios` SPM dep **and** its
  transitive `plcrashreporter` pin; deleted the embedded PostHog project key.
- **Gave up:** usage insight (acceptable — telemetry is not a user feature).
- **How:** `ClickyAnalytics` kept as a no-op enum with the **identical public API**
  (all `track*` methods + new no-op `identifyUser`), so all 18 call sites compile
  unchanged. Direct `PostHogSDK.identify` in `submitEmail` routed through the shim;
  FormSpark email capture preserved. Removed `import PostHog` from `CompanionManager`.
  pbxproj: all 5 PostHog GUID refs removed, Sparkle's 7 refs intact, braces balanced.
- **Perf/size delta:** binary should shrink (PostHog + plcrashreporter gone) — _measure on Xcode machine._
- **Xcode validation:** ⏳ build w/o posthog-ios; launch; confirm no analytics network
  calls; confirm no crash on former call sites (esp. `submitEmail`).

### B — STT (AssemblyAI/OpenAI → WhisperKit) ✅ code complete 2026-06-01
- **Gained:** $0, fully on-device, no key, full privacy. WhisperKit is MIT.
- **Gave up:** AssemblyAI's true-streaming turn model; WhisperKit needs ~1s of
  audio before a partial decodes, so very short presses resolve only on the
  final pass (handled via requestFinalTranscript). No first-class keyterm biasing.
- **How:** new `WhisperKitTranscriptionProvider` accumulates resampled 16 kHz
  mono Float32 samples and runs `transcribe(audioArray:)` on a ~0.5s debounce for
  partials + a final pass on key-up; shared WhisperKit instance (CoreML
  compile/prewarm is expensive). Added `BuddyFloat32AudioConverter`. Factory
  simplified to whisperkit|apple. Deleted AssemblyAI + OpenAI providers.
- **Gotcha handled:** the SPM package was **renamed** WhisperKit →
  `argmaxinc/argmax-oss-swift` v1.0.0 (pinned at commit `25c62997`);
  `AudioStreamTranscriber` owns its own mic so it can't take the app's fed
  buffers — hence the manual transcribe loop.
- **Xcode validation:** ⏳ model downloads on first run; live partials + final
  transcript; latency vs AssemblyAI; Apple Speech fallback engages if WK fails.

### D — Vision (Claude → Gemini) ✅ code complete 2026-06-01
- **Gained:** free-tier vision (gemini-2.5-flash) vs paid Anthropic; same
  screenshot→stream→[POINT] pipeline + feature set preserved.
- **Gave up:** still a cloud key (not fully local); subject to free-tier rate
  limits; grounding accuracy vs Claude is the key unknown to measure.
- **How:** `GeminiAPI` mirrors ClaudeAPI's signatures; maps system→systemInstruction,
  assistant→model role, image→inlineData; parses SSE `candidates[].content.parts[].text`
  (no `[DONE]`). Worker slimmed to 1 route proxying `streamGenerateContent?alt=sse`
  with `x-goog-api-key` + model allowlist. Picker → Flash/Flash-Lite; `claude-*`
  persisted ids migrate to the default.
- **[POINT] (highest risk):** tag + parser UNCHANGED. Gemini's native `[y,x]`
  0-1000 convention (confirmed by an independent adversarial verifier) is handled
  by one isolated `screenshotPixelCoordinate(...)` swap+scale. **Verified locally
  with swiftc: 13/13 parse+convert tests pass, incl. the axis-swap (top-right) case.**
- **Also removed:** dead `ElementLocationDetector.swift` — a second, unused,
  key-holding direct Claude Computer Use call (the last hard-coded paid API).
- **Xcode validation:** ⏳ streaming renders progressively; history preserved;
  **[POINT] hit-rate across ≥10 varied + multi-monitor prompts**; `[POINT:none]`
  suppresses; picker switches models. Record hit-rate + confirm no transpose.

### Worker & verification I could run here (no Xcode)
- Worker passes **strict `tsc` typecheck** with `@cloudflare/workers-types`; routing
  + model-allowlist + stream-select logic verified via a node simulation.
- Kokoro WAV PCM16/24kHz encoding round-trips as a valid container (stdlib check).
- `[POINT]` parse+convert verified with a compiled `swiftc` harness (13/13).
- Swift app code is reviewed at the source/contract level only; **compile/run +
  all latency/accuracy/voice-quality checks happen on the Xcode machine.**

### C — TTS (ElevenLabs → Kokoro) ✅ code complete 2026-06-01
- **Gained:** $0, fully offline, no key, no per-character cost. Kokoro-82M is
  Apache-2.0; kokoro-onnx is MIT. WAV PCM16/24kHz round-trip verified locally.
- **Gave up:** voice naturalness likely a notch below ElevenLabs; needs a local
  Python sidecar running (mitigated by AVSpeechSynthesizer auto-fallback so the
  app is never mute even before install). ~88MB int8 model downloaded on demand.
- **How:** `KokoroTTSClient` is a drop-in for `ElevenLabsTTSClient` (identical
  `speakText`/`isPlaying`/`stopPlayback`). Sidecar = stdlib `http.server`, model
  loaded once, inference lock, 127.0.0.1-only, `/health` probe. ElevenLabs client
  deleted; CompanionManager rewired.
- **Design choice:** translation/format kept simple — sidecar returns WAV so no
  Swift-side audio decoding is needed. Default voice `af_heart` (grade-A).
- **Xcode validation:** ⏳ run `tts-sidecar/setup_and_run.sh`; confirm spoken
  response plays + `stopPlayback` interrupts; kill sidecar → confirm AVSpeech
  fallback speaks; record time-to-first-audio vs ElevenLabs + voice-quality note.
- **Open item:** worker `/tts` route removal happens with Swap D integration pass.

### D — Vision (Claude → Gemini)
- **Gained:** free tier vs paid Anthropic; still cloud-quality VLM.
- **Gave up:** _TBD (still a cloud key — not fully local; grounding accuracy vs Claude)._
- **Measured:** _TBD `[POINT]` hit-rate, streaming latency, winning coord tactic._

---

## Risks & open items
- **`[POINT]` accuracy (highest):** open/free VLM grounding may lag Claude.
  Mitigation: normalized-space prompting + Swift scaling; Xcode accuracy gate.
- **Gemini free-tier rate limits:** may throttle heavy use. Mitigation: documented;
  model picker lets user pick lighter model.
- **Sidecar UX:** Kokoro needs a running local process. Mitigation: AVSpeech
  fallback + launch script + README.
- **Cannot build here:** all compile/run/accuracy validation deferred to Xcode machine.
