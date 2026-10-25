import SwiftUI
import AppKit

/// A lightweight, app-local drag session. Rows/cards arm a drag after a
/// deliberate long press and then follow the pointer; the sidebar playlists are
/// the drop targets. If the pointer leaves the main window, the payload is
/// promoted to a native macOS file drag so Finder can copy the files and text
/// editors receive their absolute paths.
@MainActor
final class DragController: NSObject, ObservableObject, NSDraggingSource {
    static let longPressDuration: TimeInterval = 0.25
    struct Payload {
        let songs: [Song]
        let title: String
        let subtitle: String
        let artwork: Artwork?
    }

    static let shared = DragController()

    @Published private(set) var payload: Payload?
    @Published private(set) var location: CGPoint?
    @Published private(set) var targetPlaylistID: UUID?
    var playlistFrames: [UUID: CGRect] = [:]

    /// A 150 ms long press has succeeded, but the pointer has not moved yet.
    /// The marquee gestures ignore their drags while this is true so holding a
    /// card/row starts an item drag instead of a box selection.
    private(set) var isArmed = false
    /// The payload captured by the long press before movement starts. The
    /// container drag promotes it to an actual drag once the pointer moves.
    private var armedPayload: Payload?
    /// True while a box-selection drag is in progress. A long press arriving
    /// after a quick drag has started must not turn the marquee into an item
    /// drag mid-gesture.
    var isMarqueeActive = false

    private var mouseUpMonitor: Any?
    private var didStartNativeDrag = false
    private var nativeDragWatchTimer: Timer?

    private override init() {
        super.init()
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if self.payload != nil {
                    self.finish()
                } else {
                    self.disarm()
                }
            }
            return event
        }
    }

    var isDragging: Bool { payload != nil }


    func arm() { isArmed = true }

    func arm(_ payload: Payload) {
        guard self.payload == nil, armedPayload == nil else { return }
        armedPayload = payload
        isArmed = true
    }

    func disarm() {
        armedPayload = nil
        isArmed = false
        stopNativeDragWatch()
    }

    /// Promotes the long-press payload into a real drag. Called by the
    /// container drag gesture on the first movement after the hold.
    func beginArmed() {
        guard payload == nil, let armedPayload else { return }
        self.armedPayload = nil
        payload = armedPayload
        targetPlaylistID = nil
        startNativeDragWatch()
    }

    func begin(_ payload: Payload) {
        guard self.payload == nil else { return }
        self.armedPayload = nil
        self.payload = payload
        self.targetPlaylistID = nil
        startNativeDragWatch()
    }

    func update(location: CGPoint) {
        guard payload != nil else { return }
        self.location = location
        targetPlaylistID = playlistFrames.first(where: { $0.value.contains(location) })?.key
        startNativeDragWatch()
        startNativeDragIfNeeded()
    }

    private func startNativeDragWatch() {
        guard nativeDragWatchTimer == nil, payload != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startNativeDragIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        nativeDragWatchTimer = timer
    }

    private func stopNativeDragWatch() {
        nativeDragWatchTimer?.invalidate()
        nativeDragWatchTimer = nil
    }

    /// Once the pointer leaves the main window, switch from the custom overlay
    /// to a real AppKit drag session. The pasteboard carries both the file URL
    /// and the plain path, so Finder copies files and text editors paste paths.
    private func startNativeDragIfNeeded() {
        guard !didStartNativeDrag,
              let payload,
              let window = WindowModeCenter.shared.mainWindow,
              let view = window.contentView else { return }
        let mouse = NSEvent.mouseLocation
        guard !window.frame.contains(mouse) else { return }
        let urls = payload.songs.compactMap(\.fileURL)
        guard !urls.isEmpty else { return }

        let windowPoint = window.convertPoint(fromScreen: mouse)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: windowPoint,
            modifierFlags: NSEvent.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }

        let viewPoint = view.convert(windowPoint, from: nil)
        var items: [NSDraggingItem] = []
        for (index, url) in urls.enumerated() {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            let offset = CGFloat(index) * 6
            dragging.setDraggingFrame(
                NSRect(x: viewPoint.x - 16 + offset,
                       y: viewPoint.y - 16 - offset,
                       width: 32, height: 32),
                contents: icon
            )
            items.append(dragging)
        }

        didStartNativeDrag = true
        stopNativeDragWatch()
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true

        // The native session now owns the drag. Remove the in-app preview and
        // avoid an accidental playlist drop when the mouse is released later.
        self.payload = nil
        self.location = nil
        self.targetPlaylistID = nil
        self.isArmed = false
        self.armedPayload = nil
        self.isMarqueeActive = false
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        Task { @MainActor in
            DragController.shared.didStartNativeDrag = false
        }
    }

    func finish() {
        let target = targetPlaylistID
        let songs = payload?.songs ?? []
        payload = nil
        location = nil
        targetPlaylistID = nil
        isArmed = false
        armedPayload = nil
        isMarqueeActive = false
        didStartNativeDrag = false
        stopNativeDragWatch()
        if let target, !songs.isEmpty {
            if target == Library.starredPlaylistID {
                Library.shared.setStarred(songs.map(\.id), starred: true)
            } else {
                Library.shared.addToPlaylist(target, songs: songs)
            }
        }
    }
}

struct PlaylistFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct LongPressDragModifier: ViewModifier {
    let payload: () -> DragController.Payload?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: DragController.longPressDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        DragController.shared.arm()
                    case .second(true, let drag?):
                        DragController.shared.arm()
                        if DragController.shared.payload == nil {
                            guard let payload = payload() else { return }
                            DragController.shared.begin(payload)
                        }
                        DragController.shared.update(location: drag.location)
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    DragController.shared.finish()
                }
        )
    }
}

private struct LongPressArmModifier: ViewModifier {
    let payload: () -> DragController.Payload?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: DragController.longPressDuration)
                .onEnded { _ in
                    guard !DragController.shared.isMarqueeActive,
                          DragController.shared.payload == nil,
                          let payload = payload() else { return }
                    DragController.shared.arm(payload)
                }
        )
    }
}

extension View {
    func longPressDraggable(_ payload: @escaping () -> DragController.Payload?) -> some View {
        modifier(LongPressDragModifier(payload: payload))
    }

    /// For album cards/rows: only arm the item drag after a 150 ms hold. The
    /// enclosing Albums/Recently Added view owns the drag gesture so a quick
    /// drag can still be a marquee.
    func longPressArmable(_ payload: @escaping () -> DragController.Payload?) -> some View {
        modifier(LongPressArmModifier(payload: payload))
    }
}
