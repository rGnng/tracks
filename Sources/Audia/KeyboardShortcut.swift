import SwiftUI
import AppKit

/// A single-key/multi-modifier shortcut recorded with standard macOS key
/// handling. The matching key is the character produced by the key event, so
/// shifted symbols such as `*` work without also requiring Shift to be stored
/// separately for matching. Modifiers are retained for display.
struct KeyboardShortcut: Codable, Equatable {
    var key: String
    var modifiers: UInt
    var display: String

    static let defaultStar = KeyboardShortcut(key: "*", modifiers: [], display: "*")

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    init(key: String, modifiers: NSEvent.ModifierFlags, display: String) {
        self.key = key
        self.modifiers = modifiers.rawValue
        self.display = display
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control]
        guard modifierFlags.intersection(relevant) ==
                event.modifierFlags.intersection(relevant) else {
            return false
        }
        if key.hasPrefix("keyCode:") {
            return key == "keyCode:\(event.keyCode)"
        }
        return event.characters == key
    }

    init?(event: NSEvent) {
        guard !event.isARepeat else { return nil }
        let rawCharacters = event.characters ?? ""
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Control+letter produces a control character; show the letter instead.
        let displayCharacters = flags.contains(.control)
            ? (event.charactersIgnoringModifiers ?? rawCharacters)
            : rawCharacters
        let label = Self.keyLabel(for: event, characters: displayCharacters)
        guard !label.isEmpty else { return nil }

        key = rawCharacters.isEmpty ? "keyCode:\(event.keyCode)" : rawCharacters
        modifiers = flags.rawValue
        display = Self.displayString(label: label, flags: flags, characters: displayCharacters)
    }

    private static func displayString(label: String,
                                      flags: NSEvent.ModifierFlags,
                                      characters: String) -> String {
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        let isLetter = characters.count == 1 && characters.first?.isLetter == true
        let includeShift = flags.contains(.shift) && (isLetter || label.count > 1)
        if includeShift { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        value += isLetter ? label.uppercased() : label
        return value
    }

    private static func keyLabel(for event: NSEvent, characters: String) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        default:
            return characters
        }
    }
}

enum KeyboardShortcutStore {
    private static let legacyKey = "shortcut.starCurrent"
    private static let storageKey = "shortcut.starCurrent.v2"

    private struct Setting: Codable {
        var shortcut: KeyboardShortcut?
    }

    static func load() -> KeyboardShortcut? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey),
           let setting = try? JSONDecoder().decode(Setting.self, from: data) {
            return setting.shortcut
        }
        if let legacy = defaults.string(forKey: legacyKey) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return KeyboardShortcut(key: trimmed, modifiers: [], display: trimmed)
            }
        }
        return .defaultStar
    }

    static func save(_ shortcut: KeyboardShortcut?) {
        let setting = Setting(shortcut: shortcut)
        guard let data = try? JSONEncoder().encode(setting) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

@MainActor
enum ShortcutRecorderState {
    static var isRecording = false
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = { shortcut = $0 }
        view.setShortcut(shortcut)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onChange = { shortcut = $0 }
        view.setShortcut(shortcut)
    }

    static func dismantleNSView(_ view: ShortcutRecorderView, coordinator: ()) {
        view.tearDownRecording()
    }
}

@MainActor
final class ShortcutRecorderView: NSView {
    var onChange: ((KeyboardShortcut?) -> Void)?

    private(set) var shortcut: KeyboardShortcut?
    private var previousShortcut: KeyboardShortcut?
    private var isRecording = false
    private var resignObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        focusRingType = .default
        toolTip = "Click, then press a key combination."
        setAccessibilityRole(.button)
        setAccessibilityLabel("Star current item shortcut")
        setAccessibilityHelp("Click, then press a key combination.")
        setShortcut(.defaultStar)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        guard let window else {
            if isRecording { cancelRecording() }
            return
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.cancelRecording()
            }
        }
    }

    func setShortcut(_ value: KeyboardShortcut?) {
        guard !isRecording else { return }
        shortcut = value
        needsDisplay = true
        updateAccessibilityValue()
    }

    override func becomeFirstResponder() -> Bool {
        if !isRecording {
            beginRecording()
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        } else if !isRecording {
            beginRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        let commandLike = event.modifierFlags.intersection([.command, .option, .control])
        if event.keyCode == 53, commandLike.isEmpty {
            cancelRecording()
            return
        }

        let allModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 51 || event.keyCode == 117), allModifiers.isEmpty {
            finishRecording(nil)
            return
        }

        guard let captured = KeyboardShortcut(event: event) else { return }
        finishRecording(captured)
    }

    private func beginRecording() {
        previousShortcut = shortcut
        isRecording = true
        ShortcutRecorderState.isRecording = true
        needsDisplay = true
        updateAccessibilityValue()
    }

    private func finishRecording(_ value: KeyboardShortcut?) {
        shortcut = value
        onChange?(value)
        isRecording = false
        ShortcutRecorderState.isRecording = false
        needsDisplay = true
        updateAccessibilityValue()
    }

    private func cancelRecording() {
        shortcut = previousShortcut
        isRecording = false
        ShortcutRecorderState.isRecording = false
        needsDisplay = true
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        let value = isRecording ? "Recording" : (shortcut?.display ?? "None")
        setAccessibilityValue(value)
    }

    func tearDownRecording() {
        guard isRecording else { return }
        isRecording = false
        ShortcutRecorderState.isRecording = false
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: 5, yRadius: 5).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = isRecording ? "Type shortcut" : (shortcut?.display ?? "None")
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: shortcut == nil && !isRecording
                ? NSColor.secondaryLabelColor
                : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(x: 5,
                          y: (bounds.height - size.height) / 2,
                          width: bounds.width - 10,
                          height: size.height)
        text.draw(in: rect, withAttributes: attributes)
    }
}
