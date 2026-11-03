import Foundation

@MainActor public final class ElevenLabsTranscriber: TranscriptionProvider {
    public var onTranscript: ((TranscriptEvent) -> Void)?
    public var onStatus: ((AudioRole, TranscriptionStatus) -> Void)?
    private var channels: [AudioRole: ScribeChannel] = [:]
    private var generation = UUID()
    public init() {}
    public func connect(apiKey: String, language: String) async throws {
        disconnect()
        let token = generation
        var opened: [ScribeChannel] = []
        do {
            for role in [AudioRole.interviewer, .you] {
                let channel = ScribeChannel(role: role)
                channel.onTranscript = { [weak self] event in guard let self, self.generation == token else { return }; self.onTranscript?(event) }
                channel.onStatus = { [weak self] message in guard let self, self.generation == token else { return }; self.onStatus?(role, message) }
                channels[role] = channel
                opened.append(channel)
                try await channel.open(key: apiKey, language: language)
                guard generation == token, !Task.isCancelled else { throw CancellationError() }
            }
        } catch { opened.forEach { $0.close() }; if generation == token { disconnect() }; throw error }
    }
    public func send(_ chunk: AudioChunk) { channels[chunk.role]?.enqueue(chunk.pcm16) }
    public func disconnect() { generation = UUID(); channels.values.forEach { $0.close() }; channels.removeAll() }
}

@MainActor private final class ScribeChannel {
    let role: AudioRole
    var onTranscript: ((TranscriptEvent) -> Void)?
    var onStatus: ((TranscriptionStatus) -> Void)?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var pending: [Data] = []
    private var active = false
    private var retentionWarning = false
    init(role: AudioRole) { self.role = role }

    func open(key: String, language: String) async throws {
        var url = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var query = [URLQueryItem(name: "model_id", value: "scribe_v2_realtime"), URLQueryItem(name: "audio_format", value: "pcm_16000"), URLQueryItem(name: "commit_strategy", value: "vad"), URLQueryItem(name: "vad_silence_threshold_secs", value: "0.5"), URLQueryItem(name: "enable_logging", value: "false")]
        if language == "en" || language == "de" { query.append(.init(name: "language_code", value: language)) }
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        // The deadline cancels the socket itself so receive never outlives failed startup.
        let deadline = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { deadline.cancel() }
        while true {
            let message = try await socket.receive()
            let text = Self.text(message)
            if let event = try ScribeMessage.decode(text, role: role) { onTranscript?(event) }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            if object?["message_type"] as? String == "warning" { retentionWarning = true; onStatus?(.connected("Connected; provider retention warning. Zero retention is not confirmed.")) }
            if object?["message_type"] as? String == "session_started" { break }
        }
        active = true
        onStatus?(.connected(retentionWarning ? "Connected; provider retention warning. Zero retention is not confirmed." : "Connected. Provider retention depends on your account."))
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard self.active else { return }
                    let text = Self.text(message)
                    if let event = try ScribeMessage.decode(text, role: self.role) { self.onTranscript?(event) }
                    else if (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["message_type"] as? String == "warning" { self.onStatus?(.connected("Provider retention warning; zero retention is not confirmed.")) }
                }
            } catch {
                if self.active {
                    let detail = (error as? ScribeError)?.localizedDescription ?? "Connection lost."
                    self.fail("Disconnected. \(detail) Stop and start to reconnect.")
                }
            }
        }
    }

    func enqueue(_ data: Data) {
        guard active, !data.isEmpty else { return }
        guard pending.count < 40 else { fail("Audio network backlog exceeded 2 seconds. Stop and start to reconnect."); return }
        pending.append(data)
        guard sender == nil else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            defer { self.sender = nil }
            do {
                while self.active && !self.pending.isEmpty && !Task.isCancelled {
                    let data = self.pending.removeFirst()
                    guard let socket = self.socket else { return }
                    try await socket.send(.string(ScribeMessage.audioMessage(data)))
                }
            } catch { if self.active { self.fail("Audio upload failed. Stop and start to reconnect.") } }
        }
    }
    func close() {
        active = false
        receiver?.cancel(); receiver = nil
        sender?.cancel(); sender = nil
        pending.removeAll()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
    private func fail(_ text: String) { close(); onStatus?(.failed(text)) }
    private static func text(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message { case .string(let text): return text; case .data(let data): return String(decoding: data, as: UTF8.self); @unknown default: return "" }
    }
}
