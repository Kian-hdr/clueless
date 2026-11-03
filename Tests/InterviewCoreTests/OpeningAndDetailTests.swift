import XCTest
@testable import InterviewCore

final class OpeningAndDetailTests: XCTestCase {
    func testOpeningAppearsBeforeReasonedDetailAndIsNeverReplaced() async throws {
        let fast = FixtureAnswerProvider(events: [.delta("TOPIC: Testing\n\nI would start with cancellation."), .completed])
        let detail = FixtureAnswerProvider(events: [.delta("DETAILS:\nCheck cleanup and timeouts."), .completed])
        let provider = OpeningAndDetailProvider(opening: fast, detail: detail)
        defer { provider.shutdown() }
        let request = AnswerRequest(question: "How would you test it?", profile: "Synthetic", roleDescription: "", conversation: "", language: .german)
        var text = ""
        var completed = 0
        for try await event in provider.answer(request) {
            switch event { case .delta(let delta): text += delta; case .completed: completed += 1; case .notice, .usage, .apiUsage, .resetIncompleteOpening: break }
        }
        XCTAssertEqual(text, "TOPIC: Testing\n\nI would start with cancellation.\n\nDETAILS:\nCheck cleanup and timeouts.")
        XCTAssertEqual(detail.lastRequest?.openingAnswer, "I would start with cancellation.")
        XCTAssertEqual(fast.lastRequest?.language, .german)
        XCTAssertEqual(detail.lastRequest?.language, .german)
        XCTAssertEqual(completed, 1)
    }
    func testUnavailableOpeningFallsBackWithNotice() async throws {
        let fast = FixtureAnswerProvider(events: [], prepareError: FixtureError.unavailable)
        let detail = FixtureAnswerProvider(events: [.delta("TOPIC: Testing\n\nThe complete Codex answer."), .completed])
        let provider = OpeningAndDetailProvider(opening: fast, detail: detail)
        defer { provider.shutdown() }
        var text = "", notices = 0
        for try await event in provider.answer(.init(question: "Test?", profile: "", roleDescription: "", conversation: "")) {
            switch event { case .delta(let delta): text += delta; case .notice: notices += 1; case .completed, .usage, .apiUsage, .resetIncompleteOpening: break }
        }
        XCTAssertTrue(text.contains("complete Codex answer"))
        XCTAssertGreaterThan(notices, 0)
    }
    func testIncompleteFastResponseRecoversWithoutReplacingAVisibleSentence() async throws {
        let failure = FastAnswerError.providerFailure("provider_incomplete")
        for (partial, visible) in [("TOPIC: Old\n\nI would", false), ("TOPIC: Old\n\nI would test retries.", true)] {
            let fast = FixtureAnswerProvider(events: [.delta(partial)], answerError: failure)
            let replacement = visible ? "DETAILS:\nCheck the retry cap." : "TOPIC: Retry\n\nI would check the retry cap."
            let detail = FixtureAnswerProvider(events: [.delta(replacement), .completed])
            let provider = OpeningAndDetailProvider(opening: fast, detail: detail)
            defer { provider.shutdown() }
            var displayed = ""
            var sawPartial = false
            var resetCount = 0
            for try await event in provider.answer(.init(question: "How would you test retries?", profile: "", roleDescription: "", conversation: "")) {
                switch event {
                case .delta(let text): displayed += text; if text == partial { sawPartial = true }
                case .resetIncompleteOpening: resetCount += 1; displayed = ""
                default: break
                }
            }
            XCTAssertTrue(sawPartial)
            XCTAssertEqual(resetCount, visible ? 0 : 1)
            XCTAssertEqual(displayed, visible ? partial + "\n\n" + replacement : replacement)
            XCTAssertEqual(detail.lastRequest?.openingAnswer, visible ? "I would test retries." : nil)
        }
    }
    func testMemoryFollowupDoesNotCreateAnotherPaidOpening() async throws {
        let fast = FixtureAnswerProvider(events: [.delta("Must not run"), .completed])
        let detail = FixtureAnswerProvider(events: [.delta("DETAILS:\nA supported additional fact."), .completed])
        let provider = OpeningAndDetailProvider(opening: fast, detail: detail)
        defer { provider.shutdown() }
        var text = ""
        for try await event in provider.answer(.init(question: "Follow-up", profile: "Synthetic", roleDescription: "", conversation: "", openingAnswer: "Existing opening.")) {
            if case .delta(let delta) = event { text += delta }
        }
        XCTAssertNil(fast.lastRequest)
        XCTAssertEqual(detail.lastRequest?.openingAnswer, "Existing opening.")
        XCTAssertEqual(text, "DETAILS:\nA supported additional fact.")
    }
    func testDetailFailureDoesNotInvalidateCompleteOpening() async throws {
        let fast = FixtureAnswerProvider(events: [.delta("TOPIC: Testing\n\nI would test cleanup."), .completed])
        let detail = FixtureAnswerProvider(events: [], answerError: FixtureError.unavailable)
        let provider = OpeningAndDetailProvider(opening: fast, detail: detail)
        defer { provider.shutdown() }
        var text = "", completed = false, warned = false
        for try await event in provider.answer(.init(question: "Test?", profile: "", roleDescription: "", conversation: "")) {
            switch event { case .delta(let delta): text += delta; case .completed: completed = true; case .notice(let message): warned = warned || message.contains("unavailable"); case .usage, .apiUsage, .resetIncompleteOpening: break }
        }
        XCTAssertTrue(text.contains("I would test cleanup."))
        XCTAssertTrue(completed)
        XCTAssertTrue(warned)
    }
    func testInterruptAfterOpeningPreventsPendingDetailTransmission() async throws {
        let opened = expectation(description: "Opening has streamed")
        let prepared = expectation(description: "Detail warmup is waiting")
        let fast = FixtureAnswerProvider(events: [.delta("TOPIC: Testing\n\nI would test cleanup."), .completed])
        let detail = WaitingDetailProvider(prepared: prepared)
        let provider = OpeningAndDetailProvider(opening: fast, detail: detail)
        defer { provider.shutdown() }
        let reading = Task {
            do {
                var notified = false
                for try await event in provider.answer(.init(question: "Test?", profile: "Synthetic memory", roleDescription: "", conversation: "")) {
                    if case .delta = event, !notified { opened.fulfill(); notified = true }
                }
            } catch {}
        }
        await fulfillment(of: [opened, prepared], timeout: 3)
        await provider.interrupt()
        detail.resume()
        await reading.value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(detail.answerCalls, 0)
    }
}
private enum FixtureError: Error { case unavailable }
private final class FixtureAnswerProvider: AnswerProvider, @unchecked Sendable {
    let events: [AnswerEvent]
    let prepareError: Error?
    let answerError: Error?
    var lastRequest: AnswerRequest?
    init(events: [AnswerEvent], prepareError: Error? = nil, answerError: Error? = nil) { self.events = events; self.prepareError = prepareError; self.answerError = answerError }
    func prepare() async throws { if let prepareError { throw prepareError } }
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        lastRequest = request
        return AsyncThrowingStream { stream in
            for event in events { stream.yield(event) }
            if let answerError { stream.finish(throwing: answerError) } else { stream.finish() }
        }
    }
    func interrupt() async {}
    func shutdown() {}
}

private final class WaitingDetailProvider: AnswerProvider, @unchecked Sendable {
    let prepared: XCTestExpectation
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Error>?
    private var calls = 0
    var answerCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    init(prepared: XCTestExpectation) { self.prepared = prepared }
    func prepare() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); waiter = continuation; lock.unlock(); prepared.fulfill()
        }
    }
    func resume() { lock.lock(); let next = waiter; waiter = nil; lock.unlock(); next?.resume() }
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        lock.lock(); calls += 1; lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }
    func interrupt() async {}
    func shutdown() { resume() }
}
