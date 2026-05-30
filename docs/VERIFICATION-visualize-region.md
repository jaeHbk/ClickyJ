# Verification — Visualize a Region

This feature was implemented in an environment with **no `Xcode.app`** (only Command
Line Tools) where `xcodebuild` is forbidden, so it could not be built, run, or profiled
here. Pure logic (parsing + all coordinate math) was machine-verified with `swiftc`, and
the full diff passed a rigorous static review (`clicky-swift-reviewer`) that found zero
compile blockers. The checklist below is what **you** run in Xcode to confirm runtime
behavior. No runtime success is claimed until you complete it.

## What was machine-verified (no Xcode needed)

- `convertGlobalRectToDisplayLocalCGRect` (AppKit global → CG-local for `sourceRect`) — `swiftc` assertions incl. secondary-display Y-flip. ✅
- `parseRegionAnnotations` (HEADING + `[ANNOTATE:]`, malformed/empty/inline/spaced cases) — 26 `swiftc` assertions. ✅
- `mapCropPixelToGlobal` (crop-pixel → AppKit global, clamp + Y-flip + offset, degenerate guard) — `swiftc` assertions. ✅
- `convertLocalSwiftUIRectToAppKitGlobalRect` + `rectangleBetween` (selection rect) — `swiftc` assertions incl. non-zero-origin display. ✅
- Region request body (max_tokens 700, non-streaming, label embeds dims, JPEG media_type) — `swiftc` round-trip. ✅
- ⌃⇧V modifier detection (matches ctrl+shift+V, rejects ctrl+opt+V and non-V, tolerates capsLock) — `swiftc` assertions. ✅
- Full coordinate round-trip (marquee local → global → sourceRect, and crop-pixel → global → SwiftUI) consistent on a scale-2, negative-origin display — independent `swiftc` round-trip by the reviewer. ✅

## Xcode build + run

1. Open `leanring-buddy.xcodeproj`, select the `leanring-buddy` scheme, set the signing team, **Cmd+B**.
   - Expect success with ONLY the documented known non-blocking warnings (Swift 6 concurrency, deprecated `onChange`). The new `Task.detached` JPEG encode may add one more Swift 6 Sendable warning — that is allowed, do not "fix" it.
   - `RegionSelectionView.swift` is auto-included (filesystem-synchronized group), so no "add to target" step is needed — but if you somehow see "cannot find RegionSelectionController/RegionSelectionWindow in scope," confirm the file is in the target's Compile Sources.
2. **Cmd+R** to run. Grant permissions if prompted (region capture reuses the existing Screen Recording permission).

## Behavior checklist

3. **Trigger via hotkey:** press **⌃⇧V**. The screen containing the cursor dims; the menu-bar panel dismisses if open.
4. **Drag-select:** press and drag — a DS-blue bordered rectangle with a faint blue fill tracks the drag, and a monospaced `W × H` chip follows the bottom-right corner.
5. **Capture + annotate:** release on a region with clear UI/text (≥16×16 pt). The dim disappears, the buddy shows its spinner, then a heading chip + callout labels (with connector lines to dot markers) appear over the region, and the buddy flies to each annotation in sequence (~1.2s each), then rests.
6. **Verify orientation:** callouts must point at the right elements — top-of-crop callouts near the top of the region, not vertically flipped. (A flip would indicate a `regionGlobalFrame`/`displayFrame` mix-up upstream.)
7. **Too-small / Esc cancel:** drag <16×16 and release → silent cancel, no capture (console: `🟦 Region selection cancelled: too small`). Start a drag then press **Esc** → cancels; press **Esc** before dragging → cancels. No network call in any case, and clicks reach the underlying app afterward (window fully torn down).
8. **Re-trigger:** while a visualization shows, press ⌃⇧V again → old one clears, new selection begins (only ever one dim layer).
9. **Push-to-talk interaction:** while a visualization shows, press **⌃⌥** (push-to-talk) → visualization clears, normal voice flow proceeds. Then confirm push-to-talk records/transcribes/speaks/points **exactly as before** (the ⌃⇧V detector never touches push-to-talk modifier state).
10. **Key-repeat:** hold ⌃⇧V down for a second → only ONE selection starts (the per-press latch prevents repeats).
11. **Auto-fade:** leave a visualization untouched ~12s → it auto-clears.
12. **Cursor-move dismiss:** after the guided flight finishes, move the mouse >100px → the visualization clears and the buddy resumes following.
13. **No collision with element pointing:** ask a normal push-to-talk question that yields a `[POINT:]` flight → the buddy still flies/points exactly as before.
14. **Panel row:** open the menu-bar panel → tap **"Visualize a region (⌃⇧V)"** → it behaves identically to the hotkey (panel dismisses, marquee appears, pointer cursor on hover).
15. **Multi-monitor (if available):** drag-select on a secondary display → rectangle/callouts/flight render only on that display; the primary draws nothing for the visualization.
16. **Failure path:** with the Worker URL temporarily broken (or no network), trigger a visualization → spinner clears to idle, no stuck overlay, console logs `⚠️ Region visualization error`, and a `region_visualization_failed` analytics event fires (no image/content in the event).

## If something is wrong

- Upside-down callouts → coordinate origin mix-up in `captureRegionAsJPEG` / `mapCropPixelToGlobal` (but those are `swiftc`-verified, so suspect the wiring in `visualizeRegion`).
- Capture is the whole screen, not the region → `SCStreamConfiguration.sourceRect` not honored on your hardware; the CGImage-crop fallback should handle it — check the `📐 Region capture: sourceRect not honored` console line.
- Selection window won't take Esc → the window must become key; confirm `NSApp.activate(ignoringOtherApps:)` ran (the app is a background agent).
