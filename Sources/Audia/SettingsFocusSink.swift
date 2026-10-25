import SwiftUI
import AppKit

/// An invisible, non-editable view used as the initial first responder of the
/// Settings window. This keeps AppKit from automatically focusing the first
/// text field when the window opens, without clearing the first responder
/// (which triggers the system alert sound).
struct SettingsFocusSink: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusSinkView {
        FocusSinkView()
    }

    func updateNSView(_ nsView: FocusSinkView, context: Context) {}
}

final class FocusSinkView: NSView {
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var needsInitialFocus = true

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }

        guard let window else { return }
        window.initialFirstResponder = self

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
            self.needsInitialFocus = false
        }

        // The Settings window is reused when it is closed and reopened. Focus
        // the sink again on the next opening, but leave focus alone when the
        // user merely switches away and back without closing the window.
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
    }
}
