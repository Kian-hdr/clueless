import SwiftUI
import AppKit
import InterviewCore

enum WorkspaceSection: String, CaseIterable { case answer = "Answer", question = "Question", transcript = "Transcript", setup = "Setup", metrics = "Metrics" }
@MainActor final class WorkspaceState: ObservableObject { @Published var section: WorkspaceSection = .answer }

/// Deliberately opened secondary workspace. The in-call UI is CompactCallView.
@MainActor struct ContentView: View {
    @ObservedObject var session: InterviewSession
    @ObservedObject var workspace: WorkspaceState
    var showWidget: () -> Void
    init(session: InterviewSession, workspace: WorkspaceState? = nil, showWidget: @escaping () -> Void = {}) {
        self.session = session; self.workspace = workspace ?? WorkspaceState(); self.showWidget = showWidget
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Clueless", systemImage: "waveform").font(.headline)
                Spacer()
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Button("Show widget", systemImage: "rectangle.on.rectangle", action: showWidget)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            TabView(selection: $workspace.section) {
                answerView.tabItem { Label("Answer", systemImage: "text.bubble") }.tag(WorkspaceSection.answer)
                questionView.tabItem { Label("Question", systemImage: "text.cursor") }.tag(WorkspaceSection.question)
                TranscriptView(session: session)
                    .tabItem { Label("Transcript", systemImage: "waveform") }.tag(WorkspaceSection.transcript)
                SetupView(session: session).tabItem { Label("Setup", systemImage: "slider.horizontal.3") }.tag(WorkspaceSection.setup)
                ScrollView { Text(session.metrics.report).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                    .tabItem { Label("Metrics", systemImage: "gauge.with.dots.needle.bottom.50percent") }.tag(WorkspaceSection.metrics)
            }.padding(12)
            Divider()
            Text("Share only the chosen application window. A floating widget is not guaranteed invisible in desktop capture.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }.frame(minWidth: 560, minHeight: 480)
    }
    private var answerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text(session.answer.raw.isEmpty ? "Your answer will appear in the floating widget." : session.answer.topic).font(.title3.weight(.semibold))
                if let previous = session.answer.previousParagraph { Text("Previous wording").font(.caption).foregroundStyle(.secondary); MarkdownAnswerView(previous, fontSize: session.textSize).foregroundStyle(.secondary) }
                MarkdownAnswerView(session.answer.paragraph, fontSize: session.textSize).textSelection(.enabled)
                if !session.answer.detail.isEmpty { Divider(); Text("Supporting detail & code").font(.headline); MarkdownAnswerView(session.answer.detail, fontSize: 14).textSelection(.enabled) }
                if let detail = session.memoryDetail { Divider(); Text("Memory follow-up").font(.headline); MarkdownAnswerView(detail, fontSize: 14).textSelection(.enabled) }
                if !session.memorySources.isEmpty { Divider(); Text("Context references").font(.caption).foregroundStyle(.secondary); ForEach(session.memorySources, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) } }
                Stepper("Reading text: \(Int(session.textSize)) pt", value: $session.textSize, in: 14...32).font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
    private var questionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Question or coding prompt").font(.headline)
            TextEditor(text: $session.manualPrompt).font(.system(size: 14, design: .monospaced)).border(.separator.opacity(0.4)).accessibilityLabel("Question or coding prompt")
            HStack {
                Button("Try sample question") { session.trySample(); showWidget() }
                Spacer()
                Button("Answer now", systemImage: "bolt.fill") { session.answerNow(); showWidget() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            Text("The sample uses OpenAI and Codex without recording audio. Answers also appear in the widget.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}
