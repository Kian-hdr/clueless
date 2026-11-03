#!/usr/bin/env python3
"""Bounded synthetic test through the bundled native helper and protected runner."""
import argparse
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT = r'''
import Foundation
@main struct Probe {
    static func main() async {
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let fast = ProtectedFastAnswerProvider(helperURL: helper)
        let profile = "Fictional candidate. Built small Swift applications and a task-cancellation test harness. Has never managed an engineering team. No degree or employment history is verified. " + (0..<20).map { "Synthetic project \($0): designed a small personal application, wrote tests, and documented limitations. No commercial customers or revenue are claimed." }.joined(separator: "\n")
        let questions = ["How would you explain a hash table lookup?", "Wie würden Sie den Abbruch einer asynchronen Aufgabe testen?", "Tell me about your experience managing a 50-person engineering team."]
        let limit = min(3, max(1, Int(ProcessInfo.processInfo.environment["CLUELESS_FAST_PROBE_LIMIT"] ?? "3") ?? 3))
        do {
            try await fast.prepare()
            for question in questions.prefix(limit) {
                try await measure(fast, question: question, profile: profile, path: "native-fast-opening")
            }
            if ProcessInfo.processInfo.environment["CLUELESS_FAST_PROBE_DETAIL"] == "1" {
                let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/InterviewAssistant/Benchmarks/Hybrid")
                let codex = CodexAnswerProvider(runtimeRoot: runtime, model: "gpt-6-luna")
                let combined = OpeningAndDetailProvider(opening: fast, detail: codex)
                try await combined.prepare()
                try await measure(combined, question: "Write a Python function for binary search on a sorted list; return -1 when absent. Explain complexity.", profile: profile, path: "fast-opening-plus-codex-code")
                combined.shutdown()
            }
            fast.shutdown()
        } catch {
            fast.shutdown()
            print("NATIVE_FAST_PROBE_FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
    static func measure(_ provider: AnswerProvider, question: String, profile: String, path: String) async throws {
        let start = Date()
        var presentation = AnswerPresentation()
        var first: Double?, visible: Double?, sentence: Double?, paragraph: Double?
        var apiInput = 0, apiOutput = 0, codexInput = 0, codexOutput = 0
        var notices: [String] = []
        for try await event in provider.answer(.init(question: question, profile: profile, roleDescription: "Software interview", conversation: "")) {
            let elapsed = Date().timeIntervalSince(start)
            switch event {
            case .delta(let text):
                if first == nil { first = elapsed }
                presentation.append(text)
                if visible == nil && !presentation.paragraph.isEmpty { visible = elapsed }
                if sentence == nil && presentation.hasFirstSentence { sentence = elapsed }
                if paragraph == nil && presentation.paragraphComplete { paragraph = elapsed }
            case .resetIncompleteOpening: presentation.resetIncompleteOpening()
            case .usage(let input, let output): codexInput += input; codexOutput += output
            case .apiUsage(let input, let output): apiInput += input; apiOutput += output
            case .notice(let notice): notices.append(notice)
            case .completed: if paragraph == nil { paragraph = elapsed }
            }
        }
        let value: [String: Any] = ["path": path, "question": question, "firstDeltaSeconds": first ?? -1, "firstVisibleTextSeconds": visible ?? -1, "firstSentenceSeconds": sentence ?? -1, "paragraphSeconds": paragraph ?? -1, "completeSeconds": Date().timeIntervalSince(start), "apiInputTokens": apiInput, "apiOutputTokens": apiOutput, "codexInputTokens": codexInput, "codexOutputTokens": codexOutput, "notices": notices]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
        print("SYNTHETIC_ANSWER_BEGIN\n\(presentation.raw)\nSYNTHETIC_ANSWER_END")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--include-detail", action="store_true", help="Add one bounded Codex coding question")
    args = parser.parse_args()
    helper = ROOT / "dist/Clueless.app/Contents/Helpers/CluelessFastAnswer"
    if not helper.is_file():
        raise SystemExit("Build the bundled native helper with script/build_and_run.sh --build-only first.")
    sources = ["Contracts.swift", "InterviewLogic.swift", "CodexAnswerProvider.swift", "ProtectedFastAnswerProvider.swift", "OpeningAndDetailProvider.swift"]
    with tempfile.TemporaryDirectory(prefix="clueless_native_fast_probe_") as folder:
        work = pathlib.Path(folder)
        harness = work / "Probe.swift"
        harness.write_text(SWIFT)
        binary = work / "Probe"
        subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", *[str(ROOT / "Sources/InterviewCore" / name) for name in sources], str(harness), "-o", str(binary)], check=True, timeout=90)
        env = dict(os.environ)
        if args.include_detail:
            env["CLUELESS_FAST_PROBE_DETAIL"] = "1"
        subprocess.run([str(binary), str(helper)], env=env, check=True, timeout=180)


if __name__ == "__main__":
    main()
