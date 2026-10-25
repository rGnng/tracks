import SwiftUI

struct ContentPane: View {
    let selection: SidebarSelection
    let searchText: String
    @Binding var openAlbumID: UUID?

    @AppStorage("albumViewMode") private var albumViewMode = "grid"
    @AppStorage("albumSort") private var albumSort = GridSort.album.rawValue
    @ObservedObject private var library = Library.shared
    @ObservedObject private var navigation = NavigationCenter.shared
    @State private var navigationDetail = false

    private var isGrid: Bool { albumViewMode != "list" }

    private var sort: GridSort {
        GridSort(rawValue: albumSort) ?? .album
    }

    var body: some View {
        content
            .background(Theme.contentBackground)
            .onHover { inside in
                if inside { KeyboardNavigator.shared.region = .content }
            }
            .onChange(of: openAlbumID) { _, id in
                if id != nil { navigationDetail = true }
            }
            .onChange(of: selection) { _, newValue in
                if newValue != .library(.albums) {
                    navigationDetail = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goBackRequested)) { _ in
                navigationDetail = false
            }
    }

    // MARK: Content routing

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .library(.albums):
            if isGrid || navigationDetail {
                AlbumGrid(albums: sortedAlbums, openAlbumID: $openAlbumID)
                    .id(selection)
            } else {
                AlbumList(albums: sortedAlbums)
                    .id(selection)
            }
        case .library(.recentlyAdded):
            if isGrid || navigationDetail {
                AlbumGrid(albums: recentAlbums, openAlbumID: $openAlbumID)
                    .id(selection)
            } else {
                AlbumList(albums: recentAlbums)
                    .id(selection)
            }
        case .library(.artists):
            ArtistsBrowser(artists: filteredArtists, initialArtistID: navigation.artistToOpen)
                .id(selection)
        case .library(.songs):
            SongTable(songs: filteredSongs, context: .songs)
                .id(selection)
        case .library(.genres):
            GenresBrowser(genres: filteredGenres)
                .id(selection)
        case .starred:
            SongTable(songs: filteredStarredSongs, context: .starred)
                .id(selection)
        case .playlist(let id):
            SongTable(songs: playlistSongs(id), context: .playlist(id))
                .id(selection)
        }
    }

    // MARK: Derived

    private var sortedAlbums: [Album] {
        switch sort {
        case .album:
            return filteredAlbums.sorted { $0.title < $1.title }
        case .artist:
            return filteredAlbums.sorted {
                $0.artist == $1.artist ? $0.title < $1.title : $0.artist < $1.artist
            }
        case .year:
            return filteredAlbums.sorted { $0.yearNumber > $1.yearNumber }
        }
    }

    private var recentAlbums: [Album] {
        filteredAlbums.sorted {
            let a = $0.addedAt
            let b = $1.addedAt
            if abs(a - b) < 0.5 {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return a > b
        }
    }

    // MARK: Search filtering

    private var q: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ s: String) -> Bool {
        q.isEmpty || s.lowercased().contains(q)
    }

    private var filteredAlbums: [Album] {
        guard !q.isEmpty else { return library.albums }
        return library.albums.filter {
            matches($0.title) || matches($0.artist) || matches($0.genre)
        }
    }

    private var filteredArtists: [ArtistSummary] {
        guard !q.isEmpty else { return library.artists }
        return library.artists.filter { a in
            matches(a.name) || a.albums.contains { matches($0.title) }
        }
    }

    private var filteredSongs: [Song] {
        guard !q.isEmpty else { return library.allSongs }
        return library.allSongs.filter {
            matches($0.title) || matches($0.artist) || matches($0.albumArtist)
                || matches($0.album) || matches($0.genre)
        }
    }

    private var filteredStarredSongs: [Song] {
        let songs = library.starredSongs
        guard !q.isEmpty else { return songs }
        return songs.filter {
            matches($0.title) || matches($0.artist) || matches($0.albumArtist)
                || matches($0.album) || matches($0.genre)
        }
    }

    private var filteredGenres: [GenreItem] {
        guard !q.isEmpty else { return library.genres }
        return library.genres.filter { matches($0.name) }
    }

    private func playlistSongs(_ id: UUID) -> [Song] {
        let songs = library.playlistSongs(id)
        guard !q.isEmpty else { return songs }
        return songs.filter {
            matches($0.title) || matches($0.artist) || matches($0.albumArtist)
                || matches($0.album) || matches($0.genre)
        }
    }
}

// MARK: - Sorting

enum GridSort: String, CaseIterable {
    case album = "Album"
    case artist = "Artist"
    case year = "Year"
}
