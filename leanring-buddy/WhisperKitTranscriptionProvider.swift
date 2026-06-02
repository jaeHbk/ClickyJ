//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device, open-source speech-to-text for ClickyJ. Replaces the paid
//  AssemblyAI streaming + OpenAI Whisper API transcription providers.
//
//  Uses WhisperKit (Argmax Open-Source SDK, MIT) running OpenAI Whisper
//  models locally via CoreML — no API key, no network, full privacy.
//
//  Streaming strategy:
//  The app feeds live microphone AVAudioPCMBuffers through appendAudioBuffer.
//  WhisperKit's built-in AudioStreamTranscriber owns its own microphone and
//  cannot accept externally-fed buffers, so this provider instead accumulates
//  resampled 16 kHz mono Float samples and runs WhisperKit.transcribe(audioArray:)
//  on a short debounce for progressive partials, plus one final pass on key-up.
//
//  This provider conforms to the same BuddyTranscriptionProvider /
//  BuddyStreamingTranscriptionSession contracts the AssemblyAI/Apple providers
//  used, so the rest of the dictation pipeline is unchanged.
//

import AVFoundation
import Foundation
import WhisperKit

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "WhisperKit"

    // WhisperKit does NOT use Apple's Speech framework, so no speech-recognition
    // permission is required (only microphone access, handled elsewhere).
    let requiresSpeechRecognitionPermission = false

    // Always available — the model is downloaded on first use and run locally.
    let isConfigured = true
    let unavailableExplanation: String? = nil

    /// The Whisper model variant to load. `base.en` is the best accuracy/size
    /// tradeoff for short push-to-talk utterances; `tiny.en` is faster/smaller.
    private let modelVariant = "openai_whisper-base.en"

    /// A single shared WhisperKit instance. Building one is expensive (CoreML
    /// compile + prewarm), so it is created once and reused across all sessions.
    /// Actor-isolated access is via async; we cache the loaded instance here.
    private static var sharedWhisperKitInstance: WhisperKit?
    private static let sharedInstanceLock = NSLock()

    /// Loads (or returns the cached) WhisperKit instance.
    private func loadWhisperKitInstance() async throws -> WhisperKit {
        Self.sharedInstanceLock.lock()
        if let existingInstance = Self.sharedWhisperKitInstance {
            Self.sharedInstanceLock.unlock()
            return existingInstance
        }
        Self.sharedInstanceLock.unlock()

        let configuration = WhisperKitConfig(
            model: modelVariant,
            // download + load the model if it isn't already cached, and prewarm
            // the CoreML graph so the first real transcription isn't slow.
            download: true,
            load: true,
            prewarm: true
        )

        let whisperKitInstance = try await WhisperKit(configuration)

        Self.sharedInstanceLock.lock()
        Self.sharedWhisperKitInstance = whisperKitInstance
        Self.sharedInstanceLock.unlock()

        return whisperKitInstance
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let whisperKitInstance = try await loadWhisperKitInstance()

        return WhisperKitTranscriptionSession(
            whisperKitInstance: whisperKitInstance,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    // Slightly longer than Apple Speech: the final decode may take a beat on
    // larger utterances. The manager uses this as a safety fallback timeout.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.0

    private let whisperKitInstance: WhisperKit
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioConverter = BuddyFloat32AudioConverter()

    /// All accumulated 16 kHz mono Float samples for the current utterance.
    /// Guarded by `stateQueue` because audio buffers arrive on the audio thread
    /// while decode tasks read snapshots concurrently.
    private var accumulatedSamples: [Float] = []
    private let stateQueue = DispatchQueue(label: "com.clickyj.whisperkit.state")

    /// The in-flight partial-decode task, cancelled/replaced on each new tick
    /// so only the latest audio snapshot is transcribed.
    private var partialDecodeTask: Task<Void, Never>?

    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var latestPartialText = ""

    /// WhisperKit needs roughly 1s of audio before a chunk decodes meaningfully.
    /// 16 kHz → 16000 samples per second.
    private let minimumSamplesForPartialDecode = 16_000

    /// Debounce partial decodes so we don't kick off a transcribe on every tiny
    /// buffer. Tracked as a sample-count threshold since the last decode.
    private var sampleCountAtLastPartialDecode = 0
    private let samplesBetweenPartialDecodes = 8_000 // ~0.5s at 16 kHz

    init(
        whisperKitInstance: WhisperKit,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.whisperKitInstance = whisperKitInstance
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }

        guard let convertedSamples = audioConverter.convertToFloatSamples(from: audioBuffer),
              !convertedSamples.isEmpty else {
            return
        }

        var shouldStartPartialDecode = false
        var samplesSnapshot: [Float] = []

        stateQueue.sync {
            accumulatedSamples.append(contentsOf: convertedSamples)

            let totalSamples = accumulatedSamples.count
            let samplesSinceLastDecode = totalSamples - sampleCountAtLastPartialDecode

            if totalSamples >= minimumSamplesForPartialDecode,
               samplesSinceLastDecode >= samplesBetweenPartialDecodes {
                sampleCountAtLastPartialDecode = totalSamples
                samplesSnapshot = accumulatedSamples
                shouldStartPartialDecode = true
            }
        }

        guard shouldStartPartialDecode else { return }

        // Replace any in-flight partial decode with one over the latest snapshot.
        partialDecodeTask?.cancel()
        partialDecodeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcribedText = try await self.transcribe(samples: samplesSnapshot)
                guard !Task.isCancelled else { return }
                if !transcribedText.isEmpty {
                    self.latestPartialText = transcribedText
                    self.onTranscriptUpdate(transcribedText)
                }
            } catch is CancellationError {
                // Superseded by a newer snapshot — ignore.
            } catch {
                // Partial decode failures are non-fatal; the final decode still runs.
            }
        }
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true

        // Stop partial decoding; run one authoritative pass over all audio.
        partialDecodeTask?.cancel()

        let finalSamplesSnapshot = stateQueue.sync { accumulatedSamples }

        Task { [weak self] in
            guard let self else { return }

            // No audio captured at all — deliver an empty final transcript.
            guard !finalSamplesSnapshot.isEmpty else {
                self.deliverFinalTranscriptIfNeeded(self.latestPartialText)
                return
            }

            do {
                let finalText = try await self.transcribe(samples: finalSamplesSnapshot)
                let resolvedText = finalText.isEmpty ? self.latestPartialText : finalText
                self.deliverFinalTranscriptIfNeeded(resolvedText)
            } catch {
                // If the final decode fails but we have a partial, use it rather
                // than erroring out and losing the user's utterance entirely.
                if !self.latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.deliverFinalTranscriptIfNeeded(self.latestPartialText)
                } else {
                    self.onError(error)
                }
            }
        }
    }

    func cancel() {
        hasRequestedFinalTranscript = true
        partialDecodeTask?.cancel()
        partialDecodeTask = nil
        stateQueue.sync {
            accumulatedSamples.removeAll()
        }
    }

    /// Runs WhisperKit over the given samples and returns the joined transcript.
    private func transcribe(samples: [Float]) async throws -> String {
        let transcriptionResults = try await whisperKitInstance.transcribe(audioArray: samples)
        let joinedText = transcriptionResults
            .map { $0.text }
            .joined(separator: " ")
        return joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        partialDecodeTask?.cancel()
    }
}
