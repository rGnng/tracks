import SwiftUI
import AppKit

extension Notification.Name {
    static let libraryWindowDidShow = Notification.Name("tracks.libraryWindowDidShow")
    static let focusContent = Notification.Name("tracks.focusContent")
    static let clearSearch = Notification.Name("tracks.clearSearch")
}

/// Keeps the Library window from auto-focusing the search field when it is
/// ordered back on screen. The sink becomes the initial first responder and is
/// re-focused after an explicit show, close, or first key event.
struct LibraryFocusSink: NSViewRepresentable {
    func makeNSView(context: Context) -> LibraryFocusSinkView {
        LibraryFocusSinkView()
    }

    func updateNSView(_ nsView: LibraryFocusSinkView, context: Context) {}
}

@MainActor
final class LibraryFocusSinkView: NSView {
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var showObserver: NSObjectProtocol?
    private var contentFocusObserver: NSObjectProtocol?
    private var needsInitialFocus = true

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        for observer in [keyObserver, closeObserver, showObserver, contentFocusObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        keyObserver = nil
        closeObserver = nil
        showObserver = nil
        contentFocusObserver = nil

        guard let window else { return }
        window.initialFirstResponder = self

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
            self.needsInitialFocus = false
        }

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.needsInitialFocus else { return }
                self.needsInitialFocus = false
                window.makeFirstResponder(self)
            }
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                self?.needsInitialFocus = true
                window?.initialFirstResponder = self
            }
        }

        showObserver = NotificationCenter.default.addObserver(
            forName: .libraryWindowDidShow,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window else { return }
                self.needsInitialFocus = false
                window.makeFirstResponder(self)
            }
        }

        contentFocusObserver = NotificationCenter.default.addObserver(
            forName: .focusContent,
            object: nil,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window else { return }
                self.needsInitialFocus = false
                window.makeFirstResponder(self)
            }
        }
    }
}
