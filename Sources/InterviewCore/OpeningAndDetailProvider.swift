import Foundation

/// Keeps the quick opening stable while a separate isolated provider reasons about detail.
public final class OpeningAndDetailProvider: AnswerProvider {
    private let opening: AnswerProvider
    private let detail: AnswerProvider
    private let coordinator: OpeningAndDetailCoordinator
    public init(opening: AnswerProvider, detail: AnswerProvider) {
        self.opening = opening; self.detail = detail
        coordinator = OpeningAndDetailCoordinator(opening: opening, detail: detail)
    }
    public func prepare() async throws { try await coordinator.prepare() }
    public func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        let coordinator = coordinator
        let token = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task { await coordinator.run(request, token: token, stream: continuation) }
            continuation.onTermination = { _ in task.cancel(); Task { await coordinator.cancel(token) } }
        }
    }
    public func interrupt() async { await coordinator.interrupt() }
    public func shutdown() { opening.shutdown(); detail.shutdown(); Task { await coordinator.finishShutdown() } }
}

private actor OpeningAndDetailCoordinator {
    let opening: AnswerProvider, detail: AnswerProvider
    var fastAvailable = false
    var warming: Task<Void, Error>?
    var generation = UUID()
    var current: AsyncThrowingStream<AnswerEvent, Error>.Continuation?
    init(opening: AnswerProvider, detail: AnswerProvider) { self.opening = opening; self.detail = detail }
    func prepare() async throws {
        do {
            try await opening.prepare()
            fastAvailable = true
            if warming == nil { let provider = detail; warming = Task { try await provider.prepare() } }
        } catch {
            fastAvailable = false
            try await detail.prepare()
        }
    }
    private func valid(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }
    func run(_ request: AnswerRequest, token: UUID, stream: AsyncThrowingStream<AnswerEvent, Error>.Continuation) async {
        guard !Task.isCancelled else { stream.finish(); return }
        generation = token
        current?.finish(throwing: CancellationError()); current = stream
        await opening.interrupt()
        guard valid(token) else { stream.finish(); return }
        await detail.interrupt()
        guard valid(token) else { stream.finish(); return }
        do {
            try await prepare()
            guard valid(token) else { stream.finish(); return }
            // Memory supplements already follow a visible answer and need checked detail only.
            if !fastAvailable || request.openingAnswer != nil {
                stream.yield(.notice(request.openingAnswer == nil ? "Codex answer · fast opening unavailable" : "Codex checked follow-up"))
                for try await event in detail.answer(request) {
                    guard valid(token) else { return }
                    if case .completed = event {} else { stream.yield(event) }
                }
                finish(token, stream: stream)
                return
            }
            stream.yield(.notice("Fast opening · checked detail follows · separate OpenAI API usage"))
            var fast = AnswerPresentation()
            do {
                for try await event in opening.answer(request) {
                    guard valid(token) else { return }
                    switch event {
                    case .delta(let delta): fast.append(delta); stream.yield(event)
                    case .resetIncompleteOpening: fast.resetIncompleteOpening(); stream.yield(event)
                    case .usage, .apiUsage, .notice: stream.yield(event)
                    case .completed: break
                    }
                }
                guard !fast.paragraph.isEmpty else { throw CodexError.protocolFailure }
            } catch {
                guard valid(token) else { return }
                if fast.hasFirstSentence {
                    stream.yield(.notice("Fast opening ended early; Codex is checking the answer"))
                } else {
                    if !fast.raw.isEmpty { stream.yield(.resetIncompleteOpening) }
                    stream.yield(.notice("Fast opening unavailable; using Codex"))
                    try await detail.prepare()
                    guard valid(token) else { return }
                    for try await event in detail.answer(request) {
                        guard valid(token) else { return }
                        if case .completed = event {} else { stream.yield(event) }
                    }
                    finish(token, stream: stream)
                    return
                }
            }
            guard valid(token) else { return }
            stream.yield(.delta("\n\nDETAILS:\n"))
            let checked = AnswerRequest(question: request.question, profile: request.profile, roleDescription: request.roleDescription, conversation: request.conversation, openingAnswer: fast.paragraph, language: request.language)
            do {
                if let warmup = warming { warming = nil; try await warmup.value }
                try Task.checkCancellation()
                guard valid(token) else { return }
                try await detail.prepare()
                guard valid(token) else { return }
                var raw = "", delivered = 0
                for try await event in detail.answer(checked) {
                    guard valid(token) else { return }
                    switch event {
                    case .delta(let delta):
                        raw += delta
                        // Wait for the whole header, so a partial "DETA" is never displayed.
                        if let newline = raw.firstIndex(of: "\n"), raw[..<newline].trimmingCharacters(in: .whitespacesAndNewlines) == "DETAILS:" {
                            let body = String(raw[raw.index(after: newline)...])
                            if body.count > delivered { stream.yield(.delta(String(body.dropFirst(delivered)))); delivered = body.count }
                        }
                    case .usage, .apiUsage: stream.yield(event)
                    case .notice, .resetIncompleteOpening: break
                    case .completed: break
                    }
                }
                if delivered == 0 && !raw.isEmpty { stream.yield(.delta("Checked follow-up:\n" + raw)) }
            } catch {
                guard valid(token) else { return }
                stream.yield(.notice("Opening ready; supporting detail unavailable. Answer now retries."))
            }
            finish(token, stream: stream)
        } catch {
            guard generation == token else { return }
            current = nil; stream.finish(throwing: error)
        }
    }
    private func finish(_ token: UUID, stream: AsyncThrowingStream<AnswerEvent, Error>.Continuation) {
        guard generation == token else { return }
        current = nil; stream.yield(.completed); stream.finish()
    }
    func cancel(_ token: UUID) async { guard generation == token, current != nil else { return }; await interrupt() }
    func interrupt() async {
        let token = UUID(); generation = token
        current?.finish(throwing: CancellationError()); current = nil
        await opening.interrupt()
        guard generation == token else { return }
        await detail.interrupt()
    }
    func finishShutdown() { generation = UUID(); current?.finish(throwing: CancellationError()); current = nil; warming?.cancel(); warming = nil }
}
