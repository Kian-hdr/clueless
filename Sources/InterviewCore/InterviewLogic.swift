import Foundation

public struct TranscriptTurn: Identifiable, Sendable {
    public let id = UUID()
    public let role: AudioRole
    public let text: String
    public let receivedAt: Date
}

public struct TranscriptBuffer: Sendable {
    public private(set) var turns: [TranscriptTurn] = []
    public private(set) var partial: [AudioRole: String] = [:]
    public let maxCharacters: Int
    public init(maxCharacters: Int = 12_000) { self.maxCharacters = max(80, maxCharacters) }
    public mutating func apply(_ event: TranscriptEvent) {
        let text = String(event.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(maxCharacters / 2))
        if event.isFinal {
            partial[event.role] = nil
            if !text.isEmpty { turns.append(.init(role: event.role, text: text, receivedAt: event.receivedAt)) }
            while turns.count > 1 && turns.reduce(0, { $0 + $1.text.count + 16 }) > maxCharacters { turns.removeFirst() }
        } else { partial[event.role] = text }
    }
    public var context: String {
        let committed = turns.map { "\($0.role == .you ? "You" : "Interviewer"): \($0.text)" }
        let interim = [AudioRole.interviewer, .you].compactMap { role in partial[role].map { "\(role == .you ? "You" : "Interviewer"): \($0)" } }
        return String((committed + interim).joined(separator: "\n").suffix(maxCharacters))
    }
}

public enum QuestionPolicy {
    public static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func shouldAnswer(text: String, role: AudioRole) -> Bool {
        guard role == .interviewer else { return false }
        let normalized = normalized(text)
        guard !["thank you", "thanks", "okay", "ok", "yes", "no", "danke", "alles klar", "great", "sounds good"].contains(normalized) else { return false }
        return text.contains("?") || normalized.split(separator: " ").count >= 4 || ["why", "how", "warum", "wieso", "weshalb", "example", "beispiel"].contains(normalized)
    }
}

public struct AnswerPresentation: Sendable {
    public private(set) var raw = ""
    public private(set) var previousParagraph: String?
    public private(set) var isCorrection = false
    public init() {}
    public mutating func append(_ delta: String) { raw += delta }
    public mutating func resetIncompleteOpening() { raw = "" }
    public mutating func beginCorrection() {
        previousParagraph = paragraph.isEmpty ? previousParagraph : paragraph
        raw = ""
        isCorrection = previousParagraph != nil
    }
    public var topic: String {
        guard let first = raw.components(separatedBy: "\n").first, first.hasPrefix("TOPIC:") else { return "Suggested answer" }
        return String(first.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    }
    private var body: String {
        if !raw.contains("\n"), "TOPIC:".hasPrefix(raw) { return "" }
        let content = raw.hasPrefix("TOPIC:") ? raw.components(separatedBy: "\n").dropFirst().joined(separator: "\n") : raw
        return String(content.drop(while: { $0 == "\n" || $0 == "\r" }))
    }
    private var detailBoundary: Range<String.Index>? { body.range(of: "\n\nDETAILS:") }
    /// The complete opening can contain multiple Markdown blocks. Only the
    /// explicit DETAILS boundary separates later reasoning from the opening.
    public var paragraph: String {
        let content = body
        if let boundary = content.range(of: "\n\nDETAILS:") { return String(content[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let separator = content.range(of: "\n\n", options: .backwards) {
            let tail = String(content[separator.upperBound...])
            if !tail.isEmpty, "DETAILS:".hasPrefix(tail) { return String(content[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var detail: String {
        let content = body
        guard let boundary = content.range(of: "\n\nDETAILS:") else { return "" }
        return String(content[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var hasFirstSentence: Bool {
        paragraph.range(of: #"[.!?](?:\s|$)"#, options: .regularExpression) != nil
    }
    public var paragraphComplete: Bool { detailBoundary != nil }
}

public struct SessionMetrics: Sendable {
    public var audioSeconds: [AudioRole: Double] = [:]
    public var firstVisibleTextSeconds: [Double] = []
    public var firstSentenceSeconds: [Double] = []
    public var paragraphSeconds: [Double] = []
    public var completionSeconds: [Double] = []
    public var finalTranscriptToRequestSeconds: [Double] = []
    public var inputTokens = 0
    public var outputTokens = 0
    public var apiInputTokens = 0
    public var apiOutputTokens = 0
    public var droppedAudioChunks = 0
    public init() {}
    public var streamHours: Double { audioSeconds.values.reduce(0, +) / 3600 }
    public var firstSentenceP95: Double? { Self.p95(firstSentenceSeconds) }
    public var paragraphP95: Double? { Self.p95(paragraphSeconds) }
    public static func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    public var report: String {
        func format(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "not measured" }
        return "Final transcript → answer request p95: \(format(Self.p95(finalTranscriptToRequestSeconds))) (n=\(finalTranscriptToRequestSeconds.count))\nAnswer request → first visible text p95: \(format(Self.p95(firstVisibleTextSeconds))) (n=\(firstVisibleTextSeconds.count))\nAnswer request → first sentence p95: \(format(firstSentenceP95)) (n=\(firstSentenceSeconds.count))\nAnswer request → opening complete p95: \(format(paragraphP95)) (n=\(paragraphSeconds.count))\nAnswer request → full response p95: \(format(Self.p95(completionSeconds))) (n=\(completionSeconds.count))\nCaptured audio: \(String(format: "%.1f", streamHours * 60)) stream-minutes across both channels (not verified billed usage)\nCodex reported tokens: \(inputTokens) input / \(outputTokens) output\nDirect API reported tokens: \(apiInputTokens) input / \(apiOutputTokens) output\nGrant coverage and invoice cost: unverified. Network and provider latency are included in answer timings; question-end timing requires a reference recording."
    }
}
