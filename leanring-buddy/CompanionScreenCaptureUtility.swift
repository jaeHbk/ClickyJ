//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

/// Result of capturing a single drag-selected screen region as a tight JPEG crop.
/// Carries everything `CompanionManager` needs to map Claude's crop-pixel-space
/// annotation coordinates back onto AppKit global screen coordinates, using the
/// same pixel → point → AppKit transform proven at CompanionManager.swift:653-674.
struct RegionCapture {
    /// JPEG-encoded bytes of the cropped region (quality 0.8), ready for base64 in ClaudeAPI.
    let imageData: Data
    /// Width of the crop in image pixels (honors the display's backing scale factor).
    let cropPixelWidth: Int
    /// Height of the crop in image pixels (honors the display's backing scale factor).
    let cropPixelHeight: Int
    /// The selected region in AppKit global coordinates (bottom-left origin) — used
    /// as the point-space frame for mapping annotation pixels back to the screen.
    let regionGlobalFrame: CGRect
    /// The full frame (AppKit global coordinates) of the display the region was drawn on.
    let displayFrame: CGRect
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            // PERFORMANCE: JPEG-encode off the main actor. NSBitmapImageRep encoding
            // is CPU-heavy and previously ran synchronously on @MainActor once per
            // display, blocking UI during every push-to-talk turn. Task.detached
            // moves it off-main; nil result (encode failure) skips this display.
            let jpegData: Data? = await Task.detached(priority: .userInitiated) {
                NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            }.value
            guard let jpegData else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    // MARK: - Region Capture (Visualize a Region feature)

    /// Converts a selection rectangle expressed in AppKit global coordinates
    /// (bottom-left origin, the same space as `NSScreen.frame` and
    /// `NSEvent.mouseLocation`) into the display-local Core Graphics rectangle
    /// (top-left origin) that `SCStreamConfiguration.sourceRect` expects.
    ///
    /// This is the exact inverse of the screenshot-pixel → AppKit transform used
    /// for `[POINT:]` at CompanionManager.swift:653-674 (which computes
    /// `appKitY = displayHeight - displayLocalY`). Here we start from an AppKit
    /// global rect and recover the top-left-origin local rect.
    ///
    /// Pure function (no ScreenCaptureKit / live-display state) so it can be
    /// isolate-compiled and reasoned about independently.
    static func convertGlobalRectToDisplayLocalCGRect(
        globalRect: CGRect,
        displayFrame: CGRect
    ) -> CGRect {
        // 1. Translate the global rect into the display's local AppKit space
        //    (still bottom-left origin) by subtracting the display origin.
        let localOriginXInAppKit = globalRect.origin.x - displayFrame.origin.x
        let localOriginYInAppKit = globalRect.origin.y - displayFrame.origin.y

        // 2. Flip Y from bottom-left origin (AppKit) to top-left origin (Core Graphics).
        //    In AppKit the rect's top edge is at (localOriginYInAppKit + height);
        //    measuring that top edge down from the display's top gives the CG origin.
        let cgLocalOriginY = displayFrame.height - (localOriginYInAppKit + globalRect.height)

        return CGRect(
            x: localOriginXInAppKit,
            y: cgLocalOriginY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    /// Captures exactly the drag-selected region as a tight JPEG crop.
    ///
    /// `globalRect` is in AppKit global coordinates (bottom-left origin) and `screen`
    /// is the `NSScreen` the selection was drawn on. The region is captured at the
    /// display's true backing-pixel density so Claude's crop-pixel-space `[ANNOTATE:]`
    /// coordinates map back precisely. Clicky's own windows are excluded from the shot
    /// (same exclusion as `captureAllScreensAsJPEG`), and JPEG encoding runs off the
    /// main actor in a detached task. Falls back to capturing the full display and
    /// cropping the CGImage if `SCStreamConfiguration.sourceRect` is not honored.
    static func captureRegionAsJPEG(globalRect: CGRect, on screen: NSScreen) async throws -> RegionCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for region capture"])
        }

        // Resolve the NSScreen to its SCDisplay via the shared CGDirectDisplayID, the
        // same NSScreenNumber device-description key used in captureAllScreensAsJPEG (:55).
        guard let screenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == screenDisplayID }) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not match the selection screen to a capturable display"])
        }

        // The display's full AppKit frame (bottom-left origin), same coordinate system
        // as globalRect, NSEvent.mouseLocation, and the overlay's screenFrame.
        let displayFrame = screen.frame

        // Exclude all windows belonging to this app so the AI sees only the user's
        // content, not our overlays or panels (identical to captureAllScreensAsJPEG :42-45).
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        // Convert the AppKit global selection rect (bottom-left origin) to the display's
        // Core Graphics local rect (top-left origin) for sourceRect.
        let displayLocalCGRect = convertGlobalRectToDisplayLocalCGRect(
            globalRect: globalRect,
            displayFrame: displayFrame
        )

        // Size the capture to the region's true backing-pixel dimensions so annotation
        // coordinates land at full density (unlike the all-screens path's fixed 1280 cap).
        let backingScaleFactor = screen.backingScaleFactor
        let cropPixelWidth = max(1, Int((globalRect.width * backingScaleFactor).rounded()))
        let cropPixelHeight = max(1, Int((globalRect.height * backingScaleFactor).rounded()))

        let configuration = SCStreamConfiguration()
        configuration.width = cropPixelWidth
        configuration.height = cropPixelHeight
        // sourceRect is expressed in the display's point space (top-left origin); the
        // configured width/height above set the output pixel resolution of that region.
        configuration.sourceRect = displayLocalCGRect

        let capturedCGImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        // Fallback: if sourceRect was not honored (the returned image covers the whole
        // display instead of just the region), crop the CGImage to the region ourselves.
        // We detect this by comparing the captured size to the requested crop size with a
        // small tolerance (ScreenCaptureKit may round dimensions by a pixel or two).
        let sourceRectWasHonored =
            abs(capturedCGImage.width - cropPixelWidth) <= 2 &&
            abs(capturedCGImage.height - cropPixelHeight) <= 2

        let cgImage: CGImage
        if sourceRectWasHonored {
            cgImage = capturedCGImage
        } else {
            // The captured image is the full display at backing-pixel density. Compute the
            // crop rect in that pixel space: x/y scale directly from the top-left-origin
            // displayLocalCGRect (which is already top-left origin, matching the CGImage).
            let cropOriginXInPixels = displayLocalCGRect.origin.x * backingScaleFactor
            let cropOriginYInPixels = displayLocalCGRect.origin.y * backingScaleFactor
            let cropRectInPixels = CGRect(
                x: cropOriginXInPixels,
                y: cropOriginYInPixels,
                width: CGFloat(cropPixelWidth),
                height: CGFloat(cropPixelHeight)
            )
            guard let croppedImage = capturedCGImage.cropping(to: cropRectInPixels) else {
                throw NSError(domain: "CompanionScreenCapture", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to crop full-display capture to the selected region"])
            }
            print("📐 Region capture: sourceRect not honored, cropped full display \(capturedCGImage.width)x\(capturedCGImage.height) to \(cropRectInPixels)")
            cgImage = croppedImage
        }

        // Detached encode keeps JPEG compression off the main actor (consistent with
        // the perf pass). base64 happens later in ClaudeAPI, not here.
        let jpegData: Data = try await Task.detached(priority: .userInitiated) {
            guard let encoded = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                throw NSError(domain: "CompanionScreenCapture", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to JPEG-encode the region crop"])
            }
            return encoded
        }.value

        // The actual produced CGImage dimensions are the source of truth for pixel size
        // (ScreenCaptureKit may round to even dimensions), so report those.
        let actualPixelWidth = cgImage.width
        let actualPixelHeight = cgImage.height

        print("📐 Region capture: globalRect=\(globalRect) → cgLocal=\(displayLocalCGRect), pixels=\(actualPixelWidth)x\(actualPixelHeight), scale=\(backingScaleFactor)")

        return RegionCapture(
            imageData: jpegData,
            cropPixelWidth: actualPixelWidth,
            cropPixelHeight: actualPixelHeight,
            regionGlobalFrame: globalRect,
            displayFrame: displayFrame
        )
    }
}
