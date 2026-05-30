//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    /// Event-driven mouse-movement monitors that replaced the old 60fps polling
    /// Timer (see startTrackingCursor). The global monitor fires while other apps
    /// are active (the normal case for this background overlay); the local monitor
    /// covers movement while our own app is active. Both are torn down in onDisappear.
    @State private var globalMouseMovementMonitor: Any?
    @State private var localMouseMovementMonitor: Any?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Region Visualization State

    /// Timer that auto-clears the active region visualization after a hold
    /// period (default 12s) if the user does not dismiss it sooner. Invalidated
    /// when a new visualization arrives, on manual clear, or on view disappear.
    @State private var regionVisualizationAutoClearTimer: Timer?

    /// True while the buddy is flying through the sequence of annotation points
    /// for the active region visualization. While true, cursor-move cancellation
    /// is suppressed so the full guided tour completes (mirrors the forward-flight
    /// behavior of element pointing, where movement does not interrupt).
    @State private var isAnnotationFlightInProgress: Bool = false

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm clicky"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (companionManager.voiceState == .idle || companionManager.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening.
            // PERFORMANCE: the view stays in the tree (opacity cross-fade avoids the
            // cursor "pop"), but its TimelineView animation is PAUSED unless actually
            // listening, so the ~36fps bar recomputation doesn't run at idle.
            BlueCursorWaveformView(
                buddyDictationManager: companionManager.buddyDictationManager,
                isListening: companionManager.voiceState == .listening
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS).
            // PERFORMANCE: stays in the tree (cross-fade), but the repeatForever
            // rotation only runs while processing so it doesn't spin invisibly at idle.
            BlueCursorSpinnerView(isProcessing: companionManager.voiceState == .processing)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Region visualization — selected-region rectangle, heading chip,
            // callout labels, and connector lines. Only renders on the screen
            // that contains the region, gated inside the computed section below.
            activeRegionVisualizationSection

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            if let globalMouseMovementMonitor {
                NSEvent.removeMonitor(globalMouseMovementMonitor)
                self.globalMouseMovementMonitor = nil
            }
            if let localMouseMovementMonitor {
                NSEvent.removeMonitor(localMouseMovementMonitor)
                self.localMouseMovementMonitor = nil
            }
            navigationAnimationTimer?.invalidate()
            regionVisualizationAutoClearTimer?.invalidate()
            regionVisualizationAutoClearTimer = nil
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: companionManager.activeRegionVisualization) { newVisualization in
            // Tear down any prior auto-clear timer whenever the visualization changes.
            regionVisualizationAutoClearTimer?.invalidate()
            regionVisualizationAutoClearTimer = nil

            guard let visualization = newVisualization else {
                // Visualization was cleared — stop any in-progress guided flight.
                if isAnnotationFlightInProgress {
                    finishRegionVisualizationFlight()
                }
                return
            }

            // Only the screen that contains the region drives the flight + auto-clear.
            guard regionVisualizationIsOnThisScreen(visualization) else { return }

            // Fly the buddy through the annotations (guards internally against
            // colliding with an element-pointing flight).
            beginRegionVisualizationFlight(visualization)

            // Auto-fade after a 12s hold if the user does not dismiss sooner.
            // CompanionManager owns the actual clear so all dismissal paths
            // (Esc, re-press, push-to-talk, auto) funnel through one place.
            regionVisualizationAutoClearTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { _ in
                Task { @MainActor in
                    print("🗺️ Region visualization: 12s hold elapsed, auto-clearing")
                    companionManager.clearRegionVisualization()
                }
            }
        }
    }

    /// Renders the active region visualization on the screen that owns it:
    /// a thin rounded rectangle around the selected region, a heading title chip
    /// near its top-left, and a callout label + connector line for each annotation.
    /// Returns nothing on screens that do not contain the region (so only one
    /// monitor ever draws it), and when no visualization is active.
    @ViewBuilder
    private var activeRegionVisualizationSection: some View {
        if let visualization = companionManager.activeRegionVisualization,
           regionVisualizationIsOnThisScreen(visualization) {

            // Region frame converted from AppKit global to this screen's SwiftUI
            // coordinate space. AppKit y is bottom-left; flipping the origin means
            // the AppKit max-y corner becomes the SwiftUI top edge.
            let regionGlobalFrame = visualization.regionGlobalFrame
            let topLeftGlobal = CGPoint(x: regionGlobalFrame.minX, y: regionGlobalFrame.maxY)
            let topLeftSwiftUI = swiftUIPointForGlobalPoint(topLeftGlobal)
            let regionRectInSwiftUI = CGRect(
                x: topLeftSwiftUI.x,
                y: topLeftSwiftUI.y,
                width: regionGlobalFrame.width,
                height: regionGlobalFrame.height
            )

            // Thin rounded rectangle around the selected region.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.regionSelectionStroke, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.regionSelectionFill)
                )
                .frame(width: regionRectInSwiftUI.width, height: regionRectInSwiftUI.height)
                .position(x: regionRectInSwiftUI.midX, y: regionRectInSwiftUI.midY)
                .shadow(color: DS.Colors.regionSelectionStroke.opacity(0.4), radius: 8, x: 0, y: 0)
                .allowsHitTesting(false)

            // Heading title chip near the region's top-left corner.
            if let heading = visualization.heading, !heading.isEmpty {
                Text(heading)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.annotationCallout)
                            .shadow(color: DS.Colors.annotationCallout.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .position(x: regionRectInSwiftUI.minX + 4, y: regionRectInSwiftUI.minY - 14)
                    .allowsHitTesting(false)
            }

            // One callout (label bubble + connector line) per annotation.
            ForEach(Array(visualization.annotations.enumerated()), id: \.offset) { _, annotation in
                let targetPoint = swiftUIPointForGlobalPoint(annotation.globalPoint)
                let labelPoint = calloutLabelOffsetPoint(forTargetPoint: targetPoint)
                RegionAnnotationCalloutView(
                    label: annotation.label,
                    targetPoint: targetPoint,
                    labelPoint: labelPoint
                )
                .allowsHitTesting(false)
            }
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    /// Begins tracking the mouse to drive the buddy.
    ///
    /// PERFORMANCE: this used to poll `NSEvent.mouseLocation` on a 60fps repeating
    /// Timer that ran forever (one per screen), re-rendering the overlay ~62x/sec
    /// even when the mouse was idle or on another monitor — the app's single largest
    /// idle battery drain. It is now event-driven: `NSEvent` mouse-movement monitors
    /// fire `handleCursorMovement` ONLY when the mouse actually moves, so a still
    /// cursor costs nothing. A global monitor catches movement while other apps are
    /// active (the normal case for this background overlay); a local monitor covers
    /// the brief windows where our own app is active. All prior per-move behavior is
    /// preserved verbatim in `handleCursorMovement`.
    private func startTrackingCursor() {
        // Seed the on-screen flag once now; subsequent updates are movement-driven.
        isCursorOnThisScreen = screenFrame.contains(NSEvent.mouseLocation)

        let movementEventMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]

        globalMouseMovementMonitor = NSEvent.addGlobalMonitorForEvents(matching: movementEventMask) { [self] _ in
            // Global monitors don't carry our window's coordinate context, so read
            // the authoritative global mouse location (same value the old timer used).
            handleCursorMovement(mouseLocation: NSEvent.mouseLocation)
        }

        localMouseMovementMonitor = NSEvent.addLocalMonitorForEvents(matching: movementEventMask) { [self] event in
            handleCursorMovement(mouseLocation: NSEvent.mouseLocation)
            return event
        }
    }

    /// Per-movement work, formerly the body of the 60fps tracking Timer. Logic is
    /// unchanged: update the on-screen flag, handle region-visualization dismissal,
    /// handle return-flight cancellation, and (when following) move the buddy.
    private func handleCursorMovement(mouseLocation: CGPoint) {
        self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

        // Region visualization dismissal: once the guided annotation tour has
        // finished (isAnnotationFlightInProgress == false) but the rectangle +
        // callouts are still showing, a >100px cursor move clears it — same
        // gesture and threshold as the element-pointing return-flight cancel below.
        if !self.isAnnotationFlightInProgress,
           let activeVisualization = self.companionManager.activeRegionVisualization,
           self.regionVisualizationIsOnThisScreen(activeVisualization) {
            let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let distanceFromFlightStart = hypot(
                currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
            )
            if distanceFromFlightStart > 100 {
                print("🗺️ Region visualization: cursor moved >100px, clearing")
                self.regionVisualizationAutoClearTimer?.invalidate()
                self.regionVisualizationAutoClearTimer = nil
                self.companionManager.clearRegionVisualization()
            }
        }

        // During forward flight or pointing, the buddy is NOT interrupted by
        // mouse movement — it completes its full animation and return flight.
        // Only during the RETURN flight do we allow cursor movement to cancel
        // (so the buddy snaps to following if the user moves while it's flying back).
        if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
            let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let distanceFromNavigationStart = hypot(
                currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
            )
            if distanceFromNavigationStart > 100 {
                cancelNavigationAndResumeFollowing()
            }
            return
        }

        // During forward navigation or pointing, just skip cursor tracking
        if self.buddyNavigationMode != .followingCursor {
            return
        }

        // Normal cursor following
        let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
        let buddyX = swiftUIPosition.x + 35
        let buddyY = swiftUIPosition.y + 25
        self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Region Visualization Flight

    /// Whether the given region visualization belongs to THIS screen — true when
    /// this screen's frame contains the region's center point. Mirrors the
    /// single-buddy rule used for element pointing (see buddyIsVisibleOnThisScreen)
    /// so only one BlueCursorView ever draws it.
    private func regionVisualizationIsOnThisScreen(_ visualization: CompanionManager.RegionVisualization) -> Bool {
        let regionCenter = CGPoint(
            x: visualization.regionGlobalFrame.midX,
            y: visualization.regionGlobalFrame.midY
        )
        return screenFrame.contains(regionCenter)
    }

    /// Converts an AppKit global point to this screen's SwiftUI coordinate space.
    /// Thin wrapper over convertScreenPointToSwiftUICoordinates so the annotation
    /// rendering and the flight share one conversion (keeps coordinates consistent).
    private func swiftUIPointForGlobalPoint(_ globalPoint: CGPoint) -> CGPoint {
        return convertScreenPointToSwiftUICoordinates(globalPoint)
    }

    /// Where the callout label bubble sits relative to its target point:
    /// 14pt up and to the right, so the label clears the target and the
    /// connector line is visible.
    private func calloutLabelOffsetPoint(forTargetPoint targetPoint: CGPoint) -> CGPoint {
        return CGPoint(x: targetPoint.x + 14, y: targetPoint.y - 14)
    }

    /// Begins flying the buddy through every annotation in the visualization,
    /// one after another, pausing on each. Refuses to start if the buddy is
    /// already busy with an element-pointing flight (both paths share
    /// buddyNavigationMode + the flight timer, so they must not run together).
    private func beginRegionVisualizationFlight(_ visualization: CompanionManager.RegionVisualization) {
        // Record the current cursor position FIRST so the post-tour >100px
        // cursor-move dismissal (in startTrackingCursor) always compares against a
        // fresh anchor — even on the skip paths below, where the rectangle +
        // callouts still render statically. Without this, a skipped guided flight
        // would leave a stale anchor from a prior element-pointing flight and could
        // dismiss the visualization almost immediately.
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Don't fight the existing element-pointing flight. If it's mid-flight we
        // skip the guided tour — the rectangle + callouts still render statically.
        guard buddyNavigationMode == .followingCursor else {
            print("🗺️ Region visualization: buddy busy navigating, skipping guided flight")
            return
        }

        // Don't interrupt the first-launch welcome animation.
        guard !showWelcome || welcomeText.isEmpty else {
            print("🗺️ Region visualization: welcome animation active, skipping guided flight")
            return
        }

        guard !visualization.annotations.isEmpty else {
            print("🗺️ Region visualization: no annotations to fly to")
            return
        }

        isAnnotationFlightInProgress = true
        isReturningToCursor = false
        buddyNavigationMode = .navigatingToTarget

        print("🗺️ Region visualization: flying buddy through \(visualization.annotations.count) annotations")
        flyBuddyToAnnotation(at: 0, annotations: visualization.annotations)
    }

    /// Recursively flies the buddy to annotation `index`, holds ~1.2s, then
    /// advances to the next. When the last annotation is reached, finishes the
    /// flight and lets the buddy rest beside the final target.
    private func flyBuddyToAnnotation(
        at index: Int,
        annotations: [CompanionManager.RegionAnnotation]
    ) {
        // Stop if the visualization was cleared out from under us mid-tour.
        guard companionManager.activeRegionVisualization != nil else {
            finishRegionVisualizationFlight()
            return
        }

        guard index < annotations.count else {
            finishRegionVisualizationFlight()
            return
        }

        let annotation = annotations[index]
        let targetInSwiftUI = swiftUIPointForGlobalPoint(annotation.globalPoint)

        // Offset so the buddy sits beside the annotated point (8 right, 12 below),
        // matching the element-pointing offset in startNavigatingToElement.
        let offsetTarget = CGPoint(x: targetInSwiftUI.x + 8, y: targetInSwiftUI.y + 12)

        // Clamp inside the screen with padding, same as startNavigatingToElement.
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        animateBezierFlightArc(to: clampedTarget) {
            // If the visualization was cleared or another flight took over, bail.
            guard self.buddyNavigationMode == .navigatingToTarget,
                  self.isAnnotationFlightInProgress else { return }

            // Rest pointer angle while pausing on this annotation.
            self.triangleRotationDegrees = -35.0

            // Hold ~1.2s on this annotation, then advance to the next one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard self.isAnnotationFlightInProgress,
                      self.buddyNavigationMode == .navigatingToTarget else { return }
                self.flyBuddyToAnnotation(at: index + 1, annotations: annotations)
            }
        }
    }

    /// Ends the guided annotation tour: the buddy rests in place, navigation mode
    /// returns to following, and the cursor-move cancel becomes armed (handled in
    /// startTrackingCursor). Does NOT clear the visualization — the rectangle and
    /// callouts stay until the auto-clear timer fires or the user dismisses.
    private func finishRegionVisualizationFlight() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        isAnnotationFlightInProgress = false
        // Returning to .followingCursor re-arms normal cursor tracking; the buddy
        // springs back to the cursor on the next mouse move (the desired
        // "tour done, resume following" behavior).
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        print("🗺️ Region visualization: guided flight finished, resuming cursor following")
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Region Annotation Callout

/// A single annotation callout drawn over a visualized region: a thin connector
/// line from the label bubble to the target point, a small dot at the target,
/// plus the label bubble itself. The bubble styling intentionally matches the
/// navigation pointer bubble so callouts feel like the same "buddy speaking"
/// affordance. Coordinates are in this screen's SwiftUI space.
private struct RegionAnnotationCalloutView: View {
    let label: String
    /// The point being annotated (in SwiftUI coordinates).
    let targetPoint: CGPoint
    /// Where the label bubble is anchored (offset up-right of the target).
    let labelPoint: CGPoint

    var body: some View {
        ZStack {
            // Thin connector line from the label anchor to the target point.
            Path { path in
                path.move(to: labelPoint)
                path.addLine(to: targetPoint)
            }
            .stroke(DS.Colors.annotationConnector, lineWidth: 1)

            // A small dot marking the exact target point.
            Circle()
                .fill(DS.Colors.annotationCallout)
                .frame(width: 5, height: 5)
                .position(targetPoint)

            // Label bubble — same styling as the navigation pointer bubble.
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Colors.annotationCallout)
                        .shadow(color: DS.Colors.annotationCallout.opacity(0.5), radius: 6, x: 0, y: 0)
                )
                .fixedSize()
                .position(labelPoint)
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    /// PERFORMANCE: the waveform observes the dictation manager DIRECTLY rather
    /// than reading a copy republished on CompanionManager. The mic delivers a
    /// power-level update ~45x/sec while recording; routing it through
    /// CompanionManager (which the whole menu-bar panel observes) re-rendered the
    /// entire panel body on every tick. Observing buddyDictationManager here scopes
    /// those re-renders to just this small view. The displayed value is identical.
    @ObservedObject var buddyDictationManager: BuddyDictationManager

    /// Whether the user is currently speaking (push-to-talk held). When false,
    /// the TimelineView schedule is PAUSED so the ~36fps bar animation doesn't run
    /// while the waveform is invisible (opacity 0) at idle.
    let isListening: Bool

    private var audioPowerLevel: CGFloat { buddyDictationManager.currentAudioPowerLevel }

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0, paused: !isListening)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    /// Whether the AI is currently processing. The repeatForever rotation runs ONLY
    /// while this is true, so the spinner doesn't keep animating invisibly at idle
    /// (the view stays in the tree for an opacity cross-fade; see the ZStack).
    let isProcessing: Bool

    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                if isProcessing { startSpinning() }
            }
            .onChange(of: isProcessing) { nowProcessing in
                if nowProcessing {
                    startSpinning()
                } else {
                    // Stop the repeating animation cleanly so it isn't left running
                    // forever once the spinner fades out.
                    withAnimation(.linear(duration: 0.2)) {
                        isSpinning = false
                    }
                }
            }
    }

    private func startSpinning() {
        isSpinning = false
        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
            isSpinning = true
        }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
