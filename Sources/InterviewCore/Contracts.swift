import Foundation

public enum AudioRole: String, Codable, Sendable { case interviewer, you }
public struct AudioChunk: Sendable {
    public let role: AudioRole
    public let pcm16: Data
    public let capturedAt: Date
    public init(role: AudioRole, pcm16: Data, capturedAt: Date = Date()) { self.role = role; self.pcm16 = pcm16; self.capturedAt = capturedAt }
}
public struct TranscriptEvent: Sendable {
    public let role: AudioRole
    public let text: String
    public let isFinal: Bool
    public let receivedAt: Date
    public init(role: AudioRole, text: String, isFinal: Bool, receivedAt: Date = Date()) { self.role = role; self.text = text; self.isFinal = isFinal; self.receivedAt = receivedAt }
}
public enum AnswerLanguage: String, Sendable {
    case automatic = "auto", english = "en", german = "de"

    public var instruction: String {
        switch self {
        case .automatic: return "Use German if the interview question is in German. Otherwise use English. Never answer in another language."
        case .english: return "Write the entire answer in English, even if the transcript contains other languages."
        case .german: return "Write the entire answer in German, even if the transcript contains other languages."
        }
    }
}

public struct AnswerRequest: Sendable {
    public let question: String
    public let profile: String
    public let roleDescription: String
    public let conversation: String
    public let openingAnswer: String?
    public let language: AnswerLanguage
    public init(question: String, profile: String, roleDescription: String, conversation: String, openingAnswer: String? = nil, language: AnswerLanguage = .automatic) { self.question = question; self.profile = profile; self.roleDescription = roleDescription; self.conversation = conversation; self.openingAnswer = openingAnswer; self.language = language }
}
public enum AnswerEvent: Sendable {
    case delta(String)
    case resetIncompleteOpening
    case completed
    case usage(input: Int, output: Int)
    case apiUsage(input: Int, output: Int)
    case notice(String)
}
public protocol AnswerProvider: AnyObject {
    func prepare() async throws
    func answer(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error>
    func interrupt() async
    func shutdown()
}
public enum TranscriptionStatus: Sendable {
    case connected(String)
    case failed(String)
}

@MainActor public protocol TranscriptionProvider: AnyObject {
    var onTranscript: ((TranscriptEvent) -> Void)? { get set }
    var onStatus: ((AudioRole, TranscriptionStatus) -> Void)? { get set }
    func connect(apiKey: String, language: String) async throws
    func send(_ chunk: AudioChunk)
    func disconnect()
}
