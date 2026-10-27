import SwiftUI
import AppKit
import ObjectiveC

// MARK: - Window configuration (full-size content view)

/// Makes the hosting window use a full-size content view so the traffic lights
/// sit *inside* the window chrome (no separate title bar), matching iTunes 12.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { configureWindow(window) }
    }

    private final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configureWindow(window)
        }
    }
}

/// Height of the custom top bar. Used as the window's title-bar height so macOS
/// lays the traffic lights out in this strip.
private let toolbarHeight: CGFloat = 45

@MainActor
private var didConfigureFrameView = false

// Note: no manual traffic-light offset here. Shifting the title-bar container
// by -9pt used to push the traffic lights into the custom toolbar, but it also
// broke full-screen layout.
//
// Window movement is delegated to AppKit from a bottom-most toolbar surface and
// the MiniPlayer cover. The automatic title-bar drag is disabled because it
// would swallow control drags in the full-size toolbar.
@MainActor
private func configureWindow(_ window: NSWindow) {
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarSeparatorStyle = .none
    // AppKit's title-bar drag would also swallow mouse-downs on controls in the
    // full-size toolbar. Drag surfaces below ask AppKit to perform the native
    // window move explicitly instead.
    window.isMovable = false
    window.isMovableByWindowBackground = false
    window.initialFirstResponder = nil
    window.tabbingMode = .disallowed

    configureBrowserStyleTitlebar(for: window)
    WindowModeCenter.shared.register(window)

    // The first synchronous pass runs while SwiftUI is still sizing/showing the
    // window. Run one more after the current layout turn so the private
    // title-bar height is applied to the final frame.
    DispatchQueue.main.async { [weak window] in
        guard let window else { return }
        refreshBrowserTitlebarLayout(for: window)
    }
}

/// Chromium/Helium ask AppKit to treat a taller custom top bar as the title bar
/// (`_titlebarHeight`) and to center the traffic lights vertically in it
/// (`_shouldCenterTrafficLights`). That is how Chrome's traffic lights line up
/// with its tab strip without any manual frame offsets. Apply this only to the
/// main window's custom toolbar: standard Settings/Get Info/About title bars
/// already position their native traffic lights correctly, and enabling this
/// hook for them shifts the group 12pt to the right. Fall back to the stock
/// behaviour if the private hooks are gone.
@MainActor
private func configureBrowserStyleTitlebar(for window: NSWindow) {
    guard !didConfigureFrameView, let frameView = window.contentView?.superview else { return }
    didConfigureFrameView = true

    let frameClass: AnyClass = type(of: frameView)

    let centerSelector = NSSelectorFromString("_shouldCenterTrafficLights")
    if let method = class_getInstanceMethod(frameClass, centerSelector) {
        typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: BoolGetter.self)
        let replacement: @convention(block) (AnyObject) -> Bool = { object in
            guard let view = object as? NSView,
                  let window = view.window,
                  !window.styleMask.contains(.fullScreen),
                  window === WindowModeCenter.shared.mainWindow else {
                return original(object, centerSelector)
            }
            return true
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    let heightSelector = NSSelectorFromString("_titlebarHeight")
    if let method = class_getInstanceMethod(frameClass, heightSelector) {
        typealias HeightGetter = @convention(c) (AnyObject, Selector) -> CGFloat
        let original = unsafeBitCast(method_getImplementation(method), to: HeightGetter.self)
        let replacement: @convention(block) (AnyObject) -> CGFloat = { object in
            guard let view = object as? NSView,
                  let window = view.window,
                  !window.styleMask.contains(.fullScreen) else {
                return original(object, heightSelector)
            }
            guard window === WindowModeCenter.shared.mainWindow else {
                return original(object, heightSelector)
            }
            if WindowModeCenter.shared.mode == .miniPlayer { return 0 }
            return toolbarHeight
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    refreshBrowserTitlebarLayout(for: window)
}

/// AppKit only re-reads `_titlebarHeight` during a title-bar layout pass that is
/// triggered by a frame change. Nudge the width by one point and restore the
/// exact frame. This is only called during initial setup, mode changes and
/// full-screen transitions, never merely because the window becomes key; an
/// activation refresh here caused a visible one-frame jitter at drag start.
@MainActor
func refreshBrowserTitlebarLayout(for window: NSWindow) {
    guard !window.styleMask.contains(.fullScreen),
          let frameView = window.contentView?.superview else { return }
    frameView.needsLayout = true
    frameView.layoutSubtreeIfNeeded()

    let frame = window.frame
    window.setFrame(frame.insetBy(dx: 1, dy: 0), display: false)
    window.setFrame(frame, display: false)
}

// MARK: - AppKit-backed drag surface

/// An invisible AppKit view that reports horizontal drags as a 0...1 fraction.
///
/// AppKit caches the window's title-bar as a drag area and that wins over
/// controls drawn underneath it, so a plain SwiftUI `DragGesture` still dragged
/// the window. Following Chromium/Helium's macOS window code, automatic window
/// dragging is disabled for the whole window (`isMovable = false`) and the drag
/// is handled by a real `NSView` that refuses to move the window.
struct FractionDragControl: NSViewRepresentable {
    var onChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onChanged = onChanged
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onChanged = onChanged
    }

    final class DragView: NSView {
        var onChanged: ((CGFloat) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            report(event)
        }

        override func mouseDragged(with event: NSEvent) {
            report(event)
        }

        private func report(_ event: NSEvent) {
            guard bounds.width > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let fraction = min(max(point.x / bounds.width, 0), 1)
            onChanged?(fraction)
        }
    }
}

// MARK: - Native window drag surface

/// Transparent hit surface that hands dragging to AppKit's native window move.
/// It does not track the mouse or window frame itself.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            // Activate before the drag begins so the first mouse-down is not
            // consumed by window activation.
            window?.makeKey()
            return true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Hairline divider

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
    }
}

struct VDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1)
    }
}

// MARK: - Album artwork placeholder

struct AlbumArtwork: View {
    let artwork: Artwork

    @State private var image: NSImage?
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(Color(white: 0.60))
            }
        }
        .background(Theme.controlBackground)
        .clipped()
        .task(id: taskKey) {
            image = await ArtworkCache.shared.image(for: artwork)
        }
        .onReceive(NotificationCenter.default.publisher(for: .artworkDidChange)) { note in
            if let id = note.object as? String, id != artwork.cacheKey { return }
            reloadToken += 1
        }
    }

    private var taskKey: String {
        "\(artwork.cacheKey ?? "inline")-\(artwork.imageData?.count ?? 0)-\(reloadToken)"
    }
}

// MARK: - Helpers

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatRemaining(_ t: TimeInterval) -> String {
    "-" + formatTime(t)
}

func formatDuration(_ t: TimeInterval) -> String {
    let total = Int(t.rounded())
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Segmented accent control

struct AccentSegment<Value: Hashable> {
    let value: Value
    let title: String
}

/// Small segmented control that uses the app highlight color directly. This is
/// needed because AppKit's native segmented picker ignores `.tint` and always
/// fills the selected segment with the bright system accent.
struct AccentSegmentedControl<Value: Hashable>: View {
    let segments: [AccentSegment<Value>]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let selected = selection == segment.value
                Button {
                    selection = segment.value
                } label: {
                    Text(segment.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? Theme.highlightForeground : Theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? Theme.selectionFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.controlFillActive)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.controlBorder.opacity(0.55), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Star control

/// Compact star toggle used at the trailing edge of every track list. The
/// backing state lives in `songs.loved` and is exposed through
/// `Library.starredSongIDs`, so the icon updates even when a view holds an
/// older `Song` snapshot (for example the album-detail page).
struct StarButton: View {
    let songID: UUID
    var isSelected: Bool = false

    @ObservedObject private var library = Library.shared

    private var starred: Bool { library.starredSongIDs.contains(songID) }

    var body: some View {
        Button {
            library.toggleStar(songID)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(starred ? "Unstar" : "Star")
        .accessibilityLabel(starred ? "Unstar" : "Star")
    }

    private var iconColor: Color {
        if starred {
            return isSelected ? Theme.highlightForeground : Theme.highlight
        }
        return isSelected
            ? Theme.highlightForeground.opacity(0.85)
            : Theme.secondaryText.opacity(0.85)
    }
}


extension View {
    /// Publishes this row/card frame for drag-to-select containers.
    func selectionFrame(id: UUID, in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MarqueeFramesKey.self,
                    value: [id: proxy.frame(in: .named(space))]
                )
            }
        )
    }
}
