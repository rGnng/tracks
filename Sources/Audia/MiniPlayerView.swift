import SwiftUI
import AppKit

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerState
    @ObservedObject private var library = Library.shared
    @ObservedObject private var windowMode = WindowModeCenter.shared

    @State private var hovering = false
    @State private var showVolume = false
    @State private var showRemaining = false
    @State private var queueResizeStart: CGFloat?

    private var showControls: Bool { hovering || showVolume }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, MiniPlayerMetrics.minWidth)
            VStack(spacing: 0) {
                cover(width: width)
                middle(width: width)
                bottom(width: width)
                if windowMode.miniQueueExpanded {
                    Divider()
                    MiniQueuePanel()
                        .frame(height: max(0, windowMode.miniQueueHeight
                                           - MiniPlayerMetrics.queueResizeHandleHeight - 1))
                    queueResizeHandle
                        .frame(height: MiniPlayerMetrics.queueResizeHandleHeight)
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.contentBackground)
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.15), value: hovering)
        }
    }

    // MARK: Cover

    private func cover(width: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let song = player.currentSong {
                    AlbumArtwork(artwork: library.artwork(forSongID: song.id))
                } else {
                    ZStack {
                        Theme.lcdIdleFill
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: 54, weight: .regular))
                            .foregroundColor(Theme.secondaryText.opacity(0.9))
                    }
                }
            }
            .frame(width: width, height: width)
            .clipped()

            // Keep the cover draggable in MiniPlayer without manual position
            // tracking. AppKit owns the move, including native screen/window
            // behavior; acceptsFirstMouse makes it work when Tracks is inactive.
            WindowDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 9) {
                MiniTrafficLight(color: Color(.displayP3, red: 0.886, green: 0.396, blue: 0.341),
                                 symbol: "xmark",
                                 help: "Close") {
                    windowMode.closeMiniPlayer()
                }
                MiniTrafficLight(color: Color(.displayP3, red: 0.953, green: 0.753, blue: 0.094),
                                 symbol: "minus",
                                 help: "Minimize") {
                    windowMode.minimizeMiniPlayer()
                }
            }
            .padding(.leading, 10)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .frame(width: width, height: width)
        .clipped()
    }

    // MARK: Middle (info on idle, controls on hover)

    private func middle(width: CGFloat) -> some View {
        ZStack {
            info
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(showControls ? 0 : 1)
                .allowsHitTesting(!showControls)

            controls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: MiniPlayerMetrics.middle)
    }

    @ViewBuilder
    private var info: some View {
        if let song = player.currentSong {
            VStack(alignment: .center, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Text("\(song.artist) - \(song.album)")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(y: 2)
        }
    }

    private var controls: some View {
        ZStack {
            HStack(spacing: 0) {
                volumeButton
                Spacer(minLength: 0)
                queueButton
            }

            HStack(spacing: 16) {
                transportButton("backward.fill", size: 14,
                                disabled: player.currentSong == nil) {
                    player.previous()
                }
                transportButton(player.isPlaying ? "pause.fill" : "play.fill",
                                size: 21,
                                disabled: player.currentSong == nil) {
                    player.togglePlayPause()
                }
                transportButton("forward.fill", size: 14,
                                disabled: player.currentSong == nil) {
                    player.next()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var volumeButton: some View {
        Image(systemName: volumeIcon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Theme.secondaryText)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .onEnded { player.toggleMute() }
                    .exclusively(before: TapGesture().onEnded {
                        showVolume.toggle()
                    })
            )
            .popover(isPresented: $showVolume, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                    Slider(value: Binding(
                        get: { player.displayVolume },
                        set: { player.setDisplayVolume($0) }
                    ), in: 0...1)
                    .frame(width: 150)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .help(player.isVolumeLocked
                  ? (player.isSystemMuted ? "Unmute system volume" : "Mute system volume")
                  : (player.isMuted ? "Unmute (double-click)" : "Mute (double-click)"))
    }

    private var queueButton: some View {
        Button {
            windowMode.toggleMiniQueue()
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(windowMode.miniQueueExpanded ? Theme.highlight : Theme.secondaryText)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(windowMode.miniQueueExpanded ? "Hide Queue" : "Show Queue")
    }

    private var queueResizeHandle: some View {
        ZStack {
            Theme.contentBackground
            Capsule()
                .fill(Theme.secondaryText.opacity(0.55))
                .frame(width: 28, height: 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help("Drag to resize queue")
        .accessibilityLabel("Resize queue")
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if queueResizeStart == nil {
                        queueResizeStart = windowMode.miniQueueHeight
                    }
                    guard let start = queueResizeStart else { return }
                    windowMode.setMiniQueueHeight(start + value.translation.height)
                }
                .onEnded { _ in
                    queueResizeStart = nil
                }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    // MARK: Bottom seek bar

    private func bottom(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(formatTime(player.elapsed))
                .frame(width: 36, alignment: .leading)
            miniSeekBar
            Button {
                showRemaining.toggle()
            } label: {
                Text(showRemaining
                     ? formatRemaining(max(0, player.duration - player.elapsed))
                     : formatTime(player.duration))
                    .frame(width: 36, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.secondaryText)
            .help(showRemaining ? "Show Total Time" : "Show Remaining Time")
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundColor(Theme.secondaryText)
        .padding(.horizontal, 6)
        .frame(width: width, height: MiniPlayerMetrics.bottom)
    }

    private var miniSeekBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.track)
                    .frame(height: 4)
                Rectangle()
                    .fill(Theme.lcdProgress)
                    .frame(width: max(0, geo.size.width * player.progress), height: 4)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.currentSong != nil, geo.size.width > 0 else { return }
                        player.seek(to: min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 14)
    }

    private func transportButton(_ icon: String,
                                 size: CGFloat,
                                 disabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(disabled ? Theme.secondaryText.opacity(0.4) : Theme.primaryText)
                .frame(width: size >= 16 ? 34 : 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var volumeIcon: String {
        if player.isMutedForUI { return "speaker.slash.fill" }
        if player.displayVolume < 0.34 { return "speaker.wave.1.fill" }
        if player.displayVolume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Mini traffic lights

/// The mini player is too compact for a real title bar, so it draws its own
/// controls. These mirror the macOS 27 Liquid Glass traffic lights while the
/// Library keeps AppKit's native window buttons.
private struct MiniTrafficLight: View {
    let color: Color
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var activeColor: Color {
        guard controlActiveState != .key else { return color }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.34, alpha: 1)
                : NSColor(calibratedWhite: 0.62, alpha: 1)
        })
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(activeColor)

                Circle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.24), location: 0.00),
                                .init(color: .clear, location: 0.40),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Circle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.64),
                                .init(color: .white.opacity(0.22), location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.13), .clear],
                            center: UnitPoint(x: 0.30, y: 0.24),
                            startRadius: 0,
                            endRadius: 8
                        )
                    )

                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.72),
                                .white.opacity(0.02),
                                .black.opacity(0.06),
                                .white.opacity(0.50),
                            ],
                            center: .center
                        ),
                        lineWidth: 0.7
                    )

                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(.black.opacity(0.55))
                }
            }
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.24), radius: 0.6, y: 0.5)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Compact queue panel

private enum MiniQueueTab: Hashable {
    case upNext
    case history
}

private struct MiniQueuePanel: View {
    @EnvironmentObject private var player: PlayerState
    @State private var tab: MiniQueueTab = .upNext

    private var upNextEntries: [QueueEntry] {
        player.upNextEntries
    }

    private var historySongs: [Song] {
        player.history
    }

    var body: some View {
        VStack(spacing: 0) {
            AccentSegmentedControl(
                segments: [
                    AccentSegment(value: MiniQueueTab.upNext, title: "Up Next"),
                    AccentSegment(value: MiniQueueTab.history, title: "History"),
                ],
                selection: $tab
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if tab == .upNext {
                if upNextEntries.isEmpty {
                    emptyLabel("Nothing Up Next")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(upNextEntries) { entry in
                                MiniQueueRow(song: entry.song, queueEntryID: entry.id) {
                                    player.playQueueEntry(id: entry.id)
                                }
                            }
                        }
                    }
                }
            } else if historySongs.isEmpty {
                emptyLabel("No History")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(historySongs) { song in
                            MiniQueueRow(song: song) {
                                player.playFromQueue(song)
                            }
                        }
                    }
                }
            }
        }
        .background(Theme.contentBackground)
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Theme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MiniQueueRow: View {
    let song: Song
    var queueEntryID: UInt32? = nil
    let action: () -> Void

    @ObservedObject private var library = Library.shared
    @State private var hover = false

    private var starred: Bool {
        library.starredSongIDs.contains(song.id)
    }

    private var subtitle: String {
        song.album.isEmpty ? song.artist : "\(song.artist) · \(song.album)"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(song.title)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.primaryText)
                        .lineLimit(1)
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(Theme.secondaryText)
                            .accessibilityLabel("Starred")
                    }
                }
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(formatTime(song.duration))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundColor(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(hover ? Theme.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .contextMenu {
            QueueSongContextMenu(song: song, queueEntryID: queueEntryID)
        }
    }
}
