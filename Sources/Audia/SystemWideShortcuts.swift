import AppKit
import Carbon

/// Registers shortcuts that must work while Tracks is not focused.
///
/// Carbon hot keys are used instead of `NSEvent` global monitors because they
/// work without requiring Accessibility permission and consume the key before
/// it reaches the foreground app.
@MainActor
final class SystemWideShortcutCenter {
    static let shared = SystemWideShortcutCenter()

    private static let signature = OSType(0x54524B53) // "TRKS"

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: ShortcutAction] = [:]

    private init() {
        installHandler()
    }

    func start() {
        reload()
    }

    func reload() {
        unregisterAll()

        for (offset, binding) in KeyboardShortcutStore.loadBindings().enumerated() {
            guard binding.scope == .systemWide,
                  let action = binding.action,
                  let shortcut = binding.shortcut else { continue }
            let id = UInt32(offset + 1)
            if register(shortcut, id: id) {
                actions[id] = action
            }
        }
    }

    fileprivate func handle(id: UInt32) {
        actions[id]?.perform()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        SystemWideShortcutCenter.shared.handle(id: hotKeyID.id)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    @discardableResult
    private func register(_ shortcut: KeyboardShortcut, id: UInt32) -> Bool {
        guard let keyCode = shortcut.keyCode else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers(shortcut.modifierFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        return true
    }

    private func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
