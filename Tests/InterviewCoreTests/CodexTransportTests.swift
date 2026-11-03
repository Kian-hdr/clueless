import XCTest
@testable import InterviewCore

final class CodexTransportTests: XCTestCase {
    func testSpeedTierNeverSilentlyFallsBackOrChangesStandardRequests() throws {
        var standard: [String: Any] = ["model": "fixture"]
        CodexServiceTier.standard.apply(to: &standard)
        XCTAssertNil(standard["serviceTier"])
        var fastest: [String: Any] = [:]
        CodexServiceTier.ultrafast.apply(to: &fastest)
        XCTAssertEqual(fastest["serviceTier"] as? String, "ultrafast")
        XCTAssertThrowsError(try CodexServiceTier.ultrafast.validateReadback([:]))
        XCTAssertThrowsError(try CodexServiceTier.ultrafast.validateReadback(["serviceTier": "priority"]))
        XCTAssertNoThrow(try CodexServiceTier.ultrafast.validateReadback(["serviceTier": "ultrafast"]))
    }
    func testFakeProcessStreamsInOrderAndRejectsOtherThreadEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = folder.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("opaque-test-auth".utf8).write(to: source.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["models": [["slug": "gpt-6.1-sol"]]]).write(to: source.appendingPathComponent("models_cache.json"))
        let flags = String(data: try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: CodexIsolation.disabledFeatures.map { ($0, false) })), encoding: .utf8)!
        let script = """
        #!/usr/bin/python3
        import json, sys, threading, time
        lock = threading.Lock()
        counter = 0
        def emit(obj):
            line = json.dumps(obj, ensure_ascii=False) + '\\n'
            raw = line.encode('utf-8')
            with lock:
                for i in range(0, len(raw), 7):
                    sys.stdout.buffer.write(raw[i:i+7]); sys.stdout.buffer.flush()
        def delayed_reply(i):
            time.sleep(0.25)
            emit({'id': i, 'result': {}})
        for line in sys.stdin:
            m = json.loads(line); method = m.get('method'); i = m.get('id')
            if i is None: continue
            result = {}
            if method == 'account/read': result = {'account': {'type': 'chatgpt'}}
            elif method == 'config/read': result = {'config': {'features': json.loads('\(flags)'), 'mcp_servers': {}}}
            elif method == 'mcpServerStatus/list': result = {'data': [], 'nextCursor': None}
            elif method == 'thread/start':
                counter += 1
                result = {'instructionSources': [], 'sandbox': {'type': 'readOnly'}, 'thread': {'id': 'fixture-' + str(counter), 'ephemeral': True}}
            elif method == 'turn/interrupt':
                threading.Thread(target=delayed_reply, args=(i,), daemon=True).start()
                continue
            elif method == 'turn/start':
                tid = m['params']['threadId']; turn = 'turn-' + tid
                question = json.loads(m['params']['input'][0]['text'])['QUESTION']
                emit({'id': i, 'result': {'turn': {'id': turn}}})
                emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'different', 'turnId': 'old', 'delta': 'MUST NOT APPEAR'}})
                parts = ['Holding'] if question == 'Hold' else ['TOPIC: Grüße', '\\n\\n' + ('Newest answer.' if question == 'Newest' else 'A correct answer.'), '\\n\\nDETAILS:\\nMore.']
                for part in parts:
                    emit({'method': 'item/agentMessage/delta', 'params': {'threadId': tid, 'turnId': turn, 'delta': part}})
                if question != 'Hold':
                    emit({'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'completed'}}})
                continue
            emit({'id': i, 'result': result})
        """
        let executable = folder.appendingPathComponent("fake_codex.py")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let provider = CodexAnswerProvider(executableURL: executable, runtimeRoot: folder.appendingPathComponent("Runtime"), sourceHomeURL: source)
        defer { provider.shutdown() }
        try await provider.prepare()
        var output = "", completed = false
        for try await event in provider.answer(AnswerRequest(question: "Fixture?", profile: "", roleDescription: "", conversation: "")) {
            switch event {
            case .delta(let text): output += text
            case .completed: completed = true
            case .resetIncompleteOpening: XCTFail("Unexpected reset from a single provider")
            case .usage, .apiUsage, .notice: break
            }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(output, "TOPIC: Grüße\n\nA correct answer.\n\nDETAILS:\nMore.")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("Runtime/auth.json").path), source.appendingPathComponent("auth.json").path)

        let holding = expectation(description: "First answer is in progress")
        let first = Task {
            do {
                for try await event in provider.answer(AnswerRequest(question: "Hold", profile: "", roleDescription: "", conversation: "")) {
                    if case .delta = event { holding.fulfill() }
                }
            } catch { }
        }
        await fulfillment(of: [holding], timeout: 3)
        let superseded = Task { () -> String in
            var output = ""
            do {
                for try await event in provider.answer(AnswerRequest(question: "Superseded", profile: "", roleDescription: "", conversation: "")) {
                    if case .delta(let text) = event { output += text }
                }
            } catch { }
            return output
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        var newest = ""
        for try await event in provider.answer(AnswerRequest(question: "Newest", profile: "", roleDescription: "", conversation: "")) {
            if case .delta(let text) = event { newest += text }
        }
        let stale = await superseded.value
        await first.value
        XCTAssertEqual(stale, "", "A request delayed by interrupt must not overwrite its newer successor")
        XCTAssertTrue(newest.contains("Newest answer."))
    }
    func testLiveCodexSyntheticAnswerWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["RUN_INTERVIEW_LIVE_CODEX"] == "1" else { throw XCTSkip("Set RUN_INTERVIEW_LIVE_CODEX=1 for a bounded synthetic account-backed probe") }
        let provider = CodexAnswerProvider()
        defer { provider.shutdown() }
        let preparing = Date()
        try await provider.prepare()
        print("LIVE_CODEX_READY_SECONDS=\(Date().timeIntervalSince(preparing))")
        let start = Date()
        var text = "", first: Double?, completed = false
        for try await event in provider.answer(AnswerRequest(question: "How would you explain a hash table lookup?", profile: "The candidate has built small Swift applications. No other experience is verified.", roleDescription: "Software engineering interview", conversation: "")) {
            switch event {
            case .delta(let delta):
                if first == nil { first = Date().timeIntervalSince(start) }
                text += delta
            case .completed: completed = true
            case .resetIncompleteOpening: XCTFail("Unexpected reset from a single provider")
            case .usage(let input, let output): print("LIVE_CODEX_TOKENS input=\(input) output=\(output)")
            case .notice, .apiUsage: break
            }
        }
        XCTAssertTrue(completed)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.lowercased().contains("hash"))
        print("LIVE_CODEX_FIRST_DELTA_SECONDS=\(first ?? -1) COMPLETE_SECONDS=\(Date().timeIntervalSince(start)) CHARACTERS=\(text.count)")
    }
    func testLineDecoderHandlesSplitUTF8AndMultipleEvents() throws {
        var decoder = CodexLineDecoder()
        let bytes = Data("{\"delta\":\"Grüße\"}\n{\"id\":2}\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1
        XCTAssertTrue(try decoder.append(bytes.prefix(split)).isEmpty)
        let messages = try decoder.append(bytes.suffix(from: split))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["delta"] as? String, "Grüße")
    }

    func testMalformedOrExcessiveFramesFailClosed() throws {
        var decoder = CodexLineDecoder(maximumFrameBytes: 12)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 13)))
        var invalid = CodexLineDecoder()
        XCTAssertThrowsError(try invalid.append(Data("not-json\n".utf8)))
    }

    func testCatalogRemovesEveryAdvertisedCapability() throws {
        let model: [String: Any] = ["slug": "gpt-6.1-sol", "shell_type": "unified_exec", "apply_patch_tool_type": "freeform", "experimental_supported_tools": ["clock"], "tool_mode": "code_mode_only", "supports_search_tool": true]
        let sanitized = CodexIsolation.sanitize(model)
        XCTAssertEqual(sanitized["shell_type"] as? String, "disabled")
        XCTAssertTrue(sanitized["apply_patch_tool_type"] is NSNull)
        XCTAssertEqual(sanitized["experimental_supported_tools"] as? [String], [])
        XCTAssertEqual(sanitized["tool_mode"] as? String, "direct")
        XCTAssertEqual(sanitized["supports_search_tool"] as? Bool, false)
    }

    func testThreadReadbackRejectsInheritedInstructionsAndWritableSandbox() throws {
        let good: [String: Any] = ["instructionSources": [], "sandbox": ["type": "readOnly"], "thread": ["id": "test", "ephemeral": true]]
        XCTAssertNoThrow(try CodexIsolation.validateThread(good))
        var inherited = good; inherited["instructionSources"] = ["/private/AGENTS.md"]
        XCTAssertThrowsError(try CodexIsolation.validateThread(inherited))
        var writable = good; writable["sandbox"] = ["type": "dangerFullAccess"]
        XCTAssertThrowsError(try CodexIsolation.validateThread(writable))
        var persisted = good; persisted["thread"] = ["id": "test", "ephemeral": false]
        XCTAssertThrowsError(try CodexIsolation.validateThread(persisted))
    }

    func testPromptTreatsAudioAsDataAndNeverInventsExperience() {
        let prompt = CodexIsolation.instructions
        XCTAssertTrue(prompt.contains("untrusted"))
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("35–50"))
        XCTAssertFalse(prompt.contains("execute"))
    }

    func testTOMLStringDoesNotUseJSONSlashEscapes() {
        XCTAssertEqual(CodexIsolation.tomlString("/Users/example/Application Support"), "\"/Users/example/Application Support\"")
        XCTAssertEqual(CodexIsolation.tomlString("a\"b"), "\"a\\\"b\"")
    }
}
