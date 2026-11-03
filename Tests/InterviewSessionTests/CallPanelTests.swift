import XCTest
import AppKit
import SwiftUI
import Combine
import InterviewCore
@testable import InterviewAssistant

@MainActor final class CallPanelTests: XCTestCase {
    func testGeometryPreservesTopCenterAndClampsToVisibleScreen() {
        let visible = NSRect(x: 100, y: 200, width: 1440, height: 900)
        let anchor = NSPoint(x: 820, y: 1092)
        let collapsed = CallPanelGeometry.frame(size: CallPanelGeometry.collapsed, topCenter: anchor, visibleFrame: visible)
        let expanded = CallPanelGeometry.frame(size: CallPanelGeometry.expanded, topCenter: anchor, visibleFrame: visible)
        XCTAssertEqual(collapsed.size, NSSize(width: 364, height: 76))
        XCTAssertEqual(expanded.size, NSSize(width: 444, height: 336))
        XCTAssertEqual(expanded.midX, collapsed.midX)
        XCTAssertEqual(expanded.maxY, collapsed.maxY)
        let clamped = CallPanelGeometry.frame(size: CallPanelGeometry.expanded, topCenter: NSPoint(x: -900, y: 10000), visibleFrame: visible)
        XCTAssertTrue(visible.contains(clamped))
        let tiny = NSRect(x: -200, y: 50, width: 220, height: 170)
        XCTAssertTrue(tiny.contains(CallPanelGeometry.frame(size: CallPanelGeometry.expanded, topCenter: anchor, visibleFrame: tiny)))
    }

    func testPanelHasNonactivatingFloatingFocusPolicyAndClearBacking() {
        let (session, surface, _) = fixture()
        let controller = CallPanelController(session: session, surface: surface, openWorkspace: {}, presentationEnabled: false)
        let panel = controller.panel
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertEqual(panel.title, "Clueless Call Assistant")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.isVisible, "Property tests must not present real desktop windows")
    }

    func testCollapseAndHidePreserveSessionAndStreamingCannotReopenQuestion() async {
        let (session, surface, audio) = fixture()
        let controller = CallPanelController(session: session, surface: surface, openWorkspace: {}, presentationEnabled: false)
        let moved = controller.panel.frame.offsetBy(dx: 100, dy: -80)
        controller.panel.setFrame(moved, display: false)
        session.isListening = true
        session.question = "How would you test cancellation?"
        session.answer.append("TOPIC: Testing\n\nI would test cancellation and cleanup.")
        await settleLayout()
        XCTAssertTrue(surface.expanded)
        XCTAssertEqual(controller.panel.frame.midX, moved.midX)
        XCTAssertEqual(controller.panel.frame.maxY, moved.maxY)
        let top = controller.panel.frame.maxY, center = controller.panel.frame.midX
        surface.collapse()
        await settleLayout()
        let collapsed = controller.panel.frame
        session.answer.append(" More streaming text.")
        XCTAssertFalse(surface.expanded)
        XCTAssertEqual(controller.panel.frame, collapsed)
        XCTAssertEqual(controller.panel.frame.maxY, top)
        XCTAssertEqual(controller.panel.frame.midX, center)
        XCTAssertTrue(session.isListening)
        XCTAssertEqual(audio.stops, 0)
        controller.hide()
        session.question = "What are the edge cases?"
        session.answer = AnswerPresentation()
        session.answer.append("TOPIC: Edge cases\n\nI would start with empty input.")
        XCTAssertTrue(surface.hidden)
        XCTAssertFalse(surface.expanded)
        XCTAssertTrue(session.isListening)
        XCTAssertEqual(audio.stops, 0)
        controller.show()
        XCTAssertFalse(surface.hidden)
        controller.toggleVisibility()
        XCTAssertTrue(surface.hidden)
    }

    func testCollapsedHostingBoundsAndRootSizeMatchAfterExpandedLayout() async {
        let (session, surface, _) = fixture()
        let controller = CallPanelController(session: session, surface: surface, openWorkspace: {}, presentationEnabled: false)
        surface.toggleExpanded()
        await settleLayout()
        guard let hosting = controller.panel.contentView as? NSHostingView<CompactCallView> else { return XCTFail("Expected the native SwiftUI host") }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.panel.frame.size, CallPanelGeometry.expanded)
        XCTAssertEqual(hosting.frame.size, CallPanelGeometry.expanded)
        XCTAssertEqual(hosting.bounds.size, CallPanelGeometry.expanded)
        // Demonstrate the ordering that made synchronous native resizing unsafe:
        // @Published delivers the next value before the observed object stores it.
        var propertyWhilePublishing: Bool?
        var frameWhilePublishing: NSSize?
        let observation = surface.$expanded.dropFirst().sink { _ in
            propertyWhilePublishing = surface.expanded
            frameWhilePublishing = controller.panel.frame.size
        }
        surface.collapse()
        XCTAssertEqual(propertyWhilePublishing, true)
        XCTAssertEqual(frameWhilePublishing, CallPanelGeometry.expanded, "Do not shrink AppKit while SwiftUI still reads the expanded state")
        XCTAssertEqual(controller.panel.frame.size, CallPanelGeometry.expanded, "Native resizing is coalesced after this state transaction commits")
        await settleLayout()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.panel.frame.size, CallPanelGeometry.collapsed)
        XCTAssertEqual(hosting.frame, NSRect(origin: .zero, size: CallPanelGeometry.collapsed))
        XCTAssertEqual(hosting.bounds, NSRect(origin: .zero, size: CallPanelGeometry.collapsed))
        withExtendedLifetime(observation) {}
    }

    private func settleLayout() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    func testNewQuestionCanExpandOnceAndErrorsRespectHiddenState() {
        let (session, surface, _) = fixture()
        // Keep the controller alive while exercising its subscriptions.
        let controller = CallPanelController(session: session, surface: surface, openWorkspace: {}, presentationEnabled: false)
        session.question = "First?"
        session.answer.append("TOPIC: First\n\nThe first answer.")
        surface.collapse()
        session.question = "Second?"
        session.answer = AnswerPresentation()
        session.answer.append("TOPIC: Second\n\nThe second answer.")
        XCTAssertTrue(surface.expanded)
        surface.collapse()
        session.question = "Second?"
        session.answer = AnswerPresentation()
        session.answer.append("TOPIC: Second\n\nA retry is still a new answer.")
        XCTAssertTrue(surface.expanded)
        surface.collapse()
        session.error = "Synthetic setup issue"
        XCTAssertTrue(surface.expanded)
        controller.hide()
        surface.collapse()
        session.error = "Another synthetic issue"
        XCTAssertFalse(surface.expanded)
        XCTAssertTrue(surface.hidden)
    }

    private func fixture() -> (InterviewSession, CallSurfaceState, PanelFixtureAudio) {
        _ = NSApplication.shared
        let audio = PanelFixtureAudio()
        let session = InterviewSession(provider: PanelFixtureProvider(), audio: audio, transcriber: PanelFixtureTranscriber(), credential: { nil }, initialProfile: "Synthetic profile")
        session.memoryEnabled = false
        return (session, CallSurfaceState(), audio)
    }
}

private final class PanelFixtureProvider: AnswerProvider {
    func prepare() async throws {}
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func interrupt() async {}
    func shutdown() {}
}
@MainActor private final class PanelFixtureAudio: AudioCapturing {
    var onChunk: ((AudioChunk) -> Void)?
    var onLevel: ((AudioRole, Float) -> Void)?
    var onError: ((String) -> Void)?
    var stops = 0
    func start() async throws {}
    func stop() { stops += 1 }
}
@MainActor private final class PanelFixtureTranscriber: TranscriptionProvider {
    var onTranscript: ((TranscriptEvent) -> Void)?
    var onStatus: ((AudioRole, TranscriptionStatus) -> Void)?
    func connect(apiKey: String, language: String) async throws {}
    func send(_ chunk: AudioChunk) {}
    func disconnect() {}
}
