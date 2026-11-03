import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var session: InterviewSession
    @State private var apiKey = ""
    var body: some View {
        Form {
            Section("ElevenLabs") {
                SecureField(session.hasKey ? "Replace API key" : "API key", text: $apiKey).textFieldStyle(.roundedBorder).onSubmit(saveKey)
                HStack {
                    Button("Save to Keychain", action: saveKey).disabled(apiKey.isEmpty)
                    Text(session.hasKey ? "Saved on this Mac" : "No standalone credential yet").font(.caption).foregroundStyle(.secondary)
                }
                Text("Two realtime streams. Grant coverage and provider retention depend on your account. No raw audio is saved locally.").font(.caption).foregroundStyle(.secondary)
                Text(session.providerStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Interview context") {
                HStack { Text(session.profileStatus); Spacer(); Button("Select personal Vault…", action: selectVault) }
                Text("The approved CV is hash-checked. Selected memory excerpts are sent to OpenAI for answers and checked detail.").font(.caption).foregroundStyle(.secondary)
                Toggle("Personal memory", isOn: Binding(get: { session.memoryEnabled }, set: session.setMemoryEnabled))
                HStack { Text("\(session.memoryNotePaths.count) selected personal project/career notes").font(.caption); Spacer(); Button("Select safe notes…", action: selectNotes) }
                Text(session.memoryStatus).font(.caption).foregroundStyle(.secondary)
                Text("Role description").font(.caption)
                TextEditor(text: $session.roleDescription).font(.system(size: 12)).frame(minHeight: 60)
                Picker("Spoken language", selection: $session.language) { Text("English / German automatically").tag("auto"); Text("English").tag("en"); Text("German").tag("de") }
            }
            Section("Answers & controls") {
                Text("Fast openings use the protected OpenAI connection, with separate API usage. Codex checks detail and code. If the connection is unavailable, Clueless uses Codex for the complete answer.").font(.caption).foregroundStyle(.secondary)
                Text("⌘⇧Return Answer · ⌘⇧Space Listen / pause · ⌘⇧H Hide / show").font(.system(size: 11, design: .monospaced))
                Text("Collapse and hide preserve the session. Pause stops audio capture.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.error { Section { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) } }
        }.formStyle(.grouped)
    }
    private func saveKey() { session.saveKey(apiKey); if session.hasKey { apiKey = "" } }
    private func selectVault() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Select your personal Vault folder"
        if panel.runModal() == .OK, let url = panel.url { session.loadProfile(root: url) }
    }
    private func selectNotes() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText]; panel.directoryURL = PrivateSettings.defaultVault.appendingPathComponent("Wiki/Projects")
        panel.message = "Choose interview-safe personal project/career Markdown notes. Relevant excerpts may be sent to OpenAI."
        if panel.runModal() == .OK { session.selectMemoryNotes(panel.urls) }
    }
}
