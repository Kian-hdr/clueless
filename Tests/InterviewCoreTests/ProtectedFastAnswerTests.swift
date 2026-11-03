import XCTest
@testable import InterviewCore

final class ProtectedFastAnswerTests: XCTestCase {
    func testFakeBrokerStreamsAndCancellationNeverLeaksOlderAnswer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("helper.py"), broker = folder.appendingPathComponent("broker.py")
        let helperSource = """
        #!/usr/bin/python3
        import json, sys, time
        def emit(value):
            raw = (json.dumps(value, ensure_ascii=False) + '\\n').encode()
            for index in range(0, len(raw), 7):
                sys.stdout.buffer.write(raw[index:index+7]); sys.stdout.buffer.flush()
        request = json.load(sys.stdin)
        if request['question'] == 'Error':
            emit({'type': 'error', 'code': 'RAW_SENSITIVE_ERROR_MUST_NOT_ESCAPE'})
            sys.exit(1)
        if request['question'] == 'Hold':
            emit({'type': 'delta', 'text': 'Old partial'})
            time.sleep(8)
            emit({'type': 'delta', 'text': 'STALE MUST NOT APPEAR'})
        else:
            emit({'type': 'delta', 'text': 'TOPIC: Grüße\\n\\nThe newest answer.'})
        emit({'type': 'usage', 'input': 12, 'output': 9})
        emit({'type': 'completed', 'serviceTier': 'fast'})
        """
        let brokerSource = """
        #!/usr/bin/python3
        import os, sys
        assert 'CLUELESS_TEST_UNRELATED_SECRET' not in os.environ
        assert 'OPENAI_API_KEY' not in os.environ
        if sys.argv[1:] == ['list']:
            print('openai/synthetic-test\\tOPENAI_API_KEY')
        else:
            assert sys.argv[1:3] == ['openai/synthetic-test', '--']
            os.execv(sys.argv[3], [sys.argv[3]])
        """
        try Data(helperSource.utf8).write(to: helper); try Data(brokerSource.utf8).write(to: broker)
        for url in [helper, broker] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        setenv("CLUELESS_TEST_UNRELATED_SECRET", "synthetic", 1)
        defer { unsetenv("CLUELESS_TEST_UNRELATED_SECRET") }
        let provider = ProtectedFastAnswerProvider(helperURL: helper, brokerURL: broker)
        defer { provider.shutdown() }
        try await provider.prepare()
        let partial = expectation(description: "Old response started")
        let old = Task {
            var output = ""
            do {
                for try await event in provider.answer(AnswerRequest(question: "Hold", profile: "", roleDescription: "", conversation: "")) {
                    if case .delta(let text) = event { output += text; partial.fulfill() }
                }
            } catch { }
            return output
        }
        await fulfillment(of: [partial], timeout: 3)
        var output = "", completed = false, tier = ""
        for try await event in provider.answer(AnswerRequest(question: "Newest", profile: "", roleDescription: "", conversation: "")) {
            switch event {
            case .delta(let text): output += text
            case .notice(let text): tier = text
            case .completed: completed = true
            case .resetIncompleteOpening: XCTFail("Unexpected reset from a single provider")
            case .usage, .apiUsage: break
            }
        }
        let oldOutput = await old.value
        XCTAssertEqual(oldOutput, "Old partial")
        XCTAssertEqual(output, "TOPIC: Grüße\n\nThe newest answer.")
        XCTAssertTrue(completed)
        XCTAssertTrue(tier.contains("fast"))
        do {
            for try await _ in provider.answer(AnswerRequest(question: "Error", profile: "", roleDescription: "", conversation: "")) { }
            XCTFail("An error frame must fail the stream")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("RAW_SENSITIVE"))
            XCTAssertTrue(error.localizedDescription.contains("helper_failure"))
        }
    }
    func testAliasDiscoveryRequiresUniqueOpenAIEnvironmentMatch() throws {
        let listing = "custom/other\tAPI_KEY\nopenai/example\tOPENAI_API_KEY\n"
        XCTAssertEqual(try ProtectedAliasResolver.resolve(listing, requested: nil), "openai/example")
        XCTAssertThrowsError(try ProtectedAliasResolver.resolve(listing + "openai/second\tOPENAI_API_KEY\n", requested: nil))
        XCTAssertThrowsError(try ProtectedAliasResolver.resolve("openai/example\tWRONG\n", requested: nil))
        XCTAssertThrowsError(try ProtectedAliasResolver.resolve(listing, requested: "openai/missing"))
        XCTAssertEqual(try ProtectedAliasResolver.resolve(listing + "openai/second\tOPENAI_API_KEY\n", requested: "openai/second"), "openai/second")
    }

    func testFramesHandleFragmentedUTF8AndRejectUnboundedContent() throws {
        var decoder = FastHelperFrameDecoder()
        let data = Data("{\"type\":\"delta\",\"text\":\"Grüße\"}\n{\"type\":\"completed\",\"serviceTier\":\"priority\"}\n".utf8)
        let split = data.firstIndex(of: 0xc3)! + 1
        XCTAssertTrue(try decoder.append(data.prefix(split)).isEmpty)
        let events = try decoder.append(data.suffix(from: split))
        XCTAssertEqual(events.count, 2)
        if case .delta(let text) = events[0] { XCTAssertEqual(text, "Grüße") } else { XCTFail() }
        if case .completed(let tier) = events[1] { XCTAssertEqual(tier, "priority") } else { XCTFail() }
        var bounded = FastHelperFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try bounded.append(Data(repeating: 65, count: 9)))
    }

    func testSSERejectsIncompleteResponseAndToolItems() throws {
        var incomplete = FastResponseAccumulator()
        XCTAssertThrowsError(try incomplete.consume(["type": "response.incomplete"]))
        var tool = FastResponseAccumulator()
        XCTAssertThrowsError(try tool.consume(["type": "response.output_item.added", "item": ["type": "function_call"]]))
        var missing = FastResponseAccumulator()
        XCTAssertThrowsError(try missing.consume(["type": "response.completed", "response": ["status": "completed"]]))
    }

    func testSSERequiresTextUsageAndExplicitSuccessfulCompletion() throws {
        var response = FastResponseAccumulator()
        let delta = try response.consume(["type": "response.output_text.delta", "delta": "TOPIC: Lookup\n\nAn answer."])
        XCTAssertEqual(delta.count, 1)
        let completion = try response.consume(["type": "response.completed", "response": ["status": "completed", "service_tier": "fast", "usage": ["input_tokens": 18, "output_tokens": 9]]])
        XCTAssertEqual(completion.count, 2)
        XCTAssertTrue(response.completed)
    }
}
