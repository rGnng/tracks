import SwiftUI
import AppKit

@MainActor
final class DebugSettings: ObservableObject {
    static let shared = DebugSettings()

    @Published var showFrames: Bool {
        didSet { UserDefaults.standard.set(showFrames, forKey: "debug.showFrames") }
    }
    @Published var showFrameLabels: Bool {
        didSet { UserDefaults.standard.set(showFrameLabels, forKey: "debug.showFrameLabels") }
    }
    @Published var showAlbumGridLayout: Bool {
        didSet { UserDefaults.standard.set(showAlbumGridLayout, forKey: "debug.showAlbumGridLayout") }
    }
    @Published var showAlbumGridInfo: Bool {
        didSet { UserDefaults.standard.set(showAlbumGridInfo, forKey: "debug.showAlbumGridInfo") }
    }
    @Published var showViewInfo: Bool {
        didSet { UserDefaults.standard.set(showViewInfo, forKey: "debug.showViewInfo") }
    }
    @Published var showPlaybackInfo: Bool {
        didSet { UserDefaults.standard.set(showPlaybackInfo, forKey: "debug.showPlaybackInfo") }
    }
    @Published var openWithApp: Bool {
        didSet { UserDefaults.standard.set(openWithApp, forKey: "debug.openWithApp") }
    }

    private init() {
        let defaults = UserDefaults.standard

        // Every debug overlay starts off. Missing keys are written once so the
        // unchecked default is also the persisted value; later changes go
        // through the property observers above.
        func storedBool(_ key: String) -> Bool {
            if let value = defaults.object(forKey: key) as? Bool {
                return value
            }
            defaults.set(false, forKey: key)
            return false
        }

        showFrames = storedBool("debug.showFrames")
        showFrameLabels = storedBool("debug.showFrameLabels")
        showAlbumGridLayout = storedBool("debug.showAlbumGridLayout")
        showAlbumGridInfo = storedBool("debug.showAlbumGridInfo")
        showViewInfo = storedBool("debug.showViewInfo")
        showPlaybackInfo = storedBool("debug.showPlaybackInfo")
        openWithApp = storedBool("debug.openWithApp")
    }
}

struct AlbumGridDebugInfo: Equatable {
    var width: CGFloat = 0
    var columns = 0
    var cardWidth: CGFloat = 0
    var cardHeight: CGFloat = 0
    var rowHeight: CGFloat = 0
    var total = 0
    var selected = 0
    var selectedIndex = -1
    var selectedID = ""
    var firstAlbumGap: CGFloat?
    var minVisibleDelta: CGFloat?
    var maxVisibleDelta: CGFloat?
    var selectedActualFrame: CGRect?
    var selectedModelFrame: CGRect?
    var selectedFrameDelta: CGFloat?
    var lastRevealSource = "—"
    var lastRevealTarget: CGFloat?
    var lastRevealOffsetBefore: CGFloat = 0
    var scrollID = "—"
    var scrollPoint = "—"
    var scrollEdge = "—"
    var scrollPositionedByUser = false
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

struct AlbumLocateRequest: Equatable, Identifiable {
    let id = UUID()
    let albumID: UUID
}

struct AlbumLocatorDebugInfo: Equatable {
    var status = "idle"
    var requestedID = ""
    var foundIndex = -1
    var columns = 0
    var cardWidth: CGFloat = 0
    var cardHeight: CGFloat = 0
    var rowHeight: CGFloat = 0
    var computedFrame: CGRect?
    var actualFrame: CGRect?
    var frameDelta: CGFloat?
    var minVisibleFrameDelta: CGFloat?
    var maxVisibleFrameDelta: CGFloat?
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
    var targetOffset: CGFloat?
}

struct SongTableDebugInfo: Equatable {
    var context = ""
    var rows = 0
    var selected = 0
    var selectedIndex = -1
    var selectedID = ""
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

struct AlbumDetailDebugInfo: Equatable {
    var album = ""
    var songs = 0
    var selected = 0
    var selectedIndex = -1
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

struct BrowserDebugInfo: Equatable {
    var title = ""
    var items = 0
    var selected = ""
    var albums = 0
    var selectedSongs = 0
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
    var listOffset: CGFloat = 0
    var listViewport: CGFloat = 0
    var listContent: CGFloat = 0
}

struct SidebarDebugInfo: Equatable {
    var selection = ""
    var playlists = 0
}

@MainActor
final class DebugState: ObservableObject {
    static let shared = DebugState()
    @Published var albumGrid = AlbumGridDebugInfo()
    @Published var songTable = SongTableDebugInfo()
    @Published var albumDetail = AlbumDetailDebugInfo()
    @Published var browser = BrowserDebugInfo()
    @Published var sidebar = SidebarDebugInfo()
    @Published var albumLocateRequest: AlbumLocateRequest?
    @Published var albumLocator = AlbumLocatorDebugInfo()
}

private struct DebugFrameModifier: ViewModifier {
    @EnvironmentObject private var debug: DebugSettings
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if debug.showFrames {
            content.overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .stroke(Color.red.opacity(0.8), lineWidth: 1)
                        if debug.showFrameLabels {
                            Text(label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.red)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .offset(x: 3, y: 2)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

extension View {
    func debugFrame(_ label: String) -> some View {
        modifier(DebugFrameModifier(label: label))
    }
}

/// Column/row guides for the album grid. Drawn over the lazy grid content so
/// the lines line up with the actual card pitch.
struct AlbumGridLayoutOverlay: View {
    let columns: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let rowSpacing: CGFloat
    let padding: CGFloat
    let selectedActualFrame: CGRect?
    let selectedModelFrame: CGRect?
    let viewportTop: CGFloat
    let viewportBottom: CGFloat
    let revealTarget: CGFloat?

    var body: some View {
        Canvas { context, size in
            let columnStep = cardWidth + 22
            let rowStep = cardHeight + rowSpacing
            let guide = Color.blue.opacity(0.55)

            for column in 0...max(columns, 1) {
                let x = padding + CGFloat(column) * columnStep
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(guide), lineWidth: 0.5)
            }

            var y = padding
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(guide), lineWidth: 0.5)
                y += rowStep
            }

            if let model = selectedModelFrame {
                context.stroke(
                    Path(model),
                    with: .color(.blue),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                context.draw(
                    Text("model").font(.system(size: 9, weight: .semibold)).foregroundColor(.blue),
                    at: CGPoint(x: model.minX + 3, y: model.minY + 3),
                    anchor: .topLeading
                )
            }

            if let actual = selectedActualFrame {
                context.stroke(Path(actual), with: .color(.green), lineWidth: 1.5)
                context.draw(
                    Text("cached").font(.system(size: 9, weight: .semibold)).foregroundColor(.green),
                    at: CGPoint(x: actual.minX + 3, y: actual.minY + 16),
                    anchor: .topLeading
                )
            }

            for (lineY, label, color) in [
                (viewportTop, "viewport top", Color.red),
                (viewportBottom, "viewport bottom", Color.orange)
            ] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: lineY))
                path.addLine(to: CGPoint(x: size.width, y: lineY))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
                context.draw(
                    Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(color),
                    at: CGPoint(x: padding + 4, y: lineY + 2),
                    anchor: .topLeading
                )
            }

            if let revealTarget {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: revealTarget))
                path.addLine(to: CGPoint(x: size.width, y: revealTarget))
                context.stroke(
                    path,
                    with: .color(.purple),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 3])
                )
                context.draw(
                    Text("reveal target").font(.system(size: 9, weight: .semibold)).foregroundColor(.purple),
                    at: CGPoint(x: padding + 4, y: revealTarget + 14),
                    anchor: .topLeading
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DebugPanel: View {
    @ObservedObject private var debug = DebugSettings.shared
    @ObservedObject private var state = DebugState.shared
    @ObservedObject private var navigation = NavigationRouter.shared
    @ObservedObject private var player = PlayerState.shared

    @State private var showingLocateInput = false
    @State private var locateInput = ""

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 560),
                                    spacing: 10,
                                    alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Debug")
                        .font(.system(size: 13, weight: .semibold))
                    Text("⌃⌥⌘D")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(state.albumGrid.total) albums · \(player.queue.count) queued")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }

                section("Options") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140),
                                                 spacing: 8,
                                                 alignment: .leading)],
                              alignment: .leading,
                              spacing: 3) {
                        Toggle("Frames", isOn: $debug.showFrames)
                        Toggle("Labels", isOn: $debug.showFrameLabels)
                            .disabled(!debug.showFrames)
                        Toggle("Grid guides", isOn: $debug.showAlbumGridLayout)
                        Toggle("Grid metrics", isOn: $debug.showAlbumGridInfo)
                        Toggle("View metrics", isOn: $debug.showViewInfo)
                        Toggle("Playback", isOn: $debug.showPlaybackInfo)
                        Toggle("Open with app", isOn: $debug.openWithApp)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    section("Album Locator") {
                        HStack(spacing: 8) {
                            Button(showingLocateInput ? "Hide Input" : "Locate Album…") {
                                showingLocateInput.toggle()
                                if showingLocateInput { locateInput = "" }
                            }
                            Text("Jump by album UUID")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }

                        if showingLocateInput {
                            HStack(spacing: 6) {
                                TextField("Album UUID", text: $locateInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .onSubmit { locateAlbum() }
                                Button("Locate") { locateAlbum() }
                                    .disabled(locateUUID == nil)
                                Button("Cancel") { showingLocateInput = false }
                            }
                        }

                        metric("status", state.albumLocator.status)
                        metric("album", state.albumLocator.requestedID.isEmpty ? "—" : state.albumLocator.requestedID)
                        metric("index", state.albumLocator.foundIndex >= 0 ? "\(state.albumLocator.foundIndex)" : "—")
                        metric("columns", state.albumLocator.columns > 0 ? "\(state.albumLocator.columns)" : "—")
                        metric("card", state.albumLocator.columns > 0
                            ? "\(fmt3(state.albumLocator.cardWidth)) × \(fmt3(state.albumLocator.cardHeight))"
                            : "—")
                        metric("row height", state.albumLocator.rowHeight > 0
                            ? fmt3(state.albumLocator.rowHeight)
                            : "—")
                        metric("computed", rectString(state.albumLocator.computedFrame))
                        metric("cached", rectString(state.albumLocator.actualFrame))
                        metric("cache delta", optionalFmt3(state.albumLocator.frameDelta))
                        metric("cache delta min", optionalFmt3(state.albumLocator.minVisibleFrameDelta))
                        metric("cache delta max", optionalFmt3(state.albumLocator.maxVisibleFrameDelta))
                        metric("offset at request", fmt(state.albumLocator.offset))
                        metric("target offset", optionalFmt(state.albumLocator.targetOffset))
                        metric("viewport / content",
                               "\(fmt(state.albumLocator.viewport)) / \(fmt(state.albumLocator.content))")
                    }

                    if debug.showAlbumGridInfo {
                        section("AlbumGrid") {
                            metric("albums", "\(state.albumGrid.total)")
                            metric("selected", "\(state.albumGrid.selected)")
                            metric("index", "\(state.albumGrid.selectedIndex)")
                            metric("selected id", state.albumGrid.selectedID.isEmpty ? "—" : state.albumGrid.selectedID)
                            metric("grid width", fmt(state.albumGrid.width))
                            metric("columns", "\(state.albumGrid.columns)")
                            metric("card", "\(fmt(state.albumGrid.cardWidth)) × \(fmt(state.albumGrid.cardHeight))")
                            metric("row height", fmt(state.albumGrid.rowHeight))
                            metric("first album gap", optionalFmt(state.albumGrid.firstAlbumGap))
                            metric("cache delta min", optionalFmt3(state.albumGrid.minVisibleDelta))
                            metric("cache delta max", optionalFmt3(state.albumGrid.maxVisibleDelta))
                            metric("cached selected", rectString(state.albumGrid.selectedActualFrame))
                            metric("model selected", rectString(state.albumGrid.selectedModelFrame))
                            metric("cache delta", optionalFmt3(state.albumGrid.selectedFrameDelta))
                            metric("reveal source", state.albumGrid.lastRevealSource)
                            metric("reveal target", optionalFmt3(state.albumGrid.lastRevealTarget))
                            metric("offset before", fmt(state.albumGrid.lastRevealOffsetBefore))
                            metric("scroll id", state.albumGrid.scrollID)
                            metric("scroll point", state.albumGrid.scrollPoint)
                            metric("scroll edge", state.albumGrid.scrollEdge)
                            metric("user positioned", state.albumGrid.scrollPositionedByUser ? "yes" : "no")
                            metric("offset", fmt(state.albumGrid.offset))
                            metric("viewport", fmt(state.albumGrid.viewport))
                            metric("content", fmt(state.albumGrid.content))
                        }
                    }

                    if debug.showViewInfo {
                        section("SongTable") {
                            metric("context", state.songTable.context)
                            metric("rows", "\(state.songTable.rows)")
                            metric("selected", "\(state.songTable.selected)")
                            metric("index", "\(state.songTable.selectedIndex)")
                            metric("selected id", state.songTable.selectedID.isEmpty ? "—" : state.songTable.selectedID)
                            metric("offset", fmt(state.songTable.offset))
                            metric("viewport", fmt(state.songTable.viewport))
                            metric("content", fmt(state.songTable.content))
                        }

                        section("Browser") {
                            metric("title", state.browser.title)
                            metric("items", "\(state.browser.items)")
                            metric("selected", state.browser.selected)
                            metric("albums", "\(state.browser.albums)")
                            metric("songs selected", "\(state.browser.selectedSongs)")
                            metric("pane offset", fmt(state.browser.offset))
                            metric("pane viewport", fmt(state.browser.viewport))
                            metric("pane content", fmt(state.browser.content))
                            metric("list offset", fmt(state.browser.listOffset))
                            metric("list viewport", fmt(state.browser.listViewport))
                            metric("list content", fmt(state.browser.listContent))
                        }

                        section("AlbumDetail") {
                            metric("album", state.albumDetail.album)
                            metric("songs", "\(state.albumDetail.songs)")
                            metric("selected", "\(state.albumDetail.selected)")
                            metric("index", "\(state.albumDetail.selectedIndex)")
                            metric("offset", fmt(state.albumDetail.offset))
                            metric("viewport", fmt(state.albumDetail.viewport))
                            metric("content", fmt(state.albumDetail.content))
                        }

                        section("Sidebar") {
                            metric("selection", state.sidebar.selection)
                            metric("playlists", "\(state.sidebar.playlists)")

                            Divider()
                            Text("Navigation")
                                .font(.system(size: 10.5, weight: .semibold))
                            metric("focus", focusName)
                            metric("last arrow", arrowName)
                            metric("last scroll", scrollName)
                        }
                    }

                    if debug.showPlaybackInfo {
                        section("Playback") {
                            metric("state", playbackState)
                            metric("title", player.currentSong?.title ?? "—")
                            metric("artist", player.currentSong?.artist ?? "—")
                            metric("album", player.currentSong?.album ?? "—")
                            metric("elapsed", String(format: "%.1f / %.1f", player.elapsed, player.duration))
                            metric("queue", "\(player.queue.count)")
                            metric("current index", player.currentIndex.map(String.init) ?? "—")
                            metric("volume", String(format: "%.0f%%", displayVolume * 100))
                            metric("system volume", String(format: "%.0f%%", player.systemVolume * 100))
                            metric("volume locked", player.isVolumeLocked ? "yes" : "no")
                            metric("muted", player.isSystemMuted ? "yes" : "no")
                            metric("shuffle", player.isShuffleOn ? "on" : "off")
                            metric("repeat", player.repeatMode.rawValue)
                            metric("missing", "\(player.missingFileIDs.count)")
                            metric("history", "\(player.history.count)")
                            metric("queue entry", player.currentEntry.map { "\($0.id)" } ?? "—")
                        }
                    }
                }

                Text("Tip: frame overlays are local to each view and do not receive mouse events.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .frame(minWidth: 680, minHeight: 440)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.bottom, 1)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .font(.system(size: 10.5))
        .frame(minHeight: 12.5)
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func optionalFmt(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return fmt(value)
    }

    private func fmt3(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func optionalFmt3(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return fmt3(value)
    }

    private func rectString(_ rect: CGRect?) -> String {
        guard let rect else { return "—" }
        return String(format: "%.2f, %.2f  %.2f × %.2f",
                      rect.minX, rect.minY, rect.width, rect.height)
    }

    private var locateUUID: UUID? {
        UUID(uuidString: locateInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func locateAlbum() {
        guard let id = locateUUID else {
            state.albumLocator = AlbumLocatorDebugInfo(
                status: "invalid UUID",
                requestedID: locateInput
            )
            return
        }
        state.albumLocator = AlbumLocatorDebugInfo(
            status: "requested",
            requestedID: id.uuidString
        )
        state.albumLocateRequest = AlbumLocateRequest(albumID: id)
        NavigationCenter.shared.sidebarSelection = .library(.albums)
    }

    private var playbackState: String {
        guard player.currentSong != nil else { return "stopped" }
        return player.isPlaying ? "playing" : "paused"
    }

    private var displayVolume: Double {
        player.isVolumeLocked ? player.systemVolume : player.volume
    }

    private var focusName: String {
        switch navigation.focus {
        case .sidebar: return "sidebar"
        case .albumGrid: return "albumGrid"
        case .albumDetail: return "albumDetail"
        case .browserList: return "browserList"
        case .browserTracks: return "browserTracks"
        case .songTable: return "songTable"
        }
    }

    private var arrowName: String {
        guard let arrow = navigation.arrow else { return "—" }
        switch arrow.direction {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        }
    }

    private var scrollName: String {
        guard let event = navigation.scrollEvent else { return "—" }
        switch event.command {
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        }
    }
}

struct DebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Debug Panel") {
                openWindow(id: "debug")
            }
            .keyboardShortcut("d", modifiers: [.command, .option, .control])
        }
    }
}
