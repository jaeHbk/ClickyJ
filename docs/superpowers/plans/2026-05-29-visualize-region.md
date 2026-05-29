# Visualize a Region — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a ⌃⇧V "visualize a region" flow to Clicky: drag-select a screen rectangle, capture it as a tight crop, ask Claude for `[ANNOTATE:x,y:label]` callouts, and draw an annotated overlay while the blue buddy cursor flies to each annotated point.

**Architecture:** A parallel entry path through Clicky's existing capture → Claude → overlay pipeline. The only new infrastructure is a mouse-accepting selection window (the existing overlays are deliberately click-through). Capture reuses `CompanionScreenCaptureUtility` patterns; the Claude call reuses the `ClaudeAPI`→Cloudflare-Worker `/chat` path; rendering and the buddy flight reuse `BlueCursorView` + `animateBezierFlightArc`.

**Tech Stack:** Swift 5 / SwiftUI + AppKit (NSWindow/NSHostingView), ScreenCaptureKit, Combine, the existing Cloudflare Worker proxy.

**Build constraint:** No `Xcode.app` in this environment and `xcodebuild` is forbidden by AGENTS.md. Pure functions are machine-verified with `swiftc` scratch files; everything else uses a manual Xcode checklist plus the `clicky-swift-reviewer` subagent. The full per-task Swift bodies authored and adversarially verified for this plan are staged at `/tmp/clicky_plan_parts/` (reference during implementation).

---

## Resolved symbol ownership (CRITICAL — fixes the 5 cross-component conflicts the verifier caught)

These decisions are binding. Each shared symbol has exactly ONE owner; every other task consumes it.

| Symbol | Single owner / definition site | Notes |
|---|---|---|
| `struct RegionCapture` | `CompanionScreenCaptureUtility.swift` (top-level) | Fields: `imageData: Data`, `cropPixelWidth: Int`, `cropPixelHeight: Int`, `regionGlobalFrame: CGRect`, `displayFrame: CGRect`. The pure-logic task does NOT redeclare it. |
| `struct RegionAnnotation` | nested `CompanionManager.RegionAnnotation` | `: Equatable`. Fields: `globalPoint: CGPoint`, `label: String`. |
| `struct RegionVisualization` | nested `CompanionManager.RegionVisualization` | `: Equatable`. Fields: `regionGlobalFrame: CGRect`, `displayFrame: CGRect`, `heading: String?`, `annotations: [RegionAnnotation]`. Equatable is REQUIRED because `BlueCursorView` uses `.onChange(of: activeRegionVisualization)`. OverlayWindow references them as `CompanionManager.RegionVisualization` / `CompanionManager.RegionAnnotation`. |
| Analytics methods | `ClickyAnalytics.swift`, ONE canonical set | `trackRegionVisualizationStarted()`, `trackRegionVisualizationCompleted(annotationCount: Int)`, `trackRegionVisualizationFailed(reason: String)`. `visualizeRegion` calls exactly these. The panel-discoverability task does NOT redeclare them. |
| Clear method | `CompanionManager.clearRegionVisualization()` | One name. OverlayWindow calls `companionManager.clearRegionVisualization()` (NOT `clearActiveRegionVisualization`). |
| `regionAnnotationSystemPrompt` | `ClaudeAPI.regionAnnotationSystemPrompt` only | Do NOT add a duplicate `CompanionManager.regionVisualizationSystemPrompt`. |
| `Notification.Name.clickyStartRegionVisualization` | the existing extension in `MenuBarPanelManager.swift:17-19` | Single declaration. |
| `.visualizeRegionRequested` | new case on `BuddyPushToTalkShortcut.ShortcutTransition` (BuddyDictationManager.swift:83-87) | Both exhaustive switches (GlobalPushToTalkShortcutMonitor.swift:119, CompanionManager.swift:474) get the new case. |

`RegionSelectionController.beginSelection` signature: `func beginSelection(onComplete: @escaping ((CGRect, NSScreen)?) -> Void)` — passes `nil` on cancel.

---

## Task order (verified dependency order — symbols exist before use)

Implement in this order so no task references a not-yet-created symbol. Commit after each task.

1. **Task A — Region capture** (`CompanionScreenCaptureUtility.swift`): `RegionCapture` struct + pure `convertGlobalRectToDisplayLocalCGRect(globalRect:displayFrame:)` + `captureRegionAsJPEG(globalRect:on:)`.
2. **Task B1 — DS tokens** (`DesignSystem.swift`): `regionSelectionStroke`, `regionSelectionFill`, `annotationCallout`, `annotationConnector` near `overlayCursorBlue` (:144). (Independent; early.)
3. **Task B2 — Notification name** (`MenuBarPanelManager.swift:17-19`): add `clickyStartRegionVisualization`.
4. **Task B3 — Analytics** (`ClickyAnalytics.swift`): the one canonical method set (Started / Completed(annotationCount:) / Failed(reason:)), no screen content sent.
5. **Task C — Pure logic + data structs** (`CompanionManager.swift`): nested `RegionAnnotation`/`RegionVisualization` (Equatable), static `parseRegionAnnotations(from:)`, static `mapCropPixelToGlobal(pixelPoint:capture:)`. Machine-verify both pure functions with a `swiftc` scratch file.
6. **Task D — ClaudeAPI call** (`ClaudeAPI.swift`): `regionAnnotationSystemPrompt` + `analyzeRegionForAnnotations(imageData:cropPixelWidth:cropPixelHeight:)` (non-streaming, max_tokens 700, routes through Worker `/chat`).
7. **Task E — Selection window** (new `RegionSelectionView.swift`): `RegionSelectionWindow`, `RegionSelectionController`, marquee SwiftUI view; converts local SwiftUI rect → AppKit global on mouse-up; Esc / too-small / re-begin → `onComplete(nil)`.
8. **Task F — State + shortcut wiring** (`CompanionManager.swift`, `GlobalPushToTalkShortcutMonitor.swift`, `BuddyDictationManager.swift`): `.visualizeRegionRequested` case + both switches; V (keyCode 9) + control+shift detection in the tap; `@Published activeRegionVisualization`; `regionSelectionController`; `beginRegionSelection()`; `visualizeRegion(globalRect:on:)`; `clearRegionVisualization()`; observe the notification in `start()`/`stop()`; cancel region viz on push-to-talk `.pressed`.
9. **Task G — Overlay rendering + flight** (`OverlayWindow.swift`): `.onChange(of: companionManager.activeRegionVisualization)`; the callouts + connector lines + region rectangle section in the ZStack; sequence the buddy to each annotation via `animateBezierFlightArc`; 12s auto-clear timer (stored, invalidated in `onDisappear`); >100px cursor-move cancel; guard against fighting the existing `[POINT]` flight.

---

## Per-task specifications

Each task below states Files, the exact symbols, the verification, and the commit. Full pre-written Swift bodies (adversarially verified, line-accurate) are in `/tmp/clicky_plan_parts/<slug>.md`. Apply them with the ownership resolutions above — in particular, DELETE the duplicate `RegionCapture` from the parse part, DELETE the duplicate analytics/struct/clear-name definitions from the parts that don't own them, and ADD `: Equatable` to the two nested structs.

### Task A — Region capture

**Files:** Modify `leanring-buddy/CompanionScreenCaptureUtility.swift` (add `RegionCapture` after `:22`; add helpers inside the enum before `:132`). Scratch: `/tmp/clicky_region_geometry_check.swift`.

- [ ] **A1** Add `struct RegionCapture` (top-level) with the 5 agreed fields.
- [ ] **A2** Add pure `static func convertGlobalRectToDisplayLocalCGRect(globalRect:displayFrame:) -> CGRect` (AppKit bottom-left → CG top-left; inverse of CompanionManager.swift:653-674).
- [ ] **A3** Add `static func captureRegionAsJPEG(globalRect: CGRect, on screen: NSScreen) async throws -> RegionCapture`: resolve the `SCDisplay` for `screen` (via `deviceDescription` NSScreenNumber → `displayID`, mirroring :53-58), build `SCContentFilter(display:excludingWindows: ownAppWindows)` exactly like :42-45/:81, set `config.sourceRect` from the helper and `config.width/height` to the region pixel size honoring `screen.backingScaleFactor`, capture via `SCScreenshotManager.captureImage`, JPEG-encode (q0.8) **inside `Task.detached`** (off main), return `RegionCapture`. Include the `sourceRect`-unavailable fallback: capture full display then `cgImage.cropping(to:)`.
- [ ] **A4** Machine-verify the geometry: write `/tmp/clicky_region_geometry_check.swift` (standalone copy of `convertGlobalRectToDisplayLocalCGRect` + asserts for primary display, bottom-flush region, and a non-zero-origin secondary display). Run `swiftc -o /tmp/cg /tmp/clicky_region_geometry_check.swift && /tmp/cg`. Expected: all asserts pass, no output / "ok".
- [ ] **A5** Commit: `feat(capture): add region screenshot capture for visualize feature`.

### Task B1 — DS tokens

**Files:** Modify `leanring-buddy/DesignSystem.swift` (near `:144`).
- [ ] **B1.1** Add `regionSelectionStroke` (= `overlayCursorBlue`), `regionSelectionFill` (= `blue500.opacity(0.12)`), `annotationCallout` (= `overlayCursorBlue`), `annotationConnector` (= `blue400.opacity(0.85)`).
- [ ] **B1.2** Commit: `feat(design): add region-visualization color tokens`.

### Task B2 — Notification name

**Files:** Modify `leanring-buddy/MenuBarPanelManager.swift:17-19`.
- [ ] **B2.1** Add `static let clickyStartRegionVisualization = Notification.Name("clickyStartRegionVisualization")` to the existing extension.
- [ ] **B2.2** Commit: `feat(region): add start-region-visualization notification`.

### Task B3 — Analytics (canonical set)

**Files:** Modify `leanring-buddy/ClickyAnalytics.swift` (after `:104`).
- [ ] **B3.1** Add `trackRegionVisualizationStarted()`, `trackRegionVisualizationCompleted(annotationCount: Int)`, `trackRegionVisualizationFailed(reason: String)` — properties limited to `annotation_count` / `reason`, NO screen content.
- [ ] **B3.2** Commit: `feat(analytics): add region-visualization events (no content)`.

### Task C — Pure logic + data structs

**Files:** Modify `leanring-buddy/CompanionManager.swift` (structs near the other nested types; statics near `parsePointingCoordinates` `:784`). Scratch: `/tmp/clicky_parse_check.swift`.
- [ ] **C1** Add nested `struct RegionAnnotation: Equatable { let globalPoint: CGPoint; let label: String }` and `struct RegionVisualization: Equatable { let regionGlobalFrame: CGRect; let displayFrame: CGRect; let heading: String?; let annotations: [RegionAnnotation] }`.
- [ ] **C2** Add `static func parseRegionAnnotations(from:) -> (heading: String?, annotations: [(point: CGPoint, label: String)])` — parse optional `HEADING:` line + zero-or-more `[ANNOTATE:x,y:label]` (regex mirroring `parsePointingCoordinates`, matching globally).
- [ ] **C3** Add `static func mapCropPixelToGlobal(pixelPoint: CGPoint, capture: RegionCapture) -> CGPoint` — clamp to crop pixel bounds, scale by region-point/crop-pixel ratio, flip Y within region point height, offset by `regionGlobalFrame.origin` (mirrors :653-674).
- [ ] **C4** Machine-verify: `/tmp/clicky_parse_check.swift` (standalone copies + a minimal `RegionCapture` stand-in) with asserts for: valid multi-annotation, HEADING-only, no tags, malformed tag ignored, out-of-range coord clamped. Run `swiftc -o /tmp/pc /tmp/clicky_parse_check.swift && /tmp/pc`. Expected: all asserts pass.
- [ ] **C5** Commit: `feat(region): add annotation parsing and crop-pixel->global mapping`.

### Task D — ClaudeAPI annotation call

**Files:** Modify `leanring-buddy/ClaudeAPI.swift` (after `analyzeImage` `:290`).
- [ ] **D1** Add `private static let regionAnnotationSystemPrompt` (the spec's annotation prompt).
- [ ] **D2** Add `func analyzeRegionForAnnotations(imageData: Data, cropPixelWidth: Int, cropPixelHeight: Int) async throws -> String` modeled on `analyzeImage` (non-streaming), `max_tokens: 700`, image label includes the crop pixel dimensions, single user image + prompt, routes through `self.session`→Worker `/chat`. Returns raw text.
- [ ] **D3** Verify (static review): confirm it reuses `makeAPIRequest`, `detectImageMediaType`, the Worker URL — never `api.anthropic.com` directly.
- [ ] **D4** Commit: `feat(claude): add region annotation analysis via worker proxy`.

### Task E — Region selection window

**Files:** Create `leanring-buddy/RegionSelectionView.swift`. (Must be added to the Xcode target — flagged in the checklist.)
- [ ] **E1** `RegionSelectionWindow: NSWindow` — borderless, `ignoresMouseEvents = false`, `canBecomeKey = true`, `level = .screenSaver`, `collectionBehavior` joins all spaces, dim clear background, `isReleasedWhenClosed = false`.
- [ ] **E2** `RegionSelectionMarqueeView` (SwiftUI) — drag gesture draws the rubber-band Rect with `regionSelectionStroke`/`regionSelectionFill`, live WxH readout; reports start/current points.
- [ ] **E3** `@MainActor final class RegionSelectionController` — `beginSelection(onComplete: @escaping ((CGRect, NSScreen)?) -> Void)`: show ONE window on the cursor's screen, host the marquee, on mouse-up convert local SwiftUI rect → AppKit global (inverse of `convertScreenPointToSwiftUICoordinates`) and call `onComplete((rect, screen))`; Esc / `< 16×16` / a second `beginSelection` → `onComplete(nil)`; tear down the window immediately on either path.
- [ ] **E4** Machine-verify the local→global rect math with a `swiftc` scratch (inverse-transform asserts incl. non-zero-origin secondary display).
- [ ] **E5** Commit: `feat(region): add rubber-band region selection window`.

### Task F — State + shortcut wiring

**Files:** Modify `BuddyDictationManager.swift:83-87`, `GlobalPushToTalkShortcutMonitor.swift:100-131`, `CompanionManager.swift`.
- [ ] **F1** Add `.visualizeRegionRequested` to `BuddyPushToTalkShortcut.ShortcutTransition`; update the exhaustive switch at `GlobalPushToTalkShortcutMonitor.swift:119` and `CompanionManager.swift:474`.
- [ ] **F2** In `GlobalPushToTalkShortcutMonitor.handleGlobalEventTap`, detect `keyDown` with keyCode 9 (`V`) while `modifierFlags` superset of `[.control, .shift]` (deviceIndependentFlagsMask) → `shortcutTransitionPublisher.send(.visualizeRegionRequested)`. Keep this independent of the press/release PTT state (it's a one-shot).
- [ ] **F3** Add to `CompanionManager`: `@Published var activeRegionVisualization: RegionVisualization?`, `private let regionSelectionController = RegionSelectionController()`, observe `.clickyStartRegionVisualization` in `start()` (store the observer; remove in `stop()`).
- [ ] **F4** Add `beginRegionSelection()`: cancel `currentResponseTask`, `elevenLabsTTSClient.stopPlayback()`, `clearDetectedElementLocation()`, `clearRegionVisualization()`, dismiss panel (post `.clickyDismissPanel`), ensure overlay visible (mirror :485-489), then `regionSelectionController.beginSelection { [weak self] result in guard let self, let (rect, screen) = result else { return }; self.visualizeRegion(globalRect: rect, on: screen) }`.
- [ ] **F5** Add `visualizeRegion(globalRect:on:)` mirroring `sendTranscriptToClaudeWithScreenshot` (:586): set a `currentResponseTask`, `voiceState = .processing`, `captureRegionAsJPEG`, `analyzeRegionForAnnotations`, `parseRegionAnnotations`, map each point via `mapCropPixelToGlobal`, build `RegionVisualization`, publish to `activeRegionVisualization`, `voiceState = .idle`, with `CancellationError` + error handling and `trackRegionVisualizationCompleted/Failed`.
- [ ] **F6** Add `clearRegionVisualization()`: cancel `currentResponseTask`, set `activeRegionVisualization = nil`.
- [ ] **F7** In `handleShortcutTransition`, add the `.visualizeRegionRequested` case → `beginRegionSelection()`; in the `.pressed` (push-to-talk) case, also `clearRegionVisualization()` so PTT cancels an active viz.
- [ ] **F8** Machine-verify nothing here is pure-logic-new (the pure functions were verified in C); static-review the actor isolation.
- [ ] **F9** Commit: `feat(region): wire region-visualize shortcut, selection, and orchestration`.

### Task G — Overlay rendering + buddy flight

**Files:** Modify `leanring-buddy/OverlayWindow.swift` (BlueCursorView). Scratch: `/tmp/clicky_render_geom_check.swift`.
- [ ] **G1** Add `@State private var regionVisualizationAutoClearTimer: Timer?` and a `@State private var isAnnotationFlightInProgress`.
- [ ] **G2** Add `.onChange(of: companionManager.activeRegionVisualization)` (requires `RegionVisualization: Equatable` from Task C): when non-nil and the region center is on THIS screen, start the flight sequence; when nil, stop/clear.
- [ ] **G3** Add a ZStack section that, gated on `activeRegionVisualization != nil && regionVisualizationIsOnThisScreen`, draws: a thin rounded Rect around `regionGlobalFrame` (converted to SwiftUI coords), each annotation as a callout label (reuse navigation-bubble styling :264-295) at an offset, and a `Path` connector from label to target.
- [ ] **G4** Add `beginRegionVisualizationFlight` / `flyBuddyToAnnotation` that sequence `animateBezierFlightArc` across annotation points (pause ~1.2s each) then rest; guard with `buddyNavigationMode` so it doesn't fight the `[POINT]` flight.
- [ ] **G5** Auto-clear after 12s via the stored timer; invalidate it in `onDisappear` (extend :366-370); cancel + `companionManager.clearRegionVisualization()` on cursor move >100px (mirror :420-429).
- [ ] **G6** Machine-verify any new pure geometry helper with `swiftc`.
- [ ] **G7** Commit: `feat(region): render annotations and fly buddy along callouts`.

### Task H — Docs + verification

- [ ] **H1** Update `AGENTS.md` Key Files table: add `RegionSelectionView.swift`; note the visualize-region feature in Architecture; bump line counts for files that grew >50 lines.
- [ ] **H2** Add `docs/VERIFICATION-visualize-region.md` (the Xcode manual checklist below).
- [ ] **H3** Dispatch the `clicky-swift-reviewer` subagent over the full diff; address blocking findings.
- [ ] **H4** Commit: `docs(region): update agent docs and add verification checklist`.

---

## Spec coverage check (self-review)

- Trigger ⌃⇧V → Task F1/F2. Panel discoverability row → Task B/Task F notification. ✓
- Drag-select region → Task E. Capture crop → Task A. ✓
- Claude annotation call via Worker → Task D. Parse + map → Task C. ✓
- Annotated overlay + buddy flight → Task G. ✓
- Dismissal (Esc / re-press / push-to-talk / auto-fade) → Task E (Esc), Task F7 (PTT/re-press), Task G5 (auto). ✓
- No-build verification (swiftc for pure logic, Xcode checklist, reviewer subagent) → Tasks A4/C4/E4/G6/H. ✓
- Routes through Worker, no resurrected dead code, conventions honored → enforced in Task D + ownership table. ✓

## Manual Xcode verification checklist (the human runs this)

1. Add `RegionSelectionView.swift` to the `leanring-buddy` target (new file). Build (Cmd+B) — expect success (Swift 6 concurrency + deprecated onChange warnings are known/expected).
2. Run (Cmd+R). Grant permissions if prompted.
3. Press ⌃⇧V → screen dims, marquee draws as you drag.
4. Release on a region with text/UI → spinner, then a heading + callout labels appear over the region and the buddy flies to each.
5. Press Esc mid-drag → selection cancels, no network call.
6. Press ⌃⇧V again while a viz is showing → previous clears, new selection starts.
7. Press ⌃⌥ (push-to-talk) while a viz is showing → viz clears, normal voice flow works.
8. Let a viz sit untouched → it auto-fades after ~12s.
9. Move the mouse far away during a viz → it cancels and the buddy resumes following.
10. (Multi-monitor, if available) select on the secondary display → annotations draw on that display, not the primary.
11. Confirm normal push-to-talk voice + element-pointing still works unchanged.
