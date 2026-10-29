import SwiftUI
import AppKit

// MARK: - Album grid

private struct AlbumCardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    @Binding var openAlbumID: UUID?
    let viewKey: String

    @ObservedObject private var debug = DebugSettings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var expandedAlbum: Album?
    @State private var columnCount = 5
    @State private var gridCardWidth: CGFloat = 0
    @State private var gridWidth: CGFloat = 0
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var albumIndexByID: [UUID: Int] = [:]
    @State private var pendingLocateRequest: AlbumLocateRequest?
    @State private var lastRevealSource = "—"
    @State private var lastRevealTarget: CGFloat?
    @State private var lastRevealOffsetBefore: CGFloat = 0
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBaseSelection: Set<UUID> = []
    @State private var gridGlobalOrigin: CGPoint = .zero
    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = ListScrollMetrics()

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 22)]
    private static let contentTopPadding: CGFloat = 22
    private var contentTopPadding: CGFloat { Self.contentTopPadding }

    init(albums: [Album], openAlbumID: Binding<UUID?>, viewKey: String) {
        self.albums = albums
        self._openAlbumID = openAlbumID
        self.viewKey = viewKey

        let stored = openAlbumID.wrappedValue == nil
            ? SessionViewState.shared.albumState(for: viewKey)
            : nil
        let saved = stored?.itemCount == albums.count ? stored : nil
        _scrollPosition = State(initialValue: ScrollPosition(
            idType: Never.self,
            y: max(0, saved?.offset ?? 0)
        ))
    }

    private var player: PlayerState { PlayerState.shared }

    var body: some View {
        ZStack {
            // Keep the grid mounted while an album is open so opening a detail
            // and coming back does not rebuild or reposition the parent grid.
            grid
                .debugFrame("AlbumGrid")
                .opacity(expandedAlbum == nil ? 1 : 0)
                .allowsHitTesting(expandedAlbum == nil)
                .accessibilityHidden(expandedAlbum != nil)

            if let album = expandedAlbum {
                AlbumDetailView(album: album) {
                    closeAlbum()
                }
                .id(album.id)
                .background(Theme.contentBackground)
                .zIndex(1)
            }
        }
        .background(Theme.contentBackground)
        .onReceive(NotificationCenter.default.publisher(for: .goBackRequested)) { _ in
            if expandedAlbum != nil { closeAlbum() }
        }
        .onChange(of: openAlbumID, initial: true) { _, id in
            guard let id else { return }
            revealAlbum(id: id, in: albums)
        }
        .onAppear {
            if !albums.isEmpty {
                let valid = Set(albums.map(\.id))
                selectedIDs.formIntersection(valid)
                if let selectionAnchor, !valid.contains(selectionAnchor) {
                    self.selectionAnchor = nil
                }
            }
            updateStatusBar()
            rebuildAlbumIndex()
            publishDebugState()
            if let request = DebugState.shared.albumLocateRequest {
                pendingLocateRequest = request
            }
            attemptPendingLocate()
        }
        .onDisappear {
            guard metrics.viewportHeight > 0 else { return }
            SessionViewState.shared.saveAlbum(
                .init(offset: metrics.offset,
                      itemCount: albums.count),
                for: viewKey
            )
        }
        .onChange(of: selectedIDs) { _, _ in
            updateStatusBar()
            publishDebugState()
        }
        .onChange(of: expandedAlbum) { _, _ in updateStatusBar() }
        .onReceive(NavigationRouter.shared.arrowEvents) { arrow in
            guard NavigationRouter.shared.focus == .albumGrid else { return }
            moveSelection(arrow.direction)
        }
        .onReceive(NavigationRouter.shared.scrollEvents) { event in
            guard NavigationRouter.shared.focus == .albumGrid else { return }
            handleScroll(event.command)
        }
        .onReceive(DebugState.shared.$albumLocateRequest) { request in
            guard let request else { return }
            pendingLocateRequest = request
            attemptPendingLocate()
        }
        .onChange(of: albums) { _, newAlbums in
            rebuildAlbumIndex()
            // If the target album was hidden by the previous search results,
            // open it as soon as the unfiltered album list arrives.
            if let id = openAlbumID {
                revealAlbum(id: id, in: newAlbums)
            }
            let valid = Set(newAlbums.map(\.id))
            selectedIDs.formIntersection(valid)
            if let selectionAnchor, !valid.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
            if let expandedAlbum, !valid.contains(expandedAlbum.id) {
                closeAlbum()
            }
            updateStatusBar()
            publishDebugState()
            attemptPendingLocate()
        }
    }

    private func revealAlbum(id: UUID, in albums: [Album]) {
        guard let album = albums.first(where: { $0.id == id }) else { return }
        selectedIDs = [album.id]
        selectionAnchor = album.id
        expandedAlbum = album
        openAlbumID = nil
        NavigationRouter.shared.setFocus(.albumDetail)
    }

    private func closeAlbum() {
        expandedAlbum = nil
        NavigationRouter.shared.setFocus(.albumGrid)
    }

    /// While an album is expanded, AlbumDetailView owns the status bar context
    /// so it can switch between the album and the selected track.
    private func updateStatusBar() {
        guard expandedAlbum == nil else { return }
        if !selectedIDs.isEmpty {
            StatusBarCenter.shared.context = .albums(Array(selectedIDs))
        } else {
            StatusBarCenter.shared.context = .library
        }
    }

    private var rowCount: Int {
        guard columnCount > 0 else { return 0 }
        return (albums.count + columnCount - 1) / columnCount
    }

    private func isLastRow(_ index: Int) -> Bool {
        guard rowCount > 0 else { return true }
        return index >= (rowCount - 1) * max(columnCount, 1)
    }

    @ViewBuilder
    private func albumCard(_ album: Album) -> some View {
        AlbumCard(album: album, isSelected: selectedIDs.contains(album.id)) {
            player.play(album.songs)
        }
        .id(album.id)
        .debugFrame("AlbumCard \(album.title) [\(album.id.uuidString.prefix(4))]")
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AlbumCardFramesKey.self,
                    value: [album.id: proxy.frame(in: .named("albumGridSpace"))]
                )
            }
        )
        .contentShape(Rectangle())
        .gesture(
            TapGesture().onEnded {
                handleCardTap(album)
            }
        )
        .contextMenu {
            Button("Play") { player.play(contextSongs(for: album)) }
            Button("Shuffle") { player.playShuffled(contextSongs(for: album)) }
            Divider()
            AddToPlaylistMenu(songs: contextSongs(for: album))
            Button("Play Next") { player.playNext(contextSongs(for: album)) }
            Button("Play Later") { player.playLater(contextSongs(for: album)) }
            Divider()
            Button("Get Info…") {
                InfoCenter.shared.target = .album(album.id)
                openWindow(id: "get-info")
            }
            Divider()
            Button("Delete…") {
                LibraryDeletion.confirmDelete(albums: contextAlbums(for: album))
            }
            .disabled(!LibraryDeletion.canDelete(albums: contextAlbums(for: album)))
        }
        .longPressArmable { dragPayload(for: album) }
    }

    private var grid: some View {
        GeometryReader { viewport in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                            albumCard(album)
                                .padding(.bottom, isLastRow(index) ? 0 : 26)
                        }
                    }
                    .padding(contentTopPadding)
                    .overlay {
                        if debug.showAlbumGridLayout {
                            AlbumGridLayoutOverlay(
                                columns: columnCount,
                                cardWidth: gridCardWidth,
                                cardHeight: gridCardHeight,
                                rowSpacing: 26,
                                padding: contentTopPadding,
                                selectedActualFrame: selectedActualFrame,
                                selectedModelFrame: selectedModelFrame,
                                viewportTop: metrics.offset,
                                viewportBottom: metrics.offset + metrics.viewportHeight,
                                revealTarget: lastRevealTarget
                            )
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { updateGridMetrics(width: geo.size.width) }
                                .onChange(of: geo.size.width) { _, width in
                                    updateGridMetrics(width: width)
                                }
                        }
                    )
                }
                .frame(minHeight: viewport.size.height, alignment: .top)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { clearSelection() }
                )
                .coordinateSpace(name: "albumGridSpace")
                .onPreferenceChange(AlbumCardFramesKey.self) {
                    cardFrames = $0
                    publishDebugState()
                    updateLocatorRenderedFrameIfNeeded()
                }
                .overlay(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { gridGlobalOrigin = proxy.frame(in: .global).origin }
                            .onChange(of: proxy.frame(in: .global).origin) { _, origin in
                                gridGlobalOrigin = origin
                            }
                    }
                    .allowsHitTesting(false)
                )
                .overlay { marqueeOverlay }
                .simultaneousGesture(marqueeGesture)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ListScrollMetrics.self) { geometry in
                ListScrollMetrics(offset: geometry.contentOffset.y,
                                  viewportHeight: geometry.containerSize.height,
                                  contentHeight: geometry.contentSize.height)
            } action: { _, new in
                metrics = new
                publishDebugState()
                attemptPendingLocate()
            }
        }
    }

    private var currentGridSampleFrame: CGRect? {
        for frame in cardFrames.values {
            if frame.maxY > metrics.offset, frame.minY < metrics.offset + metrics.viewportHeight {
                return frame
            }
        }
        return nil
    }

    private func updateGridMetrics(width: CGFloat) {
        gridWidth = width
        let cols = columns(for: width)
        columnCount = cols
        let available = width - 44 - CGFloat(max(cols - 1, 0)) * 22
        gridCardWidth = max(available / CGFloat(max(cols, 1)), 1)
        publishDebugState()
        attemptPendingLocate()
    }

    private func publishDebugState() {
        let currentAlbumID = selectedAlbumID
        let selectedIndex = currentAlbumID.flatMap { albumIndexByID[$0] } ?? -1
        let selectedID = currentAlbumID?.uuidString ?? "—"
        let modelFrame = selectedModelFrame
        let actualFrame = selectedActualFrame
        let selectedFrameDelta = modelFrame.flatMap { model in
            actualFrame.map { frameDelta(model, $0) }
        }
        let firstAlbumGap = albums.first.flatMap { album in
            cardFrames[album.id].map { frame in
                let gap = frame.minY - metrics.offset
                return abs(gap) < 0.05 ? 0 : gap
            }
        }
        let visibleDeltas = visibleFrameDeltas(for: gridLayout)
        let scrollID = scrollPosition.viewID.map { String(describing: $0) } ?? "nil"
        let scrollPoint = scrollPosition.point.map {
            String(format: "%.1f, %.1f", $0.x, $0.y)
        } ?? "nil"
        let scrollEdge = scrollPosition.edge.map { String(describing: $0) } ?? "nil"
        DebugState.shared.albumGrid = AlbumGridDebugInfo(
            width: gridWidth,
            columns: columnCount,
            cardWidth: gridCardWidth,
            cardHeight: gridCardHeight,
            rowHeight: gridCardHeight + 26,
            total: albums.count,
            selected: selectedIDs.count,
            selectedIndex: selectedIndex,
            selectedID: selectedID,
            firstAlbumGap: firstAlbumGap,
            minVisibleDelta: visibleDeltas?.min,
            maxVisibleDelta: visibleDeltas?.max,
            selectedActualFrame: actualFrame,
            selectedModelFrame: modelFrame,
            selectedFrameDelta: selectedFrameDelta,
            lastRevealSource: lastRevealSource,
            lastRevealTarget: lastRevealTarget,
            lastRevealOffsetBefore: lastRevealOffsetBefore,
            scrollID: scrollID,
            scrollPoint: scrollPoint,
            scrollEdge: scrollEdge,
            scrollPositionedByUser: scrollPosition.isPositionedByUser,
            offset: metrics.offset,
            viewport: metrics.viewportHeight,
            content: metrics.contentHeight
        )
    }

    private func rebuildAlbumIndex() {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(albums.count)
        for (index, album) in albums.enumerated() {
            map[album.id] = index
        }
        albumIndexByID = map
    }

    private var gridCardHeight: CGFloat {
        let width = gridCardWidth > 0 ? gridCardWidth : 182
        let textHeight = currentGridSampleFrame.map { max($0.height - $0.width, 0) } ?? 38
        return width + textHeight
    }

    private var gridLayout: AlbumGridLayout {
        AlbumGridLayout(count: albums.count,
                        columns: max(columnCount, 1),
                        cardWidth: gridCardWidth > 0 ? gridCardWidth : 182,
                        cardHeight: gridCardHeight,
                        columnSpacing: 22,
                        rowSpacing: 26,
                        padding: contentTopPadding)
    }

    private var selectedAlbumID: UUID? {
        selectionAnchor ?? selectedIDs.first
    }

    private var selectedModelFrame: CGRect? {
        guard let id = selectedAlbumID,
              let index = albumIndexByID[id] else { return nil }
        return gridLayout.frame(at: index)
    }

    private var selectedActualFrame: CGRect? {
        guard let id = selectedAlbumID else { return nil }
        return cardFrames[id]
    }

    private func modelFrame(at index: Int) -> CGRect {
        gridLayout.frame(at: index) ?? .zero
    }

    private func topVisibleAlbumIndex() -> Int? {
        for index in albums.indices {
            let frame = modelFrame(at: index)
            if frame.maxY > metrics.offset + 0.5 {
                return index
            }
        }
        return nil
    }

    private func isOnScreen(_ id: UUID, index: Int) -> Bool {
        let frame = modelFrame(at: index)
        return frame.maxY > metrics.offset + 0.5
            && frame.minY < metrics.offset + metrics.viewportHeight - 0.5
    }

    private func moveSelection(_ direction: NavigationDirection) {
        guard expandedAlbum == nil, !albums.isEmpty else { return }
        let columns = max(columnCount, 1)
        let delta: Int
        switch direction {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -columns
        case .down: delta = columns
        }

        let currentID = selectionAnchor ?? selectedIDs.first
        let index: Int
        if let currentID,
           let current = albums.firstIndex(where: { $0.id == currentID }),
           isOnScreen(currentID, index: current) {
            index = min(max(current + delta, 0), albums.count - 1)
        } else if let top = topVisibleAlbumIndex() {
            index = top
        } else if let currentID,
                  let current = albums.firstIndex(where: { $0.id == currentID }) {
            index = min(max(current + delta, 0), albums.count - 1)
        } else {
            index = 0
        }

        let album = albums[index]
        selectedIDs = [album.id]
        selectionAnchor = album.id
        revealSelection()
    }

    private func revealSelection() {
        guard let id = selectionAnchor,
              let index = albumIndexByID[id] else { return }
        let frame = modelFrame(at: index)
        let target = ListScroll.revealTarget(for: frame,
                                             metrics: metrics,
                                             padding: contentTopPadding)
        lastRevealSource = "model"
        lastRevealTarget = target
        lastRevealOffsetBefore = metrics.offset
        if let target {
            scrollPosition.scrollTo(y: target)
        }
        publishDebugState()
    }

    private func handleScroll(_ command: NavigationScrollCommand) {
        guard expandedAlbum == nil else { return }
        switch command {
        case .home:
            scrollPosition.scrollTo(edge: .top)
        case .end:
            scrollPosition.scrollTo(edge: .bottom)
        case .pageUp, .pageDown:
            guard metrics.viewportHeight > 0 else { return }
            let rowHeight = gridCardHeight + 26
            let visibleRows = max(1, Int(ceil(metrics.viewportHeight / rowHeight)))
            let pageHeight = CGFloat(max(1, visibleRows - 1)) * rowHeight
            let delta = command == .pageUp ? -pageHeight : pageHeight
            let target = min(max(metrics.offset + delta, 0), metrics.maxOffset)
            scrollPosition.scrollTo(y: target)
        }
    }

    private func attemptPendingLocate() {
        guard let request = pendingLocateRequest else { return }
        guard !albums.isEmpty else {
            DebugState.shared.albumLocator = AlbumLocatorDebugInfo(
                status: "waiting for albums",
                requestedID: request.albumID.uuidString
            )
            return
        }
        guard let index = albumIndexByID[request.albumID] else {
            DebugState.shared.albumLocator = AlbumLocatorDebugInfo(
                status: "not found",
                requestedID: request.albumID.uuidString,
                offset: metrics.offset,
                viewport: metrics.viewportHeight,
                content: metrics.contentHeight
            )
            finishPendingLocate(request)
            return
        }
        guard gridWidth > 0, gridCardWidth > 0, columnCount > 0,
              metrics.viewportHeight > 0, metrics.contentHeight > 0 else {
            DebugState.shared.albumLocator = AlbumLocatorDebugInfo(
                status: "waiting for layout",
                requestedID: request.albumID.uuidString,
                foundIndex: index,
                columns: columnCount,
                cardWidth: gridCardWidth,
                cardHeight: gridCardHeight,
                rowHeight: gridCardHeight + 26,
                offset: metrics.offset,
                viewport: metrics.viewportHeight,
                content: metrics.contentHeight
            )
            return
        }

        let layout = gridLayout
        guard let computed = layout.frame(at: index) else {
            finishPendingLocate(request)
            return
        }
        let actual = cardFrames[request.albumID]
        let delta = actual.map { frameDelta(computed, $0) }
        let visibleDeltas = visibleFrameDeltas(for: layout)
        let target = ListScroll.ensureVisibleTarget(for: computed,
                                                    metrics: metrics,
                                                    padding: contentTopPadding)

        if expandedAlbum != nil {
            expandedAlbum = nil
        }
        selectedIDs = [request.albumID]
        selectionAnchor = request.albumID
        NavigationRouter.shared.setFocus(.albumGrid)
        if let target {
            scrollPosition.scrollTo(y: target)
        }

        DebugState.shared.albumLocator = AlbumLocatorDebugInfo(
            status: target == nil ? "already visible" : "scrolled",
            requestedID: request.albumID.uuidString,
            foundIndex: index,
            columns: layout.columns,
            cardWidth: layout.cardWidth,
            cardHeight: layout.cardHeight,
            rowHeight: layout.rowHeight,
            computedFrame: computed,
            actualFrame: actual,
            frameDelta: delta,
            minVisibleFrameDelta: visibleDeltas?.min,
            maxVisibleFrameDelta: visibleDeltas?.max,
            offset: metrics.offset,
            viewport: metrics.viewportHeight,
            content: metrics.contentHeight,
            targetOffset: target
        )

        finishPendingLocate(request)
    }

    private func finishPendingLocate(_ request: AlbumLocateRequest) {
        pendingLocateRequest = nil
        if DebugState.shared.albumLocateRequest?.id == request.id {
            DebugState.shared.albumLocateRequest = nil
        }
    }

    private func frameDelta(_ computed: CGRect, _ actual: CGRect) -> CGFloat {
        max(max(abs(computed.minX - actual.minX), abs(computed.minY - actual.minY)),
            max(abs(computed.width - actual.width), abs(computed.height - actual.height)))
    }

    private func visibleFrameDeltas(for layout: AlbumGridLayout) -> (min: CGFloat, max: CGFloat)? {
        var minimum: CGFloat?
        var maximum: CGFloat?
        for (id, actual) in cardFrames {
            guard actual.maxY > metrics.offset + 0.5,
                  actual.minY < metrics.offset + metrics.viewportHeight - 0.5 else { continue }
            guard let index = albumIndexByID[id],
                  let computed = layout.frame(at: index) else { continue }
            let delta = frameDelta(computed, actual)
            minimum = min(minimum ?? delta, delta)
            maximum = max(maximum ?? delta, delta)
        }
        guard let minimum, let maximum else { return nil }
        return (minimum, maximum)
    }

    private func updateLocatorRenderedFrameIfNeeded() {
        var info = DebugState.shared.albumLocator
        guard info.actualFrame == nil,
              let id = UUID(uuidString: info.requestedID),
              let actual = cardFrames[id],
              let index = albumIndexByID[id],
              let computed = gridLayout.frame(at: index) else { return }
        info.actualFrame = actual
        info.frameDelta = frameDelta(computed, actual)
        let deltas = visibleFrameDeltas(for: gridLayout)
        info.minVisibleFrameDelta = deltas?.min
        info.maxVisibleFrameDelta = deltas?.max
        DebugState.shared.albumLocator = info
    }

    private func contextAlbums(for album: Album) -> [Album] {
        guard selectedIDs.contains(album.id), selectedIDs.count > 1 else { return [album] }
        return albums.filter { selectedIDs.contains($0.id) }
    }

    private func contextSongs(for album: Album) -> [Song] {
        contextAlbums(for: album).flatMap(\.songs)
    }

    private func dragPayload(for album: Album) -> DragController.Payload? {
        let targets = contextAlbums(for: album)
        let songs = targets.flatMap(\.songs)
        guard !songs.isEmpty else { return nil }
        if targets.count > 1 {
            return .init(songs: songs,
                         title: "\(targets.count) albums",
                         subtitle: "\(songs.count) songs",
                         artwork: nil)
        }
        return .init(songs: songs,
                     title: album.title,
                     subtitle: "\(songs.count) songs",
                     artwork: album.artwork)
    }

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width + 22) / (158 + 22)))
    }

    private func handleCardTap(_ album: Album) {
        NavigationRouter.shared.setFocus(.albumGrid)
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        if shift,
           let anchor = selectionAnchor,
           let from = albums.firstIndex(where: { $0.id == anchor }),
           let to = albums.firstIndex(where: { $0.id == album.id }) {
            let range = from <= to ? from...to : to...from
            let ids = Set(range.map { albums[$0].id })
            selectedIDs = command ? selectedIDs.union(ids) : ids
        } else if command {
            if selectedIDs.contains(album.id) {
                selectedIDs.remove(album.id)
            } else {
                selectedIDs.insert(album.id)
            }
            selectionAnchor = selectedIDs.isEmpty ? nil : album.id
        } else {
            selectedIDs = [album.id]
            selectionAnchor = album.id
            expandedAlbum = album
        }
    }

    private func clearSelection() {
        NavigationRouter.shared.setFocus(.albumGrid)
        selectedIDs.removeAll()
        selectionAnchor = nil
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("albumGridSpace"))
            .onChanged { value in
                if DragController.shared.isArmed {
                    DragController.shared.isMarqueeActive = false
                    marqueeStart = nil
                    marqueeCurrent = nil
                    if DragController.shared.payload == nil {
                        DragController.shared.beginArmed()
                    }
                    let globalLocation = CGPoint(x: value.location.x + gridGlobalOrigin.x,
                                                 y: value.location.y + gridGlobalOrigin.y)
                    DragController.shared.update(location: globalLocation)
                    return
                }
                DragController.shared.isMarqueeActive = true
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeBaseSelection = selectedIDs
                }
                marqueeCurrent = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                if DragController.shared.payload != nil {
                    DragController.shared.finish()
                }
                DragController.shared.isMarqueeActive = false
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    private var marqueeOverlay: some View {
        Group {
            if let start = marqueeStart, let current = marqueeCurrent {
                let rect = marqueeRect(start, current)
                Rectangle()
                    .fill(Theme.selectionFill.opacity(0.14))
                    .overlay(
                        Rectangle().strokeBorder(Theme.selectionFill.opacity(0.80), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func marqueeRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }

    private func updateMarqueeSelection() {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let rect = marqueeRect(start, current)
        var hits: Set<UUID> = []
        for (index, album) in albums.enumerated() where modelFrame(at: index).intersects(rect) {
            hits.insert(album.id)
        }
        let additive = NSEvent.modifierFlags.contains(.command)
            || NSEvent.modifierFlags.contains(.shift)
        selectedIDs = additive ? marqueeBaseSelection.union(hits) : hits
    }
}

private struct AlbumCard: View {
    let album: Album
    let isSelected: Bool
    let onPlay: () -> Void

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AlbumArtwork(artwork: album.artwork)
                    .aspectRatio(1, contentMode: .fit)

                if hover {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Theme.selectionFill : .clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(hover ? 0.20 : 0.05), radius: hover ? 5 : 1, y: hover ? 2 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .onHover { hover = $0 }
    }
}

// MARK: - Expanded album detail

private struct ArtistLinkText: View {
    let name: String
    var fontSize: CGFloat = 15
    var isSelected: Bool = false
    @State private var hover = false

    var body: some View {
        Button {
            NavigationCenter.shared.artistToOpen = name
        } label: {
            Text(name)
                .font(.system(size: fontSize))
                .foregroundColor(textColor)
                .underline(hover)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Show albums by \(name)")
    }

    private var textColor: Color {
        if isSelected { return Theme.highlightForeground.opacity(hover ? 1 : 0.85) }
        return hover ? Theme.highlight : Theme.secondaryText
    }
}

private struct AlbumDetailView: View {
    let album: Album
    let onClose: () -> Void

    @ObservedObject private var playback = PlaybackStatus.shared
    @State private var selectedSongIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var trackFrames: [UUID: CGRect] = [:]
    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = ListScrollMetrics()

    private var isMultiDisc: Bool { album.isMultiDisc }
    private var player: PlayerState { PlayerState.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("All Albums")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Theme.highlight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)

                HStack(alignment: .top, spacing: 24) {
                    AlbumArtwork(artwork: album.artwork)
                        .frame(width: 208, height: 208)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(album.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(2)
                        ArtistLinkText(name: album.artist)
                            .padding(.top, 2)
                        Text(albumInfo)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryText)
                            .padding(.top, 4)

                        HStack(spacing: 8) {
                            AlbumActionButton(title: "Play", icon: "play.fill") {
                                player.play(album.songs)
                            }
                            AlbumActionButton(title: "Shuffle", icon: "shuffle") {
                                player.playShuffled(album.songs)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 14)

                        Hairline()

                        VStack(spacing: 0) {
                            ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                                let selected = selectedSongIDs.contains(song.id)
                                let previousSelected = index > 0 && selectedSongIDs.contains(album.songs[index - 1].id)
                                let nextSelected = index + 1 < album.songs.count && selectedSongIDs.contains(album.songs[index + 1].id)
                                let contextSelection = selected && selectedSongIDs.count > 1
                                    ? album.songs.filter { selectedSongIDs.contains($0.id) }
                                    : []
                                AlbumTrackRow(
                                    song: song,
                                    albumArtist: album.artist,
                                    isMultiDisc: isMultiDisc,
                                    isSelected: selected,
                                    isCurrent: playback.currentSongID == song.id,
                                    isMissing: playback.missingFileIDs.contains(song.id),
                                    isPlaying: playback.isPlaying,
                                    previousSelected: previousSelected,
                                    nextSelected: nextSelected
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { handleRowTap(song) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    player.play(song, in: album.songs)
                                })
                                .id(song.id)
                                .songContextMenu(song, queue: album.songs, selection: contextSelection)
                                .selectionFrame(id: song.id, in: "albumTrackSpace")
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: AlbumCardFramesKey.self,
                                            value: [song.id: proxy.frame(in: .named("albumDetailContent"))]
                                        )
                                    }
                                )
                                .longPressArmable { dragPayload(for: song) }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.top, 4)
                        .marqueeSelectable(selection: $selectedSongIDs, space: "albumTrackSpace")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(22)
            .coordinateSpace(name: "albumDetailContent")
            .onPreferenceChange(AlbumCardFramesKey.self) { trackFrames = $0 }
            .onTapGesture { clearSelection() }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ListScrollMetrics.self) { geometry in
            ListScrollMetrics(offset: geometry.contentOffset.y,
                              viewportHeight: geometry.containerSize.height,
                              contentHeight: geometry.contentSize.height)
        } action: { _, new in
            metrics = new
            publishDebugState()
        }
        .debugFrame("AlbumDetail")
        .onReceive(NavigationRouter.shared.arrowEvents) { arrow in
            guard NavigationRouter.shared.focus == .albumDetail else { return }
            moveSelection(arrow.direction)
        }
        .onReceive(NavigationRouter.shared.scrollEvents) { event in
            guard NavigationRouter.shared.focus == .albumDetail else { return }
            handleScroll(event.command)
        }
        .onChange(of: selectedSongIDs) { _, _ in
            updateStatusBar()
            publishDebugState()
        }
        .onAppear {
            NavigationRouter.shared.setFocus(.albumDetail)
            updateStatusBar()
            publishDebugState()
            guard selectedSongIDs.isEmpty,
                  let currentID = playback.currentSongID,
                  album.songs.contains(where: { $0.id == currentID }) else { return }
            selectedSongIDs = [currentID]
            selectionAnchor = currentID
            DispatchQueue.main.async {
                scrollPosition.scrollTo(id: currentID, anchor: .center)
            }
        }
    }

    private func publishDebugState() {
        let selectedIndex = selectionAnchor.flatMap { id in
            album.songs.firstIndex(where: { $0.id == id })
        } ?? -1
        DebugState.shared.albumDetail = AlbumDetailDebugInfo(
            album: album.title,
            songs: album.songs.count,
            selected: selectedSongIDs.count,
            selectedIndex: selectedIndex,
            offset: metrics.offset,
            viewport: metrics.viewportHeight,
            content: metrics.contentHeight
        )
    }

    private func handleRowTap(_ song: Song) {
        NavigationRouter.shared.setFocus(.albumDetail)
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        if shift,
           let anchor = selectionAnchor,
           let from = album.songs.firstIndex(where: { $0.id == anchor }),
           let to = album.songs.firstIndex(where: { $0.id == song.id }) {
            let range = from <= to ? from...to : to...from
            let ids = Set(range.map { album.songs[$0].id })
            selectedSongIDs = command ? selectedSongIDs.union(ids) : ids
        } else if command {
            if selectedSongIDs.contains(song.id) {
                selectedSongIDs.remove(song.id)
            } else {
                selectedSongIDs.insert(song.id)
            }
            selectionAnchor = selectedSongIDs.isEmpty ? nil : song.id
        } else {
            selectedSongIDs = [song.id]
            selectionAnchor = song.id
        }
    }

    private func clearSelection() {
        NavigationRouter.shared.setFocus(.albumDetail)
        selectedSongIDs.removeAll()
        selectionAnchor = nil
    }

    private func moveSelection(_ direction: NavigationDirection) {
        guard direction == .up || direction == .down else { return }
        let songs = album.songs
        guard !songs.isEmpty else { return }
        let delta = direction == .up ? -1 : 1
        let currentID = selectionAnchor ?? selectedSongIDs.first

        let index: Int
        if let currentID,
           let current = songs.firstIndex(where: { $0.id == currentID }),
           isOnScreen(currentID, index: current) {
            index = min(max(current + delta, 0), songs.count - 1)
        } else if let top = topVisibleSongIndex() {
            index = top
        } else if let currentID,
                  let current = songs.firstIndex(where: { $0.id == currentID }) {
            index = min(max(current + delta, 0), songs.count - 1)
        } else {
            index = 0
        }

        let id = songs[index].id
        selectedSongIDs = [id]
        selectionAnchor = id
        revealSelection()
    }

    private func topVisibleSongIndex() -> Int? {
        for index in album.songs.indices {
            guard let frame = trackFrames[album.songs[index].id] else { continue }
            if frame.maxY > metrics.offset + 0.5 {
                return index
            }
        }
        return nil
    }

    private func isOnScreen(_ id: UUID, index: Int) -> Bool {
        guard let frame = trackFrames[id] else { return false }
        return frame.maxY > metrics.offset + 0.5
            && frame.minY < metrics.offset + metrics.viewportHeight - 0.5
    }

    private func revealSelection() {
        guard let id = selectionAnchor else { return }
        guard let frame = trackFrames[id] else {
            scrollPosition.scrollTo(id: id, anchor: .center)
            return
        }
        guard let target = ListScroll.revealTarget(for: frame,
                                                   metrics: metrics,
                                                   padding: 22) else { return }
        scrollPosition.scrollTo(y: target)
    }

    private func handleScroll(_ command: NavigationScrollCommand) {
        switch command {
        case .home:
            scrollPosition.scrollTo(edge: .top)
        case .end:
            scrollPosition.scrollTo(edge: .bottom)
        case .pageUp, .pageDown:
            guard metrics.viewportHeight > 0 else { return }
            let visibleRows = max(1, Int(ceil(metrics.viewportHeight / 28)))
            let pageHeight = CGFloat(max(1, visibleRows - 1) * 28)
            let delta = command == .pageUp ? -pageHeight : pageHeight
            let target = min(max(metrics.offset + delta, 0), metrics.maxOffset)
            scrollPosition.scrollTo(y: target)
        }
    }

    private func dragPayload(for song: Song) -> DragController.Payload? {
        let songs = selectedSongIDs.contains(song.id) && selectedSongIDs.count > 1
            ? album.songs.filter { selectedSongIDs.contains($0.id) }
            : [song]
        guard !songs.isEmpty else { return nil }
        if songs.count > 1 {
            return .init(songs: songs,
                         title: "\(songs.count) songs",
                         subtitle: "Selected tracks",
                         artwork: nil)
        }
        return .init(songs: songs,
                     title: song.title,
                     subtitle: song.artist,
                     artwork: nil)
    }

    private var albumInfo: String {
        var parts: [String] = []
        if !album.genre.isEmpty { parts.append(album.genre) }
        if !album.year.isEmpty { parts.append(album.year) }
        if isMultiDisc {
            parts.append("\(album.effectiveDiscTotal) discs")
        }
        parts.append("\(album.songs.count) songs")
        return parts.joined(separator: " · ")
    }

    private func updateStatusBar() {
        if !selectedSongIDs.isEmpty {
            StatusBarCenter.shared.context = .tracks(Array(selectedSongIDs))
        } else {
            StatusBarCenter.shared.context = .album(album.id)
        }
    }


}

// MARK: - Album action buttons (Play / Shuffle)

struct AlbumActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Theme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hover ? Theme.controlFillActive : Theme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct AlbumTrackRow: View {
    let song: Song
    let albumArtist: String
    let isMultiDisc: Bool
    let isSelected: Bool
    let isCurrent: Bool
    let isMissing: Bool
    let isPlaying: Bool
    let previousSelected: Bool
    let nextSelected: Bool

    @State private var hover = false

    private var trackLabel: String {
        guard isMultiDisc, song.discNumber > 0, song.trackNumber > 0 else {
            return song.trackNumberLabel
        }
        return "\(song.discNumber)-\(String(format: "%02d", song.trackNumber))"
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isMissing {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.highlightForeground : .orange)
                } else if isCurrent {
                    Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.highlightForeground : Theme.highlight)
                } else {
                    Text(trackLabel)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? Theme.highlightForeground.opacity(0.85) : Theme.secondaryText)
                }
            }
            .frame(width: isMultiDisc ? 40 : 30, alignment: .leading)

            HStack(spacing: 6) {
                Text(song.title)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? Theme.highlightForeground : Theme.primaryText)
                    .lineLimit(1)
                if song.artist != albumArtist {
                    Text(song.artist)
                        .font(.system(size: 11.5))
                        .foregroundColor(isSelected ? Theme.highlightForeground.opacity(0.72) : Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 12)

            Text(song.timeLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(isSelected ? Theme.highlightForeground.opacity(0.85) : Theme.secondaryText)
                .frame(width: 52, alignment: .trailing)

            StarButton(songID: song.id, isSelected: isSelected)
                .frame(width: 26)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: previousSelected ? 0 : 5,
                bottomLeadingRadius: nextSelected ? 0 : 5,
                bottomTrailingRadius: nextSelected ? 0 : 5,
                topTrailingRadius: previousSelected ? 0 : 5
            )
            .fill(isSelected ? Theme.selectionFill : (hover ? Theme.rowHover : Color.clear))
        )
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}

// MARK: - Album list (compact rows)

func rowBackground(index: Int, selected: Bool) -> Color {
    if selected { return Theme.selectionFill }
    return index.isMultiple(of: 2) ? Theme.contentBackground : Theme.rowAlternate
}

// MARK: - Song table

enum SongTableContext: Hashable {
    case songs
    /// Built-in Stared playlist, backed by the songs' star flags.
    case starred
    case playlist(UUID)

    var storageKey: String {
        switch self {
        case .songs: return "songs"
        case .starred: return "starred"
        case .playlist: return "playlist"
        }
    }

    var viewStateKey: String {
        switch self {
        case .songs: return "songs"
        case .starred: return "starred"
        case .playlist(let id): return "playlist:\(id.uuidString)"
        }
    }

    /// Sorting is remembered per playlist, while column widths and visibility
    /// remain shared by the table kind.
    var sortStorageKey: String {
        switch self {
        case .songs: return "songs"
        case .starred: return "starred"
        case .playlist(let id): return "playlist.\(id.uuidString)"
        }
    }

    var playlistID: UUID? {
        if case .playlist(let id) = self { return id }
        return nil
    }
}

enum SongColumn: String, CaseIterable, Hashable {
    case track, name, time, artist, albumArtist, album, genre, plays, addSequence, addTime

    var title: String {
        switch self {
        case .track: return "#"
        case .name: return "Name"
        case .time: return "Time"
        case .artist: return "Artist"
        case .albumArtist: return "Album Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .plays: return "Plays"
        case .addSequence: return "Add Seq"
        case .addTime: return "Add Time"
        }
    }

    var isPlaylistOnly: Bool {
        self == .addSequence || self == .addTime
    }

    var isTrailing: Bool {
        switch self {
        case .track, .time, .plays, .addSequence: return true
        default: return false
        }
    }

    var minWidth: Double {
        switch self {
        case .track: return 24
        case .name: return 120
        case .time: return 44
        case .artist: return 60
        case .albumArtist: return 70
        case .album: return 60
        case .genre: return 50
        case .plays: return 40
        case .addSequence: return 68
        case .addTime: return 130
        }
    }

    static let defaultOrder: [SongColumn] = [.name, .artist, .albumArtist, .album, .genre, .plays, .track, .time]
}

struct SongTable: View {
    let songs: [Song]
    let context: SongTableContext
    let playlistInfo: [UUID: PlaylistItemInfo]

    @ObservedObject private var playback = PlaybackStatus.shared
    @Environment(\.openWindow) private var openWindow
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @AppStorage private var sortKeyRaw: String
    @AppStorage private var sortAscending: Bool
    @State private var sortedSongs: [Song] = []
    @State private var rowIndexByID: [UUID: Int] = [:]
    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = ListScrollMetrics()

    @AppStorage private var nameWidth: Double
    @AppStorage private var trackWidth: Double
    @AppStorage private var timeWidth: Double
    @AppStorage private var artistWidth: Double
    @AppStorage private var albumArtistWidth: Double
    @AppStorage private var albumWidth: Double
    @AppStorage private var genreWidth: Double
    @AppStorage private var playsWidth: Double
    @AppStorage private var addSequenceWidth: Double
    @AppStorage private var addTimeWidth: Double

    @AppStorage private var showTrack: Bool
    @AppStorage private var showTime: Bool
    @AppStorage private var showArtist: Bool
    @AppStorage private var showAlbumArtist: Bool
    @AppStorage private var showAlbum: Bool
    @AppStorage private var showGenre: Bool
    @AppStorage private var showPlays: Bool
    @AppStorage private var showAddSequence: Bool
    @AppStorage private var showAddTime: Bool

    @AppStorage private var columnOrderCSV: String

    @State private var draggingColumn: SongColumn?
    @State private var dragOffset: CGFloat = 0

    /// Fixed leading column showing the playback state of the current row.
    private let statusWidth: CGFloat = 28
    /// Fixed trailing slot for the per-track star button.
    private let starWidth: CGFloat = 28
    private static let contentTopPadding: CGFloat = 6
    private var contentTopPadding: CGFloat { Self.contentTopPadding }

    private var player: PlayerState { PlayerState.shared }

    init(songs: [Song], context: SongTableContext,
         playlistInfo: [UUID: PlaylistItemInfo] = [:]) {
        self.songs = songs
        self.context = context
        self.playlistInfo = playlistInfo
        let prefix = "songTable2.\(context.storageKey)"
        let sortPrefix = "songTable2.\(context.sortStorageKey)"
        _nameWidth = AppStorage(wrappedValue: 300, "\(prefix).nameWidth")
        _trackWidth = AppStorage(wrappedValue: 32, "\(prefix).trackWidth")
        _timeWidth = AppStorage(wrappedValue: 52, "\(prefix).timeWidth")
        _artistWidth = AppStorage(wrappedValue: 150, "\(prefix).artistWidth")
        _albumArtistWidth = AppStorage(wrappedValue: 150, "\(prefix).albumArtistWidth")
        _albumWidth = AppStorage(wrappedValue: 190, "\(prefix).albumWidth")
        _genreWidth = AppStorage(wrappedValue: 130, "\(prefix).genreWidth")
        _playsWidth = AppStorage(wrappedValue: 60, "\(prefix).playsWidth")
        _addSequenceWidth = AppStorage(wrappedValue: 60, "\(prefix).addSequenceWidth")
        _addTimeWidth = AppStorage(wrappedValue: 150, "\(prefix).addTimeWidth")
        _showTrack = AppStorage(wrappedValue: false, "\(prefix).showTrack")
        _showTime = AppStorage(wrappedValue: true, "\(prefix).showTime")
        _showArtist = AppStorage(wrappedValue: true, "\(prefix).showArtist")
        _showAlbumArtist = AppStorage(wrappedValue: true, "\(prefix).showAlbumArtist")
        _showAlbum = AppStorage(wrappedValue: true, "\(prefix).showAlbum")
        _showGenre = AppStorage(wrappedValue: true, "\(prefix).showGenre")
        _showPlays = AppStorage(wrappedValue: true, "\(prefix).showPlays")
        _showAddSequence = AppStorage(wrappedValue: true, "\(prefix).showAddSequence")
        _showAddTime = AppStorage(wrappedValue: false, "\(prefix).showAddTime")

        let orderKey = "\(prefix).columnOrder"
        let newDefault = SongColumn.defaultOrder.map(\.rawValue).joined(separator: ",")
        _columnOrderCSV = AppStorage(wrappedValue: newDefault, orderKey)
        _sortKeyRaw = AppStorage(wrappedValue: SongSortKey.name.rawValue, "\(sortPrefix).sortKey")
        _sortAscending = AppStorage(wrappedValue: true, "\(sortPrefix).sortAscending")

        let initialSortKey = SongSortKey(
            rawValue: UserDefaults.standard.string(forKey: "\(sortPrefix).sortKey") ?? ""
        ) ?? .name
        let initialAscending = UserDefaults.standard.object(
            forKey: "\(sortPrefix).sortAscending"
        ) as? Bool ?? true
        let initialSongs = songsSorted(songs,
                                       by: initialSortKey,
                                       ascending: initialAscending,
                                       playlistInfo: playlistInfo)
        var initialIndexes: [UUID: Int] = [:]
        initialIndexes.reserveCapacity(initialSongs.count)
        for (index, song) in initialSongs.enumerated() {
            initialIndexes[song.id] = index
        }
        _sortedSongs = State(initialValue: initialSongs)
        _rowIndexByID = State(initialValue: initialIndexes)

        let stored = SessionViewState.shared.songState(for: context.viewStateKey)
        let saved = stored?.itemCount == songs.count ? stored : nil
        _scrollPosition = State(initialValue: ScrollPosition(
            idType: Never.self,
            y: max(0, saved?.offset ?? 0)
        ))
    }

    // MARK: Column metadata

    private var availableColumns: [SongColumn] {
        context.playlistID == nil
            ? SongColumn.allCases.filter { !$0.isPlaylistOnly }
            : SongColumn.allCases
    }

    private var columnOrder: [SongColumn] {
        let available = availableColumns
        let parsed = columnOrderCSV.split(separator: ",")
            .compactMap { SongColumn(rawValue: String($0)) }
            .filter { available.contains($0) }
        let missing = available.filter { !parsed.contains($0) }
        var result = parsed + missing.filter { !$0.isPlaylistOnly }
        guard context.playlistID != nil else { return result }

        let playlistMissing = missing.filter(\.isPlaylistOnly)
        guard !playlistMissing.isEmpty else { return result }
        let insertion = result.firstIndex(of: .genre).map { $0 + 1 } ?? result.count
        result.insert(contentsOf: playlistMissing, at: insertion)
        return result
    }

    private var displayColumns: [SongColumn] {
        columnOrder.filter { isVisible($0) }
    }

    private func isVisible(_ column: SongColumn) -> Bool {
        switch column {
        case .track: return showTrack
        case .name: return true
        case .time: return showTime
        case .artist: return showArtist
        case .albumArtist: return showAlbumArtist
        case .album: return showAlbum
        case .genre: return showGenre
        case .plays: return showPlays
        case .addSequence: return context.playlistID != nil && showAddSequence
        case .addTime: return context.playlistID != nil && showAddTime
        }
    }

    private func width(of column: SongColumn) -> Double {
        switch column {
        case .track: return trackWidth
        case .name: return nameWidth
        case .time: return timeWidth
        case .artist: return artistWidth
        case .albumArtist: return albumArtistWidth
        case .album: return albumWidth
        case .genre: return genreWidth
        case .plays: return playsWidth
        case .addSequence: return addSequenceWidth
        case .addTime: return addTimeWidth
        }
    }

    private func widthBinding(_ column: SongColumn) -> Binding<Double> {
        switch column {
        case .track: return $trackWidth
        case .name: return $nameWidth
        case .time: return $timeWidth
        case .artist: return $artistWidth
        case .albumArtist: return $albumArtistWidth
        case .album: return $albumWidth
        case .genre: return $genreWidth
        case .plays: return $playsWidth
        case .addSequence: return $addSequenceWidth
        case .addTime: return $addTimeWidth
        }
    }

    private var totalWidth: Double {
        displayColumns.reduce(0) { $0 + width(of: $1) }
    }

    private func sortKey(for column: SongColumn) -> SongSortKey? {
        switch column {
        case .name: return .name
        case .time: return .time
        case .artist: return .artist
        case .albumArtist: return .albumArtist
        case .album: return .album
        case .genre: return .genre
        case .addSequence: return .addSequence
        case .addTime: return .addTime
        case .track, .plays: return nil
        }
    }

    private var sortKey: SongSortKey {
        SongSortKey(rawValue: sortKeyRaw) ?? .name
    }

    private var ascending: Bool { sortAscending }

    private var sorted: [Song] { sortedSongs }

    private func rebuildSorted() {
        let rebuilt = songsSorted(songs, by: sortKey, ascending: ascending,
                                  playlistInfo: playlistInfo)
        var indexes: [UUID: Int] = [:]
        indexes.reserveCapacity(rebuilt.count)
        for (index, song) in rebuilt.enumerated() {
            indexes[song.id] = index
        }
        sortedSongs = rebuilt
        rowIndexByID = indexes
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header(available: geo.size.width)
                Hairline()
                list
            }
            .onAppear {
                fit(in: geo.size.width)
                updateStatusBar()
            }
            .onChange(of: geo.size.width) { _, width in
                fit(in: width)
            }
        }
        .background(Theme.contentBackground)
        .debugFrame("SongTable")
        .task {
            rebuildSorted()
            let valid = Set(songs.map(\.id))
            selectedIDs.formIntersection(valid)
            if let selectionAnchor, !valid.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
            updateStatusBar()
            publishDebugState()
        }
        .onReceive(NavigationRouter.shared.arrowEvents) { arrow in
            guard NavigationRouter.shared.focus == .songTable else { return }
            moveSelection(arrow.direction)
        }
        .onReceive(NavigationRouter.shared.scrollEvents) { event in
            guard NavigationRouter.shared.focus == .songTable else { return }
            handleScroll(event.command)
        }
        .onChange(of: selectedIDs) { _, _ in
            updateStatusBar()
            publishDebugState()
        }
        .onChange(of: songs) { _, newSongs in
            let valid = Set(newSongs.map(\.id))
            selectedIDs.formIntersection(valid)
            if let selectionAnchor, !valid.contains(selectionAnchor) {
                self.selectionAnchor = nil
            }
            rebuildSorted()
            updateStatusBar()
            publishDebugState()
        }
        .onChange(of: playlistInfo) { _, _ in
            rebuildSorted()
            publishDebugState()
        }
        .onDisappear {
            guard metrics.viewportHeight > 0 else { return }
            SessionViewState.shared.saveSong(
                .init(offset: metrics.offset,
                      itemCount: songs.count),
                for: context.viewStateKey
            )
        }
    }

    private func publishDebugState() {
        let selectedIndex = selectionAnchor.flatMap { id in
            rowIndexByID[id]
        } ?? -1
        DebugState.shared.songTable = SongTableDebugInfo(
            context: context.storageKey,
            rows: sorted.count,
            selected: selectedIDs.count,
            selectedIndex: selectedIndex,
            selectedID: (selectionAnchor ?? selectedIDs.first)?.uuidString ?? "",
            offset: metrics.offset,
            viewport: metrics.viewportHeight,
            content: metrics.contentHeight
        )
    }

    private func updateStatusBar() {
        if !selectedIDs.isEmpty {
            StatusBarCenter.shared.context = .tracks(Array(selectedIDs))
        } else if context == .starred {
            StatusBarCenter.shared.context = .starred
        } else if let playlistID = context.playlistID {
            StatusBarCenter.shared.context = .playlist(playlistID)
        } else {
            StatusBarCenter.shared.context = .library
        }
    }

    // MARK: Header

    private func header(available: CGFloat) -> some View {
        let columns = displayColumns
        let boundaries = boundaryPositions(columns)

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: statusWidth, height: 1)
                ForEach(columns, id: \.self) { column in
                    headerCell(column)
                        .offset(x: draggingColumn == column ? dragOffset : 0)
                        .zIndex(draggingColumn == column ? 2 : 0)
                        .gesture(reorderGesture(column))
                }
                Spacer(minLength: 0)
                Color.clear
                    .frame(width: starWidth, height: 1)
            }
            .padding(.horizontal, 10)

            ZStack(alignment: .topLeading) {
                ForEach(Array(boundaries.enumerated()), id: \.offset) { _, entry in
                    resizeHandle(widthBinding(entry.0), at: entry.1,
                                 available: available - statusWidth - starWidth,
                                 minWidth: entry.0.minWidth) { autoFit(entry.0) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 10 + statusWidth)
            .zIndex(1)
        }
        .frame(height: 26)
        .contextMenu {
            if context.playlistID != nil {
                Toggle("Add Seq", isOn: $showAddSequence)
                Toggle("Add Time", isOn: $showAddTime)
                Divider()
            }
            Toggle("Track", isOn: $showTrack)
            Toggle("Time", isOn: $showTime)
            Toggle("Artist", isOn: $showArtist)
            Toggle("Album Artist", isOn: $showAlbumArtist)
            Toggle("Album", isOn: $showAlbum)
            Toggle("Genre", isOn: $showGenre)
            Toggle("Plays", isOn: $showPlays)
        }
    }

    private func boundaryPositions(_ columns: [SongColumn]) -> [(SongColumn, Double)] {
        var x: Double = 0
        return columns.map { column in
            x += width(of: column)
            return (column, x)
        }
    }

    private func headerCell(_ column: SongColumn) -> some View {
        SongHeaderLabel(title: column.title,
                        width: width(of: column),
                        alignment: column.isTrailing ? .trailing : .leading,
                        active: sortKey(for: column) == sortKey,
                        ascending: ascending) {
            if let key = sortKey(for: column) {
                setSort(key)
            }
        }
    }

    private func reorderGesture(_ column: SongColumn) -> some Gesture {
        LongPressGesture(minimumDuration: DragController.longPressDuration)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    draggingColumn = column
                    dragOffset = drag.translation.width
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    let target = targetIndex(for: column, offset: drag.translation.width)
                    move(column, to: target)
                }
                draggingColumn = nil
                dragOffset = 0
            }
    }

    private func targetIndex(for column: SongColumn, offset: CGFloat) -> Int {
        let columns = displayColumns
        guard let from = columns.firstIndex(of: column) else { return 0 }
        var centers: [CGFloat] = []
        var x: CGFloat = 0
        for c in columns {
            let w = CGFloat(width(of: c))
            centers.append(x + w / 2)
            x += w
        }
        let draggedCenter = centers[from] + offset
        var target = from
        for index in columns.indices where index != from {
            if index < from, draggedCenter < centers[index] {
                target = min(target, index)
            }
            if index > from, draggedCenter > centers[index] {
                target = max(target, index)
            }
        }
        return target
    }

    private func move(_ column: SongColumn, to targetVisibleIndex: Int) {
        let columns = displayColumns
        guard let from = columns.firstIndex(of: column), targetVisibleIndex != from else { return }
        var order = columnOrder
        guard let fullFrom = order.firstIndex(of: column) else { return }
        order.remove(at: fullFrom)
        let anchor = columns[targetVisibleIndex]
        guard let fullAnchor = order.firstIndex(of: anchor) else { return }
        let insert = targetVisibleIndex > from ? fullAnchor + 1 : fullAnchor
        order.insert(column, at: min(insert, order.count))
        columnOrderCSV = order.map(\.rawValue).joined(separator: ",")
    }

    private func resizeHandle(_ width: Binding<Double>, at boundary: Double,
                              available: CGFloat, minWidth: Double,
                              onDoubleClick: @escaping () -> Void) -> some View {
        let others = totalWidth - width.wrappedValue
        let maxWidth = max(Double(available) - 20 - others, minWidth)
        return SongColumnHandle(width: width, minWidth: minWidth, maxWidth: maxWidth,
                                onDoubleClick: onDoubleClick)
            .offset(x: boundary - 6)
    }

    private func fit(in available: CGFloat) {
        let limit = Double(available) - 20 - Double(statusWidth) - Double(starWidth)
        guard limit > 40 else { return }

        let others = totalWidth - nameWidth
        if others + nameWidth > limit {
            nameWidth = max(120, min(nameWidth, limit - others))
        }

        let total = totalWidth
        guard total > limit + 0.5 else { return }

        let scale = limit / total
        func scaled(_ value: Double, _ minimum: Double) -> Double { max(minimum, value * scale) }

        if abs(scaled(trackWidth, 24) - trackWidth) > 0.5 { trackWidth = scaled(trackWidth, 24) }
        if abs(scaled(timeWidth, 44) - timeWidth) > 0.5 { timeWidth = scaled(timeWidth, 44) }
        if abs(scaled(artistWidth, 60) - artistWidth) > 0.5 { artistWidth = scaled(artistWidth, 60) }
        if abs(scaled(albumArtistWidth, 70) - albumArtistWidth) > 0.5 { albumArtistWidth = scaled(albumArtistWidth, 70) }
        if abs(scaled(albumWidth, 60) - albumWidth) > 0.5 { albumWidth = scaled(albumWidth, 60) }
        if abs(scaled(genreWidth, 50) - genreWidth) > 0.5 { genreWidth = scaled(genreWidth, 50) }
        if abs(scaled(playsWidth, 40) - playsWidth) > 0.5 { playsWidth = scaled(playsWidth, 40) }
        if abs(scaled(addSequenceWidth, 60) - addSequenceWidth) > 0.5 { addSequenceWidth = scaled(addSequenceWidth, 60) }
        if abs(scaled(addTimeWidth, 130) - addTimeWidth) > 0.5 { addTimeWidth = scaled(addTimeWidth, 130) }
        if abs(scaled(nameWidth, 120) - nameWidth) > 0.5 { nameWidth = scaled(nameWidth, 120) }
    }

    // MARK: Column auto-fit

    private func autoFit(_ column: SongColumn) {
        switch column {
        case .track:
            trackWidth = 32
        case .name:
            let widths = sorted.map { textWidth($0.title, 13) } + [textWidth("Name", 11, .semibold)]
            nameWidth = min(max(Double(widths.max() ?? 100) + 30, 120), 700)
        case .time:
            let widths = sorted.map { textWidth($0.timeLabel, 12) } + [textWidth("Time", 11, .semibold)]
            timeWidth = min(max(Double(widths.max() ?? 40) + 24, 44), 180)
        case .artist:
            artistWidth = fittedWidth(for: sorted.map(\.artist), header: "Artist", min: 60, max: 420)
        case .albumArtist:
            albumArtistWidth = fittedWidth(for: sorted.map(\.albumArtist), header: "Album Artist", min: 70, max: 420)
        case .album:
            albumWidth = fittedWidth(for: sorted.map(\.album), header: "Album", min: 60, max: 420)
        case .genre:
            genreWidth = fittedWidth(for: sorted.map(\.genre), header: "Genre", min: 50, max: 320)
        case .plays:
            playsWidth = fittedWidth(for: sorted.map { String($0.plays) }, header: "Plays", min: 40, max: 160)
        case .addSequence:
            let values = sorted.compactMap { playlistInfo[$0.id]?.sequence }.map(String.init)
            addSequenceWidth = fittedWidth(for: values, header: "Add Seq", min: 60, max: 100)
        case .addTime:
            let values = sorted.compactMap { playlistInfo[$0.id].map { playlistAddedTimeLabel($0.addedAt) } }
            addTimeWidth = fittedWidth(for: values, header: "Add Time", min: 130, max: 260)
        }
    }

    private func fittedWidth(for values: [String], header: String, min: Double, max: Double) -> Double {
        let content = values.map { textWidth($0, 12) }.max() ?? 0
        let headerWidth = textWidth(header, 11, .semibold) + 14
        return Swift.min(Swift.max(Double(Swift.max(content, headerWidth)) + 24, min), max)
    }

    private func textWidth(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Rows

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sorted, id: \.id) { song in
                    rowView(song, index: rowIndexByID[song.id] ?? 0)
                        .id(song.id)
                }
            }
            .padding(.vertical, contentTopPadding)
            .onTapGesture { clearSelection() }
            .marqueeSelectable(selection: $selectedIDs, space: "songTableSpace")
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ListScrollMetrics.self) { geometry in
            ListScrollMetrics(offset: geometry.contentOffset.y,
                              viewportHeight: geometry.containerSize.height,
                              contentHeight: geometry.contentSize.height)
        } action: { _, new in
            metrics = new
            publishDebugState()
        }
        .onTapGesture { clearSelection() }
    }

    private func rowView(_ song: Song, index: Int) -> some View {
        let selected = selectedIDs.contains(song.id)
        let previousSelected = index > 0 && selectedIDs.contains(sorted[index - 1].id)
        let nextSelected = index + 1 < sorted.count && selectedIDs.contains(sorted[index + 1].id)

        return HStack(spacing: 0) {
            statusCell(song, selected: selected)
            ForEach(displayColumns, id: \.self) { column in
                rowCell(column, song: song)
            }
            Spacer(minLength: 0)
            StarButton(songID: song.id, isSelected: selected)
                .frame(width: starWidth)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            if selected {
                // Match AlbumDetailView's track rows: a rounded bar inset from
                // the container edges, with adjacent selected rows joined.
                UnevenRoundedRectangle(
                    topLeadingRadius: previousSelected ? 0 : 5,
                    bottomLeadingRadius: nextSelected ? 0 : 5,
                    bottomTrailingRadius: nextSelected ? 0 : 5,
                    topTrailingRadius: previousSelected ? 0 : 5
                )
                .fill(Theme.selectionFill)
                .padding(.horizontal, 6)
            } else {
                (index.isMultiple(of: 2) ? Theme.contentBackground : Theme.rowAlternate)
            }
        }
        .id(song.id)
        .selectionFrame(id: song.id, in: "songTableSpace")
        .contentShape(Rectangle())
        .onTapGesture { handleRowTap(song) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { player.play(song, in: sorted) })
        .contextMenu {
            Button("Play") { playContext(song) }
            Divider()
            AddToPlaylistMenu(songs: contextSongs(for: song))
            Button("Play Next") { player.playNext(contextSongs(for: song)) }
            Button("Play Later") { player.playLater(contextSongs(for: song)) }
            Divider()
            Button("Get Info…") {
                InfoCenter.shared.target = .song(song.id)
                openWindow(id: "get-info")
            }
            Button("Go to Album") { goToAlbum(song) }
            if let playlistID = context.playlistID {
                Divider()
                Button("Remove from Playlist") {
                    Library.shared.removeFromPlaylist(playlistID,
                                                       songIDs: contextSongs(for: song).map(\.id))
                }
            }
            Divider()
            Button("Delete…") {
                LibraryDeletion.confirmDelete(songs: contextSongs(for: song))
            }
            .disabled(!LibraryDeletion.canDelete(songs: contextSongs(for: song)))
        }
        .longPressArmable { dragPayload(for: song) }
    }

    private func contextSongs(for song: Song) -> [Song] {
        guard selectedIDs.contains(song.id), selectedIDs.count > 1 else {
            return [song]
        }
        return sorted.filter { selectedIDs.contains($0.id) }
    }

    private func goToAlbum(_ song: Song) {
        guard let albumID = Library.shared.song(withID: song.id)?.album.id else { return }
        NavigationCenter.shared.albumToOpen = albumID
    }

    private func playContext(_ song: Song) {
        let targets = contextSongs(for: song)
        if targets.count > 1 {
            player.play(targets)
        } else {
            player.play(song, in: sorted)
        }
    }

    private func dragPayload(for song: Song) -> DragController.Payload? {
        let songs = contextSongs(for: song)
        guard !songs.isEmpty else { return nil }
        if songs.count > 1 {
            return .init(songs: songs,
                         title: "\(songs.count) songs",
                         subtitle: "Selected tracks",
                         artwork: nil)
        }
        return .init(songs: songs,
                     title: song.title,
                     subtitle: song.artist,
                     artwork: nil)
    }

    @ViewBuilder
    private func statusCell(_ song: Song, selected: Bool) -> some View {
        Group {
            if playback.missingFileIDs.contains(song.id) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(selected ? Theme.highlightForeground : .orange)
                    .help("File is currently missing; it was not removed from the library")
            } else if playback.currentSongID == song.id {
                Image(systemName: playback.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selected ? Theme.highlightForeground : Theme.highlight)
            } else {
                Color.clear
            }
        }
        .frame(width: statusWidth, height: 26)
    }

    @ViewBuilder
    private func rowCell(_ column: SongColumn, song: Song) -> some View {
        let selected = selectedIDs.contains(song.id)
        switch column {
        case .track:
            textCell(song.trackNumberLabel, selected: selected)
                .frame(width: width(of: .track), alignment: .trailing)
        case .name:
            HStack(spacing: 0) {
                Text(song.title)
                    .font(.system(size: 13))
                    .foregroundColor(selected ? Theme.highlightForeground : Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: width(of: .name), alignment: .leading)
        case .time:
            textCell(song.timeLabel, selected: selected)
                .frame(width: width(of: .time), alignment: .trailing)
        case .artist:
            textCell(song.artist, selected: selected)
                .frame(width: width(of: .artist), alignment: .leading)
        case .albumArtist:
            textCell(song.albumArtist, selected: selected)
                .frame(width: width(of: .albumArtist), alignment: .leading)
        case .album:
            textCell(song.album, selected: selected)
                .frame(width: width(of: .album), alignment: .leading)
        case .genre:
            textCell(song.genre, selected: selected)
                .frame(width: width(of: .genre), alignment: .leading)
        case .plays:
            textCell("\(song.plays)", selected: selected)
                .frame(width: width(of: .plays), alignment: .trailing)
        case .addSequence:
            let value = playlistInfo[song.id]?.sequence
            textCell(value.map(String.init) ?? "—", selected: selected)
                .frame(width: width(of: .addSequence), alignment: .trailing)
        case .addTime:
            let value = playlistInfo[song.id].map { playlistAddedTimeLabel($0.addedAt) }
            textCell(value ?? "—", selected: selected)
                .frame(width: width(of: .addTime), alignment: .leading)
        }
    }

    private func textCell(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(selected ? Theme.highlightForeground : Theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 5)
    }

    private func handleRowTap(_ song: Song) {
        NavigationRouter.shared.setFocus(.songTable)
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        if shift,
           let anchor = selectionAnchor,
           let from = sorted.firstIndex(where: { $0.id == anchor }),
           let to = sorted.firstIndex(where: { $0.id == song.id }) {
            let range = from <= to ? from...to : to...from
            let ids = Set(range.map { sorted[$0].id })
            selectedIDs = command ? selectedIDs.union(ids) : ids
        } else if command {
            if selectedIDs.contains(song.id) {
                selectedIDs.remove(song.id)
            } else {
                selectedIDs.insert(song.id)
            }
            selectionAnchor = selectedIDs.isEmpty ? nil : song.id
        } else {
            selectedIDs = [song.id]
            selectionAnchor = song.id
        }
    }

    private func clearSelection() {
        NavigationRouter.shared.setFocus(.songTable)
        selectedIDs.removeAll()
        selectionAnchor = nil
    }

    private func moveSelection(_ direction: NavigationDirection) {
        guard direction == .up || direction == .down else { return }
        let items = sorted
        guard !items.isEmpty else { return }
        let delta = direction == .up ? -1 : 1
        let currentID = selectionAnchor ?? selectedIDs.first

        let index: Int
        if let currentID,
           let current = items.firstIndex(where: { $0.id == currentID }),
           isOnScreen(currentID, index: current) {
            index = min(max(current + delta, 0), items.count - 1)
        } else if let top = topVisibleSongIndex() {
            index = top
        } else if let currentID,
                  let current = items.firstIndex(where: { $0.id == currentID }) {
            index = min(max(current + delta, 0), items.count - 1)
        } else {
            index = 0
        }

        let id = items[index].id
        selectedIDs = [id]
        selectionAnchor = id
        revealSelection()
    }

    private func topVisibleSongIndex() -> Int? {
        for index in sorted.indices {
            if songRowFrame(at: index).maxY > metrics.offset + 0.5 {
                return index
            }
        }
        return nil
    }

    private func isOnScreen(_ id: UUID, index: Int) -> Bool {
        let frame = songRowFrame(at: index)
        return frame.maxY > metrics.offset + 0.5
            && frame.minY < metrics.offset + metrics.viewportHeight - 0.5
    }

    private func songRowFrame(at index: Int) -> CGRect {
        CGRect(x: 0, y: 6 + CGFloat(index) * 26, width: 1, height: 26)
    }

    private func revealSelection() {
        guard let id = selectionAnchor,
              let index = sorted.firstIndex(where: { $0.id == id }) else { return }
        let frame = songRowFrame(at: index)
        guard let target = ListScroll.revealTarget(for: frame,
                                                   metrics: metrics,
                                                   padding: 6) else { return }
        scrollPosition.scrollTo(y: target)
    }

    private func handleScroll(_ command: NavigationScrollCommand) {
        switch command {
        case .home:
            scrollPosition.scrollTo(edge: .top)
        case .end:
            scrollPosition.scrollTo(edge: .bottom)
        case .pageUp, .pageDown:
            guard metrics.viewportHeight > 0 else { return }
            let visibleRows = max(1, Int(ceil(metrics.viewportHeight / 26)))
            let pageHeight = CGFloat(max(1, visibleRows - 1) * 26)
            let delta = command == .pageUp ? -pageHeight : pageHeight
            let target = min(max(metrics.offset + delta, 0), metrics.maxOffset)
            scrollPosition.scrollTo(y: target)
        }
    }

    private func setSort(_ key: SongSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKeyRaw = key.rawValue
            sortAscending = true
        }
        rebuildSorted()
        publishDebugState()
    }
}


enum SongSortKey: String, CaseIterable {
    case name, time, artist, albumArtist, album, genre, addSequence, addTime
}

func songsSorted(_ songs: [Song], by key: SongSortKey, ascending: Bool,
                 playlistInfo: [UUID: PlaylistItemInfo] = [:]) -> [Song] {
    songs.sorted { a, b in
        switch key {
        case .name:
            return ascending ? a.title < b.title : a.title > b.title
        case .time:
            return ascending ? a.duration < b.duration : a.duration > b.duration
        case .artist:
            let x = a.artist + a.album
            let y = b.artist + b.album
            return ascending ? x < y : x > y
        case .albumArtist:
            let x = a.albumArtist + a.album + String(a.trackNumber)
            let y = b.albumArtist + b.album + String(b.trackNumber)
            return ascending ? x < y : x > y
        case .album:
            let x = a.album + String(a.trackNumber)
            let y = b.album + String(b.trackNumber)
            return ascending ? x < y : x > y
        case .genre:
            return ascending ? a.genre < b.genre : a.genre > b.genre
        case .addSequence:
            let x = playlistInfo[a.id]?.sequence ?? Int.max
            let y = playlistInfo[b.id]?.sequence ?? Int.max
            if x == y {
                return ascending ? a.title < b.title : a.title > b.title
            }
            return ascending ? x < y : x > y
        case .addTime:
            let x = playlistInfo[a.id]?.addedAt ?? 0
            let y = playlistInfo[b.id]?.addedAt ?? 0
            if x == y {
                let sx = playlistInfo[a.id]?.sequence ?? Int.max
                let sy = playlistInfo[b.id]?.sequence ?? Int.max
                if sx != sy { return ascending ? sx < sy : sx > sy }
                return ascending ? a.title < b.title : a.title > b.title
            }
            return ascending ? x < y : x > y
        }
    }
}

func playlistAddedTimeLabel(_ timestamp: TimeInterval) -> String {
    guard timestamp > 0 else { return "—" }
    return playlistAddTimeFormatter.string(from: Date(timeIntervalSince1970: timestamp))
}

private let playlistAddTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    return formatter
}()

enum SongSortStore {
    static func key(for context: SongTableContext) -> SongSortKey {
        let raw = UserDefaults.standard.string(forKey: "\(prefix(for: context)).sortKey") ?? ""
        return SongSortKey(rawValue: raw) ?? .name
    }

    static func ascending(for context: SongTableContext) -> Bool {
        let key = "\(prefix(for: context)).sortAscending"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func sorted(_ songs: [Song], for context: SongTableContext,
                       playlistInfo: [UUID: PlaylistItemInfo] = [:]) -> [Song] {
        songsSorted(songs, by: key(for: context), ascending: ascending(for: context),
                    playlistInfo: playlistInfo)
    }

    private static func prefix(for context: SongTableContext) -> String {
        "songTable2.\(context.sortStorageKey)"
    }
}

private struct SongHeaderLabel: View {
    let title: String
    let width: Double
    var leadingPad: CGFloat = 0
    let alignment: Alignment
    let active: Bool
    let ascending: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
            if active {
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.secondaryText)
            }
            if alignment != .trailing { Spacer(minLength: 0) }
        }
        .padding(.leading, leadingPad)
        .padding(.horizontal, 5)
        .frame(width: CGFloat(width), height: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Draggable divider placed above the header. Uses the pointer's screen position
/// directly, so grabbing a divider never jumps the column.
private struct SongColumnHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double
    let onDoubleClick: () -> Void

    @State private var startWidth: Double?
    @State private var startX: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(hovering ? Theme.highlight : Theme.divider.opacity(0.55))
                .frame(width: 1)
        }
        .frame(width: 12, height: 26)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if startWidth == nil {
                        startWidth = width
                        startX = value.location.x
                    }
                    guard let startWidth, let startX else { return }
                    let delta = value.location.x - startX
                    width = min(max(startWidth + delta, minWidth), maxWidth)
                }
                .onEnded { _ in
                    startWidth = nil
                    startX = nil
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleClick() }
        )
    }
}


private extension Song {
    var timeLabel: String {
        formatTime(duration)
    }
}
