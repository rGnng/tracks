import SwiftUI
import AppKit

enum MiniPlayerMetrics {
    static let minWidth: CGFloat = 320
    static let width: CGFloat = 320
    static let maxWidth: CGFloat = 560
    static let middle: CGFloat = 42
    static let bottom: CGFloat = 30
    static let minQueueHeight: CGFloat = 140
    static let defaultQueueHeight: CGFloat = 201
    static let maxQueueHeight: CGFloat = 500
    static let queueResizeHandleHeight: CGFloat = 20

    static func height(forWidth width: CGFloat, queueHeight: CGFloat = 0) -> CGFloat {
        width + middle + bottom + queueHeight
    }

    static var baseHeight: CGFloat { height(forWidth: width) }
}

/// Owns the Library and MiniPlayer windows. Only one is visible at a time.
/// MiniPlayer is a separate borderless window with its own hosting view.
@MainActor
final class WindowModeCenter: ObservableObject {
    enum Mode {
        case library
        case miniPlayer
    }

    static let shared = WindowModeCenter()

    @Published private(set) var mode: Mode = .library
    @Published private(set) var isFullScreen = false
    @Published private(set) var miniQueueExpanded = false
    private var isFullScreenTransitioning = false
    private var pendingMode: Mode?
    private var fullScreenExitTimeout: DispatchWorkItem?
    @Published private(set) var miniQueueHeight: CGFloat = MiniPlayerMetrics.defaultQueueHeight

    // Keep both windows alive after their last visible state so global
    // show/hide and Command-1/2 can order them back in.
    private var window: NSWindow?
    private var miniWindow: NSWindow?

    /// The single Library window. Exposed so the private title-bar height hook
    /// only applies to it and not to Settings/Get Info windows.
    var mainWindow: NSWindow? { window }
    var miniPlayerWindow: NSWindow? { miniWindow }

    var isLibraryWindowVisible: Bool {
        guard mode == .library, let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    /// True while the active window is full screen or entering/leaving full
    /// screen. Hiding the app in any of these states leaves an ownerless Space
    /// behind, so the show/hide shortcut ignores it.
    var isActiveWindowFullScreen: Bool {
        switch mode {
        case .library:
            return isFullScreen || isFullScreenTransitioning
                || (window?.styleMask.contains(.fullScreen) ?? false)
        case .miniPlayer:
            return miniWindow?.styleMask.contains(.fullScreen) ?? false
        }
    }

    private var libraryFrame: NSRect?
    private var miniWidth: CGFloat = MiniPlayerMetrics.width
    private let miniResizeDelegate = MiniResizeDelegate()
    private let libraryMinSize = NSSize(width: 1040, height: 640)
    private let miniScreenPadding: CGFloat = 12
    private static let libraryFrameKey = "WindowMode.libraryFrame"
    private static let miniWidthKey = "WindowMode.miniWidth"
    private static let miniQueueHeightKey = "WindowMode.miniQueueHeight"

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.libraryFrameKey) {
            let frame = NSRectFromString(stored)
            if frame.width > 0, frame.height > 0 {
                libraryFrame = frame
            }
        }
        if let storedWidth = UserDefaults.standard.object(forKey: Self.miniWidthKey) as? Double {
            miniWidth = CGFloat(min(max(storedWidth, Double(MiniPlayerMetrics.minWidth)),
                                   Double(MiniPlayerMetrics.maxWidth)))
        }
        if let storedQueueHeight = UserDefaults.standard.object(forKey: Self.miniQueueHeightKey) as? Double {
            miniQueueHeight = CGFloat(min(max(storedQueueHeight, Double(MiniPlayerMetrics.minQueueHeight)),
                                           Double(MiniPlayerMetrics.maxQueueHeight)))
        }
    }

    private func libraryWindowBecameKey() {
        guard mode != .library else { return }
        mode = .library
        miniQueueExpanded = false
        miniWindow?.orderOut(nil)
        NotificationCenter.default.post(name: .libraryWindowDidShow, object: window)
    }

    private func miniWindowBecameKey() {
        guard mode != .miniPlayer else { return }
        if let window,
           window.styleMask.contains(.fullScreen) || isFullScreen {
            return
        }
        if let window, window.isVisible, !window.isMiniaturized {
            libraryFrame = window.frame
            UserDefaults.standard.set(NSStringFromRect(window.frame),
                                      forKey: Self.libraryFrameKey)
        }
        mode = .miniPlayer
        miniQueueExpanded = false
        window?.orderOut(nil)
    }

    func register(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isFullScreenTransitioning = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isFullScreen = true
                self.isFullScreenTransitioning = false
                // A mode switch requested during the enter animation still
                // needs to leave the full-screen Space before showing mini.
                if self.pendingMode == .miniPlayer {
                    self.scheduleFullScreenExitTimeout()
                    window.toggleFullScreen(nil)
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isFullScreenTransitioning = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isFullScreen = false
                self.isFullScreenTransitioning = false
                self.finishPendingModeAfterFullScreenExit()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.libraryWindowBecameKey() }
        }
        window.styleMask.insert(.resizable)
        window.minSize = libraryMinSize
        window.maxSize = NSSize(width: 10000, height: 10000)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
        if let libraryFrame, !window.styleMask.contains(.fullScreen) {
            let constrained = window.constrainFrameRect(libraryFrame, to: window.screen)
            window.setFrame(constrained, display: false)
        }
    }

    func showWindow() {
        switch mode {
        case .library:
            showLibraryWindow()
        case .miniPlayer:
            showMiniPlayerWindow()
        }
    }

    func hideWindow() {
        // macOS treats a full-screen window as its own Space. Hiding the app
        // while that Space is active leaves an ownerless black Space and makes
        // unhide restore the wrong state. Match the system Command-H behavior
        // and ignore hide requests during full screen.
        guard !isActiveWindowFullScreen else { return }
        // Hide the whole application, like Command-H. This deactivates Tracks
        // and returns focus to the previous app instead of leaving an empty
        // active app with its player window merely ordered out.
        NSApp.hide(nil)
    }

    func toggleWindowVisibility() {
        let current: NSWindow? = mode == .miniPlayer ? miniWindow : window
        guard let current else {
            showWindow()
            return
        }
        if !NSApp.isHidden, current.isVisible, !current.isMiniaturized {
            guard !isActiveWindowFullScreen else { return }
            hideWindow()
        } else {
            showWindow()
        }
    }

    func setMode(_ newMode: Mode) {
        if newMode == .library {
            pendingMode = nil
            fullScreenExitTimeout?.cancel()
            fullScreenExitTimeout = nil
        } else if pendingMode == .miniPlayer {
            return
        }

        guard newMode != mode else {
            if newMode == .miniPlayer {
                showMiniPlayerWindow()
            } else if pendingMode == nil, !isFullScreenTransitioning {
                showLibraryWindow()
            }
            return
        }

        if newMode == .miniPlayer {
            guard let window else {
                mode = .miniPlayer
                miniQueueExpanded = false
                showMiniPlayerWindow()
                return
            }

            let fullScreen = window.styleMask.contains(.fullScreen) || isFullScreen
            if fullScreen || isFullScreenTransitioning {
                pendingMode = .miniPlayer
                scheduleFullScreenExitTimeout()
                if fullScreen {
                    window.toggleFullScreen(nil)
                }
                // If the window is still entering full screen, didEnter will
                // exit it and the didExit notification will finish the switch.
                return
            }

            libraryFrame = window.frame
            UserDefaults.standard.set(NSStringFromRect(window.frame),
                                      forKey: Self.libraryFrameKey)
            mode = .miniPlayer
            miniQueueExpanded = false
            showMiniPlayerWindow()
            return
        }

        mode = .library
        miniQueueExpanded = false
        miniWindow?.orderOut(nil)
        showLibraryWindow()
    }

    private func scheduleFullScreenExitTimeout() {
        fullScreenExitTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingMode == .miniPlayer else { return }
            self.pendingMode = nil
            self.fullScreenExitTimeout = nil
            self.isFullScreenTransitioning = false
            self.isFullScreen = self.window?.styleMask.contains(.fullScreen) ?? false
        }
        fullScreenExitTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func finishPendingModeAfterFullScreenExit() {
        guard pendingMode == .miniPlayer else { return }
        pendingMode = nil
        fullScreenExitTimeout?.cancel()
        fullScreenExitTimeout = nil
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        libraryFrame = window.frame
        UserDefaults.standard.set(NSStringFromRect(window.frame),
                                  forKey: Self.libraryFrameKey)
        mode = .miniPlayer
        miniQueueExpanded = false
        showMiniPlayerWindow()
    }

    func closeMiniPlayer() {
        setMode(.library)
    }

    func minimizeMiniPlayer() {
        miniWindow?.miniaturize(nil)
    }

    private func showLibraryWindow() {
        miniWindow?.orderOut(nil)
        guard let window else { return }
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .libraryWindowDidShow, object: window)
    }

    private func showMiniPlayerWindow() {
        let mini = ensureMiniWindow()
        window?.orderOut(nil)
        NSApp.unhide(nil)
        if mini.isMiniaturized {
            mini.deminiaturize(nil)
        }
        mini.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureMiniWindow() -> NSWindow {
        if let miniWindow { return miniWindow }

        var frame = initialMiniFrame()
        let mini = MiniPlayerWindow(contentRect: frame,
                                    styleMask: [.titled, .closable, .miniaturizable,
                                                .resizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: false)
        mini.isReleasedWhenClosed = false
        mini.titleVisibility = .hidden
        mini.titlebarAppearsTransparent = true
        mini.titlebarSeparatorStyle = .none
        mini.isMovable = false
        mini.isMovableByWindowBackground = false
        mini.isOpaque = true
        mini.backgroundColor = .windowBackgroundColor
        mini.hasShadow = true
        mini.title = "Tracks MiniPlayer"
        mini.tabbingMode = .disallowed
        mini.acceptsMouseMovedEvents = true
        mini.collectionBehavior = [.managed, .fullScreenNone]
        mini.animationBehavior = .none
        mini.delegate = miniResizeDelegate
        miniResizeDelegate.owner = self
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            mini.standardWindowButton(type)?.isHidden = true
        }

        let host = NSHostingView(rootView: MiniPlayerView()
            .environmentObject(PlayerState.shared))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        mini.contentView = host

        let maxWidth = maxMiniWidth(for: mini)
        let width = min(max(miniWidth, MiniPlayerMetrics.minWidth), maxWidth)
        miniWidth = width.rounded()
        frame.size = NSSize(width: miniWidth,
                            height: MiniPlayerMetrics.height(forWidth: miniWidth))
        frame = mini.constrainFrameRect(frame, to: mini.screen)
        mini.setFrame(frame, display: false)
        mini.minSize = NSSize(width: MiniPlayerMetrics.minWidth,
                              height: MiniPlayerMetrics.height(forWidth: MiniPlayerMetrics.minWidth))
        mini.maxSize = NSSize(width: maxWidth,
                              height: mini.screen?.visibleFrame.height ?? 10000)
        miniWindow = mini
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: mini,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.miniWindowBecameKey() }
        }
        refreshLibraryTitlebarLayout(for: mini)
        return mini
    }

    private func initialMiniFrame() -> NSRect {
        let base = libraryFrame ?? window?.frame ??
            NSRect(x: 80, y: 120, width: MiniPlayerMetrics.width,
                   height: MiniPlayerMetrics.baseHeight)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(base) })
            ?? window?.screen
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let maxWidth = min(MiniPlayerMetrics.maxWidth,
                           max(MiniPlayerMetrics.minWidth,
                               visible.width - miniScreenPadding * 2))
        let width = min(max(miniWidth, MiniPlayerMetrics.minWidth), maxWidth).rounded()
        let height = MiniPlayerMetrics.height(forWidth: width)
        var x = base.minX
        if visible.width > 0 {
            x = min(max(x, visible.minX + miniScreenPadding),
                    visible.maxX - width - miniScreenPadding)
        }
        let y = max(visible.minY + miniScreenPadding, base.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func toggleMiniQueue() {
        setMiniQueueExpanded(!miniQueueExpanded)
    }

    func setMiniQueueExpanded(_ expanded: Bool) {
        guard mode == .miniPlayer, let miniWindow else { return }
        guard expanded != miniQueueExpanded else { return }
        miniQueueExpanded = expanded
        guard !miniWindow.styleMask.contains(.fullScreen) else { return }

        // While the queue drawer is open the bottom edge belongs to the queue
        // height handle, so native edge resizing must be off.
        if expanded {
            miniWindow.styleMask.remove(.resizable)
        } else {
            miniWindow.styleMask.insert(.resizable)
        }
        let width = miniWindow.frame.width
        let queueHeight = expanded ? clampedMiniQueueHeight(miniQueueHeight,
                                                           for: miniWindow,
                                                           width: width) : 0
        if expanded, queueHeight != miniQueueHeight {
            miniQueueHeight = queueHeight
            UserDefaults.standard.set(Double(queueHeight), forKey: Self.miniQueueHeightKey)
        }
        let targetHeight = MiniPlayerMetrics.height(forWidth: width, queueHeight: queueHeight)
        let top = miniWindow.frame.maxY
        var frame = miniWindow.frame
        frame.size.width = width
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        frame = miniWindow.constrainFrameRect(frame, to: miniWindow.screen)
        miniWindow.setFrame(frame, display: true, animate: true)
    }

    /// Changes the height of the expanded queue panel. The window top stays put
    /// and the extra height grows downward into the queue.
    func setMiniQueueHeight(_ height: CGFloat) {
        guard mode == .miniPlayer, miniQueueExpanded, let miniWindow else { return }
        let width = miniWindow.frame.width
        let queueHeight = clampedMiniQueueHeight(height, for: miniWindow, width: width)
        guard queueHeight != miniQueueHeight else { return }
        miniQueueHeight = queueHeight
        UserDefaults.standard.set(Double(queueHeight), forKey: Self.miniQueueHeightKey)

        let targetHeight = MiniPlayerMetrics.height(forWidth: width, queueHeight: queueHeight)
        let top = miniWindow.frame.maxY
        var frame = miniWindow.frame
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        frame = miniWindow.constrainFrameRect(frame, to: miniWindow.screen)
        miniWindow.setFrame(frame, display: true, animate: false)
    }

    private func maxMiniWidth(for window: NSWindow) -> CGFloat {
        var result = MiniPlayerMetrics.maxWidth
        if let visible = window.screen?.visibleFrame {
            let queueHeight = miniQueueExpanded ? miniQueueHeight : 0
            let topToBottom = window.frame.maxY - visible.minY
            result = min(result, visible.width)
            result = min(result, topToBottom - MiniPlayerMetrics.middle - MiniPlayerMetrics.bottom
                         - queueHeight - miniScreenPadding)
        }
        return max(MiniPlayerMetrics.minWidth, result)
    }

    private func maxMiniQueueHeight(for window: NSWindow, width: CGFloat) -> CGFloat {
        var result = MiniPlayerMetrics.maxQueueHeight
        if let visible = window.screen?.visibleFrame {
            let topToBottom = window.frame.maxY - visible.minY
            result = min(result, topToBottom - width - MiniPlayerMetrics.middle - MiniPlayerMetrics.bottom
                         - miniScreenPadding)
        }
        return max(MiniPlayerMetrics.minQueueHeight, result)
    }

    private func clampedMiniQueueHeight(_ height: CGFloat,
                                        for window: NSWindow,
                                        width: CGFloat) -> CGFloat {
        min(max(height, MiniPlayerMetrics.minQueueHeight),
            maxMiniQueueHeight(for: window, width: width))
    }

    fileprivate func constrainedMiniSize(proposedWidth: CGFloat,
                                         window: NSWindow) -> NSSize {
        let maxWidth = maxMiniWidth(for: window)
        let width = min(max(proposedWidth, MiniPlayerMetrics.minWidth), maxWidth).rounded()
        miniWidth = width
        UserDefaults.standard.set(Double(width), forKey: Self.miniWidthKey)
        let queueHeight = miniQueueExpanded ? miniQueueHeight : 0
        return NSSize(width: width,
                      height: MiniPlayerMetrics.height(forWidth: width, queueHeight: queueHeight).rounded())
    }

    fileprivate func miniPlayerShouldClose() -> Bool {
        setMode(.library)
        return false
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

private final class MiniPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        WindowModeCenter.shared.closeMiniPlayer()
    }
}

private final class MiniResizeDelegate: NSObject, NSWindowDelegate {
    weak var owner: WindowModeCenter?

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        MainActor.assumeIsolated {
            owner?.constrainedMiniSize(proposedWidth: frameSize.width, window: sender) ?? frameSize
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            owner?.miniPlayerShouldClose() ?? true
        }
    }
}
