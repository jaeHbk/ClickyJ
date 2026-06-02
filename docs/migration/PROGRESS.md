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
| B | Speech-to-text | WhisperKit | ⬜ not started | ⏳ XCODE |
| C | Text-to-speech | Kokoro sidecar | ✅ code done (merged `main`) | ⏳ XCODE |
| D | Vision + `[POINT]` | Gemini 2.x Flash | ⬜ not started | ⏳ XCODE |

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

### B — STT (AssemblyAI/OpenAI → WhisperKit)
- **Gained:** $0, fully offline, no key, privacy.
- **Gave up:** _TBD (streaming partials may differ from AssemblyAI turn model)._
- **Measured:** _TBD latency (ms to partial / final), accuracy notes, model size._

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
