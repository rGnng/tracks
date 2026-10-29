import SwiftUI

struct ContentPane: View {
    let selection: SidebarSelection
    let searchText: String
    @Binding var openAlbumID: UUID?

    @AppStorage("albumSort") private var albumSort = GridSort.album.rawValue
    @AppStorage("albumSortDirection") private var albumSortDirection =
        GridSortDirection.ascending.rawValue
    @ObservedObject private var library = Library.shared
    @ObservedObject private var navigation = NavigationCenter.shared

    private var sort: GridSort {
        GridSort(rawValue: albumSort) ?? .album
    }

    private var sortDirection: GridSortDirection {
        GridSortDirection(rawValue: albumSortDirection) ?? .ascending
    }

    var body: some View {
        content
            .background(Theme.contentBackground)
    }

    // MARK: Content routing

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .library(.albums):
            AlbumGrid(albums: sortedAlbums, openAlbumID: $openAlbumID)
                .id(selection)
        case .library(.recentlyAdded):
            AlbumGrid(albums: recentAlbums, openAlbumID: $openAlbumID)
                .id(selection)
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
            SongTable(songs: playlistSongs(id),
                      context: .playlist(id),
                      playlistInfo: library.playlistItemInfo(id))
                .id(selection)
        }
    }

    // MARK: Derived

    private var sortedAlbums: [Album] {
        albumsSorted(filteredAlbums, by: sort, direction: sortDirection)
    }

    private var recentAlbums: [Album] {
        recentAlbumsSorted(filteredAlbums)
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

enum GridSortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

func albumsSorted(_ albums: [Album],
                  by sort: GridSort,
                  direction: GridSortDirection) -> [Album] {
    let ascending: [Album]
    switch sort {
    case .album:
        ascending = albums.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    case .artist:
        ascending = albums.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder == .orderedSame {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return artistOrder == .orderedAscending
        }
    case .year:
        ascending = albums.sorted { $0.yearNumber < $1.yearNumber }
    }
    return direction == .descending ? Array(ascending.reversed()) : ascending
}

func recentAlbumsSorted(_ albums: [Album]) -> [Album] {
    // `Album.addedAt` walks every song in the album. Sorting recomputes it on
    // every comparison, which is expensive enough to stall playback-driven
    // view updates; cache it once per album instead.
    albums
        .map { ($0, $0.addedAt) }
        .sorted { lhs, rhs in
            if abs(lhs.1 - rhs.1) < 0.5 {
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            return lhs.1 > rhs.1
        }
        .map(\.0)
}
