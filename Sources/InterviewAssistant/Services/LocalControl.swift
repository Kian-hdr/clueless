import Foundation
import Network

@MainActor final class LocalControl {
    private let listener: NWListener
    private let lockFD: Int32

    init(session: InterviewSession) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clueless-control", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard values.isDirectory == true, values.isSymbolicLink == false,
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              attributes[.posixPermissions] as? Int == 0o700 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let fd = Darwin.open(directory.appendingPathComponent("app.lock").path,
                             O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            let endpoint = directory.appendingPathComponent("app.sock")
            var existing = stat()
            if lstat(endpoint.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid(),
                      unlink(endpoint.path) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            } else if errno != ENOENT {
                throw CocoaError(.fileWriteNoPermission)
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: endpoint.path)
            listener = try NWListener(using: parameters)
            lockFD = fd
        } catch {
            Darwin.close(fd)
            throw error
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                Task { @MainActor in
                    guard let command = data?.first else {
                        connection.cancel()
                        return
                    }
                    let response = Self.handle(command, session: session)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }
        listener.start(queue: .main)
    }

    deinit { Darwin.close(lockFD) }

    func stop() {
        listener.cancel()
    }

    private static func handle(_ command: UInt8, session: InterviewSession) -> Data {
        switch command {
        case 116: // t: current finalized transcript, explicitly requested
            let markdown = session.transcriptSnapshot?.markdown ?? ""
            return (try? JSONSerialization.data(withJSONObject: ["markdown": markdown]))
                ?? Data(#"{"error":"Could not read transcript"}"#.utf8)
        case 115: break // s: status
        case 108: session.start() // l: listen
        case 112: session.stop() // p: pause
        case 101, 100, 97: // e: English, d: German, a: automatic
            guard !session.isStarting, !session.isListening else {
                return Data(#"{"error":"Pause listening before changing the transcription language"}"#.utf8)
            }
            session.language = command == 101 ? "en" : command == 100 ? "de" : "auto"
        default: return Data(#"{"error":"Unknown control command"}"#.utf8)
        }
        let metrics = session.metrics
        return (try? JSONSerialization.data(withJSONObject: [
            "listening": session.isListening,
            "connecting": session.isStarting,
            "answering": session.isAnswering,
            "has_error": session.error != nil,
            "language": session.language,
            "start_as_notetaker": session.startAsNotetaker,
            "notetaker_only": session.notetakerOnly,
            "collecting_meeting_notes": session.collectingMeetingNotes,
            "memory_enabled": session.memoryEnabled,
            "selected_memory_note_count": session.memoryNotePaths.count,
            "memory_source_count": session.memorySources.count,
            "metrics": metrics.report,
            "audio_seconds_by_channel": Dictionary(uniqueKeysWithValues: metrics.audioSeconds.map { ($0.key.rawValue, $0.value) }),
            "partial_events_by_channel": Dictionary(uniqueKeysWithValues: session.partialTranscriptEvents.map { ($0.key.rawValue, $0.value) }),
            "finalized_events_by_channel": Dictionary(uniqueKeysWithValues: session.finalizedTranscriptEvents.map { ($0.key.rawValue, $0.value) }),
            "mic_suppressed_answer_attempts": session.micSuppressedAnswerAttempts
        ])) ?? Data(#"{"error":"Could not read status"}"#.utf8)
    }
}
