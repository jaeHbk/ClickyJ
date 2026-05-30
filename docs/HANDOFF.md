# Clicky — Session Handoff

_Last updated: 2026-05-29. Read this first to pick up the work._

## TL;DR

Two features were implemented on the Clicky macOS app across two branches, both
**code-complete, statically reviewed (zero blocking issues), and committed — but NOT yet
built, run, or merged.** The single blocker to "done" is that this dev environment
**cannot build the app** (see Constraint below), so the remaining work is: build + run
the Xcode verification checklists on a real Mac, then merge.

## What this project is

**Clicky** (fork of `farzaa/clicky`, MIT) — a **native macOS SwiftUI menu-bar app**
(Xcode target name `leanring-buddy`; the typo is intentional/legacy, do NOT rename).
Push-to-talk (⌃⌥) → AssemblyAI transcription → screenshot + Claude (via a Cloudflare
Worker proxy) → ElevenLabs TTS → a blue cursor overlay that flies to and points at
on-screen UI elements. It is NOT a web app.

Canonical project docs: `AGENTS.md` (== `CLAUDE.md`, a symlink). Read it for architecture,
conventions, and the Key Files table.

## ⚠️ Critical constraint — no build here

This machine has only Xcode **Command Line Tools, no `Xcode.app`**, and `AGENTS.md`
forbids `xcodebuild` (it invalidates TCC permissions). Therefore the GUI app **cannot be
built, run, or profiled in this environment.** The verification pattern used — and that a
future session should keep using:
- Machine-verify **pure logic** (parsing, coordinate math, RMS) with standalone `swiftc`
  scratch files under `scratch/` (gitignored). Several exist; re-run them anytime.
- Static-review everything else with the **`clicky-swift-reviewer`** subagent (in
  `.claude/agents/`). It runs its own `swiftc` typechecks on API surfaces.
- Hand the user an **Xcode checklist** (`docs/VERIFICATION-*.md`) for runtime behavior.

Xcode project note: it uses a `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so
**new `.swift` files in `leanring-buddy/` are auto-added to the target** — no `.pbxproj`
edit or manual "add file" step needed.

## Git layout

- Working repo: `~/projects/clicky`. Pristine upstream clone: `~/projects/clicky-upstream`.
- Remote `upstream` → `https://github.com/farzaa/clicky.git`. **NEVER push to `upstream`.**
- Branches off `main`:
  - `feature/visualize-region` — the new feature (10 commits).
  - `fix/performance` — branched off the feature branch; the perf pass (it contains the
    feature commits + 6 perf/doc commits on top).
- A publish remote (e.g. `origin` → `jaeHbk/<repo>`) may have been added — run
  `git remote -v` to confirm where things were pushed.

## Status by deliverable

### Feature: "Visualize a Region" (`feature/visualize-region`) — code-complete
**What it does:** press **⌃⇧V** → drag-select a screen region → the app captures that
crop → Claude returns `HEADING:` + `[ANNOTATE:x,y:label]` tags → the overlay draws callout
labels + connector lines over the region and the blue buddy flies to each annotation
(reusing the existing bezier-flight animation). Also reachable from a panel row.
- New file: `leanring-buddy/RegionSelectionView.swift` (mouse-accepting selection window).
- Touched: `CompanionScreenCaptureUtility`, `ClaudeAPI`, `CompanionManager`,
  `OverlayWindow`, `GlobalPushToTalkShortcutMonitor`, `BuddyDictationManager`,
  `CompanionPanelView`, `DesignSystem`, `ClickyAnalytics`, `MenuBarPanelManager`.
- Pure logic (`parseRegionAnnotations`, `mapCropPixelToGlobal`, all coord transforms)
  `swiftc`-verified. Static review: **zero blocking issues** (one race fixed, minor
  cleanups applied).
- Spec: `docs/superpowers/specs/2026-05-29-visualize-region-and-performance-design.md`
- Plan: `docs/superpowers/plans/2026-05-29-visualize-region.md`
- **Verify before merge:** `docs/VERIFICATION-visualize-region.md`

### Performance pass (`fix/performance`) — code-complete, behavior-preserving
8 changes, all meant to leave behavior identical while cutting battery/CPU/memory:
1. Forever 60fps cursor-tracking Timer → event-driven NSEvent mouse-movement monitors (A1).
2. Mic audio level no longer republished onto the panel-observed object (A2).
3. Permission poll stops once granted, re-arms on app activation (A3).
4. Waveform TimelineView + spinner rotation paused when invisible (A4).
5. JPEG-encode each display off the main actor (B1).
6. `analyzeImageStreaming` callback optional + forwards delta; callers omit it (B2).
7. AssemblyAI emits transcript only when it changed (B3).
8. RMS via `vDSP_rmsqv` + AVAudioFormat `==` instead of String compare (C2).
- `vDSP_rmsqv` proven bit-identical to the old scalar RMS via `swiftc`. Static review:
  **APPROVE, zero blocking** (7 isolated `swiftc` typechecks passed).
- **Verify before merge:** `docs/VERIFICATION-performance.md` — includes the headline
  idle-CPU before/after measurement (`main` vs `fix/performance`, cursor still, 60s).

## Next steps (in order)

1. **Build + run `feature/visualize-region` in Xcode** and walk
   `docs/VERIFICATION-visualize-region.md`. Record results. Fix anything that fails
   (the static review's "manual checks" section lists the likely runtime gotchas).
2. **Build + run `fix/performance`** and walk `docs/VERIFICATION-performance.md`,
   including the idle-CPU before/after. Confirm behavior is unchanged.
3. **Merge** once both checklists pass — suggested order: merge `feature/visualize-region`
   to `main` first, then rebase/merge `fix/performance` (it already contains the feature
   commits, so a merge of `fix/performance` alone also brings the feature — decide based
   on whether you want them as one or two PRs).
4. Optionally tackle the **deferred perf items** (see below) once there's a build loop.

## Explicitly NOT done (logged, not dropped)

- **C1** — overlay window rebuild on every `showOverlay` (behavior-sensitive: onboarding
  first-appearance logic keys off rebuild). Deferred.
- **C3** — stream TTS playback + `AVAudioPlayerDelegate` to free the MP3 buffer +
  event-driven transient-hide (needs NSObject conformance + a cross-file rewrite with a
  real runtime test loop). Deferred.
- **C4** — store/cancel onboarding + navigation-bubble timers with `[weak self]` (only
  active during onboarding/pointing, low impact). Deferred.
- **Dead code (zero runtime cost, intentionally untouched):** `CompanionResponseOverlayManager`
  and `ElementLocationDetector` are never instantiated anywhere.
- **Security/privacy (out of scope, needs owner keys/decisions):** open unauthenticated
  Worker proxy; a real OpenAI key shipped in the bundle (`OpenAIAPI.swift`); full
  transcripts + Claude responses sent to PostHog (`ClickyAnalytics.swift`). These are the
  highest-value follow-ups if the project goes beyond personal use.
- **Cursor-screen-only capture** — would cut tokens/payload but changes what Claude sees
  (behavior, not perf); left as a documented opt-in.

## Agentic scaffolding (reusable next session)

Committed under `.claude/` (the project-shared parts are un-ignored in `.gitignore`):
- `.claude/agents/clicky-swift-reviewer.md` — static Swift review for the no-build env.
  Dispatch it after any `.swift` change before claiming done.
- `.claude/agents/clicky-perf-auditor.md` — battery/idle-drain hunter.
- `.claude/skills/clicky-visualize-region/SKILL.md` — the feature's data flow + symbols.

## Useful commands

```bash
cd ~/projects/clicky
git remote -v                         # confirm push destination (NEVER upstream)
git log --oneline main..fix/performance
swift scratch/RegionCaptureGeometryScratch.swift   # re-run a pure-logic check
# Build/run is Xcode-only: open leanring-buddy.xcodeproj, Cmd+R. Do NOT run xcodebuild.
```
