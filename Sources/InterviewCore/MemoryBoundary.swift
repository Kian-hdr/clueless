import Foundation

public enum MemoryBoundary {
    public static func permits(path: String, selected: [String]) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."), path.hasSuffix(".md"), selected.contains(path) else { return false }
        return path.hasPrefix("Wiki/Projects/") || path.hasPrefix("Wiki/Career/")
    }
    public static func safeExcerpt(_ text: String) -> String? {
        let lower = text.lowercased()
        let excluded = ["confidential", "restricted", "nda", "project edge", "project launcher", "api_key", "api key", "access_token", "bearer ", "password", "passport", "/users/", "~/", "private key", "secret", "customer agreement"]
        guard !excluded.contains(where: lower.contains) else { return nil }
        return String(text.prefix(1800))
    }
}
