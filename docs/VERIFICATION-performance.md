# Verification — Performance pass

This pass is **behavior-preserving**: every change is meant to cut battery/CPU/memory
while leaving what the user sees and does identical. It was implemented with no
`Xcode.app` and `xcodebuild` forbidden, so it was not built or profiled here. Pure math
was machine-verified with `swiftc` (incl. `vDSP_rmsqv` proven bit-identical to the old
scalar RMS), and the full diff passed a static review (`clicky-swift-reviewer`) that ran
7 isolated `swiftc` typechecks and found **zero blocking issues**. The checklist below is
what **you** run in Xcode. No runtime/battery claim is made until you complete it.

## What changed (all behavior-preserving)

| # | Change | File(s) | Why it saves |
|---|--------|---------|--------------|
| A1 | Forever 60fps cursor-tracking Timer → event-driven NSEvent mouse-movement monitors | OverlayWindow.swift | Biggest idle drain: a still cursor now costs ~0 instead of ~62 re-renders/sec per monitor, forever |
| A2 | Stop republishing mic level onto CompanionManager; waveform observes BuddyDictationManager directly | OverlayWindow.swift, CompanionManager.swift | Recording no longer re-renders the whole menu-bar panel ~45×/sec |
| A3 | Permission poll stops once granted; re-arms on app activation if still pending | CompanionManager.swift | Kills a 1.5s forever-poll (~40 wakeups/min) for fully-onboarded users |
| A4 | Pause waveform TimelineView when not listening; spinner rotates only while processing | OverlayWindow.swift | Invisible animations stop ticking at idle |
| B1 | JPEG-encode each display off the main actor (Task.detached) | CompanionScreenCaptureUtility.swift | Per-turn UI block removed |
| B2 | `onTextChunk` optional + forwards delta; live callers omit it | ClaudeAPI.swift, CompanionManager.swift | Skips per-token main-actor hop + O(n²) string re-copy |
| B3 | AssemblyAI emits transcript only when it changed | AssemblyAIStreamingTranscriptionProvider.swift | Fewer main-actor hops / re-renders during fast speech |
| C2 | RMS via vDSP; converter compares AVAudioFormat with == not a serialized String | BuddyDictationManager.swift, BuddyAudioConversionSupport.swift | Less per-buffer CPU/allocation on the real-time audio thread |

## Machine-verified here

- `vDSP_rmsqv` == scalar `sqrt(mean(x²))` — diff 0.0 (`swiftc`). ✅
- All region/feature pure-logic harnesses still pass after the perf edits. ✅
- 7 API-surface `swiftc` typechecks by the reviewer (TimelineView `paused:`, NSEvent monitors, vDSP/AVAudioFormat, Task.detached + optional callback, struct-View `[self]` capture). ✅

## Build

1. Open `leanring-buddy.xcodeproj`, **Cmd+B**. Expect only the documented known warnings (Swift 6 concurrency — possibly one or two more from the new `Task.detached` and `@Sendable` callback; deprecated `onChange`). No new errors.

## The headline measurement — idle CPU/energy before vs after

This is the proof the pass worked. Do it on the SAME machine, app fully onboarded, cursor left **completely still**, menu-bar panel closed, for 60 seconds each:

1. **Before:** check out `main` (or `feature/visualize-region`), build, run, idle 60s. In **Activity Monitor → CPU**, note the Clicky process's % CPU (and open **Energy** tab for "Energy Impact"). Expect a steady non-trivial value (the old 60fps-per-monitor timer + 1.5s poll never sleep).
2. **After:** check out `fix/performance`, build, run, idle 60s. Note the same numbers.
3. **Expect:** the After idle CPU drops toward ~0% (only occasional wakeups), especially with 2+ monitors (the old cost scaled with monitor count). If available, `sudo powermetrics --samplers tasks -n 1 -i 1000` and compare the Clicky row's wakeups/sec.

## Behavior must be IDENTICAL — confirm each

4. **Cursor follow:** move the mouse fast across one monitor and across the boundary between two — the buddy tracks smoothly with no lag/stutter, and only one buddy shows during the cross-monitor handoff.
5. **Push-to-talk after full onboarding:** launch already fully onboarded (so the permission poll never starts), immediately hold **⌃⌥** and speak → dictation works (proves the CGEvent tap is armed at launch independent of the poll).
6. **Waveform:** hold ⌃⌥ and speak → the waveform reacts to your voice exactly as before; release → it stops. Confirm no cursor "pop" when switching triangle ↔ waveform ↔ spinner.
7. **Spinner:** after releasing, the processing spinner spins while waiting for the response, then the buddy returns. Also replay onboarding (panel footer) and confirm the spinner still animates when re-created mid-processing.
8. **Panel during recording:** open the menu-bar panel, then start push-to-talk — the panel content stays correct (it just no longer re-renders on every audio frame).
9. **Permission live-update:** with a permission revoked, keep the app active, grant it in System Settings, switch back → the panel updates within ~1.5s while active AND immediately on re-activation. Once all granted, idle CPU drops (poll stopped).
10. **Element pointing + region visualize:** a normal ⌃⌥ question that yields a `[POINT:]` flight still flies/points; ⌃⇧V region visualize still works (the feature from the other branch is unaffected).
11. **Monitor-leak check (optional, Instruments):** toggle "Show Clicky" / replay onboarding several times → `NSEvent` monitor count doesn't grow unbounded (validates `onDisappear` removes the movement monitors each time).

## Explicitly NOT done this pass (logged, not silently dropped)

- **C1 (overlay window rebuild on every showOverlay):** medium effort, behavior-sensitive (welcome/onboarding first-appearance logic keys off rebuild). Deferred to avoid an untestable regression.
- **C3 (stream TTS playback; AVAudioPlayerDelegate to free the MP3 buffer + event-driven transient-hide):** changes the TTS class to NSObject + delegate and rewrites the 200ms transient-hide poll as a continuation across two files — real regression surface that needs a runtime test loop this environment can't provide. Deferred.
- **C4 (store/cancel onboarding + navigation-bubble timers with [weak self]):** only active during onboarding/pointing (not idle), low impact; deferred to keep the diff focused and low-risk.
- **Rank 9 (`CompanionResponseOverlayManager`) and Rank 16 (`ElementLocationDetector`):** confirmed DEAD CODE (never instantiated) → zero runtime cost, intentionally untouched.
- **Security/privacy (Worker auth, OpenAI key in bundle, PostHog raw content):** out of scope per the agreed plan; needs the owner's keys/decisions.
- **Sending only the cursor screen to Claude:** a behavior change (alters what Claude sees), not perf — left as a documented opt-in.
