//
//  GeminiAPI.swift
//  Google Gemini vision API client with streaming support.
//
//  Replaces the paid Anthropic Claude client (ClaudeAPI) with Google's
//  Gemini API, which has a free tier suitable for ClickyJ. The public
//  interface intentionally mirrors the former ClaudeAPI (analyzeImageStreaming
//  / analyzeImage with identical signatures) so CompanionManager is unchanged
//  apart from the type name.
//
//  Requests route through the same Cloudflare Worker proxy (now pointed at
//  Gemini) so the API key never ships in the app. The Worker forwards the SSE
//  body straight through; this client speaks Gemini's request/response JSON.
//

import Foundation

/// Gemini API helper with streaming for progressive text display.
class GeminiAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "gemini-2.5-flash") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection so the first real API call (carrying a large image payload)
        // doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The Worker uses this to select the upstream Gemini model + endpoint
        // (streaming vs not) so the app's model picker still works.
        request.setValue(model, forHTTPHeaderField: "X-Clicky-Model")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. Gemini rejects requests where the declared mimeType
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the proxy host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Builds the Gemini `generateContent` request body from the same inputs the
    /// Claude client accepted, mapping:
    ///   - systemPrompt        -> systemInstruction.parts[].text
    ///   - conversationHistory -> contents[] with roles user / model
    ///   - images + userPrompt -> a final user content whose parts interleave
    ///     inlineData image parts (mimeType + base64) with their label text and
    ///     the user prompt.
    private func buildRequestBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        maxOutputTokens: Int
    ) -> [String: Any] {
        var contents: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            contents.append([
                "role": "user",
                "parts": [["text": userPlaceholder]]
            ])
            contents.append([
                "role": "model",
                "parts": [["text": assistantResponse]]
            ])
        }

        // Build the current user turn: each image (inlineData) is followed by its
        // label text, then the user prompt text at the end — matching the order
        // the Claude client used and Google's image-then-text recommendation.
        var currentTurnParts: [[String: Any]] = []
        for image in images {
            currentTurnParts.append([
                "inlineData": [
                    "mimeType": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentTurnParts.append(["text": image.label])
        }
        currentTurnParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentTurnParts])

        return [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": maxOutputTokens,
                "temperature": 1.0
            ]
        ]
    }

    /// Extracts the concatenated text from a Gemini response candidate's parts,
    /// skipping any non-text parts (e.g. thought summaries).
    private func extractText(fromCandidatePayload payload: [String: Any]) -> String {
        guard let candidates = payload["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }

        var combinedText = ""
        for part in parts {
            if let textChunk = part["text"] as? String {
                combinedText += textChunk
            }
        }
        return combinedText
    }

    /// Send a vision request to Gemini with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: 1024
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Gemini streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GeminiAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "GeminiAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse the SSE stream. With alt=sse each event is a line "data: {json}".
        // Each payload is a PARTIAL GenerateContentResponse whose
        // candidates[0].content.parts[].text is only the NEW chunk, so we
        // accumulate across lines. Unlike Anthropic, Gemini sends no [DONE]
        // sentinel — the stream simply ends.
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // Defensive: some proxies/clients may still forward a [DONE] marker.
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            let chunkText = extractText(fromCandidatePayload: eventPayload)
            guard !chunkText.isEmpty else { continue }

            accumulatedResponseText += chunkText
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        // Signal the Worker to use the non-streaming generateContent endpoint.
        request.setValue("false", forHTTPHeaderField: "X-Clicky-Stream")

        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: 256
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Gemini request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "GeminiAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "GeminiAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let text = extractText(fromCandidatePayload: json)
        guard !text.isEmpty else {
            throw NSError(
                domain: "GeminiAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Empty or blocked response"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
