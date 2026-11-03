import XCTest
@testable import InterviewCore

final class InterviewLogicTests: XCTestCase {
    func testPartialRevisionReplacesRatherThanDuplicates() {
        var buffer = TranscriptBuffer()
        buffer.apply(.init(role: .interviewer, text: "Tell me about Swift", isFinal: false))
        buffer.apply(.init(role: .interviewer, text: "Tell me about Swift concurrency", isFinal: false))
        XCTAssertEqual(buffer.context, "Interviewer: Tell me about Swift concurrency")
        buffer.apply(.init(role: .interviewer, text: "Tell me about Swift concurrency.", isFinal: true))
        XCTAssertEqual(buffer.turns.count, 1)
        XCTAssertEqual(buffer.partial[.interviewer], nil)
    }
    func testContextStaysBoundedAndKeepsLatestTurn() {
        var buffer = TranscriptBuffer(maxCharacters: 120)
        for i in 0..<30 { buffer.apply(.init(role: .you, text: "Response number \(i) with some detail", isFinal: true)) }
        XCTAssertLessThanOrEqual(buffer.context.count, 120)
        XCTAssertTrue(buffer.context.contains("29"))
    }
    func testOwnSpeechNeverTriggersAndShortFollowupDoes() {
        XCTAssertFalse(QuestionPolicy.shouldAnswer(text: "How would you implement this?", role: .you))
        XCTAssertTrue(QuestionPolicy.shouldAnswer(text: "Why?", role: .interviewer))
        XCTAssertTrue(QuestionPolicy.shouldAnswer(text: "Wie würden Sie das testen", role: .interviewer))
        XCTAssertFalse(QuestionPolicy.shouldAnswer(text: "Thank you", role: .interviewer))
    }
    func testStableParagraphAndExplicitCorrection() {
        var answer = AnswerPresentation()
        answer.append("TOPIC: Concurrency\nI would isolate shared state.")
        XCTAssertEqual(answer.topic, "Concurrency")
        answer.append(" Then test cancellation.\n\nDETAILS:\nUse actors.")
        XCTAssertEqual(answer.paragraph, "I would isolate shared state. Then test cancellation.")
        XCTAssertEqual(answer.detail, "Use actors.")
        let previous = answer.paragraph
        answer.beginCorrection()
        answer.append("TOPIC: Correction\nI would use structured concurrency.\n\nDETAILS:\nPrefer task groups.")
        XCTAssertEqual(answer.previousParagraph, previous)
        XCTAssertTrue(answer.isCorrection)
    }
    func testTopicWithBlankLineStillStreamsParagraph() {
        var answer = AnswerPresentation()
        answer.append("TOPIC: Testing\n\nI would test cancellation first.\n\nDETAILS:\nCover cleanup.")
        XCTAssertEqual(answer.paragraph, "I would test cancellation first.")
        XCTAssertTrue(answer.hasFirstSentence)
        XCTAssertTrue(answer.paragraphComplete)
        XCTAssertEqual(answer.detail, "Cover cleanup.")
    }
    func testMarkdownOpeningPreservesScannableBlocksBeforeDetails() {
        var answer = AnswerPresentation()
        let opening = "I’d test the cancellation contract first.\n\n- **Timing:** before, during, and near completion.\n- **Cleanup:** verify resources and child tasks."
        answer.append("TOPIC: Cancellation\n\n" + opening)
        XCTAssertEqual(answer.paragraph, opening)
        XCTAssertFalse(answer.paragraphComplete)
        answer.append("\n\nDETAILS:\nUse controlled synchronization.")
        XCTAssertEqual(answer.paragraph, opening)
        XCTAssertEqual(answer.detail, "Use controlled synchronization.")
        XCTAssertTrue(answer.paragraphComplete)
    }
    func testScribeDecodesPartialFinalAndRejectsProviderErrors() throws {
        let event = try ScribeMessage.decode(#"{"message_type":"partial_transcript","text":"hello"}"#, role: .interviewer)
        XCTAssertEqual(event?.text, "hello")
        XCTAssertFalse(event!.isFinal)
        XCTAssertTrue(try ScribeMessage.decode(#"{"message_type":"committed_transcript","text":"hello"}"#, role: .you)!.isFinal)
        XCTAssertThrowsError(try ScribeMessage.decode(#"{"message_type":"rate_limited","error":"Limit"}"#, role: .you))
    }
    func testSpeechOnlyMetricsDoNotInventProviderLatency() {
        var metrics = SessionMetrics()
        metrics.audioSeconds[.interviewer] = 12
        metrics.audioSeconds[.you] = 10
        XCTAssertNil(metrics.firstSentenceP95)
        metrics.firstSentenceSeconds = [0.4, 0.7, 1.2, 2.3]
        XCTAssertEqual(metrics.firstSentenceP95, 2.3)
        XCTAssertEqual(metrics.streamHours, 22.0 / 3600, accuracy: 0.000001)
    }
}
