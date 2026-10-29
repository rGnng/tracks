import SwiftUI
import XCTest
@testable import Audia

final class CatalogAndMPDTests: XCTestCase {
    private func makeSong(title: String,
                          artist: String,
                          album: String,
                          dateAdded: TimeInterval = 0) -> Song {
        Song(title: title,
             artist: artist,
             album: album,
             genre: "",
             duration: 1,
             trackNumber: 1,
             plays: 0,
             dateAdded: dateAdded)
    }

    private func makeAlbum(title: String,
                           songDateAdded: TimeInterval,
                           artwork: Artwork = Artwork(colors: [], cacheKey: "test")) -> Album {
        let song = makeSong(title: title, artist: "Artist", album: title, dateAdded: songDateAdded)
        return Album(title: title,
                     artist: "Artist",
                     genre: "",
                     artwork: artwork,
                     songs: [song])
    }

    func testCatalogResolvesArtworkBySongIDWhenAlbumTitlesMatch() {
        let sharedTitle = "Same Album"
        let artworkA = Artwork(colors: [.red], cacheKey: "album-a")
        let artworkB = Artwork(colors: [.blue], cacheKey: "album-b")
        let songA = makeSong(title: "Song A", artist: "Artist A", album: sharedTitle)
        let songB = makeSong(title: "Song B", artist: "Artist B", album: sharedTitle)
        let albumA = Album(title: sharedTitle,
                           artist: "Artist A",
                           genre: "Pop",
                           artwork: artworkA,
                           songs: [songA])
        let albumB = Album(title: sharedTitle,
                           artist: "Artist B",
                           genre: "Rock",
                           artwork: artworkB,
                           songs: [songB])

        let catalog = LibraryCatalog(albums: [albumA, albumB])

        XCTAssertEqual(catalog.allSongs.map(\.id), [songA.id, songB.id])
        XCTAssertEqual(catalog.artwork(forSongID: songA.id).cacheKey, "album-a")
        XCTAssertEqual(catalog.artwork(forSongID: songB.id).cacheKey, "album-b")
        XCTAssertEqual(catalog.song(withID: songA.id)?.album.id, albumA.id)
        XCTAssertEqual(catalog.song(withID: songB.id)?.album.id, albumB.id)
        XCTAssertEqual(catalog.album(withID: albumB.id)?.id, albumB.id)
    }

    func testRecentAlbumsSortedUsesNewestAndTitleTieBreak() {
        let old = makeAlbum(title: "Old", songDateAdded: 100)
        let new = makeAlbum(title: "New", songDateAdded: 200)
        let tieB = makeAlbum(title: "Tie B", songDateAdded: 300)
        let tieA = makeAlbum(title: "Tie A", songDateAdded: 300)

        let sorted = recentAlbumsSorted([old, new, tieB, tieA])
        XCTAssertEqual(sorted.map(\.title), ["Tie A", "Tie B", "New", "Old"])
    }

    @MainActor
    func testMPDStableQueueIDsUseEntryIDsNotPositions() {
        let songs = (0..<3).map {
            makeSong(title: "Song \($0)", artist: "Artist", album: "Album")
        }
        let queue = [
            QueueEntry(id: 17, song: songs[0]),
            QueueEntry(id: 42, song: songs[1]),
            QueueEntry(id: 99, song: songs[2]),
        ]

        let middle = MPDServer.stableQueueIDs(queue, currentIndex: 1)
        XCTAssertEqual(middle.songID, 42)
        XCTAssertEqual(middle.nextSongID, 99)

        let last = MPDServer.stableQueueIDs(queue, currentIndex: 2)
        XCTAssertEqual(last.songID, 99)
        XCTAssertNil(last.nextSongID)

        let outOfRange = MPDServer.stableQueueIDs(queue, currentIndex: 3)
        XCTAssertNil(outOfRange.songID)
        XCTAssertNil(outOfRange.nextSongID)

        let empty = MPDServer.stableQueueIDs(queue, currentIndex: nil)
        XCTAssertNil(empty.songID)
        XCTAssertNil(empty.nextSongID)
    }
}
