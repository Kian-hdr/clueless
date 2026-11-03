import XCTest
import InterviewCore
@testable import InterviewAssistant

@MainActor final class SessionLifecycleTests: XCTestCase {
    func testOldFailedStartupCannotStopNewSession() async {
        let provider = ControlledProvider()
        let audio = FakeAudio()
        let transcriber = FakeTranscriber()
        let session = InterviewSession(provider: provider, audio: audio, transcriber: transcriber, credential: { "fixture-not-a-key" }, initialProfile: "Synthetic candidate")
        session.memoryEnabled = false
        session.start()
        await waitUntil { provider.waiters.count == 1 }
        session.stop()
        session.start()
        await waitUntil { provider.waiters.count == 2 }
        provider.waiters[1].resume()
        await waitUntil { session.isListening }
        let stopCount = audio.stops
        provider.waiters[0].resume(throwing: TestError.failed)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.isListening)
        XCTAssertEqual(audio.stops, stopCount)
        session.stop()
    }
    func testStopDuringPreparationNeverStartsAudio() async {
        let provider = ControlledProvider()
        let audio = FakeAudio()
        let session = InterviewSession(provider: provider, audio: audio, transcriber: FakeTranscriber(), credential: { "fixture-not-a-key" }, initialProfile: "Synthetic candidate")
        session.memoryEnabled = false
        session.start()
        await waitUntil { provider.waiters.count == 1 }
        session.stop()
        provider.waiters[0].resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(session.isListening)
        XCTAssertEqual(audio.starts, 0)
    }
    func testRevokingMemoryCancelsPendingAnswerBeforeTransmission() async {
        let provider = ControlledProvider()
        let session = InterviewSession(provider: provider, audio: FakeAudio(), transcriber: FakeTranscriber(), credential: { "fixture-not-a-key" }, initialProfile: "Synthetic candidate")
        session.manualPrompt = "How would you test cancellation?"
        session.answerNow()
        await waitUntil { provider.waiters.count == 1 }
        session.memoryEnabled = false
        provider.waiters[0].resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(provider.answerCalls, 0)
        XCTAssertFalse(session.isAnswering)
    }
    func testIdenticalQuestionInANewSpeechSegmentIsAnsweredAgain() async {
        let first = expectation(description: "First question answered")
        let second = expectation(description: "Repeated new question answered")
        let provider = CountingQuestionProvider { count in if count == 1 { first.fulfill() }; if count == 2 { second.fulfill() } }
        let session = InterviewSession(provider: provider, audio: FakeAudio(), transcriber: FakeTranscriber(), credential: { nil }, initialProfile: "Synthetic candidate")
        session.memoryEnabled = false; session.isListening = true
        let event = TranscriptEvent(role: .interviewer, text: "How would you test cancellation?", isFinal: true)
        session.receive(event)
        await fulfillment(of: [first], timeout: 2)
        session.receive(event)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(provider.count, 2)
        session.stop()
    }
    func testFinalNonQuestionInvalidatesPendingPartial() async {
        let stale = expectation(description: "Superseded partial starts no answer")
        stale.isInverted = true
        let provider = CountingQuestionProvider { _ in stale.fulfill() }
        let session = InterviewSession(provider: provider, audio: FakeAudio(), transcriber: FakeTranscriber(), credential: { nil }, initialProfile: "Synthetic candidate")
        session.memoryEnabled = false
        session.isListening = true
        session.receive(.init(role: .interviewer, text: "How would you test cancellation", isFinal: false))
        session.receive(.init(role: .interviewer, text: "Okay", isFinal: true))
        await fulfillment(of: [stale], timeout: 0.8)
        session.stop()
    }
    func testNotetakerStartsWithoutPreparingAnswerProvider() async {
        let provider = ControlledProvider()
        let session = InterviewSession(provider: provider, audio: FakeAudio(), transcriber: FakeTranscriber(),
                                       credential: { "fixture-not-a-key" }, initialProfile: "")
        session.start(notetaker: true)
        await waitUntil { session.isListening }
        XCTAssertTrue(session.collectingMeetingNotes)
        XCTAssertTrue(session.notetakerOnly)
        XCTAssertTrue(provider.waiters.isEmpty)
        session.receive(.init(role: .interviewer, text: "How would you test this?", isFinal: true))
        XCTAssertEqual(session.finalizedTranscriptEvents[.interviewer], 1)
        XCTAssertFalse(session.isAnswering)
        session.discardMeetingNotes()
        session.stop()
        XCTAssertEqual(provider.answerCalls, 0)
    }
    func testTypedTranscriptionFailureStopsBothChannelsAndIdentifiesSource() async {
        let provider = CountingQuestionProvider { _ in }
        let audio = FakeAudio()
        let transcriber = FakeTranscriber()
        let session = InterviewSession(provider: provider, audio: audio, transcriber: transcriber,
                                       credential: { "fixture-not-a-key" }, initialProfile: "Synthetic candidate")
        session.start(notetaker: false)
        await waitUntil { session.isListening }
        transcriber.onStatus?(.you, .connected("Retrying after a failed diagnostic check."))
        XCTAssertTrue(session.isListening)
        transcriber.onStatus?(.you, .failed("Connection ended."))
        XCTAssertFalse(session.isListening)
        XCTAssertEqual(audio.stops, 1)
        XCTAssertEqual(session.error, "Mac mic: Connection ended.")
    }
    func testFinalCallQuestionIsAnsweredWhileMacMicIsActive() async {
        let answered = expectation(description: "Final call question answered")
        let provider = CountingQuestionProvider { _ in answered.fulfill() }
        let audio = FakeAudio()
        let session = InterviewSession(provider: provider, audio: audio, transcriber: FakeTranscriber(),
                                       credential: { nil }, initialProfile: "Synthetic candidate")
        session.memoryEnabled = false
        session.isListening = true
        audio.onLevel?(.you, 0.1)
        session.receive(.init(role: .you, text: "How would you handle an outage?", isFinal: true))
        session.receive(.init(role: .interviewer, text: "How would you test retries?", isFinal: true))
        await fulfillment(of: [answered], timeout: 1)
        XCTAssertEqual(provider.count, 1)
        XCTAssertEqual(session.question, "How would you test retries?")
        session.stop()
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Timed out waiting for controlled state")
    }
}
private final class CountingQuestionProvider: AnswerProvider {
    private(set) var count = 0
    let onRequest: (Int) -> Void
    init(onRequest: @escaping (Int) -> Void) { self.onRequest = onRequest }
    func prepare() async throws {}
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        count += 1; onRequest(count)
        return AsyncThrowingStream { stream in stream.yield(.delta("TOPIC: Testing\n\nA synthetic answer.")); stream.yield(.completed); stream.finish() }
    }
    func interrupt() async {}
    func shutdown() {}
}
private enum TestError: Error { case failed }
private final class ControlledProvider: AnswerProvider {
    var waiters: [CheckedContinuation<Void, Error>] = []
    var answerCalls = 0
    func prepare() async throws { try await withCheckedThrowingContinuation { waiters.append($0) } }
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> { answerCalls += 1; return AsyncThrowingStream { $0.finish() } }
    func interrupt() async {}
    func shutdown() {}
}
@MainActor private final class FakeAudio: AudioCapturing {
    var onChunk: ((AudioChunk) -> Void)?
    var onLevel: ((AudioRole, Float) -> Void)?
    var onError: ((String) -> Void)?
    var starts = 0
    var stops = 0
    func start() async throws { starts += 1 }
    func stop() { stops += 1 }
}
@MainActor private final class FakeTranscriber: TranscriptionProvider {
    var onTranscript: ((TranscriptEvent) -> Void)?
    var onStatus: ((AudioRole, TranscriptionStatus) -> Void)?
    func connect(apiKey: String, language: String) async throws {}
    func send(_ chunk: AudioChunk) {}
    func disconnect() {}
}
