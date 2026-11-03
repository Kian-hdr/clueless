#!/usr/bin/env python3
"""Bounded synthetic test of the actual Swift transport; never logs auth or private context."""
import pathlib
import os
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT = r'''
import Foundation
@main struct Probe {
    static func main() async {
        let model = ProcessInfo.processInfo.environment["CLUELESS_PROBE_MODEL"] ?? "gpt-6.1-sol"
        let tier = CodexServiceTier(rawValue: ProcessInfo.processInfo.environment["CLUELESS_PROBE_TIER"] ?? "default") ?? .standard
        let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/InterviewAssistant/Benchmarks/\(model)_\(tier.rawValue)")
        let provider = CodexAnswerProvider(runtimeRoot: runtime, model: model, serviceTier: tier)
        do {
            let start = Date()
            try await provider.prepare()
            print("CODEX_READY_SECONDS=\(Date().timeIntervalSince(start))")
            let allQuestions = ["How would you explain a hash table lookup?", "Write a Python function for binary search and explain its complexity.", "Tell me about your experience managing a 50-person engineering team."]
            let limit = min(3, max(1, Int(ProcessInfo.processInfo.environment["CLUELESS_PROBE_LIMIT"] ?? "3") ?? 3))
            let questions = Array(allQuestions.prefix(limit))
            for question in questions {
                let answering = Date()
                var first: Double?, sentence: Double?, paragraph: Double?, text = ""
                for try await event in provider.answer(AnswerRequest(question: question, profile: "A synthetic candidate has built small Swift apps. No further experience is verified.", roleDescription: "Software engineering interview", conversation: "")) {
                    switch event {
                    case .delta(let delta):
                        text += delta
                        let elapsed = Date().timeIntervalSince(answering)
                        if first == nil { first = elapsed }
                        let answer = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
                        if sentence == nil && answer.range(of: #"[.!?](?:\s|$)"#, options: .regularExpression) != nil { sentence = elapsed }
                        if paragraph == nil && text.contains("DETAILS:") { paragraph = elapsed }
                    case .usage(let input, let output): print("TOKENS input=\(input) output=\(output)")
                    case .completed, .resetIncompleteOpening: break
                    case .notice, .apiUsage: break
                    }
                }
                guard text.contains("TOPIC:"), text.contains("DETAILS:"), !text.isEmpty else { throw CodexError.protocolFailure }
                let metrics: [String: Any] = ["model": model, "serviceTier": tier.rawValue, "question": question, "firstDeltaSeconds": first ?? -1, "firstSentenceSeconds": sentence ?? -1, "paragraphSeconds": paragraph ?? -1, "completeSeconds": Date().timeIntervalSince(answering), "characters": text.count]
                print(String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
                // Synthetic content can be inspected without exposing any private interview/profile.
                print("SYNTHETIC_ANSWER_BEGIN\n\(text)\nSYNTHETIC_ANSWER_END")
            }
            provider.shutdown()
        } catch {
            provider.shutdown()
            print("CODEX_PROBE_FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="clueless_codex_probe_") as folder:
    work = pathlib.Path(folder)
    harness = work / "Probe.swift"
    harness.write_text(SWIFT)
    binary = work / "Probe"
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Sources/InterviewCore/Contracts.swift"), str(ROOT / "Sources/InterviewCore/CodexAnswerProvider.swift"), str(harness), "-o", str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=160)
