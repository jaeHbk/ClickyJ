---
name: clicky-visualize-region
description: Use when working on Clicky's "Visualize a region" feature — the ⌃⇧V drag-select-a-region flow that captures a screen crop, asks Claude for [ANNOTATE:] callouts, and draws an annotated overlay while the buddy cursor flies to each part. Covers the data flow, the exact symbols involved, the coordinate math, and the no-build verification path.
---

# Clicky — Visualize a Region

## What this feature is

The user presses **⌃⇧V** (control+shift+V, keyCode 9 with `[.control, .shift]`), drag-selects
a rectangle on the screen under the cursor, and Clicky draws an **annotated overlay** —
short callout labels with connector lines over the selected region — while the blue buddy
cursor flies to each annotated point in sequence. It reuses Clicky's existing
"point at things" identity rather than inventing a new presentation.

## Data flow (and the real symbols at each hop)

1. **Trigger** — `GlobalPushToTalkShortcutMonitor` emits `.visualizeRegionRequested`
   (V keyCode 9 + control+shift), OR `CompanionPanelView`'s "Visualize a region" row posts
   `Notification.Name.clickyStartRegionVisualization`. Both land in
   `CompanionManager.beginRegionSelection()`.
2. **Select** — `RegionSelectionController.beginSelection(onComplete:)`
   (`RegionSelectionView.swift`) shows a **mouse-accepting** `RegionSelectionWindow` on the
   cursor's screen (the normal overlays are click-through and cannot capture a drag), draws a
   rubber-band marquee, and returns `(CGRect global, NSScreen)?` — `nil` on cancel (Esc /
   too-small / re-trigger).
3. **Capture** — `CompanionScreenCaptureUtility.captureRegionAsJPEG(globalRect:on:)` returns a
   `RegionCapture { imageData, cropPixelWidth, cropPixelHeight, regionGlobalFrame, displayFrame }`.
   It excludes Clicky's own windows (same `SCContentFilter` as `captureAllScreensAsJPEG`) and
   uses `SCStreamConfiguration.sourceRect` (fallback: full-display capture + `CGImage.cropping`).
   Encoding runs off the main actor.
4. **Ask Claude** — `ClaudeAPI.analyzeRegionForAnnotations(imageData:cropPixelWidth:cropPixelHeight:)`
   routes through the **existing Worker `/chat` proxy** (never api.anthropic.com directly),
   `max_tokens` ~700, with the annotation system prompt. Returns raw text.
5. **Parse** — `CompanionManager.parseRegionAnnotations(from:)` (static, pure) →
   `(heading: String?, annotations: [(point: CGPoint, label: String)])`. Tags look like
   `HEADING: <title>` then `[ANNOTATE:x,y:label]` lines, `x,y` in crop-pixel space (top-left).
6. **Map** — `CompanionManager.mapCropPixelToGlobal(pixelPoint:capture:)` (static, pure)
   converts crop-pixel → display-point → AppKit global, mirroring the existing `[POINT:]`
   math (clamp, scale by point/pixel ratio, flip Y, offset by `regionGlobalFrame.origin`).
7. **Publish + render** — `CompanionManager.activeRegionVisualization: RegionVisualization?`
   drives a section in `BlueCursorView` (OverlayWindow.swift): draws the region rect + callouts,
   and flies the buddy to each `RegionAnnotation.globalPoint` by reusing `animateBezierFlightArc`.
   Auto-clears after a hold; `clearRegionVisualization()` cancels everything.

## Conventions to honor (from AGENTS.md)

- Verbose, unabbreviated names; pass args with the same name; clarity over concision.
- `@MainActor` for UI state; `async/await` everywhere; SwiftUI + AppKit via `NSHostingView`.
- All interactive controls show the pointer cursor on hover (`.pointerCursor()`).
- Route ALL network through the Worker. Never ship keys; never call provider APIs directly.
- Don't resurrect dead code (`CompanionResponseOverlayManager`, `ElementLocationDetector`).

## The no-build constraint

There is no `Xcode.app` here and `xcodebuild` is forbidden (TCC). You cannot build/run/profile.
- **Machine-verify** only the pure functions (`parseRegionAnnotations`, `mapCropPixelToGlobal`)
  via a standalone `swiftc` scratch file under `/tmp/`.
- Everything else gets a **manual Xcode verification checklist** for the human:
  build succeeds → ⌃⇧V dims + marquee → drag+release captures → heading + callouts appear over
  the region → buddy flies to each → Esc / re-press / push-to-talk all dismiss cleanly →
  push-to-talk still works unchanged → (if multi-monitor) draws on the correct screen.
- After writing Swift, dispatch the `clicky-swift-reviewer` subagent before claiming done.

## Pointers

- Spec: `docs/superpowers/specs/2026-05-29-visualize-region-and-performance-design.md`
- Plan: `docs/superpowers/plans/2026-05-29-visualize-region.md`
- Existing point-at math to mirror: `CompanionManager.swift:648-674`, parsing at `:784-823`.
- Flight animation to reuse: `OverlayWindow.swift:495-568`.
