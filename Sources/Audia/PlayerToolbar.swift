import SwiftUI
import UniformTypeIdentifiers

private enum ToolbarButtonMetrics {
    static let size: CGFloat = 30
    static let iconSize: CGFloat = 15
}

// MARK: - Top bar

struct PlayerToolbar: View {
    @Binding var searchText: String

    private let queueGap: CGFloat = 10
    private let queueButtonSize: CGFloat = ToolbarButtonMetrics.size
    private let searchFieldWidth: CGFloat = 180
    private let searchTrailing: CGFloat = 14
    // Traffic lights are centered in the 45pt title bar; with the inset style
    // used by Chrome/Helium they end around x = 74. Controls start a little
    // further right so nothing ever needs to move when the window is resized.
    private let leadingInset: CGFloat = 96

    @State private var leadingControlsWidth: CGFloat = 316

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Theme.toolbarTop, Theme.toolbarBottom],
                           startPoint: .top, endPoint: .bottom)

            HStack(spacing: 0) {
                LeadingControls()
                    .padding(.leading, leadingInset)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: LeadingControlsWidthKey.self,
                                                   value: geo.size.width)
                        }
                    )
                Spacer()
                SearchField(text: $searchText)
                    .padding(.trailing, searchTrailing)
            }

            // The play control is always centered relative to the window and grows
            // with it. The queue button hangs off its right edge without shifting
            // that center.
            GeometryReader { geo in
                let centerX = geo.size.width / 2
                let centerY = geo.size.height / 2
                let playWidth = min(max(geo.size.width * 0.36, 400), 680)
                let playLeft = centerX - playWidth / 2
                let playRight = centerX + playWidth / 2 + queueGap + queueButtonSize
                let searchLeft = geo.size.width - searchTrailing - searchFieldWidth
                let leftGapStart = max(leadingControlsWidth, leadingInset)

                NowPlayingView(width: playWidth)
                    .position(x: centerX, y: centerY)

                QueueButton()
                    .position(x: centerX + playWidth / 2 + queueGap + queueButtonSize / 2,
                              y: centerY)

                // Window dragging is scoped to genuinely empty chrome. Attaching
                // `WindowDragGesture` to the whole background made it win over the
                // custom sliders (SwiftUI gestures see events even when an AppKit
                // view is the hit target), so the drag areas exclude the controls.
                // Left of the traffic lights.
                let leftEdgeWidth = max(leadingInset - 6, 0)
                WindowDragArea()
                    .frame(width: leftEdgeWidth, height: 45)
                    .position(x: leftEdgeWidth / 2, y: centerY)

                // Strips above and below the transport/volume controls, so the
                // whole left side of the bar can be dragged without covering the
                // buttons themselves.
                WindowDragArea()
                    .frame(width: leftGapStart, height: 9)
                    .position(x: leftGapStart / 2, y: 4.5)
                WindowDragArea()
                    .frame(width: leftGapStart, height: 9)
                    .position(x: leftGapStart / 2, y: 40.5)

                if playLeft - leftGapStart > 8 {
                    WindowDragArea()
                        .frame(width: playLeft - leftGapStart, height: 45)
                        .position(x: (leftGapStart + playLeft) / 2, y: centerY)
                }
                if searchLeft - playRight > 8 {
                    WindowDragArea()
                        .frame(width: searchLeft - playRight, height: 45)
                        .position(x: (playRight + searchLeft) / 2, y: centerY)
                }
            }
        }
        .frame(height: 45)
        .clipped()
        .onPreferenceChange(LeadingControlsWidthKey.self) { leadingControlsWidth = $0 }
    }
}

private struct LeadingControlsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Explicit window-drag strip for the top bar's empty chrome.
///
/// This follows Chromium/Helium's macOS approach (`NativeWidgetMacNSWindow` +
/// frame-view drag): the window's automatic title-bar drag is disabled, and
/// window movement is applied explicitly. Only one mechanism is used — mixing
/// `performDrag(with:)` with manual frame updates made the window fight itself
/// and jitter more the further it was dragged.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandle() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragHandle: NSView {
        private var initialMouseLocation: NSPoint?
        private var initialWindowOrigin: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            initialMouseLocation = NSEvent.mouseLocation
            initialWindowOrigin = window?.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window,
                  let initialMouseLocation,
                  let initialWindowOrigin else { return }
            let current = NSEvent.mouseLocation
            window.setFrameOrigin(
                NSPoint(x: initialWindowOrigin.x + current.x - initialMouseLocation.x,
                        y: initialWindowOrigin.y + current.y - initialMouseLocation.y)
            )
        }

        override func mouseUp(with event: NSEvent) {
            initialMouseLocation = nil
            initialWindowOrigin = nil
        }
    }
}

// MARK: - Queue button

private enum QueueTab: Hashable {
    case upNext
    case history
}

private struct QueueButton: View {
    @EnvironmentObject private var player: PlayerState
    @State private var isPresented = false
    @State private var tab: QueueTab = .upNext

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: ToolbarButtonMetrics.iconSize, weight: .medium))
                .foregroundColor(isPresented ? Theme.selectionBlue : Theme.secondaryText)
                .frame(width: ToolbarButtonMetrics.size, height: ToolbarButtonMetrics.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Queue")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            QueuePopover(tab: $tab)
        }
    }
}

private struct QueuePopover: View {
    @Binding var tab: QueueTab
    @EnvironmentObject private var player: PlayerState

    @AppStorage("queue.popoverWidth") private var storedWidth = 300.0
    @AppStorage("queue.listHeight") private var storedListHeight = 260.0
    @State private var listResizeStart: CGFloat?
    @State private var widthResizeStart: CGFloat?
    @State private var draggingID: UUID?
    @State private var dropTargetIndex: Int?
    @State private var dropAtEnd = false

    private var songs: [Song] {
        tab == .upNext ? player.upNext : player.history
    }

    private var queueWidth: CGFloat {
        CGFloat(min(max(storedWidth, 260), 640))
    }

    private var listHeight: CGFloat {
        CGFloat(min(max(storedListHeight, 120), 620))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Up Next").tag(QueueTab.upNext)
                Text("History").tag(QueueTab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if songs.isEmpty {
                Text(tab == .upNext ? "Nothing Up Next" : "No History")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: listHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            queueRow(song, at: index)
                        }
                        if tab == .upNext {
                            endDropZone
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: listHeight)
            }

            Divider()
            HStack(spacing: 8) {
                if tab == .upNext {
                    Button {
                        player.clearUpNext()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.selectionBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(songs.isEmpty)
                    .opacity(songs.isEmpty ? 0.4 : 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            queueHeightHandle
        }
        .frame(width: queueWidth)
        .overlay(alignment: .leading) {
            widthResizeHandle(isLeading: true)
        }
        .overlay(alignment: .trailing) {
            widthResizeHandle(isLeading: false)
        }
    }

    /// Invisible edge handles let the popover be widened or narrowed without
    /// showing another resize icon.
    private func widthResizeHandle(isLeading: Bool) -> some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .onDisappear { NSCursor.arrow.set() }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if widthResizeStart == nil {
                            widthResizeStart = queueWidth
                        }
                        guard let start = widthResizeStart else { return }
                        let delta = isLeading ? -value.translation.width : value.translation.width
                        storedWidth = min(max(Double(start + delta), 260), 640)
                    }
                    .onEnded { _ in
                        widthResizeStart = nil
                    }
            )
    }

    private var queueHeightHandle: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Theme.secondaryText.opacity(0.55))
                .frame(width: 30, height: 3)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .help("Drag to resize queue")
        .accessibilityLabel("Resize queue")
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if listResizeStart == nil {
                        listResizeStart = listHeight
                    }
                    guard let start = listResizeStart else { return }
                    storedListHeight = min(max(Double(start + value.translation.height), 120), 620)
                }
                .onEnded { _ in
                    listResizeStart = nil
                }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    @ViewBuilder
    private func queueRow(_ song: Song, at index: Int) -> some View {
        let row = QueueRow(song: song) {
            player.playFromQueue(song)
        }
        .contextMenu {
            QueueSongContextMenu(song: song)
        }

        if tab == .upNext {
            row
                .overlay(alignment: .top) {
                    if dropTargetIndex == index {
                        Rectangle()
                            .fill(Theme.selectionBlue)
                            .frame(height: 2)
                    }
                }
                .onDrag {
                    draggingID = song.id
                    dropTargetIndex = nil
                    dropAtEnd = false
                    return NSItemProvider(object: song.id.uuidString as NSString)
                }
                .onDrop(of: [.plainText],
                        isTargeted: Binding(
                            get: { dropTargetIndex == index },
                            set: { targeted in
                                if targeted {
                                    dropTargetIndex = index
                                } else if dropTargetIndex == index {
                                    dropTargetIndex = nil
                                }
                            }
                        )) { _ in
                    performDrop(before: index)
                }
        } else {
            row
        }
    }

    private var endDropZone: some View {
        ZStack(alignment: .top) {
            Color.clear
            if dropAtEnd {
                Rectangle()
                    .fill(Theme.selectionBlue)
                    .frame(height: 2)
            }
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], isTargeted: $dropAtEnd) { _ in
            performDropAtEnd()
        }
    }

    private func performDrop(before index: Int) -> Bool {
        guard tab == .upNext,
              let draggingID,
              let from = songs.firstIndex(where: { $0.id == draggingID }) else {
            return false
        }
        defer { resetDragState() }
        guard from != index else { return true }
        let destination = from < index ? index - 1 : index
        player.moveUpNext(from: from, to: destination)
        return true
    }

    private func performDropAtEnd() -> Bool {
        guard tab == .upNext,
              let draggingID,
              let from = songs.firstIndex(where: { $0.id == draggingID }) else {
            return false
        }
        defer { resetDragState() }
        let destination = max(songs.count - 1, 0)
        guard from != destination else { return true }
        player.moveUpNext(from: from, to: destination)
        return true
    }

    private func resetDragState() {
        draggingID = nil
        dropTargetIndex = nil
        dropAtEnd = false
    }
}

private struct QueueRow: View {
    let song: Song
    let onPlay: () -> Void

    @ObservedObject private var library = Library.shared
    @State private var hover = false

    private var starred: Bool {
        library.starredSongIDs.contains(song.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(song.title)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.primaryText)
                        .lineLimit(1)
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(Theme.secondaryText)
                            .accessibilityLabel("Starred")
                    }
                }
                Text(song.artist)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                if !song.album.isEmpty {
                    Text(song.album)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.secondaryText.opacity(0.82))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(formatTime(song.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(hover ? Theme.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hover = $0 }
    }
}

/// Shared right-click menu for songs shown in the queue panel.
struct QueueSongContextMenu: View {
    let song: Song
    @EnvironmentObject private var player: PlayerState

    private var albumID: UUID? {
        Library.shared.song(withID: song.id)?.album.id
    }

    private var artistTarget: String {
        let source = Library.shared.song(withID: song.id)?.song ?? song
        let albumArtist = source.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        return albumArtist.isEmpty ? source.artist : albumArtist
    }

    private var isInQueue: Bool {
        player.queue.contains { $0.id == song.id }
    }

    var body: some View {
        Button("Play Next") {
            player.playNextFromQueue(song)
        }
        .disabled(player.currentSong?.id == song.id)

        Button("Go to Album") {
            guard let albumID else { return }
            NavigationCenter.shared.albumToOpen = albumID
        }
        .disabled(albumID == nil)

        Button("Go to Artist") {
            guard !artistTarget.isEmpty else { return }
            NavigationCenter.shared.artistToOpen = artistTarget
        }
        .disabled(artistTarget.isEmpty)

        Divider()

        Button("Delete from Queue") {
            player.removeFromQueue(song)
        }
        .disabled(!isInQueue)
    }
}

// MARK: - Left: transport + volume + device

private struct LeadingControls: View {
    @EnvironmentObject private var player: PlayerState

    var body: some View {
        HStack(spacing: 12) {
            TransportControls()
            VolumeControl()
            DeviceMenu()
        }
    }
}

private struct TransportControls: View {
    @EnvironmentObject private var player: PlayerState

    var body: some View {
        HStack(spacing: 2) {
            TransportButton(icon: "backward.fill", help: "Previous") { player.previous() }
            TransportButton(icon: player.isPlaying ? "pause.fill" : "play.fill",
                            help: player.isPlaying ? "Pause" : "Play",
                            prominent: true) { player.togglePlayPause() }
            TransportButton(icon: "forward.fill", help: "Next") { player.next() }
        }
    }
}

private struct TransportButton: View {
    let icon: String
    let help: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 14 : 11, weight: .medium))
                .foregroundColor(Theme.primaryText)
                .frame(width: prominent ? 30 : 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct VolumeControl: View {
    @EnvironmentObject private var player: PlayerState

    private var icon: String {
        if player.isMutedForUI { return "speaker.slash.fill" }
        if player.displayVolume < 0.34 { return "speaker.wave.1.fill" }
        if player.displayVolume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { player.toggleMute() } label: {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(player.isVolumeLocked
                  ? (player.isSystemMuted ? "Unmute system volume" : "Mute system volume")
                  : "Mute")

            VolumeBar()
        }
    }
}

private struct VolumeBar: View {
    @EnvironmentObject private var player: PlayerState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumbX = min(max(w * player.displayVolume - 5.5, 0), max(w - 11, 0))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.lcdProgress)
                    .frame(width: w * player.displayVolume, height: 3)
                // The thumb is always visible, not just on hover.
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .offset(x: thumbX)
            }
            .frame(width: w, height: 12)
            .position(x: w / 2, y: geo.size.height / 2)
        }
        // Shorter than before to free up room for the controls next to the
        // traffic lights, especially at the minimum window width.
        .frame(width: 60, height: 24)
        .overlay(
            FractionDragControl { fraction in
                player.setDisplayVolume(Double(fraction))
            }
        )
    }
}

private struct DeviceMenu: View {
    @ObservedObject private var audioDevices = AudioDevices.shared
    @State private var isPresented = false
    @State private var hoveredID: String?

    var body: some View {
        Button {
            audioDevices.refresh()
            isPresented.toggle()
        } label: {
            Image(systemName: audioDevices.selectedDevice.icon)
                .font(.system(size: ToolbarButtonMetrics.iconSize, weight: .medium))
                .foregroundColor(isPresented ? Theme.selectionBlue : Theme.secondaryText)
                .frame(width: ToolbarButtonMetrics.size, height: ToolbarButtonMetrics.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select output device")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Output Device")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ForEach(audioDevices.devices) { device in
                    DeviceRow(
                        name: device.name,
                        icon: device.icon,
                        isSelected: audioDevices.selectedUID == device.uid,
                        isHovered: hoveredID == device.id
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            hoveredID = device.id
                        } else if hoveredID == device.id {
                            hoveredID = nil
                        }
                    }
                    .onTapGesture {
                        PlayerState.shared.selectAudioOutput(device)
                        MPDServer.shared.notifyOutputConfigurationChanged()
                        isPresented = false
                    }
                    .help(device.name)

                    if device.isSystemDefault {
                        Divider()
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(.bottom, 6)
            .frame(width: 230)
        }
    }
}

private struct DeviceRow: View {
    let name: String
    let icon: String
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.selectionBlue)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 12)
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 14)
            Text(name)
                .font(.system(size: 12.5))
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(isHovered ? Theme.rowHover : Color.clear)
    }
}

// MARK: - Center: now playing

struct NowPlayingView: View {
    let width: CGFloat

    static let artworkSize: CGFloat = 45
    private let contentInset: CGFloat = 6
    /// Shuffle moves this far toward the artwork; star/repeat move the same
    /// distance toward the trailing edge.
    private let sideControlsOutset: CGFloat = 4
    /// Lift shuffle/star/repeat slightly above the vertical center.
    private let sideControlsLift: CGFloat = 1
    /// The 15pt icons sit inside a 20pt hit frame, so the visible edge is
    /// inset by half the difference. Use that to line up the time labels.
    private let sideControlIconInset: CGFloat = 2.5
    /// Pull both side buttons back inward so their hit-frame edges line up
    /// with the time labels below.
    private let sideControlsPullIn: CGFloat = 2.5

    @EnvironmentObject private var player: PlayerState
    @ObservedObject private var library = Library.shared
    @State private var titleHovering = false
    @State private var showRemaining = false

    var body: some View {
        Group {
            if let song = player.currentSong {
                playing(song)
            } else {
                idle
            }
        }
    }

    /// Empty display: no transport controls, no artwork, no seek bar — just a
    /// darker panel with a centered optical-disc glyph.
    private var idle: some View {
        ZStack {
            Rectangle().fill(Theme.lcdIdleFill)
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(Theme.secondaryText.opacity(0.9))
        }
        .frame(width: width, height: 45)
        .clipped()
    }

    private func playing(_ song: Song) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.lcdFill)

            VStack(spacing: 0) {
                // Shuffle on the left, title centered, star/repeat on the
                // right. Both side groups share the same inset from the content
                // area's edges.
                ZStack {
                    HStack(spacing: 6) {
                        // Balances the ellipsis slot so the title stays centred.
                        Color.clear.frame(width: 18)
                        VStack(spacing: 3) {
                            Text(song.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(Theme.primaryText)
                                .lineLimit(1)
                            Text("\(song.artist) — \(song.album)")
                                .font(.system(size: 10.5))
                                .foregroundColor(Theme.secondaryText)
                                .lineLimit(1)
                        }
                        NowPlayingMenu(song: song)
                            .opacity(titleHovering ? 1 : 0)
                            .allowsHitTesting(titleHovering)
                    }
                    .padding(.horizontal, 60)
                    .offset(y: 3)
                    .onHover { titleHovering = $0 }

                    HStack(spacing: 0) {
                        CenterControlButton(icon: "shuffle",
                                            active: player.isShuffleOn,
                                            help: "Shuffle") {
                            player.toggleShuffle()
                        }
                        .offset(x: -sideControlsOutset + sideControlsPullIn)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            CenterControlButton(icon: isStarred(song) ? "star.fill" : "star",
                                                active: isStarred(song),
                                                help: isStarred(song) ? "Unstar" : "Star") {
                                library.toggleStar(song.id)
                            }
                            CenterControlButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                                                active: player.repeatMode != .off,
                                                help: repeatHelp) {
                                player.cycleRepeatMode()
                            }
                        }
                        .offset(x: sideControlsOutset - sideControlsPullIn)
                    }
                    .offset(y: -sideControlsLift)
                }
                .padding(.leading, Self.artworkSize + contentInset)
                .padding(.trailing, contentInset)
                .frame(height: 30)

                HStack(spacing: 6) {
                    Text(formatTime(player.elapsed))
                        .frame(width: 40, alignment: .leading)
                    Spacer(minLength: 0)
                    Button {
                        showRemaining.toggle()
                    } label: {
                        Text(showRemaining
                             ? formatRemaining(max(0, player.duration - player.elapsed))
                             : formatTime(player.duration))
                            .frame(width: 40, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.secondaryText)
                    .help(showRemaining ? "Show Total Time" : "Show Remaining Time")
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundColor(Theme.secondaryText)
                .padding(.leading, Self.artworkSize + contentInset - sideControlsOutset + sideControlIconInset)
                .padding(.trailing, max(0, contentInset - sideControlsOutset + sideControlIconInset))
                .frame(height: 10)
                .offset(y: -1)

                // Full-bleed seek bar: starts at the artwork's right edge and runs
                // to the panel's right edge, with no padding.
                SeekBar()
                    .padding(.leading, Self.artworkSize)
                    .frame(height: 5)
            }
            .frame(width: width, height: 45, alignment: .top)

            AlbumArtwork(artwork: Library.shared.artwork(forAlbumTitle: song.album))
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipped()
        }
        .frame(width: width, height: 45)
        .clipped()
    }

    private func isStarred(_ song: Song) -> Bool {
        library.starredSongIDs.contains(song.id)
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }
}

// MARK: - Now playing overflow menu

private struct NowPlayingMenu: View {
    let song: Song

    @ObservedObject private var library = Library.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            AddToPlaylistMenu(songs: [song])

            Button("Go to Current Song") {
                if let album = library.albums.first(where: { album in
                    album.songs.contains { $0.id == song.id }
                }) {
                    NavigationCenter.shared.albumToOpen = album.id
                }
            }

            Divider()

            Button("Song Info…") {
                InfoCenter.shared.target = .song(song.id)
                openWindow(id: "get-info")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

private struct CenterControlButton: View {    let icon: String
    let active: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(active ? Theme.selectionBlue : Theme.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(active ? "On" : "Off")
    }
}

private struct SeekBar: View {
    @EnvironmentObject private var player: PlayerState

    private let barHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.track)
                Rectangle()
                    .fill(Theme.lcdProgress)
                    .frame(width: w * player.progress)
            }
            .frame(width: w, height: barHeight)
            .position(x: w / 2, y: geo.size.height / 2)
        }
        // Generous drag target; misses used to land on the window background and
        // start a window drag.
        .overlay(alignment: .bottom) {
            FractionDragControl { fraction in
                player.seek(to: Double(fraction))
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Right: search

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.secondaryText)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                    focused = true
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 180, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(focused ? Theme.selectionBlue : Theme.controlBorder,
                                      lineWidth: focused ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
        )
    }
}
