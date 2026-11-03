import Foundation
import Security
import CryptoKit

enum PrivateSettings {
    private static let service = "com.kiankonrad.InterviewAssistant"
    static func apiKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "elevenlabs", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func saveAPIKey(_ value: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "elevenlabs"]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw SettingsError.keychain(status) }
        } else if result != errSecSuccess { throw SettingsError.keychain(result) }
    }
    static var defaultVault: URL {
        if let path = UserDefaults.standard.string(forKey: "personalVaultRoot") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Clueless_Vault")
    }
    static func loadApprovedProfile(root: URL) throws -> (text: String, version: String) {
        // The canonical note is checked first; only its approved machine pointer is followed.
        let note = root.appendingPathComponent("Wiki/Career/CV.md")
        let noteText = try String(contentsOf: note, encoding: .utf8)
        guard noteText.contains("Approved_CV.json") else { throw SettingsError.profile("Canonical CV note has no approved pointer.") }
        let pattern = #"(?:Output|Wiki)/[A-Za-z0-9_./-]*Approved_CV\.json"#
        guard let range = noteText.range(of: pattern, options: .regularExpression) else { throw SettingsError.profile("Canonical CV note has no portable approved-pointer path.") }
        let relative = String(noteText[range])
        let pointerURL = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard pointerURL.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw SettingsError.profile("CV pointer leaves the selected personal Vault.") }
        let directory = pointerURL.deletingLastPathComponent()
        let data = try Data(contentsOf: pointerURL)
        guard let pointer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              pointer["default_for_future_cv_use"] as? Bool == true,
              let name = pointer["markdown"] as? String, !name.contains("/"), !name.contains(".."),
              let expectedHash = pointer["markdown_sha256"] as? String,
              let version = pointer["approved_version"] as? String else { throw SettingsError.profile("Approved CV metadata is incomplete.") }
        let markdown = try Data(contentsOf: directory.appendingPathComponent(name))
        let hash = SHA256.hash(data: markdown).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash else { throw SettingsError.profile("Approved CV hash does not match. Reload after the canonical pointer is updated.") }
        guard let text = String(data: markdown, encoding: .utf8) else { throw SettingsError.profile("CV Markdown is not UTF-8.") }
        return (text, version)
    }
}

enum SettingsError: LocalizedError {
    case keychain(OSStatus)
    case profile(String)
    var errorDescription: String? {
        switch self { case .keychain(let code): return "Keychain could not save the credential (\(code))."; case .profile(let text): return text }
    }
}
