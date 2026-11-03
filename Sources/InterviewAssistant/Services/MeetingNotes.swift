import Foundation
import InterviewCore

struct MeetingNotes {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Clueless/Meeting Notes", isDirectory: true)
    static let maxBytes = 2_000_000

    let startedAt: Date
    let source: String
    private(set) var rows: [String] = []
    private(set) var reachedLimit = false
    private var byteCount = 0

    init(startedAt: Date = Date(), source: String = "Live call") {
        self.startedAt = startedAt
        self.source = source
    }

    static func fromCaptions(_ url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let captions = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        var notes = MeetingNotes(source: "Imported captions")
        let normalized = captions.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains(" --> ") }),
                  timingIndex <= 1,
                  let timestamp = lines[timingIndex].components(separatedBy: " --> ").first,
                  let offset = captionOffset(timestamp) else { continue }
            notes.append(text: lines.dropFirst(timingIndex + 1).joined(separator: " "), offset: offset, label: "Caption")
        }
        guard !notes.rows.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return notes
    }

    private static func captionOffset(_ timestamp: String) -> Double? {
        let fields = timestamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count),
              let minutes = Int(fields[fields.count - 2]), (0..<60).contains(minutes),
              let seconds = Double(fields[fields.count - 1]), (0..<60).contains(seconds) else { return nil }
        let hours = fields.count == 3 ? Int(fields[0]) ?? -1 : 0
        guard (0...9999).contains(hours) else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    mutating func append(_ event: TranscriptEvent) {
        guard event.isFinal else { return }
        append(text: event.text, offset: event.receivedAt.timeIntervalSince(startedAt),
               label: event.role == .you ? "Mac mic" : "Call audio")
    }

    mutating func append(text: String, offset: TimeInterval, label: String) {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !reachedLimit else { return }
        let escaped = line.reduce(into: "") { result, character in
            if "\\`*_{}[]<>#~|!".contains(character) { result.append("\\") }
            result.append(character)
        }
        let row = String(format: "- [%.3f] **%@:** %@", locale: Locale(identifier: "en_US_POSIX"), max(0, offset), label, escaped)
        guard byteCount + row.utf8.count + 1 <= Self.maxBytes - 512 else { reachedLimit = true; return }
        byteCount += row.utf8.count + 1
        rows.append(row)
    }

    var markdown: String {
        let timing = source == "Imported captions" ? "Caption timestamps mark cue start." : "Live timestamps mark receipt of a finalized segment."
        let header = "# Meeting transcript\n\nSource: \(source)\n\nCreated: \(ISO8601DateFormatter().string(from: startedAt))\n\nTimestamps are elapsed seconds. \(timing)\n\n"
        let footer = reachedLimit ? "\n\nTranscript truncated at the local size limit.\n" : "\n"
        return header + rows.joined(separator: "\n") + footer
    }

    func save(directory: URL = Self.directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard info.isDirectory == true, info.isSymbolicLink == false,
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              attributes[.posixPermissions] as? Int == 0o700 else { throw CocoaError(.fileWriteNoPermission) }
        let id = UUID().uuidString.lowercased()
        let file = directory.appendingPathComponent(id).appendingPathExtension("md")
        let pending = directory.appendingPathComponent(".\(id).pending")
        // Create with private permissions before writing any content.
        let fd = Darwin.open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(markdown.utf8))
            try handle.close()
            try FileManager.default.moveItem(at: pending, to: file)
            return file
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: pending)
            throw error
        }
    }
}
