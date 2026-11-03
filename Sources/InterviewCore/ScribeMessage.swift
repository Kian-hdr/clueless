import Foundation

public enum ScribeError: LocalizedError {
    case provider(String)
    case disconnected
    public var errorDescription: String? {
        switch self {
        case .provider(let text): return "Transcription: \(text)"
        case .disconnected: return "Transcription disconnected. Start a new session to reconnect."
        }
    }
}
public enum ScribeMessage {
    public static func decode(_ message: String, role: AudioRole) throws -> TranscriptEvent? {
        guard let data = message.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["message_type"] as? String else { return nil }
        if type == "partial_transcript" || type == "committed_transcript" {
            return TranscriptEvent(role: role, text: object["text"] as? String ?? "", isFinal: type == "committed_transcript")
        }
        if type == "error" || type.contains("error") || ["rate_limited", "invalid_request", "quota_exceeded", "auth_error", "session_time_limit_exceeded", "input_error"].contains(type) {
            // Do not echo a provider response that might contain credentials or audio.
            throw ScribeError.provider(type)
        }
        return nil
    }
    public static func audioMessage(_ data: Data) throws -> String {
        let object: [String: Any] = ["message_type": "input_audio_chunk", "audio_base_64": data.base64EncodedString(), "sample_rate": 16000]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
