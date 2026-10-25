import SwiftUI

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

    private var songs: [Song] {
        tab == .upNext ? player.upNext : player.history
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
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(songs) { song in
                            QueueRow(song: song) {
                                player.playFromQueue(song)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 260)
            }

            if tab == .upNext {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        player.clearUpNext()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.selectionBlue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(songs.isEmpty)
                    .opacity(songs.isEmpty ? 0.4 : 1)
                }
            }
        }
        .frame(width: 300)
    }
}

private struct QueueRow: View {
    let song: Song
    let onPlay: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.primaryText)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(formatTime(song.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.secondaryText)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            StarButton(songID: song.id)
                .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(hover ? Theme.rowHover : Color.clear)
        .onHover { hover = $0 }
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
        if player.isMuted { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
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
            .help("Mute")

            VolumeBar()
        }
    }
}

private struct VolumeBar: View {
    @EnvironmentObject private var player: PlayerState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumbX = min(max(w * player.volume - 5.5, 0), max(w - 11, 0))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.lcdProgress)
                    .frame(width: w * player.volume, height: 3)
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
                player.setVolume(Double(fraction))
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
                        audioDevices.select(device)
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
