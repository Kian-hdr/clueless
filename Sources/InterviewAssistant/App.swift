import SwiftUI
import AppKit
import InterviewCore

@main struct InterviewAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("Clueless", systemImage: "bubble.left") {
            CluelessMenu(session: delegate.session, delegate: delegate)
        }
    }
}

private struct CluelessMenu: View {
    @ObservedObject var session: InterviewSession
    let delegate: AppDelegate
    var body: some View {
        Button("Show assistant", systemImage: "rectangle.on.rectangle") { delegate.showWidget() }
        Button("Open workspace", systemImage: "macwindow") { delegate.openWorkspace() }
        Button("Setup…", systemImage: "slider.horizontal.3") { delegate.openWorkspace(section: .setup) }
        Divider()
        Button(session.isListening ? "Pause listening" : "Start listening") { session.isListening || session.isStarting ? session.stop() : session.start() }
        Button("Answer now") { session.answerNow() }.disabled(session.notetakerOnly)
        Divider()
        Toggle("Start as notetaker on launch", isOn: $session.startAsNotetaker)
        if session.collectingMeetingNotes {
            Button("Save meeting transcript") { session.saveMeetingNotes() }
                .disabled(session.isListening || session.isStarting)
            Button("Discard unsaved meeting notes") { session.discardMeetingNotes() }
                .disabled(session.notetakerOnly && (session.isListening || session.isStarting))
        } else {
            Button("Collect meeting notes") { session.startMeetingNotes() }
        }
        Button("Import captions…") { delegate.importCaptions() }
        if !session.meetingNotesStatus.isEmpty { Text(session.meetingNotesStatus) }
        Divider()
        Button("Quit Clueless") { NSApp.terminate(nil) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let session: InterviewSession
    let surface = CallSurfaceState()
    let workspace = WorkspaceState()
    private var callPanel: CallPanelController?
    private var workspaceWindow: NSWindow?
    private var hotkeys: GlobalHotkeys?
    private var localControl: LocalControl?

    override init() { session = InterviewSession(); super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A background call companion: no automatic workspace or Dock activation.
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        localControl = try? LocalControl(session: session)
        callPanel = CallPanelController(session: session, surface: surface, openWorkspace: { [weak self] in self?.openWorkspace() }, openSettings: { [weak self] in self?.openWorkspace(section: .setup) })
        showWidget()
        hotkeys = GlobalHotkeys { [weak self] action in
            guard let self else { return }
            switch action {
            case 1: self.session.answerNow()
            case 2: self.session.isListening || self.session.isStarting ? self.session.stop() : self.session.start()
            default: self.callPanel?.toggleVisibility()
            }
        }
        if session.startAsNotetaker { session.start(notetaker: true) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.prepareToQuit() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { localControl?.stop(); session.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Closing the companion is sticky. A routine app activation must not
        // resurrect it; the menu-bar action and shortcut explicitly restore it.
        if !surface.hidden { showWidget() }
        return false
    }
    func importCaptions() {
        let panel = NSOpenPanel()
        panel.message = "Select an SRT or WebVTT caption file to save as a local transcript."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.importMeetingCaptions(url)
    }
    func showWidget() { callPanel?.show() }
    func openWorkspace(section: WorkspaceSection? = nil) {
        workspace.section = section ?? (session.error != nil ? .setup : session.answer.raw.isEmpty ? .question : .answer)
        if workspaceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Clueless Workspace"
            window.minSize = NSSize(width: 580, height: 500)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.contentView = NSHostingView(rootView: ContentView(session: session, workspace: workspace, showWidget: { [weak self] in self?.showWidget() }))
            window.center()
            workspaceWindow = window
        }
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Show Clueless", action: #selector(showFromMenu), keyEquivalent: "") .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clueless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        main.addItem(editItem)
        let fileItem = NSMenuItem(); let file = NSMenu(title: "File"); fileItem.submenu = file
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.insertItem(fileItem, at: 1); NSApp.mainMenu = main
    }
    @objc private func showFromMenu() { showWidget() }
}
