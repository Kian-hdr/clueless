import SwiftUI
import AppKit
import InterviewCore

@MainActor struct TranscriptView: View {
    @ObservedObject var session: InterviewSession
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy Markdown", systemImage: "doc.on.doc", action: copy)
                Button("Save Markdown", systemImage: "square.and.arrow.down") { session.saveTranscriptSnapshot() }
            }
            .disabled(session.transcript.turns.isEmpty && session.transcriptSnapshot == nil)
            if !session.meetingNotesStatus.isEmpty {
                Text(session.meetingNotesStatus).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.transcript.turns.isEmpty && session.transcript.partial.isEmpty {
                        Text("No transcript yet.").foregroundStyle(.secondary)
                    }
                    ForEach(session.transcript.turns) { turn in
                        row(turn.text, role: turn.role, timestamp: turn.receivedAt.formatted(date: .omitted, time: .standard))
                    }
                    ForEach([AudioRole.interviewer, .you], id: \.self) { role in
                        if let text = session.transcript.partial[role], !text.isEmpty {
                            row(text, role: role, timestamp: "Transcribing…").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding(20)
    }

    private func row(_ text: String, role: AudioRole, timestamp: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(role == .you ? "Mac mic" : "Call audio").font(.subheadline.weight(.semibold))
                Text(timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(text)
        }
    }

    private func copy() {
        guard let markdown = session.transcriptSnapshot?.markdown else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(markdown, forType: .string)
    }
}
