import SwiftUI
import AppKit

// MARK: - Menu model

struct AppMenuItem: Identifiable {
    enum Kind {
        case action
        case toggle
        case separator
        case header
        case label
    }

    let id = UUID()
    var kind: Kind
    var title: String = ""
    var isEnabled = true
    var isDestructive = false
    var isOn = false
    var isIndented = false
    var action: (() -> Void)?

    var height: CGFloat {
        switch kind {
        case .separator: return 9
        case .header: return 20
        case .action, .toggle, .label: return 24
        }
    }

    static func action(_ title: String,
                       enabled: Bool = true,
                       destructive: Bool = false,
                       indented: Bool = false,
                       _ action: @escaping () -> Void) -> AppMenuItem {
        AppMenuItem(kind: .action,
                    title: title,
                    isEnabled: enabled,
                    isDestructive: destructive,
                    isIndented: indented,
                    action: action)
    }

    static func toggle(_ title: String,
                       isOn: Bool,
                       _ action: @escaping () -> Void) -> AppMenuItem {
        AppMenuItem(kind: .toggle, title: title, isOn: isOn, action: action)
    }

    static var separator: AppMenuItem { AppMenuItem(kind: .separator) }
    static func header(_ title: String) -> AppMenuItem { AppMenuItem(kind: .header, title: title) }
    static func label(_ title: String) -> AppMenuItem { AppMenuItem(kind: .label, title: title) }
}

/// Right-click menu replacement. Native NSMenu always uses the system accent
/// color, so these are drawn by us to keep the app Highlights setting.
struct AppContextMenuOverlay: NSViewRepresentable {
    var items: () -> [AppMenuItem]

    func makeNSView(context: Context) -> ContextMenuCatcherView {
        let view = ContextMenuCatcherView()
        view.items = items
        return view
    }

    func updateNSView(_ view: ContextMenuCatcherView, context: Context) {
        view.items = items
    }
}

final class ContextMenuCatcherView: NSView {
    var items: () -> [AppMenuItem] = { [] }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent, isContextClick(event) {
            return super.hitTest(point)
        }
        // Hit testing can run before `NSApp.currentEvent` is populated. Check
        // the physical button state as well so right/control-click still lands.
        let buttons = NSEvent.pressedMouseButtons
        let rightDown = buttons & 0x2 != 0
        let controlLeft = buttons & 0x1 != 0 && NSEvent.modifierFlags.contains(.control)
        return rightDown || controlLeft ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        present(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            present(event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func isContextClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || event.type == .rightMouseUp
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    private func present(_ event: NSEvent) {
        let menuItems = items()
        guard !menuItems.isEmpty else { return }
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow)
            ?? NSEvent.mouseLocation
        ContextMenuController.shared.show(items: menuItems, at: screenPoint)
    }
}

extension View {
    /// Replaces SwiftUI's native `.contextMenu` so the hovered item uses the
    /// app's highlight color instead of the system accent.
    func appContextMenu(_ items: @escaping () -> [AppMenuItem]) -> some View {
        overlay(AppContextMenuOverlay(items: items))
    }
}

/// Queue-row menu shared by the main and mini queue panels.
@MainActor
func queueSongMenuItems(for song: Song) -> [AppMenuItem] {
    let player = PlayerState.shared
    let library = Library.shared
    let albumID = library.song(withID: song.id)?.album.id
    let source = library.song(withID: song.id)?.song ?? song
    let albumArtist = source.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
    let artistTarget = albumArtist.isEmpty ? source.artist : albumArtist
    let isInQueue = player.queue.contains { $0.id == song.id }

    return [
        .action("Play Next", enabled: player.currentSong?.id != song.id) {
            player.playNextFromQueue(song)
        },
        .action("Go to Album", enabled: albumID != nil) {
            guard let albumID else { return }
            NavigationCenter.shared.albumToOpen = albumID
        },
        .action("Go to Artist", enabled: !artistTarget.isEmpty) {
            guard !artistTarget.isEmpty else { return }
            NavigationCenter.shared.artistToOpen = artistTarget
        },
        .separator,
        .action("Delete from Queue", enabled: isInQueue, destructive: true) {
            player.removeFromQueue(song)
        },
    ]
}

/// Flattened Add to Playlist section used by custom context menus.
@MainActor
func addToPlaylistMenuItems(songs: [Song]) -> [AppMenuItem] {
    let library = Library.shared
    var items: [AppMenuItem] = [
        .header("Add to Playlist"),
        .action("New Playlist", enabled: !songs.isEmpty) {
            let playlist = library.createPlaylistWithUniqueName()
            library.addToPlaylist(playlist.id, songs: songs)
        },
    ]

    if library.playlists.isEmpty {
        items.append(.label("No Playlists"))
    } else {
        for playlist in library.playlists {
            items.append(.action(playlist.name, enabled: !songs.isEmpty, indented: true) {
                library.addToPlaylist(playlist.id, songs: songs)
            })
        }
    }
    return items
}

// MARK: - Menu panel

@MainActor
final class ContextMenuController {
    static let shared = ContextMenuController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private var state: ContextMenuState?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    func show(items: [AppMenuItem], at screenPoint: NSPoint) {
        guard !items.isEmpty else { return }
        dismiss()

        let width: CGFloat = 250
        let height = AppContextMenuView.height(for: items)
        let size = NSSize(width: width, height: height)
        let state = ContextMenuState(items: items)
        self.state = state

        let root = AppContextMenuView(items: items, state: state) { [weak self] item in
            self?.dismiss()
            item.action?()
        }
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(origin: .zero, size: size)

        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.setContentSize(size)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            var origin = NSPoint(x: screenPoint.x + 2, y: screenPoint.y - size.height)
            if origin.y < visible.minY {
                origin.y = screenPoint.y
            }
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            if origin.x + size.width > visible.maxX {
                origin.x = screenPoint.x - size.width
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
        panel.orderFront(nil)

        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.dismiss()
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    /// Called from the app's existing key monitor before normal shortcuts so
    /// arrow/Return/Escape reach the menu even though its panel is not key.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let state else { return false }
        switch event.keyCode {
        case 53: // Escape
            dismiss()
        case 125: // Down
            state.moveHighlight(by: 1)
        case 126: // Up
            state.moveHighlight(by: -1)
        case 36, 76: // Return / Enter
            if let item = state.highlightedItem, item.isEnabled {
                dismiss()
                item.action?()
            }
        default:
            break
        }
        // While a menu is open it owns the keyboard, like a native NSMenu.
        return true
    }

    func dismiss() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        state = nil
    }
}

@MainActor
private final class ContextMenuState: ObservableObject {
    @Published var highlightedID: UUID?
    let items: [AppMenuItem]

    init(items: [AppMenuItem]) {
        self.items = items
    }

    var highlightedItem: AppMenuItem? {
        guard let highlightedID else { return nil }
        return items.first { $0.id == highlightedID }
    }

    func moveHighlight(by delta: Int) {
        let actionable = items.filter {
            ($0.kind == .action || $0.kind == .toggle) && $0.isEnabled
        }
        guard !actionable.isEmpty else {
            highlightedID = nil
            return
        }
        if let current = highlightedID,
           let index = actionable.firstIndex(where: { $0.id == current }) {
            highlightedID = actionable[(index + delta + actionable.count) % actionable.count].id
        } else {
            highlightedID = delta > 0 ? actionable.first?.id : actionable.last?.id
        }
    }
}

private struct AppContextMenuView: View {
    let items: [AppMenuItem]
    @ObservedObject var state: ContextMenuState
    let onSelect: (AppMenuItem) -> Void

    static func height(for items: [AppMenuItem]) -> CGFloat {
        10 + items.reduce(0) { $0 + $1.height }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.vertical, 5)
        .frame(width: 250, height: Self.height(for: items), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.divider.opacity(0.65), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ item: AppMenuItem) -> some View {
        switch item.kind {
        case .separator:
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .frame(height: item.height)
        case .header:
            Text(item.title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: item.height)
        case .label:
            Text(item.title)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText.opacity(0.65))
                .padding(.leading, 10 + (item.isIndented ? 14 : 0))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: item.height)
        case .action, .toggle:
            menuRow(item)
        }
    }

    private func menuRow(_ item: AppMenuItem) -> some View {
        let hovered = item.isEnabled && state.highlightedID == item.id
        return HStack(spacing: 6) {
            Group {
                if item.kind == .toggle, item.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 12)

            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundColor(textColor(item, hovered: hovered))
        .padding(.leading, 8 + (item.isIndented ? 14 : 0))
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: item.height)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hovered ? Theme.selectionFill : Color.clear)
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            guard item.isEnabled else { return }
            state.highlightedID = inside
                ? item.id
                : (state.highlightedID == item.id ? nil : state.highlightedID)
        }
        .onTapGesture {
            guard item.isEnabled else { return }
            onSelect(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func textColor(_ item: AppMenuItem, hovered: Bool) -> Color {
        if !item.isEnabled { return Theme.secondaryText.opacity(0.5) }
        if hovered { return Theme.highlightForeground }
        return item.isDestructive ? .red : Theme.primaryText
    }
}
