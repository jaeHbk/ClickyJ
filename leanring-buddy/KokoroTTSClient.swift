//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  Local, open-source text-to-speech for ClickyJ. Replaces the paid
//  ElevenLabs service.
//
//  Primary path: POSTs text to a local Kokoro TTS sidecar
//  (tts-sidecar/kokoro_tts_server.py) on 127.0.0.1 and plays the returned
//  WAV audio (PCM16, mono, 24 kHz) via AVAudioPlayer.
//
//  Fallback path: if the sidecar is not running or errors, speech is
//  synthesized with Apple's built-in AVSpeechSynthesizer so the app is
//  never mute even before the user installs the sidecar.
//
//  This type intentionally mirrors the public surface of the former
//  ElevenLabsTTSClient (speakText, isPlaying, stopPlayback) so the call
//  sites in CompanionManager remain unchanged.
//

import AVFoundation
import Foundation

@MainActor
final class KokoroTTSClient: NSObject {
    private let sidecarURL: URL
    private let healthURL: URL
    private let session: URLSession

    /// The audio player for the current sidecar playback. Kept alive so the
    /// audio finishes even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    /// Apple's built-in synthesizer, used as a fallback when the local Kokoro
    /// sidecar is unavailable. Held strongly so speech isn't cut off.
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// The default voice spoken to the sidecar. Mirrors the server default.
    private let voiceIdentifier: String

    init(sidecarBaseURL: String = "http://127.0.0.1:8757", voiceIdentifier: String = "af_heart") {
        self.sidecarURL = URL(string: "\(sidecarBaseURL)/tts")!
        self.healthURL = URL(string: "\(sidecarBaseURL)/health")!
        self.voiceIdentifier = voiceIdentifier

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        super.init()
    }

    /// Synthesizes `text` and plays it. Tries the local Kokoro sidecar first;
    /// if that fails for any reason, falls back to AVSpeechSynthesizer so the
    /// user still hears a response. Cancellation-safe.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        do {
            try await speakViaKokoroSidecar(trimmedText)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Sidecar unreachable or returned an error — never leave the user
            // in silence. Fall back to the built-in system voice.
            print("⚠️ Kokoro sidecar unavailable (\(error.localizedDescription)); falling back to AVSpeechSynthesizer")
            speakViaSystemSynthesizer(trimmedText)
        }
    }

    /// Requests WAV audio from the local Kokoro sidecar and plays it.
    private func speakViaKokoroSidecar(_ text: String) async throws {
        var request = URLRequest(url: sidecarURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "voice": voiceIdentifier
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "KokoroTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "KokoroTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS sidecar error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        // Stop any system-voice fallback that might still be speaking.
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 Kokoro TTS: playing \(data.count / 1024)KB audio")
    }

    /// Fallback: speak `text` using Apple's built-in synthesizer.
    private func speakViaSystemSynthesizer(_ text: String) {
        // Stop any sidecar audio so the two don't overlap.
        audioPlayer?.stop()
        audioPlayer = nil

        let utterance = AVSpeechUtterance(string: text)
        // Prefer a natural-sounding voice for the user's locale when available.
        if let preferredVoice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) {
            utterance.voice = preferredVoice
        }
        speechSynthesizer.speak(utterance)
        print("🔊 System TTS (fallback): speaking \(text.count) characters")
    }

    /// Whether TTS audio is currently playing back (via either path).
    var isPlaying: Bool {
        if let audioPlayer, audioPlayer.isPlaying {
            return true
        }
        return speechSynthesizer.isSpeaking
    }

    /// Stops any in-progress playback immediately (both paths).
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
}
