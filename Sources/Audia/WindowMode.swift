import SwiftUI
import AppKit

enum MiniPlayerMetrics {
    static let minWidth: CGFloat = 320
    static let width: CGFloat = 320
    static let maxWidth: CGFloat = 560
    static let middle: CGFloat = 42
    static let bottom: CGFloat = 30
    static let queue: CGFloat = 201

    static func height(forWidth width: CGFloat, queueExpanded: Bool) -> CGFloat {
        width + middle + bottom + (queueExpanded ? queue : 0)
    }

    static var baseHeight: CGFloat { height(forWidth: width, queueExpanded: false) }
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
    private var miniWidth: CGFloat = MiniPlayerMetrics.width
    private let miniResizeDelegate = MiniResizeDelegate()
    private var originalWindowDelegate: NSWindowDelegate?
    private let libraryMinSize = NSSize(width: 1040, height: 640)
    private static let libraryFrameKey = "WindowMode.libraryFrame"
    private static let miniWidthKey = "WindowMode.miniWidth"

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

        let maxWidth = maxMiniWidth(for: window)
        let width = min(max(miniWidth, MiniPlayerMetrics.minWidth), maxWidth)
        miniWidth = width.rounded()
        let miniSize = NSSize(width: miniWidth,
                             height: MiniPlayerMetrics.height(forWidth: miniWidth, queueExpanded: false))

        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: MiniPlayerMetrics.minWidth,
                                height: MiniPlayerMetrics.height(forWidth: MiniPlayerMetrics.minWidth,
                                                                 queueExpanded: false))
        window.maxSize = NSSize(width: maxWidth,
                                height: MiniPlayerMetrics.height(forWidth: maxWidth,
                                                                 queueExpanded: true))
        installMiniResizeDelegate(window)

        if !window.styleMask.contains(.fullScreen) {
            let topLeft = NSPoint(x: window.frame.minX,
                                  y: window.frame.maxY)
            var frame = window.frame
            frame.size = miniSize
            frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - miniSize.height)
            frame = window.constrainFrameRect(frame, to: window.screen)
            window.setFrame(frame, display: true, animate: animated)
        }
    }

    func toggleMiniQueue() {
        setMiniQueueExpanded(!miniQueueExpanded)
    }

    func setMiniQueueExpanded(_ expanded: Bool) {
        guard mode == .miniPlayer else { return }
        guard expanded != miniQueueExpanded else { return }
        miniQueueExpanded = expanded
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let maxWidth = maxMiniWidth(for: window)
        let width = min(max(window.frame.width, MiniPlayerMetrics.minWidth), maxWidth)
        let targetHeight = MiniPlayerMetrics.height(forWidth: width, queueExpanded: expanded)
        let top = window.frame.maxY
        var frame = window.frame
        frame.size.width = width
        frame.size.height = targetHeight
        frame.origin.y = top - targetHeight
        frame = window.constrainFrameRect(frame, to: window.screen)
        window.setFrame(frame, display: true, animate: true)
    }

    private func maxMiniWidth(for window: NSWindow) -> CGFloat {
        var result = MiniPlayerMetrics.maxWidth
        if let visible = window.screen?.visibleFrame {
            let queueChrome = MiniPlayerMetrics.middle + MiniPlayerMetrics.bottom + MiniPlayerMetrics.queue
            result = min(result, visible.width)
            result = min(result, visible.height - queueChrome)
        }
        return max(MiniPlayerMetrics.minWidth, result)
    }

    fileprivate func constrainedMiniSize(proposedWidth: CGFloat, window: NSWindow) -> NSSize {
        let maxWidth = maxMiniWidth(for: window)
        let width = min(max(proposedWidth, MiniPlayerMetrics.minWidth), maxWidth).rounded()
        miniWidth = width
        UserDefaults.standard.set(Double(width), forKey: Self.miniWidthKey)
        return NSSize(width: width,
                      height: MiniPlayerMetrics.height(forWidth: width,
                                                       queueExpanded: miniQueueExpanded).rounded())
    }

    private func installMiniResizeDelegate(_ window: NSWindow) {
        guard window.delegate !== miniResizeDelegate else { return }
        originalWindowDelegate = window.delegate
        miniResizeDelegate.owner = self
        miniResizeDelegate.original = originalWindowDelegate
        window.delegate = miniResizeDelegate
    }

    private func removeMiniResizeDelegate(_ window: NSWindow) {
        if window.delegate === miniResizeDelegate {
            window.delegate = originalWindowDelegate
        }
        originalWindowDelegate = nil
    }

    private func applyLibrary(animated: Bool) {
        guard let window else { return }
        removeMiniResizeDelegate(window)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
        miniQueueExpanded = false
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


private final class MiniResizeDelegate: NSObject, NSWindowDelegate {
    weak var owner: WindowModeCenter?
    weak var original: NSWindowDelegate?

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        MainActor.assumeIsolated {
            owner?.constrainedMiniSize(proposedWidth: frameSize.width, window: sender) ?? frameSize
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
