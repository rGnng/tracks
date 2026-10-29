import SwiftUI
import AppKit

// MARK: - Master-detail browsers (Artists / Genres)
// Left column: a selectable list. Right column: the albums for the selection.

struct ArtistsBrowser: View {
    let artists: [ArtistSummary]

    @ObservedObject private var navigation = NavigationCenter.shared
    @State private var selectedID: String?

    private var player: PlayerState { PlayerState.shared }

    init(artists: [ArtistSummary], initialArtistID: String? = nil) {
        self.artists = artists
        let requested = initialArtistID.flatMap { id in
            artists.contains(where: { $0.id == id }) ? id : nil
        }
        let storedState = SessionViewState.shared.browserState(for: "artists")
        let stored = (storedState?.itemCount == artists.count ? storedState?.selectedID : nil).flatMap { id in
            artists.contains(where: { $0.id == id }) ? id : nil
        }
        _selectedID = State(initialValue: requested ?? stored ?? artists.first?.id)
    }

    private var selectedArtist: ArtistSummary? {
        if let id = selectedID, let a = artists.first(where: { $0.id == id }) { return a }
        return artists.first
    }

    var body: some View {
        HStack(spacing: 0) {
            BrowserList(
                items: artists,
                selectedID: $selectedID,
                title: { $0.name },
                detail: { "\($0.albums.count)" },
                viewKey: "artists"
            ) { artist in
                player.play(artist.albums.flatMap(\.songs))
            }
            .frame(width: 220)

            VDivider()

            if let artist = selectedArtist {
                BrowserAlbumPane(
                    title: artist.name,
                    subtitle: "\(artist.albums.count) albums",
                    albums: artist.albums
                )
                .id(artist.name)
            } else {
                EmptyPane("No Artists")
            }
        }
        .background(Theme.contentBackground)
        .debugFrame("ArtistsBrowser")
        .onChange(of: artists) { _, newValue in
            if selectedID == nil || !newValue.contains(where: { $0.id == selectedID }) {
                selectedID = newValue.first?.id
            }
            updateStatusBar()
        }
        .onChange(of: selectedID) { _, _ in
            updateStatusBar()
        }
        .onAppear {
            consumePendingArtist()
            updateStatusBar()
        }
        .onChange(of: navigation.artistToOpen) { _, _ in
            consumePendingArtist()
        }
    }

    private func consumePendingArtist() {
        guard let requested = navigation.artistToOpen else { return }
        if artists.contains(where: { $0.id == requested }) {
            selectedID = requested
        }
        navigation.artistToOpen = nil
    }

    private func updateStatusBar() {
        if let artist = selectedArtist {
            StatusBarCenter.shared.context = .artist(artist.name)
        } else {
            StatusBarCenter.shared.context = .library
        }
    }
}

struct GenresBrowser: View {
    let genres: [GenreItem]

    @ObservedObject private var library = Library.shared
    @State private var selectedID: String?

    private var player: PlayerState { PlayerState.shared }

    init(genres: [GenreItem]) {
        self.genres = genres
        let storedState = SessionViewState.shared.browserState(for: "genres")
        let stored = (storedState?.itemCount == genres.count ? storedState?.selectedID : nil).flatMap { name in
            genres.contains(where: { $0.name == name }) ? name : nil
        }
        _selectedID = State(initialValue: stored ?? genres.first?.name)
    }

    private var selectedGenre: GenreItem? {
        if let id = selectedID, let g = genres.first(where: { $0.name == id }) { return g }
        return genres.first
    }

    private var albumsForSelected: [Album] {
        guard let g = selectedGenre else { return [] }
        return library.albums.filter { $0.genre == g.name }
    }

    var body: some View {
        HStack(spacing: 0) {
            BrowserList(
                items: genres,
                selectedID: $selectedID,
                title: { $0.name },
                detail: { "\($0.count)" },
                viewKey: "genres"
            ) { genre in
                player.play(library.albums.filter { $0.genre == genre.name }.flatMap(\.songs))
            }
            .frame(width: 220)

            VDivider()

            if let genre = selectedGenre {
                BrowserAlbumPane(
                    title: genre.name,
                    subtitle: "\(albumsForSelected.count) albums",
                    albums: albumsForSelected
                )
                .id(genre.name)
            } else {
                EmptyPane("No Genres")
            }
        }
        .background(Theme.contentBackground)
        .debugFrame("GenresBrowser")
        .onChange(of: genres) { _, newValue in
            if selectedID == nil || !newValue.contains(where: { $0.name == selectedID }) {
                selectedID = newValue.first?.name
            }
            updateStatusBar()
        }
        .onChange(of: selectedID) { _, _ in
            updateStatusBar()
        }
        .onAppear {
            updateStatusBar()
        }
    }

    private func updateStatusBar() {
        if let genre = selectedGenre {
            StatusBarCenter.shared.context = .genre(genre.name)
        } else {
            StatusBarCenter.shared.context = .library
        }
    }
}

// MARK: - Left list

private struct BrowserList<Item: Identifiable>: View where Item.ID == String {
    let items: [Item]
    @Binding var selectedID: Item.ID?
    let title: (Item) -> String
    let detail: (Item) -> String
    let viewKey: String
    let onDoubleTap: (Item) -> Void

    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = ListScrollMetrics()

    private let contentTopPadding: CGFloat = 6

    init(items: [Item], selectedID: Binding<Item.ID?>,
         title: @escaping (Item) -> String,
         detail: @escaping (Item) -> String,
         viewKey: String,
         onDoubleTap: @escaping (Item) -> Void) {
        self.items = items
        self._selectedID = selectedID
        self.title = title
        self.detail = detail
        self.viewKey = viewKey
        self.onDoubleTap = onDoubleTap
        let stored = SessionViewState.shared.browserState(for: viewKey)
        let saved = stored?.itemCount == items.count ? stored : nil
        _scrollPosition = State(initialValue: ScrollPosition(
            idType: Never.self,
            y: max(0, saved?.offset ?? 0)
        ))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let selected = selectedID == item.id
                    BrowserRow(
                        title: title(item),
                        detail: detail(item),
                        isSelected: selected,
                        background: rowBackground(index: index, selected: selected)
                    )
                    .id(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NavigationRouter.shared.setFocus(.browserList)
                        selectedID = item.id
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap(item) })
                }
            }
            .padding(.vertical, contentTopPadding)
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
        .background(Theme.contentBackground)
        .debugFrame("BrowserList")
        .onReceive(NavigationRouter.shared.arrowEvents) { arrow in
            guard NavigationRouter.shared.focus == .browserList else { return }
            moveSelection(arrow.direction)
        }
        .onReceive(NavigationRouter.shared.scrollEvents) { event in
            guard NavigationRouter.shared.focus == .browserList else { return }
            handleScroll(event.command)
        }
        .onChange(of: selectedID) { _, _ in publishDebugState() }
        .onChange(of: items.count) { _, _ in publishDebugState() }
        .onAppear { publishDebugState() }
        .onDisappear {
            guard metrics.viewportHeight > 0 else { return }
            SessionViewState.shared.saveBrowser(
                .init(offset: metrics.offset,
                      selectedID: selectedID,
                      itemCount: items.count),
                for: viewKey
            )
        }
    }

    private func publishDebugState() {
        var info = DebugState.shared.browser
        info.items = items.count
        info.selected = selectedID ?? "—"
        info.listOffset = metrics.offset
        info.listViewport = metrics.viewportHeight
        info.listContent = metrics.contentHeight
        DebugState.shared.browser = info
    }

    private func moveSelection(_ direction: NavigationDirection) {
        guard direction == .up || direction == .down else {
            if direction == .right {
                NavigationRouter.shared.setFocus(.browserTracks)
            }
            return
        }
        guard !items.isEmpty else { return }
        let delta = direction == .up ? -1 : 1
        let index: Int
        if let currentID = selectedID,
           let current = items.firstIndex(where: { $0.id == currentID }),
           isOnScreen(index: current) {
            index = min(max(current + delta, 0), items.count - 1)
        } else if let top = topVisibleIndex() {
            index = top
        } else if let currentID = selectedID,
                  let current = items.firstIndex(where: { $0.id == currentID }) {
            index = min(max(current + delta, 0), items.count - 1)
        } else {
            index = 0
        }

        selectedID = items[index].id
        reveal(index: index)
    }

    private func rowFrame(at index: Int) -> CGRect {
        CGRect(x: 0,
               y: contentTopPadding + CGFloat(index) * 26,
               width: 1,
               height: 26)
    }

    private func topVisibleIndex() -> Int? {
        for index in items.indices {
            if rowFrame(at: index).maxY > metrics.offset + 0.5 {
                return index
            }
        }
        return nil
    }

    private func isOnScreen(index: Int) -> Bool {
        let frame = rowFrame(at: index)
        return frame.maxY > metrics.offset + 0.5
            && frame.minY < metrics.offset + metrics.viewportHeight - 0.5
    }

    private func reveal(index: Int) {
        let frame = rowFrame(at: index)
        guard let target = ListScroll.revealTarget(for: frame,
                                                   metrics: metrics,
                                                   padding: contentTopPadding) else { return }
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

}

private struct BrowserRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let background: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? Theme.highlightForeground : Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? Theme.highlightForeground.opacity(0.8) : Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(background))
        .padding(.horizontal, 6)
    }
}

// MARK: - Right album pane

/// iTunes-style detail list: every album of the current selection is shown in
/// full — artwork/header followed by that album's tracks — instead of a grid of
/// covers.
private struct BrowserAlbumPane: View {
    let title: String
    let subtitle: String
    let albums: [Album]

    @AppStorage("albumSort") private var albumSort = GridSort.album.rawValue
    @AppStorage("albumSortDirection") private var albumSortDirection =
        GridSortDirection.ascending.rawValue
    @State private var selectedSongIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var scrollPosition = ScrollPosition()
    @State private var metrics = ListScrollMetrics()

    private var player: PlayerState { PlayerState.shared }

    init(title: String, subtitle: String, albums: [Album]) {
        self.title = title
        self.subtitle = subtitle
        self.albums = albums
    }

    private var allSongs: [Song] { albums.flatMap(\.songs) }
    private var orderedSongs: [Song] { sortedAlbums.flatMap(\.songs) }

    private var sortedAlbums: [Album] {
        albumsSorted(
            albums,
            by: GridSort(rawValue: albumSort) ?? .album,
            direction: GridSortDirection(rawValue: albumSortDirection) ?? .ascending
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedAlbums) { album in
                        BrowserAlbumSection(
                            album: album,
                            selectedSongIDs: $selectedSongIDs,
                            selectedSongs: orderedSongs.filter { selectedSongIDs.contains($0.id) },
                            onRowTap: { song in handleRowTap(song) }
                        )
                        Hairline()
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 8)
                .onTapGesture { clearSelection() }
                .marqueeSelectable(selection: $selectedSongIDs, space: "browserTrackSpace")
                .onPreferenceChange(MarqueeFramesKey.self) { rowFrames = $0 }
            }
            .onTapGesture { clearSelection() }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ListScrollMetrics.self) { geometry in
                ListScrollMetrics(offset: geometry.contentOffset.y,
                                  viewportHeight: geometry.containerSize.height,
                                  contentHeight: geometry.contentSize.height)
            } action: { _, new in
                metrics = new
                publishDebugState()
            }
        }
        .onReceive(NavigationRouter.shared.arrowEvents) { arrow in
            guard NavigationRouter.shared.focus == .browserTracks else { return }
            moveSelection(arrow.direction)
        }
        .onReceive(NavigationRouter.shared.scrollEvents) { event in
            guard NavigationRouter.shared.focus == .browserTracks else { return }
            handleScroll(event.command)
        }
        .onChange(of: selectedSongIDs) { _, _ in publishDebugState() }
        .onAppear { publishDebugState() }
        .debugFrame("BrowserAlbumPane")
        .background(Theme.contentBackground)
    }

    private func publishDebugState() {
        var info = DebugState.shared.browser
        info.title = title
        info.albums = albums.count
        info.selectedSongs = selectedSongIDs.count
        info.offset = metrics.offset
        info.viewport = metrics.viewportHeight
        info.content = metrics.contentHeight
        DebugState.shared.browser = info
    }

    private func clearSelection() {
        NavigationRouter.shared.setFocus(.browserTracks)
        selectedSongIDs.removeAll()
        selectionAnchor = nil
    }

    private func moveSelection(_ direction: NavigationDirection) {
        switch direction {
        case .left:
            NavigationRouter.shared.setFocus(.browserList)
        case .up, .down:
            let songs = orderedSongs
            guard !songs.isEmpty else { return }
            let delta = direction == .up ? -1 : 1
            let currentID = selectionAnchor ?? selectedSongIDs.first

            let index: Int
            if let currentID,
               let current = songs.firstIndex(where: { $0.id == currentID }),
               isOnScreen(currentID) {
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
        case .right:
            break
        }
    }

    private func topVisibleSongIndex() -> Int? {
        for index in orderedSongs.indices {
            guard let frame = rowFrames[orderedSongs[index].id] else { continue }
            if frame.maxY > metrics.offset + 0.5 {
                return index
            }
        }
        return nil
    }

    private func isOnScreen(_ id: UUID) -> Bool {
        guard let frame = rowFrames[id] else { return false }
        return frame.maxY > metrics.offset + 0.5
            && frame.minY < metrics.offset + metrics.viewportHeight - 0.5
    }

    private func revealSelection() {
        guard let id = selectionAnchor else { return }
        guard let frame = rowFrames[id] else {
            scrollPosition.scrollTo(id: id, anchor: .center)
            return
        }
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
            let visibleRows = max(1, Int(ceil(metrics.viewportHeight / 24)))
            let pageHeight = CGFloat(max(1, visibleRows - 1) * 24)
            let delta = command == .pageUp ? -pageHeight : pageHeight
            let target = min(max(metrics.offset + delta, 0), metrics.maxOffset)
            scrollPosition.scrollTo(y: target)
        }
    }

    private func handleRowTap(_ song: Song) {
        NavigationRouter.shared.setFocus(.browserTracks)
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        if shift,
           let anchor = selectionAnchor,
           let from = orderedSongs.firstIndex(where: { $0.id == anchor }),
           let to = orderedSongs.firstIndex(where: { $0.id == song.id }) {
            let range = from <= to ? from...to : to...from
            let ids = Set(range.map { orderedSongs[$0].id })
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

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryText)
            }
            Spacer()
            HStack(spacing: 8) {
                AlbumActionButton(title: "Play", icon: "play.fill") {
                    player.play(allSongs)
                }
                AlbumActionButton(title: "Shuffle", icon: "shuffle") {
                    player.playShuffled(allSongs)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}

/// One album header plus its full track list.
private struct BrowserAlbumSection: View {
    let album: Album
    @Binding var selectedSongIDs: Set<UUID>
    let selectedSongs: [Song]
    let onRowTap: (Song) -> Void

    @ObservedObject private var playback = PlaybackStatus.shared
    @State private var playHover = false

    private var player: PlayerState { PlayerState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .albumContextMenu(album)
            ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                let selected = selectedSongIDs.contains(song.id)
                let previousSelected = index > 0 && selectedSongIDs.contains(album.songs[index - 1].id)
                let nextSelected = index + 1 < album.songs.count && selectedSongIDs.contains(album.songs[index + 1].id)
                let contextSelection = selected && selectedSongIDs.count > 1 ? selectedSongs : []
                BrowserSongRow(
                    song: song,
                    isSelected: selected,
                    isCurrent: playback.currentSongID == song.id,
                    isMissing: playback.missingFileIDs.contains(song.id),
                    isPlaying: playback.isPlaying,
                    previousSelected: previousSelected,
                    nextSelected: nextSelected
                )
                .contentShape(Rectangle())
                .onTapGesture { onRowTap(song) }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    player.play(song, in: album.songs)
                })
                .id(song.id)
                .songContextMenu(song, queue: album.songs, selection: contextSelection)
                .selectionFrame(id: song.id, in: "browserTrackSpace")
                .longPressArmable { dragPayload(for: song) }
            }
        }
        .padding(.bottom, 14)
        .debugFrame("BrowserAlbumSection \(album.title)")
    }

    private var albumInfo: String {
        var parts: [String] = []
        if !album.genre.isEmpty { parts.append(album.genre) }
        if !album.year.isEmpty { parts.append(album.year) }
        parts.append("\(album.songs.count) songs")
        return parts.joined(separator: " · ")
    }

    private func dragPayload(for song: Song) -> DragController.Payload? {
        let songs = selectedSongIDs.contains(song.id) && selectedSongIDs.count > 1
            ? selectedSongs
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AlbumArtwork(artwork: album.artwork)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                Text(albumInfo)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button { player.play(album.songs) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.primaryText)
                    .frame(width: 28, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(playHover ? Theme.controlFillActive : Theme.controlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.controlBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .onHover { playHover = $0 }
            .help("Play \(album.title)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

private struct BrowserSongRow: View {
    let song: Song
    let isSelected: Bool
    let isCurrent: Bool
    let isMissing: Bool
    let isPlaying: Bool
    let previousSelected: Bool
    let nextSelected: Bool

    @State private var hover = false

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
                    Text(song.trackNumberLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(isSelected ? Theme.highlightForeground.opacity(0.85) : Theme.secondaryText)
                }
            }
            .frame(width: 28, alignment: .leading)

            Text(song.title)
                .font(.system(size: 12.5))
                .foregroundColor(isSelected ? Theme.highlightForeground : Theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(formatTime(song.duration))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(isSelected ? Theme.highlightForeground.opacity(0.85) : Theme.secondaryText)
                .frame(width: 44, alignment: .trailing)

            StarButton(songID: song.id, isSelected: isSelected)
                .frame(width: 24)
        }
        .padding(.horizontal, 20)
        .frame(height: 24)
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

// MARK: - Empty state

private struct EmptyPane: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}
