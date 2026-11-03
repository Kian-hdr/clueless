import AppKit
import Carbon
import OSLog

@MainActor final class GlobalHotkeys {
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private static let logger = Logger(subsystem: "com.kiankonrad.Clueless", category: "Controls")
    let action: (UInt32) -> Void
    init(action: @escaping (UInt32) -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let object = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                GlobalHotkeys.logger.info("Shortcut triggered: id=\(id.id, privacy: .public)")
                object.action(id.id)
            }
            return noErr
        }, 1, &eventType, pointer, &handler)
        for (id, key) in [(UInt32(1), UInt32(kVK_Return)), (2, UInt32(kVK_Space)), (3, UInt32(kVK_ANSI_H))] {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x434C5545, id: id), GetApplicationEventTarget(), 0, &reference)
            GlobalHotkeys.logger.info("Shortcut registration: id=\(id, privacy: .public) status=\(status, privacy: .public)")
            if status == noErr, let reference { refs.append(reference) }
        }
    }
    deinit { refs.forEach { UnregisterEventHotKey($0) }; if let handler { RemoveEventHandler(handler) } }
}
