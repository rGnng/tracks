import AppKit
import Combine
import SwiftUI

/// Menu-bar icon and the transient track/star popup.
@MainActor
final class TrayController: NSObject {
    static let shared = TrayController()

    enum DefaultsKey {
        static let enabled = "tray.enabled"
        static let trackChange = "tray.trackChange"
        static let starChange = "tray.starChange"
        static let onlyWhenLibraryNotFocused = "tray.onlyWhenLibraryNotFocused"
        static let popupDurationMs = "tray.popupDurationMs"
    }

    private var statusItem: NSStatusItem?
    private var popupPanel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSongID: UUID?
    private var lastStarred: Bool?
    private var started = false

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            DefaultsKey.enabled: false,
            DefaultsKey.trackChange: false,
            DefaultsKey.starChange: true,
            DefaultsKey.onlyWhenLibraryNotFocused: true,
            DefaultsKey.popupDurationMs: 1500,
        ])
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        let player = PlayerState.shared
        lastSongID = player.currentSong?.id
        lastStarred = lastSongID.map { Library.shared.isStarred(songID: $0) }
        observePlayer()
    }

    func refresh() {
        refreshStatusItem()
        if !enabled {
            hidePopup()
        }
    }

    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    private var trackChangeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.trackChange)
    }

    private var starChangeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.starChange)
    }

    private var onlyWhenLibraryNotFocused: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.onlyWhenLibraryNotFocused)
    }

    private var popupDurationMs: Int {
        max(300, UserDefaults.standard.integer(forKey: DefaultsKey.popupDurationMs))
    }

    private func refreshStatusItem() {
        guard enabled else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }

        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "opticaldisc.fill", accessibilityDescription: "Tracks")
            ?? NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "Tracks")
            ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Tracks")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Tracks"
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Show Tracks", action: #selector(showTracks)))
        menu.addItem(menuItem(title: "Hide Tracks", action: #selector(hideTracks)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Tracks", action: #selector(quitTracks)))
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showTracks() {
        WindowModeCenter.shared.showWindow()
    }

    @objc private func hideTracks() {
        WindowModeCenter.shared.hideWindow()
    }

    @objc private func quitTracks() {
        NSApp.terminate(nil)
    }

    private func observePlayer() {
        let player = PlayerState.shared
        player.$currentIndex
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.currentSongChanged() }
            }
            .store(in: &cancellables)
        player.$queue
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.currentSongChanged() }
            }
            .store(in: &cancellables)

        Library.shared.$starredSongIDs
            .sink { [weak self] ids in
                guard let self, let song = PlayerState.shared.currentSong else { return }
                let starred = ids.contains(song.id)
                let changed = starred != self.lastStarred
                self.lastStarred = starred
                if changed, self.starChangeEnabled {
                    self.showPopup()
                }
            }
            .store(in: &cancellables)
    }

    private func currentSongChanged() {
        let id = PlayerState.shared.currentSong?.id
        let changed = id != lastSongID
        lastSongID = id
        lastStarred = id.map { Library.shared.isStarred(songID: $0) }
        if changed, id != nil, trackChangeEnabled {
            showPopup()
        }
    }

    private var libraryIsFocused: Bool {
        guard WindowModeCenter.shared.mode == .library,
              let window = WindowModeCenter.shared.mainWindow else { return false }
        return window.isVisible && window.isKeyWindow
    }

    private func showPopup() {
        guard enabled, let song = PlayerState.shared.currentSong else { return }
        if onlyWhenLibraryNotFocused, libraryIsFocused { return }

        let isStarred = Library.shared.isStarred(songID: song.id)
        let view = TrayPopupView(song: song, isStarred: isStarred)
        let size = NSSize(width: 300, height: 63)

        if popupPanel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            popupPanel = panel
        }

        guard let panel = popupPanel else { return }
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(size)
        position(panel: panel, size: size)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hidePopup()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(popupDurationMs) / 1000,
                                      execute: work)
    }

    private func position(panel: NSPanel, size: NSSize) {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                             y: visible.maxY - size.height - 4))
            }
            return
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = buttonFrame.minY - 4
        let y = max(visible.minY + 8, top - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hidePopup() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        popupPanel?.orderOut(nil)
    }
}

private struct TrayPopupView: View {
    let song: Song
    let isStarred: Bool

    private var subtitle: String {
        if song.album.isEmpty { return song.artist }
        if song.artist.isEmpty { return song.album }
        return "\(song.artist) — \(song.album)"
    }

    var body: some View {
        VStack(spacing: 0) {
            UpTriangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 14, height: 7)
                .overlay(
                    UpTriangle()
                        .stroke(Color.black.opacity(0.14), lineWidth: 0.5)
                )
            HStack(spacing: 9) {
                AlbumArtwork(artwork: Library.shared.artwork(forAlbumTitle: song.album))
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(song.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isStarred ? Theme.highlight : Theme.secondaryText)
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .frame(width: 300, height: 63, alignment: .top)
    }
}

private struct UpTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
