import XCTest
@testable import Audia

final class GetInfoTests: XCTestCase {
    func testSongTagMetadataComparisonIgnoresPlaybackAndFileState() {
        let id = UUID()
        let original = makeSong(id: id,
                                plays: 2,
                                dateAdded: 10,
                                fileURL: URL(fileURLWithPath: "/tmp/a.wav"),
                                fileSize: 10,
                                isStarred: true)
        let sameTags = makeSong(id: id,
                                plays: 9,
                                dateAdded: 99,
                                fileURL: URL(fileURLWithPath: "/tmp/b.wav"),
                                fileSize: 99,
                                isStarred: false)

        XCTAssertTrue(original.hasSameTagMetadata(as: sameTags))
        XCTAssertFalse(original.hasSameTagMetadata(as: makeSong(id: id, genre: "Jazz")))
    }

    func testAlbumTagMetadataComparisonIgnoresArtworkAndTrackOrder() {
        let albumID = UUID()
        let first = makeSong(id: UUID(), title: "First")
        let second = makeSong(id: UUID(), title: "Second")
        let original = Album(id: albumID,
                             title: "Album",
                             artist: "Artist",
                             genre: "Rock",
                             year: "2020",
                             artwork: Artwork(colors: [], imageData: Data([1])),
                             songs: [first, second])
        let sameTags = Album(id: albumID,
                             title: "Album",
                             artist: "Artist",
                             genre: "Rock",
                             year: "2020",
                             artwork: Artwork(colors: [], imageData: Data([2])),
                             songs: [
                                makeSong(id: second.id, title: "Second", plays: 4),
                                makeSong(id: first.id, title: "First", plays: 1),
                             ])

        XCTAssertTrue(original.hasSameTagMetadata(as: sameTags))

        let changedTitle = Album(id: albumID,
                                 title: "Renamed",
                                 artist: "Artist",
                                 genre: "Rock",
                                 year: "2020",
                                 artwork: Artwork(colors: []),
                                 songs: [first, second])
        XCTAssertFalse(original.hasSameTagMetadata(as: changedTitle))

        let changedSong = Album(id: albumID,
                                title: "Album",
                                artist: "Artist",
                                genre: "Rock",
                                year: "2020",
                                artwork: Artwork(colors: []),
                                songs: [first, makeSong(id: second.id, title: "Renamed")])
        XCTAssertFalse(original.hasSameTagMetadata(as: changedSong))
    }

    private func makeSong(id: UUID,
                          title: String = "Song",
                          artist: String = "Artist",
                          album: String = "Album",
                          albumArtist: String = "Album Artist",
                          genre: String = "Rock",
                          year: String = "2020",
                          trackNumber: Int = 1,
                          trackTotal: Int = 10,
                          discNumber: Int = 1,
                          discTotal: Int = 2,
                          comments: String = "Note",
                          plays: Int = 0,
                          dateAdded: TimeInterval = 0,
                          fileURL: URL? = nil,
                          fileSize: Int64? = nil,
                          isStarred: Bool = false) -> Song {
        Song(id: id,
             title: title,
             artist: artist,
             album: album,
             albumArtist: albumArtist,
             genre: genre,
             duration: 0,
             trackNumber: trackNumber,
             trackTotal: trackTotal,
             discNumber: discNumber,
             discTotal: discTotal,
             comments: comments,
             year: year,
             plays: plays,
             dateAdded: dateAdded,
             fileURL: fileURL,
             fileSize: fileSize,
             isStarred: isStarred)
    }
}
