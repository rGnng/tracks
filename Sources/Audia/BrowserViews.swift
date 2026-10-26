import SwiftUI
import AppKit

// MARK: - Master-detail browsers (Artists / Genres)
// Left column: a selectable list. Right column: the albums for the selection.

struct ArtistsBrowser: View {
    let artists: [ArtistSummary]

    @EnvironmentObject private var player: PlayerState
    @ObservedObject private var navigation = NavigationCenter.shared
    @State private var selectedID: String?

    init(artists: [ArtistSummary], initialArtistID: String? = nil) {
        self.artists = artists
        let requested = initialArtistID.flatMap { id in
            artists.contains(where: { $0.id == id }) ? id : nil
        }
        _selectedID = State(initialValue: requested ?? artists.first?.id)
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
                detail: { "\($0.albums.count)" }
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
        .onChange(of: artists) { _, newValue in
            if selectedID == nil || !newValue.contains(where: { $0.id == selectedID }) {
                selectedID = newValue.first?.id
            }
            updateStatusBar()
        }
        .onChange(of: selectedID) { _, _ in updateStatusBar() }
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

    @EnvironmentObject private var player: PlayerState
    @ObservedObject private var library = Library.shared
    @State private var selectedID: String?

    init(genres: [GenreItem]) {
        self.genres = genres
        _selectedID = State(initialValue: genres.first?.name)
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
                detail: { "\($0.count)" }
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
        .onChange(of: genres) { _, newValue in
            if selectedID == nil || !newValue.contains(where: { $0.name == selectedID }) {
                selectedID = newValue.first?.name
            }
            updateStatusBar()
        }
        .onChange(of: selectedID) { _, _ in updateStatusBar() }
        .onAppear { updateStatusBar() }
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

private struct BrowserList<Item: Identifiable>: View {
    let items: [Item]
    @Binding var selectedID: Item.ID?
    let title: (Item) -> String
    let detail: (Item) -> String
    let onDoubleTap: (Item) -> Void

    @ObservedObject private var navigator = KeyboardNavigator.shared

    var body: some View {
        ScrollViewReader { proxy in
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
                        .onTapGesture { selectedID = item.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap(item) })
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: navigator.moveCount) { _, _ in
                guard moveSelection(), let id = selectedID else { return }
                withAnimation(.easeInOut(duration: 0.08)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: navigator.activateCount) { _, _ in
                activateSelection()
            }
        }
        .background(Theme.contentBackground)
    }

    private func activateSelection() {
        guard navigator.region == .content else { return }
        guard let selectedID, let item = items.first(where: { $0.id == selectedID }) else { return }
        onDoubleTap(item)
    }

    @discardableResult
    private func moveSelection() -> Bool {
        guard navigator.region == .content else { return false }
        guard navigator.lastMove == .up || navigator.lastMove == .down else { return false }
        guard !items.isEmpty else { return false }
        let delta = navigator.lastMove == .up ? -1 : 1
        let nextID: Item.ID
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            nextID = items[min(max(index + delta, 0), items.count - 1)].id
        } else {
            nextID = items[0].id
        }
        guard nextID != selectedID else { return false }
        selectedID = nextID
        return true
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

    @EnvironmentObject private var player: PlayerState
    @AppStorage("albumSort") private var albumSort = GridSort.album.rawValue
    @State private var selectedSongIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?

    private var allSongs: [Song] { albums.flatMap(\.songs) }
    private var orderedSongs: [Song] { sortedAlbums.flatMap(\.songs) }

    private var sortedAlbums: [Album] {
        let sort = GridSort(rawValue: albumSort) ?? .album
        switch sort {
        case .album:
            return albums.sorted { $0.title < $1.title }
        case .artist:
            return albums.sorted {
                $0.artist == $1.artist ? $0.title < $1.title : $0.artist < $1.artist
            }
        case .year:
            return albums.sorted { $0.yearNumber > $1.yearNumber }
        }
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
                .padding(.bottom, 8)
                .onTapGesture { clearSelection() }
                .marqueeSelectable(selection: $selectedSongIDs, space: "browserTrackSpace")
            }
            .onTapGesture { clearSelection() }
        }
        .background(Theme.contentBackground)
    }

    private func clearSelection() {
        selectedSongIDs.removeAll()
        selectionAnchor = nil
    }

    private func handleRowTap(_ song: Song) {
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

    @EnvironmentObject private var player: PlayerState
    @State private var playHover = false

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
                    isCurrent: player.currentSong?.id == song.id,
                    isPlaying: player.isPlaying,
                    previousSelected: previousSelected,
                    nextSelected: nextSelected
                )
                .contentShape(Rectangle())
                .onTapGesture { onRowTap(song) }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    player.play(song, in: album.songs)
                })
                .songContextMenu(song, queue: album.songs, selection: contextSelection)
                .selectionFrame(id: song.id, in: "browserTrackSpace")
                .longPressArmable { dragPayload(for: song) }
            }
        }
        .padding(.bottom, 14)
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
    let isPlaying: Bool
    let previousSelected: Bool
    let nextSelected: Bool

    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isCurrent {
                    Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.highlightForeground : Theme.highlight)
                } else {
                    Text("\(song.trackNumber)")
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
            .fill(isSelected ? Theme.highlight : (hover ? Theme.rowHover : Color.clear))
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
