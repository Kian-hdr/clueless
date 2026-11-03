import Foundation
import CryptoKit
import InterviewCore

struct MemoryExcerpt: Sendable {
    let source: String
    let text: String
    let relativePath: String
    let sha256: String
    func isCurrent(root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base), let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 300_000,
              let data = try? Data(contentsOf: file) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
}
struct MemoryLookup: Sendable {
    let excerpts: [MemoryExcerpt]
    let duration: Double
    let limitation: String
}

/// Application-owned local retrieval; the language model receives no tool or filesystem access.
final class PersonalMemory: @unchecked Sendable {
    static let defaultPaths: [String] = []
    func recall(query: String, root: URL, selected: [String]) async -> MemoryLookup {
        let started = Date()
        let cleanQuery = query.components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 }.prefix(18).joined(separator: " ")
        guard !cleanQuery.isEmpty, !selected.isEmpty else { return .init(excerpts: [], duration: 0, limitation: "No selected memory notes") }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/isolinear-memory")
            process.arguments = ["recall", root.path, String(cleanQuery.prefix(500)), "--strategy", "hybrid", "--max-hits", "5", "--max-bytes", "6000"]
            process.currentDirectoryURL = root
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 2)
                timer.setEventHandler { if process.isRunning { process.terminate() } }
                timer.resume()
                defer { timer.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, data.count <= 64_000,
                      let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["ok"] as? Bool == true,
                      let result = response["data"] as? [String: Any], let hits = result["hits"] as? [[String: Any]] else {
                    return MemoryLookup(excerpts: [], duration: Date().timeIntervalSince(started), limitation: "Memory unavailable or timed out; answer uses selected profile only")
                }
                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                var excerpts: [MemoryExcerpt] = []
                for hit in hits {
                    guard let path = hit["path"] as? String, MemoryBoundary.permits(path: path, selected: selected),
                          let hash = hit["sha256"] as? String, let excerpt = hit["excerpt"] as? String,
                          let safe = MemoryBoundary.safeExcerpt(excerpt) else { continue }
                    let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                    guard file.path.hasPrefix(resolvedRoot), let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                          (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 300_000,
                          let current = try? Data(contentsOf: file), SHA256.hash(data: current).map({ String(format: "%02x", $0) }).joined() == hash else { continue }
                    let start = hit["start"] as? Int ?? 0
                    let end = hit["end"] as? Int ?? start
                    excerpts.append(.init(source: "\(path):\(start)–\(end)", text: safe, relativePath: path, sha256: hash))
                    if excerpts.count >= 3 { break }
                }
                let unsearched = result["unsearched"] as? [String] ?? []
                let truncated = result["truncated"] as? Bool ?? false
                return MemoryLookup(excerpts: excerpts, duration: Date().timeIntervalSince(started), limitation: "\(excerpts.count) selected excerpts; bounded search\(truncated ? ", truncated" : "")\(unsearched.isEmpty ? "" : "; unsearched: " + unsearched.joined(separator: ", "))")
            } catch { return MemoryLookup(excerpts: [], duration: Date().timeIntervalSince(started), limitation: "Local Isolinear CLI unavailable") }
        }.value
    }
}
