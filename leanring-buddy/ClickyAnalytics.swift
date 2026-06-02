//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Analytics is intentionally a no-op in ClickyJ.
//
//  The upstream Clicky app sent usage telemetry to PostHog (a paid SaaS).
//  ClickyJ is a privacy-respecting open-source restart, so all analytics
//  have been stripped. This enum keeps the exact same public API surface
//  as the original so every call site across the app compiles and runs
//  unchanged — each method simply does nothing.
//
//  If you ever want telemetry back, this is the single place to wire it in.
//

import Foundation

enum ClickyAnalytics {

    // MARK: - Setup

    /// No-op. Previously configured the PostHog SDK.
    static func configure() {}

    // MARK: - Identity

    /// No-op. Previously identified the user in PostHog by email.
    static func identifyUser(email: String) {}

    // MARK: - App Lifecycle

    /// No-op. Previously fired once on every app launch.
    static func trackAppOpened() {}

    // MARK: - Onboarding

    /// No-op. User clicked Start to begin onboarding for the first time.
    static func trackOnboardingStarted() {}

    /// No-op. User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {}

    /// No-op. The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {}

    /// No-op. The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {}

    // MARK: - Permissions

    /// No-op. All three permissions (accessibility, screen recording, mic) granted.
    static func trackAllPermissionsGranted() {}

    /// No-op. A single permission was granted.
    static func trackPermissionGranted(permission: String) {}

    // MARK: - Voice Interaction

    /// No-op. User pressed the push-to-talk shortcut to start talking.
    static func trackPushToTalkStarted() {}

    /// No-op. User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {}

    /// No-op. Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {}

    /// No-op. The AI responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {}

    /// No-op. The AI response included a [POINT:x,y:label] coordinate tag.
    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - Errors

    /// No-op. An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {}

    /// No-op. An error occurred during TTS playback.
    static func trackTTSError(error: String) {}
}
