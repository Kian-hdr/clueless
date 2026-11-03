import XCTest
import CryptoKit
import SwiftUI
import InterviewCore
@testable import InterviewAssistant

final class ProfileAndMemoryTests: XCTestCase {
    func testCanonicalPointerCanMoveWithoutCodeChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let career = root.appendingPathComponent("Wiki/Career")
        let output = root.appendingPathComponent("Output/Personal/Current_CV")
        try FileManager.default.createDirectory(at: career, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("Pointer: `Output/Personal/Current_CV/Approved_CV.json`".utf8).write(to: career.appendingPathComponent("CV.md"))
        let profile = Data("Synthetic profile; no personal details.".utf8)
        let hash = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
        let pointer: [String: Any] = ["default_for_future_cv_use": true, "markdown": "CV.md", "markdown_sha256": hash, "approved_version": "fixture"]
        try JSONSerialization.data(withJSONObject: pointer).write(to: output.appendingPathComponent("Approved_CV.json"))
        try profile.write(to: output.appendingPathComponent("CV.md"))
        XCTAssertEqual(try PrivateSettings.loadApprovedProfile(root: root).version, "fixture")
        try Data("Modified content".utf8).write(to: output.appendingPathComponent("CV.md"))
        XCTAssertThrowsError(try PrivateSettings.loadApprovedProfile(root: root))
    }

    func testLiveSelectedLocalMemoryWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLUELESS_TEST_VAULT"] else { throw XCTSkip("Set CLUELESS_TEST_VAULT for a bounded local-only retrieval check") }
        let approved = try PrivateSettings.loadApprovedProfile(root: URL(fileURLWithPath: path))
        XCTAssertFalse(approved.text.isEmpty)
        XCTAssertFalse(approved.version.isEmpty)
        let env = ProcessInfo.processInfo.environment
        guard let note = env["CLUELESS_TEST_MEMORY_NOTE"], let query = env["CLUELESS_TEST_MEMORY_QUERY"] else {
            throw XCTSkip("Set a selected relative note and a matching local query.")
        }
        let result = await PersonalMemory().recall(query: query, root: URL(fileURLWithPath: path), selected: [note])
        XCTAssertFalse(result.excerpts.isEmpty, result.limitation)
        XCTAssertTrue(result.excerpts.allSatisfy { $0.relativePath == note })
        print(String(format: "Local selected-memory lookup: %.0f ms; %d verified excerpts", result.duration * 1000, result.excerpts.count))
    }

    @MainActor func testRenderSyntheticPreviewWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["CLUELESS_PREVIEW_PATH"] else {
            throw XCTSkip("No preview export requested")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let session = InterviewSession(provider: PreviewProvider(), credential: { nil }, initialProfile: "Synthetic candidate")
        session.memoryEnabled = false
        session.status = "Answer ready"
        session.question = "How would you test cancellation?"
        session.answer.append("""
            TOPIC: Testing cancellation

            I’d test when cancellation happens and what state it leaves behind.

            - **Timing:** Cancel before work, during execution, and near completion.
            - **Cleanup:** Verify resources are released and no work leaks.
            - **Races:** Repeat cancellation and check that outcomes stay consistent.
            """)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        session.transcript.apply(.init(role: .interviewer, text: "How would you test cancellation in an asynchronous task?", isFinal: true, receivedAt: start))
        session.transcript.apply(.init(role: .you, text: "I’d test timing, cleanup, and races with completion.", isFinal: true, receivedAt: start.addingTimeInterval(7)))
        session.transcript.apply(.init(role: .interviewer, text: "What would you check if the task had already completed?", isFinal: true, receivedAt: start.addingTimeInterval(14)))
        _ = NSApplication.shared

        func export<V: View>(_ root: V, size: NSSize, name: String, scheme: ColorScheme) throws {
            let frame = NSRect(origin: .zero, size: size)
            let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name))
        }

        for scheme in [ColorScheme.light, .dark] {
            let surface = CallSurfaceState()
            let suffix = scheme == .dark ? "-dark" : ""
            let backdrop = scheme == .dark ? Color.black : Color(red: 0.93, green: 0.94, blue: 0.96)
            func widget() -> some View {
                CompactCallView(session: session, surface: surface, openWorkspace: {}, openSettings: {}, useOpaquePreview: true)
                    .padding(12).background(backdrop)
            }
            try export(widget(), size: .init(width: 388, height: 100), name: "compact\(suffix).png", scheme: scheme)
            surface.toggleExpanded()
            try export(widget(), size: .init(width: 468, height: 360), name: "answer\(suffix).png", scheme: scheme)
            try export(TranscriptView(session: session).background(Color(nsColor: .windowBackgroundColor)),
                       size: .init(width: 660, height: 280), name: "transcript\(suffix).png", scheme: scheme)
        }
    }

}
private final class PreviewProvider: AnswerProvider {
    func prepare() async throws {}
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func interrupt() async {}
    func shutdown() {}
}
