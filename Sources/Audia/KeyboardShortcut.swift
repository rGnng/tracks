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
    /// Physical key code, used by Carbon system-wide hot keys. Older persisted
    /// shortcuts may not have one.
    var keyCode: UInt16? = nil

    static let defaultShowHide = KeyboardShortcut(key: "keyCode:64",
                                                  modifiers: [],
                                                  display: "F17",
                                                  keyCode: 64)
    static let defaultStarCurrent = KeyboardShortcut(key: "keyCode:79",
                                                     modifiers: [],
                                                     display: "F18",
                                                     keyCode: 79)
    static let defaultGoToCurrentAlbum = KeyboardShortcut(key: "j",
                                                          modifiers: [],
                                                          display: "J",
                                                          keyCode: 38)
    static let defaultMute = KeyboardShortcut(key: "m", modifiers: [], display: "M", keyCode: 46)
    static let defaultVolumeDown = KeyboardShortcut(key: "-", modifiers: [], display: "-", keyCode: 27)
    static let defaultVolumeUp = KeyboardShortcut(key: "=", modifiers: [], display: "=", keyCode: 24)
    static let defaultPlayPause = KeyboardShortcut(key: "keyCode:49",
                                                   modifiers: [],
                                                   display: "Space",
                                                   keyCode: 49)

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var rawValue: String {
        var components: [String] = []
        if modifierFlags.contains(.control) { components.append("Ctrl") }
        if modifierFlags.contains(.option) { components.append("Alt") }
        if modifierFlags.contains(.shift) { components.append("Shift") }
        if modifierFlags.contains(.command) { components.append("Cmd") }
        components.append(key)
        return components.joined(separator: "+")
    }

    init(key: String, modifiers: NSEvent.ModifierFlags, display: String, keyCode: UInt16? = nil) {
        self.key = key
        self.modifiers = modifiers.rawValue
        self.display = display
        self.keyCode = keyCode
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

    func conflicts(with other: KeyboardShortcut) -> Bool {
        let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard modifierFlags.intersection(flags) == other.modifierFlags.intersection(flags) else {
            return false
        }
        if let keyCode, let otherKeyCode = other.keyCode, keyCode == otherKeyCode {
            return true
        }
        return key == other.key
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
        keyCode = event.keyCode
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

enum ShortcutScope: String, CaseIterable, Identifiable, Codable {
    case inApp
    case systemWide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inApp: return "In-App"
        case .systemWide: return "System-wide"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case mute
    case volumeDown
    case volumeUp
    case playPause
    case nextTrack
    case previousTrack
    case showHide
    case starCurrent
    case goToCurrentAlbum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mute: return "Mute"
        case .volumeDown: return "Volume down"
        case .volumeUp: return "Volume up"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .showHide: return "Show or hide Library Window"
        case .starCurrent: return "Star/Unstar current playing"
        case .goToCurrentAlbum: return "Go to current album"
        }
    }

    var defaultShortcut: KeyboardShortcut? {
        switch self {
        case .mute: return .defaultMute
        case .volumeDown: return .defaultVolumeDown
        case .volumeUp: return .defaultVolumeUp
        case .playPause: return .defaultPlayPause
        case .nextTrack, .previousTrack: return nil
        case .showHide: return .defaultShowHide
        case .starCurrent: return .defaultStarCurrent
        case .goToCurrentAlbum: return .defaultGoToCurrentAlbum
        }
    }

    var defaultScope: ShortcutScope {
        switch self {
        case .mute, .volumeDown, .volumeUp, .playPause,
             .nextTrack, .previousTrack, .goToCurrentAlbum: return .inApp
        case .showHide, .starCurrent: return .systemWide
        }
    }

    var allowsRepeat: Bool {
        switch self {
        case .volumeDown, .volumeUp, .nextTrack, .previousTrack: return true
        default: return false
        }
    }

    @MainActor
    func perform() {
        switch self {
        case .mute:
            PlayerState.shared.toggleMute()
        case .volumeDown:
            PlayerState.shared.stepDisplayVolume(up: false)
        case .volumeUp:
            PlayerState.shared.stepDisplayVolume(up: true)
        case .playPause:
            PlayerState.shared.togglePlayPause()
        case .nextTrack:
            PlayerState.shared.next()
        case .previousTrack:
            PlayerState.shared.previous()
        case .showHide:
            WindowModeCenter.shared.toggleWindowVisibility()
        case .starCurrent:
            guard let song = PlayerState.shared.currentSong else { return }
            Library.shared.toggleStar(song.id)
        case .goToCurrentAlbum:
            NavigationCenter.shared.openCurrentAlbum()
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Identifiable {
    var id: UUID
    var action: ShortcutAction?
    var shortcut: KeyboardShortcut?
    var scope: ShortcutScope

    init(id: UUID = UUID(),
         action: ShortcutAction,
         shortcut: KeyboardShortcut?,
         scope: ShortcutScope) {
        self.id = id
        self.action = action
        self.shortcut = shortcut
        self.scope = scope
    }

    init(id: UUID = UUID(),
         action: ShortcutAction?,
         shortcut: KeyboardShortcut?,
         scope: ShortcutScope) {
        self.id = id
        self.action = action
        self.shortcut = shortcut
        self.scope = scope
    }
}

enum KeyboardShortcutStore {
    private static let bindingsKey = "shortcut.bindings.v2"

    static func loadBindings() -> [ShortcutBinding] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: bindingsKey),
           let bindings = try? JSONDecoder().decode([ShortcutBinding].self, from: data) {
            let configured = bindings.filter { $0.action != nil }
            if configured.count != bindings.count { saveBindings(configured) }
            return configured
        }

        let initial = defaultBindings
        saveBindings(initial)
        return initial
    }

    static func saveBindings(_ bindings: [ShortcutBinding]) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: bindingsKey)
    }

    private static var defaultBindings: [ShortcutBinding] {
        ShortcutAction.allCases.compactMap { action in
            guard let shortcut = action.defaultShortcut else { return nil }
            return ShortcutBinding(action: action,
                                   shortcut: shortcut,
                                   scope: action.defaultScope)
        }
    }
}

@MainActor
enum ShortcutRecorderState {
    static var isRecording = false
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut?
    var label: String = "Shortcut"
    var showsRawValue = false
    var onFocus: (() -> Void)? = nil

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = { shortcut = $0 }
        view.onFocus = onFocus
        view.setAccessibilityLabel(label)
        view.setShortcut(shortcut)
        view.setShowsRawValue(showsRawValue)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onChange = { shortcut = $0 }
        view.onFocus = onFocus
        view.setAccessibilityLabel(label)
        view.setShortcut(shortcut)
        view.setShowsRawValue(showsRawValue)
    }

    static func dismantleNSView(_ view: ShortcutRecorderView, coordinator: ()) {
        view.tearDownRecording()
    }
}

@MainActor
final class ShortcutRecorderView: NSButton {
    var onChange: ((KeyboardShortcut?) -> Void)?
    var onFocus: (() -> Void)?

    private(set) var shortcut: KeyboardShortcut?
    private var showsRawValue = false
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
        bezelStyle = .rounded
        isBordered = true
        alignment = .left
        setButtonType(.momentaryPushIn)
        font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        toolTip = "Click, then press a key combination."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut")
        setAccessibilityHelp("Click, then press a key combination.")
        refreshDisplay()
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
        refreshDisplay()
        updateAccessibilityValue()
    }

    func setShowsRawValue(_ value: Bool) {
        guard showsRawValue != value else { return }
        showsRawValue = value
        refreshDisplay()
        updateAccessibilityValue()
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
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
        refreshDisplay()
        updateAccessibilityValue()
    }

    private func finishRecording(_ value: KeyboardShortcut?) {
        shortcut = value
        onChange?(value)
        isRecording = false
        ShortcutRecorderState.isRecording = false
        refreshDisplay()
        updateAccessibilityValue()
    }

    private func cancelRecording() {
        shortcut = previousShortcut
        isRecording = false
        ShortcutRecorderState.isRecording = false
        refreshDisplay()
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        let value = isRecording ? "Recording" : (displayValue ?? "None")
        setAccessibilityValue(value)
    }

    private var displayValue: String? {
        guard let shortcut else { return nil }
        return showsRawValue ? shortcut.rawValue : shortcut.display
    }

    private func refreshDisplay() {
        title = isRecording ? "Type shortcut" : (displayValue ?? "None")
    }

    func tearDownRecording() {
        guard isRecording else { return }
        isRecording = false
        ShortcutRecorderState.isRecording = false
    }

}

@MainActor
struct ShortcutTableButton: NSViewRepresentable {
    enum Kind: Equatable {
        case add
        case remove

        var imageName: String {
            switch self {
            case .add: return "NSAddTemplate"
            case .remove: return "NSRemoveTemplate"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .add: return "Add shortcut"
            case .remove: return "Remove selected shortcut"
            }
        }
    }

    let kind: Kind
    var isEnabled = true
    var actions: [ShortcutAction] = []
    var onSelect: ((ShortcutAction) -> Void)? = nil
    var onClick: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: kind,
                    actions: actions,
                    onSelect: onSelect,
                    onClick: onClick)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .shadowlessSquare
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.image = NSImage(named: NSImage.Name(kind.imageName))
        button.image?.isTemplate = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(kind.accessibilityLabel)
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: NSButton, coordinator: Coordinator) {
        coordinator.actions = actions
        coordinator.onSelect = onSelect
        coordinator.onClick = onClick
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        let kind: Kind
        var actions: [ShortcutAction]
        var onSelect: ((ShortcutAction) -> Void)?
        var onClick: (() -> Void)?

        init(kind: Kind,
             actions: [ShortcutAction],
             onSelect: ((ShortcutAction) -> Void)?,
             onClick: (() -> Void)?) {
            self.kind = kind
            self.actions = actions
            self.onSelect = onSelect
            self.onClick = onClick
        }

        @objc func activate(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            guard kind == .add else {
                onClick?()
                return
            }

            let menu = NSMenu()
            for action in actions {
                let item = NSMenuItem(title: action.title,
                                      action: #selector(selectAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                menu.addItem(item)
            }
            guard !menu.items.isEmpty else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height),
                       in: sender)
        }

        @objc private func selectAction(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let action = ShortcutAction(rawValue: rawValue) else { return }
            onSelect?(action)
        }
    }
}
