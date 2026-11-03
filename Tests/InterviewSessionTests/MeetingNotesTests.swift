import Foundation
import XCTest
import InterviewCore
@testable import InterviewAssistant

final class MeetingNotesTests: XCTestCase {
    func testFinalizedSegmentsSaveWithChannelAndTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var notes = MeetingNotes(startedAt: start)
        notes.append(.init(role: .you, text: "Incomplete", isFinal: false, receivedAt: start))
        notes.append(.init(role: .you, text: "Check [local]\nfirst.", isFinal: true, receivedAt: start.addingTimeInterval(1.25)))
        notes.append(.init(role: .interviewer, text: "Check the remote channel.", isFinal: true, receivedAt: start.addingTimeInterval(2)))
        let file = try notes.save(directory: root)
        let markdown = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Incomplete"))
        XCTAssertTrue(markdown.contains("- [1.250] **Mac mic:** Check \\[local\\] first."), markdown)
        XCTAssertTrue(markdown.contains("- [2.000] **Call audio:** Check the remote channel."), markdown)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testSavedMarkdownCanBeListedAndFilteredThroughMCP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var notes = MeetingNotes(startedAt: start)
        notes.append(.init(role: .you, text: "Local synthetic cue.", isFinal: true, receivedAt: start.addingTimeInterval(1)))
        notes.append(.init(role: .interviewer, text: "Remote synthetic cue.", isFinal: true, receivedAt: start.addingTimeInterval(2)))
        let file = try notes.save(directory: root)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appendingPathComponent("script/clueless_mcp.py")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-c", """
            import json, pathlib, runpy, sys
            bridge = runpy.run_path(sys.argv[1])
            call = bridge["tool_result"]
            call.__globals__["NOTES_DIR"] = pathlib.Path(sys.argv[2])
            def request(name, arguments):
                result = call(name, arguments)
                if result["isError"]:
                    raise RuntimeError(result)
                return json.loads(result["content"][0]["text"])
            listing = request("clueless_list_saved_sessions", {})
            session = listing["sessions"][0]["session_id"]
            assert session == sys.argv[3]
            result = request("clueless_fetch_transcript", {
                "session_id": session, "start_seconds": 1.5, "end_seconds": 2
            })
            print(result["markdown"])
            """, script.path, root.path, file.deletingPathExtension().lastPathComponent]
        let output = Pipe()
        python.standardOutput = output
        try python.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "- [2.000] **Call audio:** Remote synthetic cue.\n")
    }

    func testCaptionImportPreservesCueOffsets() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        let fixtures = [
            "1\r\n00:01:02,500 --> 00:01:03,000\r\nExample cue.\r\n",
            "WEBVTT\n\n01:02.500 --> 01:03.000 align:start\nExample cue.\n"
        ]
        for fixture in fixtures {
            try fixture.write(to: source, atomically: true, encoding: .utf8)
            let notes = try MeetingNotes.fromCaptions(source)
            XCTAssertEqual(notes.rows, ["- [62.500] **Caption:** Example cue."])
        }
    }
}
