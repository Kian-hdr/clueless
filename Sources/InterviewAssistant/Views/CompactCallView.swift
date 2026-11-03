import SwiftUI
import AppKit

/// The in-call surface stays read-only and compact. Editing, diagnostics, source
/// material, and code belong to the deliberately opened workspace window.
struct CompactCallView: View {
    @ObservedObject var session: InterviewSession
    @ObservedObject var surface: CallSurfaceState
    var openWorkspace: () -> Void
    var openSettings: () -> Void
    var useOpaquePreview = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var answerTextSize: Double = 16

    var body: some View {
        surfaces
            .padding(12)
            .frame(width: surface.expanded ? 444 : 364, height: surface.expanded ? 336 : 76, alignment: .top)
            .animation(nil, value: surface.expanded)
    }

    private var surfaces: some View {
        VStack(spacing: 10) {
            capsule
            if surface.expanded {
                answerCard
            }
        }
    }

    private var capsule: some View {
        HStack(spacing: 4) {
            ZStack {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(statusColor)
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                CallPanelDragHandle()
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(statusTitle). Drag to move assistant.")

            iconButton(session.isListening || session.isStarting ? "pause.fill" : "play.fill",
                       label: session.isStarting ? "Cancel connection" : session.isListening ? "Pause listening" : "Start listening",
                       help: "Listen or pause (⌘⇧Space)") {
                if session.isListening || session.isStarting { session.stop() } else { session.start() }
            }
            iconButton("bolt.fill", label: "Answer now", help: "Answer the latest question (⌘⇧Return)") { session.answerNow() }
                .disabled(!canAnswer)
            iconButton(surface.expanded ? "chevron.up" : "chevron.down",
                       label: surface.expanded ? "Collapse answer" : "Show answer",
                       help: surface.expanded ? "Collapse without pausing" : "Show the opening answer") {
                surface.toggleExpanded()
            }
            iconButton("slider.horizontal.3", label: "Open settings", help: "Open settings and the rest of the workspace", action: openSettings)
            iconButton("xmark", label: "Close assistant", help: "Close the floating assistant; restore from the menu bar (⌘⇧H)") { surface.hide() }
        }
        .padding(.horizontal, 12)
        .frame(width: 340, height: 52)
        .modifier(CallGlassSurface(shape: Capsule(), reduceTransparency: reduceTransparency || useOpaquePreview, reduceMotion: reduceMotion))
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(session.error == nil ? session.answer.topic : errorTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if session.answer.isCorrection && session.error == nil {
                    Label("Correction", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Correction: the question changed")
                }
                if session.error == nil && !session.answer.raw.isEmpty {
                    Button("Details", systemImage: "arrow.up.right", action: openWorkspace)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .focusable(false)
                        .help("Open supporting detail, code, and sources")
                }
            }

            ScrollView {
                MarkdownAnswerView(cardText, fontSize: answerTextSize + min(1, max(-2, session.textSize - 20)))
                    .foregroundStyle(session.error == nil ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        }
        .padding(16)
        .frame(width: 420, height: 250)
        .modifier(CallGlassSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), reduceTransparency: reduceTransparency || useOpaquePreview, reduceMotion: reduceMotion))
    }

    private var cardText: String {
        if let error = session.error { return error }
        if session.isListening && session.notetakerOnly { return "Collecting finalized transcript segments. Pause to save the transcript locally." }
        if !session.answer.paragraph.isEmpty { return session.answer.paragraph }
        if session.isAnswering { return "Preparing your opening answer…" }
        return session.isListening ? "Listening for the next question. Your opening answer will appear here." : "Start listening when the interview begins."
    }
    private var canAnswer: Bool {
        guard !session.notetakerOnly else { return false }
        return !session.manualPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !(session.transcript.partial[.interviewer] ?? "").isEmpty ||
        session.transcript.turns.contains(where: { $0.role == .interviewer && !$0.text.isEmpty })
    }

    private var statusTitle: String {
        if session.profileStatus.hasPrefix("Preview") { return session.isAnswering ? "Preview · preparing" : "Preview · audio off" }
        if session.error != nil { return errorTitle }
        if session.isStarting { return "Connecting" }
        if session.isAnswering { return "Preparing" }
        if session.isListening { return session.notetakerOnly ? "Taking notes" : "Listening" }
        return "Clueless"
    }
    private var errorTitle: String {
        guard let error = session.error else { return "Needs attention" }
        if !session.hasKey || error.contains("approved CV") { return "Setup needed" }
        if error.localizedCaseInsensitiveContains("audio") || error.localizedCaseInsensitiveContains("microphone") { return "Audio needs restart" }
        if error.contains("question") { return "Question needed" }
        return "Needs attention"
    }

    private var statusSymbol: String {
        if session.error != nil { return "exclamationmark.circle.fill" }
        if session.isAnswering { return "sparkle" }
        return session.isListening || session.isStarting ? "waveform" : "waveform.circle"
    }

    private var statusColor: Color {
        if session.error != nil { return .orange }
        return session.isListening ? .green : .secondary
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .accessibilityLabel(label)
        .help(help)
    }
}

private struct CallGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let reduceTransparency: Bool
    let reduceMotion: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(.separator.opacity(0.6), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(reduceMotion ? .regular : .regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }
}

/// Only the non-control status/grip region participates in dragging. The panel
/// controller owns focus policy; this view never activates the application.
private struct CallPanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            toolTip = "Drag to move assistant"
            setAccessibilityRole(.group)
            setAccessibilityLabel("Move assistant")
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
