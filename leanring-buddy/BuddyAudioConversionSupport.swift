//
//  BuddyAudioConversionSupport.swift
//  leanring-buddy
//
//  Shared audio conversion helpers for voice transcription providers.
//

import AVFoundation
import Foundation

final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?

    init(targetSampleRate: Double) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        let inputFormatDescription = audioBuffer.format.settings.description

        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            currentInputFormatDescription = inputFormatDescription
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        guard conversionStatus != .error else { return nil }
        guard let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else { return nil }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }
}

/// Converts incoming microphone `AVAudioPCMBuffer`s into 16 kHz mono Float32
/// samples, the format WhisperKit's `transcribe(audioArray:)` API requires.
///
/// Mic buffers are typically 44.1 or 48 kHz; passing them to WhisperKit without
/// resampling to 16 kHz produces garbage or empty transcripts. This converter
/// caches a single `AVAudioConverter` and re-creates it only when the input
/// format actually changes, mirroring `BuddyPCM16AudioConverter`.
final class BuddyFloat32AudioConverter {
    /// WhisperKit operates at a fixed 16 kHz sample rate.
    static let whisperKitSampleRate: Double = 16_000

    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?

    init(targetSampleRate: Double = BuddyFloat32AudioConverter.whisperKitSampleRate) {
        // Non-interleaved Float32 mono — what WhisperKit expects as [Float].
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Converts and resamples `audioBuffer` to 16 kHz mono, returning the raw
    /// Float samples. Returns nil if conversion fails or yields no frames.
    func convertToFloatSamples(from audioBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormatDescription = audioBuffer.format.settings.description

        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            currentInputFormatDescription = inputFormatDescription
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        guard conversionStatus != .error else { return nil }

        let convertedFrameCount = Int(outputBuffer.frameLength)
        guard convertedFrameCount > 0,
              let floatChannelData = outputBuffer.floatChannelData else {
            return nil
        }

        // channel 0 — mono output
        let firstChannelSamples = floatChannelData[0]
        return Array(UnsafeBufferPointer(start: firstChannelSamples, count: convertedFrameCount))
    }
}

enum BuddyWAVFileBuilder {
    static func buildWAVData(
        fromPCM16MonoAudio pcm16AudioData: Data,
        sampleRate: Int,
        channelCount: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataChunkSize = UInt32(pcm16AudioData.count)
        let fileSize = UInt32(36) + dataChunkSize

        var wavData = Data()

        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(littleEndianData(from: fileSize))
        wavData.append("WAVE".data(using: .ascii)!)
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(littleEndianData(from: UInt32(16)))
        wavData.append(littleEndianData(from: UInt16(1)))
        wavData.append(littleEndianData(from: UInt16(channelCount)))
        wavData.append(littleEndianData(from: UInt32(sampleRate)))
        wavData.append(littleEndianData(from: UInt32(byteRate)))
        wavData.append(littleEndianData(from: UInt16(blockAlign)))
        wavData.append(littleEndianData(from: UInt16(bitsPerSample)))
        wavData.append("data".data(using: .ascii)!)
        wavData.append(littleEndianData(from: dataChunkSize))
        wavData.append(pcm16AudioData)

        return wavData
    }

    private static func littleEndianData<T: FixedWidthInteger>(from value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}
