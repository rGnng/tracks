import SwiftUI
import AppKit

enum MiniPlayerMetrics {
    static let width: CGFloat = 320
    static let cover: CGFloat = 320
    static let middle: CGFloat = 42
    static let bottom: CGFloat = 30
    static let queue: CGFloat = 201
    static var baseHeight: CGFloat { cover + middle + bottom }
}

/// Switches the single main window between the full Library and the compact
/// MiniPlayer. There is deliberately no second main window.
@MainActor
final class WindowModeCenter: ObservableObject {
    enum Mode {
        case library
        case miniPlayer
    }

    static let shared = WindowModeCenter()

    @Published private(set) var mode: Mode = .library
    @Published private(set) var miniQueueExpanded = false

    private weak var window: NSWindow?

    /// The single main window. Exposed so the private title-bar height hook only
    /// applies to it and not to Settings/Get Info windows.
    var mainWindow: NSWindow? { window }
    private var libraryFrame: NSRect?
    private var miniBaseWindowHeight: CGFloat?
    private let libraryMinSize = NSSize(width: 1040, height: 640)
    private static let libraryFrameKey = "WindowMode.libraryFrame"

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.libraryFrameKey) {
            let frame = NSRectFromString(stored)
            if frame.width > 0, frame.height > 0 {
                libraryFrame = frame
            }
        }
    }

    func register(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if mode == .miniPlayer {
            applyMini(animated: false)
        } else {
            applyLibrary(animated: false)
        }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        refreshTitlebarLayout()
        switch newMode {
        case .library:
            applyLibrary(animated: true)
        case .miniPlayer:
            applyMini(animated: true)
        }
    }

    private func refreshTitlebarLayout() {
        guard let window else { return }
        refreshBrowserTitlebarLayout(for: window)
    }

    private func applyMini(animated: Bool) {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        miniQueueExpanded = false
        if !window.styleMask.contains(.fullScreen) {
            libraryFrame = window.frame
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.libraryFrameKey)
        }
        let miniSize = NSSize(width: MiniPlayerMetrics.width, height: MiniPlayerMetrics.baseHeight)
        window.styleMask.remove(.resizable)
        window.minSize = miniSize
        window.maxSize = NSSize(width: MiniPlayerMetrics.width,
                                height: MiniPlayerMetrics.baseHeight + MiniPlayerMetrics.queue + 30)

        if !window.styleMask.contains(.fullScreen) {
            let topLeft = NSPoint(x: window.frame.minX,
                                  y: window.frame.maxY)
            var frame = window.frame
            frame.size = miniSize
            frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - miniSize.height)
            frame = window.constrainFrameRect(frame, to: window.screen)
            window.setFrame(frame, display: true, animate: animated)
            miniBaseWindowHeight = window.frame.height
        }
    }

    func toggleMiniQueue() {
        setMiniQueueExpanded(!miniQueueExpanded)
    }

    func setMiniQueueExpanded(_ expanded: Bool) {
        guard mode == .miniPlayer else { return }
        guard expanded != miniQueueExpanded else { return }
        if expanded {
            miniBaseWindowHeight = window?.frame.height ?? miniBaseWindowHeight
        }
        miniQueueExpanded = expanded
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let base = miniBaseWindowHeight ?? MiniPlayerMetrics.baseHeight
        let targetHeight = base + (expanded ? MiniPlayerMetrics.queue : 0)
        let top = window.frame.maxY
        var frame = window.frame
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        frame = window.constrainFrameRect(frame, to: window.screen)
        window.setFrame(frame, display: true, animate: true)
    }

    private func applyLibrary(animated: Bool) {
        guard let window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
        miniQueueExpanded = false
        miniBaseWindowHeight = nil
        window.styleMask.insert(.resizable)
        window.minSize = libraryMinSize
        window.maxSize = NSSize(width: 10000, height: 10000)
        guard let target = libraryFrame, !window.styleMask.contains(.fullScreen) else { return }
        let constrained = window.constrainFrameRect(target, to: window.screen)
        window.setFrame(constrained, display: true, animate: animated)
    }

    /// Called on normal app termination. Quitting while the MiniPlayer is
    /// visible must not overwrite the Library frame saved when entering Mini.
    func persistLibraryFrameIfNeeded() {
        guard mode == .library,
              let window,
              !window.styleMask.contains(.fullScreen) else { return }
        libraryFrame = window.frame
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.libraryFrameKey)
    }
}
