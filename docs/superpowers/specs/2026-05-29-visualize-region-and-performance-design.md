# Clicky — "Visualize a Region" feature + performance pass — Design

Date: 2026-05-29
Author: Claude (pairing with Jaehun Baek)
Status: Approved design — ready for implementation planning

## Context

Clicky (internal target name `leanring-buddy`) is a **native macOS menu-bar SwiftUI app**.
It is not a web app. Push-to-talk (⌃⌥) captures voice → AssemblyAI streaming
transcription → a screenshot of all displays + the transcript go to Claude (via a
Cloudflare Worker proxy) → Claude streams text back and the answer is spoken via
ElevenLabs TTS → a blue triangle "cursor buddy" overlay can fly along a bezier arc
to point at a UI element Claude references (`[POINT:x,y:label:screenN]`).

This document specifies two pieces of work, delivered on two branches:

1. **Feature** (`feature/visualize-region`): a "Visualize a region" capability — the
   user drag-selects a rectangle on screen, and Clicky draws an **annotated overlay**
   (arrows + short callout labels) over that region, flying its cursor to each part
   it explains.
2. **Performance** (`fix/performance`, branched after the feature merges): a
   behavior-preserving pass that removes idle battery drains and hot-path/memory waste.

### Hard environment constraint (must read)

The development machine has **only Xcode Command Line Tools, no `Xcode.app`**, and the
project's `AGENTS.md` explicitly forbids running `xcodebuild` from the terminal (it
invalidates TCC permissions). Therefore this work **cannot be built, run, or profiled
with Instruments in this environment.** Mitigations:

- All Swift is written to compile cleanly under the project's Swift settings and
  matches existing patterns exactly.
- Pure-logic pieces (regex parsing, coordinate math) are extracted so they can be
  isolate-compiled with `swiftc` and unit-reasoned about independently.
- Each branch ships with a precise **Xcode verification checklist** the user runs on
  their machine (build, run, manual behavior checks, and — for perf — an Activity
  Monitor / `powermetrics` idle-CPU comparison).

This constraint is disclosed in the spec, the plan, and the final summary. No success
claim is made about runtime behavior that was not verified by the user.

## Non-goals / out of scope

- No build-system, signing, scheme, or directory renames (the "leanring" typo stays).
- Not fixing the documented "known non-blocking warnings" (Swift 6 concurrency,
  deprecated `onChange`).
- Security/privacy hardening (Worker auth, the OpenAI key shipped in the bundle, full
  transcript/response sent to PostHog) is **explicitly out of scope** for this pass.
- Dead code is **not** modified to "improve performance": `CompanionResponseOverlayManager`
  (CompanionResponseOverlay.swift) and `ElementLocationDetector` (ElementLocationDetector.swift)
  are never instantiated anywhere in the app, so they have zero runtime cost. They are
  noted, not touched. (The feature may *reuse* the response-overlay view pattern, but
  will not resurrect the dead manager.)

---

# Part 1 — Feature: "Visualize a Region" (annotated overlay)

## User-facing behavior

1. User presses **⌃⇧V** (control + shift + V) anywhere.
   - This combination is intentionally chosen so it is **not** a superset of the
     push-to-talk modifier pair (⌃⌥), so the two shortcuts never collide.
2. A dimmed selection layer appears on the screen that contains the cursor. The user
   drags a rectangle (rubber-band marquee). A live dimension readout and a blue
   border (DS overlay-cursor blue) track the drag.
3. On mouse-up:
   - If the rectangle is too small (< 16×16 pt), selection is cancelled silently.
   - Otherwise the selection layer disappears, Clicky shows its processing spinner,
     captures **exactly that region** as a JPEG crop, and sends it to Claude.
4. Claude returns a short heading plus up to ~5 annotations. Clicky:
   - Draws each annotation as a small callout label with a thin connector line, placed
     over the captured region (on the click-through overlay, so it never blocks input).
   - Flies the buddy cursor to each annotation target in sequence using the existing
     bezier-flight animation, pausing briefly on each.
   - Shows the heading as a small title chip near the top-left of the region.
5. Dismissal: `Esc` at any time, a click anywhere (during display), pressing ⌃⇧V again,
   or starting push-to-talk (⌃⌥) all cancel/clear the visualization and return the
   buddy to normal cursor-following.

The visualization is **transient and anchored to screen coordinates at capture time.**
It does not attempt to track the underlying window if the user scrolls or moves it
(documented limitation — live re-anchoring is a much larger feature). It auto-fades
after a hold period (default 12s) if not dismissed sooner.

## Architecture — reuse-first

The feature is a **parallel entry path** through the existing capture → Claude →
overlay pipeline. New infrastructure is limited to (a) a mouse-accepting selection
window (the existing overlays are deliberately click-through and cannot capture drag),
and (b) annotation rendering in the existing click-through overlay.

### New unit: `RegionSelectionController` + `RegionSelectionWindow` (new file `RegionSelectionView.swift`)

- **What it does:** Presents a borderless, **mouse-accepting** window covering the
  cursor's screen, hosts a SwiftUI rubber-band marquee, and reports the final
  selection rectangle (in AppKit global coordinates) plus the `NSScreen` it was drawn
  on — or `nil` if cancelled.
- **How you use it:** `controller.beginSelection(onComplete: (CGRect, NSScreen)?->Void)`.
  Exactly one selection window exists at a time; calling begin again cancels the prior.
- **What it depends on:** `NSScreen`, `NSEvent.mouseLocation`, AppKit window APIs,
  `DS.Colors`. Independent of `CompanionManager`.
- **Why a new window (not the existing overlay):** `OverlayWindow` sets
  `ignoresMouseEvents = true` and `canBecomeKey = false` by design (it must never steal
  input). Region selection fundamentally needs mouse-down/drag/up and key (Esc) events,
  so it requires a separate, temporary window whose `ignoresMouseEvents = false` and
  that can become key only for the duration of the drag. It is torn down immediately on
  completion/cancel so it never lingers as an input-blocking surface.
- **Coordinate mapping:** reuses the same AppKit↔SwiftUI conversion math already proven
  in `BlueCursorView.convertScreenPointToSwiftUICoordinates` (OverlayWindow.swift:447).
  The drag rect is built in window-local SwiftUI coords and converted to AppKit global
  coords on mouse-up.

### New method: `CompanionScreenCaptureUtility.captureRegionAsJPEG(globalRect:on:)`

- Sibling to `captureAllScreensAsJPEG()` (CompanionScreenCaptureUtility.swift:30).
- Builds the same `SCContentFilter(display:excludingWindows: ownAppWindows)` (so Clicky's
  own overlays/panels are excluded from the shot) and uses
  `SCStreamConfiguration.sourceRect` set to the region (converted from AppKit global to
  the display's Core-Graphics-origin local rect) to capture a tight crop. Falls back to
  capturing the full display and cropping the `CGImage` if `sourceRect` is unavailable.
- Returns a single `CompanionScreenCapture`-like struct carrying: JPEG `Data`, the crop's
  pixel width/height, the region's display-point size, and the region's AppKit global
  origin/frame (so annotations can be mapped back onto the screen using the *same*
  pixel→point→AppKit conversion already used for `[POINT:]` at CompanionManager.swift:653-674).
- Encoding (JPEG + base64) runs **off the main actor** (`Task.detached`), consistent with
  the perf pass.

### New method: `ClaudeAPI.analyzeRegionForAnnotations(...)`

- Sibling to `analyzeImageStreaming` (ClaudeAPI.swift:101). Same `URLSession`, same Worker
  `/chat` proxy, same TLS warmup — **routes through the Worker** (does NOT use the
  direct-to-Anthropic path in the dead `ElementLocationDetector`, preserving the
  "no keys in the binary" invariant).
- Differences: a dedicated annotation **system prompt** (below), a single image (the
  crop), no conversation history, `max_tokens` raised to ~700, non-streaming
  (`analyzeImage`-style single response is sufficient since we parse a structured tail).
- Returns the full response text; parsing happens in `CompanionManager`.

### Annotation tag format + parsing (`CompanionManager`)

Claude is instructed to answer with a one-line heading, then one annotation per line:

```
HEADING: <3-6 word title>
[ANNOTATE:x,y:label]
[ANNOTATE:x,y:label]
...
```

- `x,y` are integer pixel coordinates **in the crop's coordinate space** (top-left
  origin), exactly mirroring the existing `[POINT:]` convention so the same scaling code
  is reused.
- New `parseRegionAnnotations(from:)` static function returns `(heading: String?,
  annotations: [(point: CGPoint, label: String)])`. It is a pure function (regex +
  string work, no UI), so it is unit-reasonable and isolate-compilable. Modeled directly
  on the existing `parsePointingCoordinates` (CompanionManager.swift:784).
- Each crop-pixel coordinate is mapped to an AppKit global point using the region's
  captured pixel/point dimensions and global origin — the identical transform already at
  CompanionManager.swift:653-674, factored into a small reusable helper
  `mapCropPixelToGlobal(...)` so both `[POINT:]` and `[ANNOTATE:]` share it.

### New state on `CompanionManager`

```
@Published var activeRegionVisualization: RegionVisualization?   // nil when none
struct RegionVisualization {
    let regionGlobalFrame: CGRect          // AppKit global
    let displayFrame: CGRect               // the screen's frame
    let heading: String?
    let annotations: [RegionAnnotation]    // each: global point + label
}
```

- New orchestrator `visualizeRegion(globalRect:on:)` mirrors
  `sendTranscriptToClaudeWithScreenshot` (CompanionManager.swift:586): sets
  `voiceState = .processing`, cancels any prior `currentResponseTask`, captures the
  region, calls `analyzeRegionForAnnotations`, parses, builds `RegionVisualization`,
  publishes it, returns `voiceState` to `.idle`. **No TTS, no `[POINT]` flight** on this
  path — annotation flight is driven separately. Reuses `currentResponseTask` cancellation
  so a new utterance or a new visualization cleanly interrupts it.

### Rendering (`BlueCursorView` in OverlayWindow.swift)

- A new subview observes `companionManager.activeRegionVisualization`. When present and
  the region is on **this** screen:
  - Draws a thin rounded rectangle around the region (DS overlay-cursor blue, low-opacity
    fill) as a "you selected this" affordance.
  - Draws each annotation: a small callout label (same bubble styling as the existing
    navigation bubble) at an offset from its target, with a thin connector line from the
    label to the target point.
  - Drives the buddy to fly to each annotation target in sequence by reusing
    `animateBezierFlightArc` (OverlayWindow.swift:524) — feeding it the annotation points
    one after another. This is the same mechanism as element pointing; annotation flight
    is a thin sequencing layer over it.
- Multi-monitor: only the `BlueCursorView` whose `screenFrame` contains the region renders
  the visualization (mirrors the existing single-buddy rule at OverlayWindow.swift:395-407).

### Discoverability (`CompanionPanelView`)

- Add a "Visualize a region (⌃⇧V)" row near the model picker. Tapping it posts a new
  `.clickyStartRegionVisualization` notification (same NotificationCenter pattern as
  `.clickyDismissPanel`), which `CompanionManager` handles by dismissing the panel and
  beginning selection — identical to the hotkey path.

### Shortcut wiring

- Add a `.controlShiftV` case to `BuddyPushToTalkShortcut.ShortcutOption` semantics —
  but the cleaner approach (chosen): the global tap already sees all `flagsChanged/keyDown/keyUp`.
  Add a small dedicated detector in `GlobalPushToTalkShortcutMonitor` (or a second
  transition kind) that emits a `.visualizeRegionRequested` transition when V (keyCode 9)
  is pressed while control+shift are held. `CompanionManager.handleShortcutTransition`
  gets a new case that calls `beginRegionSelection()`. All global-shortcut handling stays
  in the one monitor + the one dispatch switch (no second event tap, per the perf goals).

### Annotation system prompt (draft)

> you're clicky. the user drag-selected a region of their screen and wants you to
> visualize/explain what's inside it. look only at the cropped image provided.
> respond with a single heading line, then up to five annotation tags, nothing else.
> first line: `HEADING: <3 to 6 word title of what this region is>`
> then one tag per important part you want to call out:
> `[ANNOTATE:x,y:label]` where x,y are integer pixel coordinates in THIS image's space
> (origin top-left, x right, y down — the image dimensions are given), and label is a
> 2 to 5 word plain-language explanation of that part. point at concrete, specific
> things (a function name, a button, a field, a value), not vague areas. order the
> annotations the way you'd explain them to a learner. all lowercase. no emojis.
> if there is nothing meaningful to annotate, respond with `HEADING: nothing to show`
> and no annotation tags.

## Error handling

- Capture failure / API error / no annotations parsed → clear `voiceState` to `.idle`,
  no visualization shown, log to console (matching existing `print` style), track an
  analytics failure count (no content). No crash, no stuck overlay.
- Selection cancelled (Esc / too-small / lost focus) → tear down selection window, no
  network call.
- A new ⌃⇧V or push-to-talk while a visualization is showing → cancel current
  (`currentResponseTask?.cancel()`, clear `activeRegionVisualization`) before starting new.

## Testing strategy (given no-build constraint)

- **Isolate-compilable pure logic:** `parseRegionAnnotations` and `mapCropPixelToGlobal`
  are pure functions. A small `swiftc`-compilable scratch harness exercises them against
  hand-written inputs (valid tags, malformed tags, out-of-range coords, no tags) to
  confirm parsing/coordinate math before they go near the app. This is the one place we
  can get real machine-checked verification without Xcode.
- **Xcode verification checklist** (user runs): build succeeds; ⌃⇧V dims + marquee draws;
  drag + release captures; annotations + heading appear over the region; buddy flies to
  each; Esc / re-press / push-to-talk all dismiss cleanly; multi-monitor (if available)
  draws on the correct screen; push-to-talk still works unchanged.

---

# Part 2 — Performance pass (behavior-preserving)

Branched as `fix/performance` after the feature merges. Every change preserves observable
behavior; the goal is to cut idle battery/CPU and hot-path/memory waste. Findings were
produced by a parallel multi-agent audit AND independently cross-verified by reading every
core file. Items are grouped by theme; rank numbers refer to the audit's ranking.

## Group A — idle drains (largest battery win)

- **A1 (rank 1) — Forever 60fps per-screen cursor `Timer`.** `OverlayWindow.swift:411-443`
  runs `Timer(0.016, repeats)` per screen for the whole session, polling
  `NSEvent.mouseLocation` and writing `cursorPosition` (→ SwiftUI relayout + spring) ~62/s
  even when idle or on another monitor; N monitors = N timers.
  **Fix:** replace with `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` (plus a
  local monitor so movement over our own windows still counts) so the closure fires only on
  real movement; early-return when position is unchanged; skip when `!isCursorOnThisScreen`
  and not navigating. The navigation/flight animation keeps its own short-lived timer
  (it is event-bounded, not idle). Behavior (buddy follows cursor) is identical.

- **A2 (rank 2) — Audio level republished onto the panel-observed object.**
  `BuddyDictationManager.updateAudioPowerLevel` → `CompanionManager.bindAudioPowerLevel`
  (CompanionManager.swift:423) writes `@Published currentAudioPowerLevel` on
  `CompanionManager`, which the menu-bar panel observes — so recording re-renders the entire
  panel body ~45×/s even though the panel never shows the level.
  **Fix:** the waveform reads the level directly from `buddyDictationManager.$currentAudioPowerLevel`
  (the overlay already has access to `companionManager.buddyDictationManager`), and the
  republish onto `CompanionManager` is removed. If any non-overlay consumer needs it, it
  moves to a dedicated lightweight `ObservableObject`. Waveform behavior is identical;
  the panel simply stops re-rendering during recording.

- **A3 (rank 3) — Forever 1.5s permission poll.** `CompanionManager.startPermissionPolling`
  (`:414`) fires `refreshAllPermissions()` every 1.5s for the app's whole life, calling AX/
  screen/mic checks and `start()/stop()` on the event tap ~40×/min.
  **Fix:** poll only while the panel is visible AND not all permissions are granted
  (`MenuBarPanelManager` starts/stops the timer on show/hide via a callback or notification),
  and additionally refresh once on `NSApplication.didBecomeActive`. Once
  `allPermissionsGranted` is true, stop polling. Live permission-grant UX during onboarding
  is preserved (panel is open then); the idle forever-poll is removed. The event-tap
  `start()` guard stays as defense-in-depth.

- **A4 (rank 11) — Always-on waveform `TimelineView` + (rank, spinner) animate while invisible.**
  `OverlayWindow.swift:716` `TimelineView(.animation)` and `:769` `repeatForever` spinner are
  permanently in the ZStack (opacity-gated), so they keep ticking when not listening/processing.
  **Fix:** mount `BlueCursorWaveformView` only when `voiceState == .listening` and
  `BlueCursorSpinnerView` only when `voiceState == .processing` (conditional in the view tree
  rather than opacity 0). The existing cross-fade is preserved by animating the container's
  insertion/removal. Visual result is identical; the schedulers stop when not in use.

## Group B — hot path / responsiveness

- **B1 (rank 8) — Image encode/base64/JSON on the main actor; sequential per display.**
  Move JPEG encode (CompanionScreenCaptureUtility) + `base64EncodedString()` +
  `JSONSerialization` (ClaudeAPI.swift:128/150) to `Task.detached(priority:.userInitiated)`,
  and capture displays concurrently with a task group. **Default capture set stays
  all-monitors** (sending only the cursor screen would change what Claude sees = behavior).
  Cursor-screen-only is left as a documented opt-in, not a silent default.

- **B2 (rank 7) — O(n²) SSE accumulation + main-actor hop with a no-op consumer.**
  `ClaudeAPI.analyzeImageStreaming` (`:206`) copies the entire accumulated string per delta
  and `await`s `onTextChunk` on `@MainActor` even though the live consumer is empty.
  **Fix:** pass only the incremental delta; make `onTextChunk` optional and skip the
  main-actor hop when nil. Callers that want full text keep their own accumulation. The
  visualization path doesn't stream, so it's unaffected.

- **B3 (rank 13) — AssemblyAI recomposes + emits full transcript on every partial.**
  `AssemblyAIStreamingTranscriptionProvider.swift:273-347` sorts+joins the whole transcript
  and fires `onTranscriptUpdate` on every partial Turn message.
  **Fix:** only recompose/emit when the composed text actually changed vs the last emit;
  throttle emits to ~100-150ms. Final transcript on key-up is unchanged.

- **B4 (rank 9) — note only.** The second 60fps timer + per-token relayout live in
  `CompanionResponseOverlayManager`, which is **dead code** (never instantiated). No runtime
  cost → not modified. Documented in the perf summary.

## Group C — memory / lifecycle / realtime-thread

- **C1 (rank 10) — `showOverlay` tears down + rebuilds all windows/hosting views/timers.**
  `OverlayWindowManager.showOverlay` (`:783`) calls `hideOverlay()` then recreates everything
  per call, even for transient show/hide.
  **Fix:** if the screen configuration is unchanged and windows already exist, reuse them
  (toggle `orderFront`/`alphaValue`) instead of rebuilding hosting views and restarting the
  tracking monitor; rebuild only on screen add/remove. Behavior identical.

- **C2 (rank 12 + 20) — Audio conversion + heap alloc + scalar RMS on the realtime render thread.**
  `BuddyAudioConversionSupport.convertToPCM16Data` and the RMS loop run synchronously on the
  `AVAudioEngine` tap thread per 1024-frame buffer.
  **Fix:** move PCM16 conversion into the existing `sendQueue.async` (or a dedicated
  conversion queue) so the render thread only does a fast handoff; reuse a pre-allocated
  output buffer; compute RMS with `vDSP_rmsqv` (Accelerate); replace the per-buffer
  `format.settings.description` string compare with an `AVAudioFormat` equality check.
  Transcription accuracy and the waveform are unchanged; glitch risk under load drops.

- **C3 (rank 17 + 21) — TTS buffers full MP3, no delegate to free it; transient-hide busy-polls.**
  `ElevenLabsTTSClient.speakText` (`:65`) holds the full decoded MP3 in `audioPlayer` until
  the next call; `CompanionManager.scheduleTransientHideIfNeeded` (`:732`) polls `isPlaying`
  every 200ms for the whole TTS duration.
  **Fix:** add an `AVAudioPlayerDelegate`; on `audioPlayerDidFinishPlaying`, nil out
  `audioPlayer` (free the buffer) and fulfill a continuation so transient-hide becomes
  **event-driven** instead of polling. Hold the fallback `NSSpeechSynthesizer` in a stored
  property so its speech isn't cut off. Playback timing is unchanged (still plays on first
  full body; true streaming playback is a larger change left out of scope).

- **C4 (rank 18 + 19) — Leak-prone onboarding & navigation-bubble timers/tasks.**
  Several `Timer.scheduledTimer` and recursive `DispatchQueue.main.asyncAfter` chains in
  `CompanionManager` (onboarding typewriter `:907`, video-audio fade `:937`, demo Task `:971`)
  and `OverlayWindow.swift` (`streamNavigationBubbleCharacter` `:605`) capture `self` strongly
  and aren't stored/cancellable.
  **Fix:** store them in cancellable properties, capture `[weak self]`, invalidate/cancel in
  `tearDownOnboardingVideo()` / `stop()` / `onDisappear` / at the start of `replayOnboarding()`.
  Prefer a single `Task` with `Task.sleep` over a 33Hz timer + chained `asyncAfter` where it
  reduces wakeups. Onboarding visuals are unchanged; orphaned timers after rapid replay are
  eliminated.

## Group D — micro (rank 22, trivial, bundled)

- Call `hideOverlay()` directly in completions already on main (drop unnecessary
  `Task { @MainActor }` hops); precompute static blended/hex colors used inside frequently
  re-rendered view bodies; use `[weak self]` in the click-outside inner `asyncAfter` for
  consistency. Mostly subsumed by A1/A2 reducing re-render frequency.

## Out of scope this pass (explicitly logged, not silently dropped)

- Security/privacy: Worker shared-secret/rate-limit (rank 4), OpenAI key in bundle (rank 5),
  PostHog raw content (rank 15). Require the user's keys/decisions.
- True streaming TTS playback (rank 17 deeper fix).
- Sending only the cursor screen to Claude (behavior change, not perf) — offered as opt-in.

## Testing strategy (perf)

- **Behavior preservation is the bar.** Each change is paired with the exact behavior that
  must remain identical (stated per item above).
- **Isolate-compile** any extracted pure helpers with `swiftc`.
- **Xcode verification checklist** (user runs): app builds; buddy still follows cursor
  smoothly; push-to-talk waveform still reacts to voice; permissions UI still updates live
  while the panel is open; onboarding still plays; THEN an **idle measurement**: leave the
  app idle (cursor still, panel closed) for 60s and compare CPU% / wakeups in Activity Monitor
  (and `powermetrics --samplers tasks` if available) before vs after — expecting the idle CPU
  of the Clicky process to drop from "continuously non-trivial" toward near-zero.

---

## Delivery plan

1. `feature/visualize-region` (this branch): implement Part 1, write a CLAUDE.md/AGENTS.md
   update, ship the Xcode verification checklist, request review, finish the branch.
2. `fix/performance` (branched after): implement Part 2 grouped commits (A → B → C → D),
   each commit stating the behavior it preserves; ship the perf verification checklist.
3. Agentic workflow scaffolding (CLAUDE.md additions, a `clicky-perf-auditor` subagent and a
   `visualize-region` skill description) is added so future sessions inherit this context.
