//
//  RegionSelectionView.swift
//  leanring-buddy
//
//  A temporary, MOUSE-ACCEPTING full-screen window used only while the user is
//  drag-selecting a screen region for the "Visualize a region" feature (⌃⇧V).
//
//  This is the deliberate inverse of OverlayWindow: OverlayWindow is permanently
//  click-through (ignoresMouseEvents = true, canBecomeKey = false) so it never
//  steals input. Region selection instead REQUIRES mouse-down/drag/up plus key
//  (Esc) events, so RegionSelectionWindow sets ignoresMouseEvents = false and
//  canBecomeKey = true. It is shown on exactly one screen, lives only for the
//  duration of a single drag, and is torn down immediately on completion or
//  cancel so it never lingers as an input-blocking surface.
//

import AppKit
import SwiftUI

/// A borderless, mouse-accepting, key-capable window that covers one screen and
/// dims it while the user drags a selection rectangle. Mirrors OverlayWindow's
/// screen-covering setup (OverlayWindow.swift:14-53) but reverses the
/// click-through and key-window behavior so it can capture the drag and Esc.
final class RegionSelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Transparent base — the dim is painted by the SwiftUI content view so
        // the live marquee can read as a highlight against it.
        self.isOpaque = false
        self.backgroundColor = .clear

        // Same level as OverlayWindow (.screenSaver) so it sits above normal
        // windows and full-screen apps. Because this window is ordered front
        // AFTER the cursor overlay, order-front recency keeps the marquee on top.
        self.level = .screenSaver

        // UNLIKE OverlayWindow: we must receive mouse events for the drag.
        self.ignoresMouseEvents = false

        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Appear over the active app even when Clicky is in the background.
        self.hidesOnDeactivate = false

        self.setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // UNLIKE OverlayWindow (which returns false): this window must become key so
    // the SwiftUI Esc key handler / local key monitor receive keyDown events.
    override var canBecomeKey: Bool {
        return true
    }

    // It does not need to be the main window — it is a transient utility surface.
    override var canBecomeMain: Bool {
        return false
    }
}

// MARK: - Rubber-band marquee

/// The SwiftUI content of RegionSelectionWindow. Dims the screen, tracks a drag
/// gesture, draws a DS-blue selection rectangle with a live width×height readout,
/// and reports the final rectangle (in window-LOCAL, top-left-origin SwiftUI
/// coordinates) to the controller on mouse-up. Esc reports a cancel.
struct RegionSelectionMarqueeView: View {
    /// Called on mouse-up with the final selection rectangle in window-local
    /// SwiftUI coordinates (top-left origin). The controller converts this to
    /// AppKit global coordinates and applies the too-small check.
    let onSelectionFinished: (CGRect) -> Void

    /// Called when the user presses Esc to cancel the selection.
    let onSelectionCancelled: () -> Void

    /// The point where the current drag began, in local SwiftUI coordinates.
    /// nil when no drag is in progress.
    @State private var dragStartPoint: CGPoint?

    /// The current selection rectangle being drawn, in local SwiftUI coordinates.
    @State private var currentSelectionRect: CGRect = .zero

    /// True once a drag has produced a rectangle, so the readout and border only
    /// appear after the user actually starts dragging.
    @State private var isActivelyDragging: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dim layer over the whole screen so the user understands the screen
            // is "frozen" for selection. Low-opacity black, like a screenshot tool.
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            // The live selection rectangle. Drawn only while/after dragging.
            if isActivelyDragging && currentSelectionRect.width > 0 && currentSelectionRect.height > 0 {
                // A brighter "cut-out" so the selected region reads as highlighted
                // against the dimmed surroundings.
                Rectangle()
                    .fill(DS.Colors.regionSelectionFill)
                    .frame(width: currentSelectionRect.width, height: currentSelectionRect.height)
                    .overlay(
                        Rectangle()
                            .stroke(DS.Colors.regionSelectionStroke, lineWidth: 1.5)
                    )
                    .position(x: currentSelectionRect.midX, y: currentSelectionRect.midY)

                // Live dimension readout in DS blue, anchored at the bottom-right
                // corner of the selection so it never covers the drag origin.
                Text("\(Int(currentSelectionRect.width)) × \(Int(currentSelectionRect.height))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(DS.Colors.regionSelectionStroke)
                            .shadow(color: DS.Colors.regionSelectionStroke.opacity(0.5), radius: 5, x: 0, y: 0)
                    )
                    .fixedSize()
                    .position(
                        x: currentSelectionRect.maxX + 4,
                        y: currentSelectionRect.maxY + 12
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { dragValue in
                    if dragStartPoint == nil {
                        dragStartPoint = dragValue.startLocation
                    }
                    isActivelyDragging = true
                    currentSelectionRect = Self.rectangleBetween(
                        startPoint: dragStartPoint ?? dragValue.startLocation,
                        currentPoint: dragValue.location
                    )
                }
                .onEnded { dragValue in
                    let finalRect = Self.rectangleBetween(
                        startPoint: dragStartPoint ?? dragValue.startLocation,
                        currentPoint: dragValue.location
                    )
                    dragStartPoint = nil
                    isActivelyDragging = false
                    currentSelectionRect = .zero
                    onSelectionFinished(finalRect)
                }
        )
        // SwiftUI Esc handling for when the window is key. A local NSEvent key
        // monitor in the controller is installed as a fallback for the case
        // where the window briefly isn't key.
        .onExitCommand {
            onSelectionCancelled()
        }
    }

    /// Builds a normalized rectangle (positive width/height) from two corner
    /// points in local SwiftUI coordinates, regardless of drag direction.
    static func rectangleBetween(startPoint: CGPoint, currentPoint: CGPoint) -> CGRect {
        let originX = min(startPoint.x, currentPoint.x)
        let originY = min(startPoint.y, currentPoint.y)
        let width = abs(currentPoint.x - startPoint.x)
        let height = abs(currentPoint.y - startPoint.y)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

// MARK: - Selection controller

/// Presents and tears down the region-selection window. Exactly one selection
/// window exists at a time; calling beginSelection again cancels the prior one
/// (reporting nil) before starting fresh. The controller converts the marquee's
/// local SwiftUI rectangle into AppKit global coordinates and reports it, or
/// reports nil if the selection is cancelled or too small.
@MainActor
final class RegionSelectionController {
    /// The single live selection window, or nil when no selection is in progress.
    private var selectionWindow: RegionSelectionWindow?

    /// The screen the current selection window covers, captured at begin time so
    /// the AppKit conversion uses the exact frame the marquee was drawn in.
    private var selectionScreen: NSScreen?

    /// The caller's completion handler for the in-progress selection. Invoked
    /// exactly once (success or cancel) and then cleared.
    private var activeCompletionHandler: (((CGRect, NSScreen)?) -> Void)?

    /// Local NSEvent monitor that catches Esc as a fallback if the SwiftUI
    /// .onExitCommand doesn't fire (e.g. a momentary loss of key status).
    private var escapeKeyEventMonitor: Any?

    /// Minimum selection size in points. Smaller selections are treated as an
    /// accidental click and cancelled silently (spec: < 16×16 pt).
    private let minimumSelectionEdgeLength: CGFloat = 16

    /// The macOS keyCode for the Escape key.
    private let escapeKeyCode: UInt16 = 53

    /// Begins a region selection on the screen containing the cursor. Shows one
    /// dimmed, mouse-accepting window, lets the user drag a rectangle, and calls
    /// `onComplete` with the selection (AppKit global rect + the NSScreen it was
    /// drawn on) on mouse-up, or `nil` on cancel / too-small / a second begin.
    func beginSelection(onComplete: @escaping ((CGRect, NSScreen)?) -> Void) {
        // A second begin cancels any prior in-progress selection first.
        if selectionWindow != nil {
            finishSelection(with: nil)
        }

        // Choose the screen the cursor is on; fall back to the main screen, and
        // if neither resolves, cancel immediately rather than force-unwrapping.
        let cursorLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorLocation) })
            ?? NSScreen.main else {
            print("⚠️ Region selection: no screen available for cursor location \(cursorLocation)")
            onComplete(nil)
            return
        }

        activeCompletionHandler = onComplete
        selectionScreen = targetScreen

        let window = RegionSelectionWindow(screen: targetScreen)

        let marqueeView = RegionSelectionMarqueeView(
            onSelectionFinished: { [weak self] localSelectionRect in
                self?.handleSelectionFinished(localSelectionRect: localSelectionRect)
            },
            onSelectionCancelled: { [weak self] in
                self?.finishSelection(with: nil)
            }
        )

        let hostingView = NSHostingView(rootView: marqueeView)
        hostingView.frame = NSRect(origin: .zero, size: targetScreen.frame.size)
        window.contentView = hostingView

        selectionWindow = window

        // Become key only for the duration of the drag so Esc reaches us. We
        // activate the app because a background app's window won't take key
        // focus otherwise (the app is normally a background menu-bar agent).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        installEscapeKeyEventMonitor()

        print("🟦 Region selection started on screen \(targetScreen.frame)")
    }

    /// Mouse-up handler: convert the local SwiftUI rect to AppKit global, apply
    /// the too-small cancel, and report.
    private func handleSelectionFinished(localSelectionRect: CGRect) {
        guard let targetScreen = selectionScreen else {
            finishSelection(with: nil)
            return
        }

        // Too-small selections are treated as an accidental click — cancel silently.
        if localSelectionRect.width < minimumSelectionEdgeLength
            || localSelectionRect.height < minimumSelectionEdgeLength {
            print("🟦 Region selection cancelled: too small (\(Int(localSelectionRect.width))×\(Int(localSelectionRect.height)))")
            finishSelection(with: nil)
            return
        }

        let globalRect = Self.convertLocalSwiftUIRectToAppKitGlobalRect(
            localRect: localSelectionRect,
            screenFrame: targetScreen.frame
        )

        print("🟦 Region selected: local \(localSelectionRect) → global \(globalRect)")
        finishSelection(with: (globalRect, targetScreen))
    }

    /// Single exit path for both success and cancel. Reports the result exactly
    /// once and tears the window down synchronously so no input-blocking surface
    /// lingers.
    private func finishSelection(with result: (rect: CGRect, screen: NSScreen)?) {
        let completionHandler = activeCompletionHandler
        activeCompletionHandler = nil

        tearDownSelectionWindow()

        if let result {
            completionHandler?((result.rect, result.screen))
        } else {
            completionHandler?(nil)
        }
    }

    /// Orders out and releases the selection window and its monitor immediately.
    private func tearDownSelectionWindow() {
        removeEscapeKeyEventMonitor()

        if let selectionWindow {
            selectionWindow.orderOut(nil)
            selectionWindow.contentView = nil
        }
        selectionWindow = nil
        selectionScreen = nil
    }

    /// Installs a local key-down monitor scoped to this app so Esc cancels even
    /// if SwiftUI's .onExitCommand doesn't fire. Returning nil swallows the Esc
    /// so it isn't also delivered to the underlying app.
    private func installEscapeKeyEventMonitor() {
        removeEscapeKeyEventMonitor()

        escapeKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            guard let self else { return keyEvent }
            if keyEvent.keyCode == self.escapeKeyCode {
                self.finishSelection(with: nil)
                return nil
            }
            return keyEvent
        }
    }

    private func removeEscapeKeyEventMonitor() {
        if let escapeKeyEventMonitor {
            NSEvent.removeMonitor(escapeKeyEventMonitor)
            self.escapeKeyEventMonitor = nil
        }
    }

    /// Converts a rectangle in window-LOCAL SwiftUI coordinates (top-left origin)
    /// to AppKit GLOBAL coordinates (bottom-left origin). This is the exact
    /// inverse of BlueCursorView.convertScreenPointToSwiftUICoordinates
    /// (OverlayWindow.swift:447-451), which maps an AppKit point to SwiftUI as:
    ///   swiftUI.x = appKit.x - screenFrame.origin.x
    ///   swiftUI.y = (screenFrame.origin.y + screenFrame.height) - appKit.y
    /// Inverting and accounting for the rect's height (a top-left-origin rect's
    /// top edge is its global-bottom edge once the Y axis flips):
    ///   global.x       = local.x + screenFrame.origin.x
    ///   global.bottomY = (screenFrame.origin.y + screenFrame.height) - (local.y + local.height)
    static func convertLocalSwiftUIRectToAppKitGlobalRect(
        localRect: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        let globalOriginX = localRect.origin.x + screenFrame.origin.x
        let globalOriginY = (screenFrame.origin.y + screenFrame.height)
            - (localRect.origin.y + localRect.height)
        return CGRect(
            x: globalOriginX,
            y: globalOriginY,
            width: localRect.width,
            height: localRect.height
        )
    }
}
