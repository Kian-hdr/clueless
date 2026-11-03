import Foundation
import Darwin

public enum FastAnswerError: LocalizedError {
    case fastUnavailable(String), invalidFrame, transport, timeout, providerFailure(String)
    public var errorDescription: String? {
        switch self {
        case .fastUnavailable(let reason): return "Fast opening unavailable: \(reason)"
        case .invalidFrame: return "Fast opening returned an invalid response."
        case .transport: return "Fast opening connection failed."
        case .timeout: return "Fast opening timed out."
        case .providerFailure(let code): return "Fast opening failed (\(FastHelperEvent.safeCode(code)))."
        }
    }
}

public enum FastHelperEvent {
    case delta(String), usage(input: Int, output: Int), completed(serviceTier: String), failed(code: String)
    public static func safeCode(_ code: String) -> String {
        let allowed = ["missing_credential", "invalid_input", "transport", "http_400", "http_401", "http_403", "http_429", "provider_failed", "provider_incomplete", "malformed_stream", "missing_usage", "blocked_redirect", "helper_failure", "timeout", "unexpected_tool", "refused"]
        return allowed.contains(code) ? code : "helper_failure"
    }
    public var json: [String: Any] {
        switch self {
        case .delta(let text): return ["type": "delta", "text": text]
        case .usage(let input, let output): return ["type": "usage", "input": input, "output": output]
        case .completed(let tier): return ["type": "completed", "serviceTier": tier]
        case .failed(let code): return ["type": "error", "code": Self.safeCode(code)]
        }
    }
}

public struct ProtectedAliasResolver {
    public static func resolve(_ listing: String, requested: String?) throws -> String {
        let candidates = Set(listing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == "OPENAI_API_KEY" else { return nil }
            let alias = String(fields[0])
            guard alias.hasPrefix("openai/"), alias.count > 7, alias.count < 200,
                  alias.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.").contains($0) }) else { return nil }
            return alias
        })
        if let requested {
            guard candidates.contains(requested) else { throw FastAnswerError.fastUnavailable("selected OpenAI credential profile was not found") }
            return requested
        }
        guard candidates.count == 1, let alias = candidates.first else {
            throw FastAnswerError.fastUnavailable(candidates.isEmpty ? "no protected OpenAI credential profile is available" : "multiple OpenAI credential profiles require an explicit selection")
        }
        return alias
    }
}

public struct FastHelperFrameDecoder {
    private var buffer = Data()
    public var maximumFrameBytes: Int
    private var totalBytes = 0
    public init(maximumFrameBytes: Int = 128 * 1024) { self.maximumFrameBytes = maximumFrameBytes }
    public mutating func append(_ data: Data) throws -> [FastHelperEvent] {
        totalBytes += data.count
        guard totalBytes <= 512 * 1024 else { throw FastAnswerError.invalidFrame }
        buffer.append(data)
        var output: [FastHelperEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard newline <= maximumFrameBytes else { throw FastAnswerError.invalidFrame }
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any], let type = value["type"] as? String else { throw FastAnswerError.invalidFrame }
            switch type {
            case "delta":
                guard let text = value["text"] as? String else { throw FastAnswerError.invalidFrame }
                output.append(.delta(text))
            case "usage":
                guard let input = value["input"] as? Int, let tokens = value["output"] as? Int, input >= 0, tokens >= 0 else { throw FastAnswerError.invalidFrame }
                output.append(.usage(input: input, output: tokens))
            case "completed":
                guard let tier = value["serviceTier"] as? String, ["default", "priority", "fast", "auto"].contains(tier) else { throw FastAnswerError.invalidFrame }
                output.append(.completed(serviceTier: tier))
            case "error": output.append(.failed(code: FastHelperEvent.safeCode(value["code"] as? String ?? "helper_failure")))
            default: throw FastAnswerError.invalidFrame
            }
        }
        guard buffer.count <= maximumFrameBytes else { throw FastAnswerError.invalidFrame }
        return output
    }
    public var hasTrailingBytes: Bool { !buffer.isEmpty }
}

/// Converts semantic Responses events into the narrow helper protocol. No tools are accepted.
public struct FastResponseAccumulator {
    public private(set) var completed = false
    private var textBytes = 0
    public init() {}
    public mutating func consume(_ event: [String: Any]) throws -> [FastHelperEvent] {
        guard !completed, let type = event["type"] as? String else { throw FastAnswerError.invalidFrame }
        switch type {
        case "response.output_text.delta":
            guard let text = event["delta"] as? String else { throw FastAnswerError.invalidFrame }
            textBytes += text.utf8.count
            guard textBytes <= 32 * 1024 else { throw FastAnswerError.invalidFrame }
            return [.delta(text)]
        case "response.output_item.added", "response.output_item.done":
            guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String, ["message", "reasoning"].contains(kind) else { throw FastAnswerError.providerFailure("unexpected_tool") }
        case "response.completed":
            guard textBytes > 0, let response = event["response"] as? [String: Any], response["status"] as? String == "completed",
                  let usage = response["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int,
                  let output = usage["output_tokens"] as? Int, input >= 0, output >= 0,
                  let tier = response["service_tier"] as? String, ["default", "priority", "fast", "auto"].contains(tier) else { throw FastAnswerError.providerFailure("missing_usage") }
            completed = true
            return [.usage(input: input, output: output), .completed(serviceTier: tier)]
        case "response.failed", "error": throw FastAnswerError.providerFailure("provider_failed")
        case "response.incomplete": throw FastAnswerError.providerFailure("provider_incomplete")
        case "response.refusal.delta", "response.refusal.done": throw FastAnswerError.providerFailure("refused")
        default: break
        }
        return []
    }
}

private final class FastProcessSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var epoch = 0
    func lease() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }
    func register(_ process: Process, id: UUID, lease: Int) -> Bool {
        lock.lock()
        guard epoch == lease else { lock.unlock(); Self.stop(process); return false }
        processes[id] = process; lock.unlock(); return true
    }
    func remove(_ id: UUID) { lock.lock(); processes.removeValue(forKey: id); lock.unlock() }
    func cancel(_ id: UUID) { lock.lock(); let process = processes.removeValue(forKey: id); lock.unlock(); if let process { Self.stop(process) } }
    func cancelAll() { lock.lock(); epoch += 1; let all = Array(processes.values); processes.removeAll(); lock.unlock(); all.forEach(Self.stop) }
    static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

public final class ProtectedFastAnswerProvider: AnswerProvider {
    private let state: FastBrokerTransport
    private let slot = FastProcessSlot()
    public init(helperURL: URL, brokerURL: URL? = nil, profile: String? = nil) {
        let broker = brokerURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/keychain-run")
        state = FastBrokerTransport(helper: helperURL, broker: broker, requestedProfile: profile, slot: slot)
    }
    public func prepare() async throws { try await state.prepare() }
    public func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        let id = UUID(), state = state
        return AsyncThrowingStream { continuation in
            let task = Task { await state.answer(request, id: id, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel(); Task { await state.cancel(id) } }
        }
    }
    public func interrupt() async { await state.interrupt() }
    public func shutdown() { slot.cancelAll(); Task { await state.interrupt() } }
}

private actor FastBrokerTransport {
    let helper: URL, broker: URL, requestedProfile: String?, slot: FastProcessSlot
    var alias: String?
    var latest = UUID()
    var activeID: UUID?
    var continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation?
    var deadline: Task<Void, Never>?
    var decoder = FastHelperFrameDecoder()
    var sawUsage = false, sawText = false, sawCompletion = false

    init(helper: URL, broker: URL, requestedProfile: String?, slot: FastProcessSlot) { self.helper = helper; self.broker = broker; self.requestedProfile = requestedProfile; self.slot = slot }
    func environment() -> [String: String] {
        var env = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }
        return env
    }
    func prepare() async throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw FastAnswerError.fastUnavailable("bundled native helper is missing") }
        guard FileManager.default.isExecutableFile(atPath: broker.path) else { throw FastAnswerError.fastUnavailable("Keychain Drop runner is not installed") }
        if alias != nil { return }
        let child = Process(), output = Pipe(), diagnostic = Pipe(), id = UUID(), lease = slot.lease()
        child.executableURL = broker; child.arguments = ["list"]; child.environment = environment()
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = diagnostic
        diagnostic.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        try child.run()
        guard slot.register(child, id: id, lease: lease) else { throw CancellationError() }
        let timer = Task { [slot] in try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { slot.cancel(id) } }
        defer { timer.cancel(); slot.remove(id) }
        let listing = try await Task.detached { () throws -> String in
            var bytes = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                bytes.append(chunk)
                guard bytes.count <= 64 * 1024 else { FastProcessSlot.stop(child); throw FastAnswerError.fastUnavailable("credential metadata exceeded its limit") }
            }
            child.waitUntilExit()
            guard child.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8) else { throw FastAnswerError.fastUnavailable("credential metadata could not be read") }
            return text
        }.value
        alias = try ProtectedAliasResolver.resolve(listing, requested: requestedProfile)
    }
    func answer(_ request: AnswerRequest, id: UUID, continuation next: AsyncThrowingStream<AnswerEvent, Error>.Continuation) async {
        guard !Task.isCancelled else { next.finish(); return }
        latest = id
        stopActive(CancellationError())
        do {
            try await prepare()
            guard latest == id, !Task.isCancelled else { next.finish(); return }
            let values = ["language": request.language.rawValue, "question": String(request.question.prefix(8000)), "profile": String(request.profile.prefix(32000)), "roleDescription": String(request.roleDescription.prefix(8000)), "conversation": String(request.conversation.suffix(12000))]
            let payload = try JSONSerialization.data(withJSONObject: values)
            guard payload.count <= 128 * 1024 else { throw FastAnswerError.fastUnavailable("selected interview context is too large") }
            let child = Process(), input = Pipe(), output = Pipe(), diagnostic = Pipe(), lease = slot.lease()
            child.executableURL = broker; child.arguments = [alias!, "--", helper.path]
            child.currentDirectoryURL = FileManager.default.temporaryDirectory
            child.environment = environment(); child.standardInput = input; child.standardOutput = output; child.standardError = diagnostic
            diagnostic.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            continuation = next; activeID = id; decoder = FastHelperFrameDecoder(); sawUsage = false; sawText = false; sawCompletion = false
            try child.run()
            guard slot.register(child, id: id, lease: lease) else { throw CancellationError() }
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled { await self?.timedOut(id) }
            }
            Task.detached { [weak self] in
                do { try input.fileHandleForWriting.write(contentsOf: payload); try input.fileHandleForWriting.close() }
                catch { await self?.failed(id, error: FastAnswerError.transport); return }
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    await self?.receive(chunk, id: id)
                }
                child.waitUntilExit()
                await self?.ended(id, status: child.terminationStatus)
            }
        } catch {
            guard latest == id else { next.finish(); return }
            if activeID == id { stopActive(error) } else { next.finish(throwing: error) }
        }
    }
    func receive(_ data: Data, id: UUID) {
        guard activeID == id, latest == id else { return }
        do {
            for event in try decoder.append(data) {
                guard !sawCompletion else { throw FastAnswerError.invalidFrame }
                switch event {
                case .delta(let text): sawText = sawText || !text.isEmpty; continuation?.yield(.delta(text))
                case .usage(let input, let output): guard !sawUsage else { throw FastAnswerError.invalidFrame }; sawUsage = true; continuation?.yield(.apiUsage(input: input, output: output))
                case .completed(let tier):
                    guard sawText, sawUsage else { throw FastAnswerError.invalidFrame }
                    continuation?.yield(.notice("Fast opening service: \(tier)"))
                    sawCompletion = true
                case .failed(let code): throw FastAnswerError.providerFailure(code)
                }
            }
        } catch { stopActive(error) }
    }
    func ended(_ id: UUID, status: Int32) {
        slot.remove(id)
        guard activeID == id, latest == id else { return }
        if status == 0, sawCompletion, !decoder.hasTrailingBytes {
            deadline?.cancel(); deadline = nil
            continuation?.yield(.completed); continuation?.finish(); continuation = nil; activeID = nil
        } else { stopActive(FastAnswerError.transport) }
    }
    func failed(_ id: UUID, error: Error) { if activeID == id { stopActive(error) } }
    func timedOut(_ id: UUID) { if activeID == id { stopActive(FastAnswerError.timeout) } }
    func stopActive(_ error: Error) {
        deadline?.cancel(); deadline = nil
        if let id = activeID { slot.cancel(id) }
        activeID = nil; continuation?.finish(throwing: error); continuation = nil
    }
    func cancel(_ id: UUID) { guard latest == id else { return }; interrupt() }
    func interrupt() { latest = UUID(); stopActive(CancellationError()) }
}
