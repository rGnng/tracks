import SwiftUI

// MARK: - Artwork

/// A deterministic placeholder "album cover": a two-color gradient, optionally
/// replaced by user-selected image data.
struct Artwork: Hashable {
    let colors: [Color]
    var imageData: Data?
    /// Stable album ID used by the asynchronous artwork cache. `imageData` is
    /// normally nil for library albums so loading a library never pulls every
    /// cover BLOB into memory.
    var cacheKey: String?

    init(colors: [Color], imageData: Data? = nil, cacheKey: String? = nil) {
        self.colors = colors
        self.imageData = imageData
        self.cacheKey = cacheKey
    }
}

// MARK: - Models

struct Song: Identifiable, Hashable {
    let id: UUID
    let title: String
    /// Track artist (`ARTIST`).
    let artist: String
    /// Album artist (`ALBUMARTIST`, falling back to the track artist).
    /// Albums are grouped by this value, not by the track artist.
    let albumArtist: String
    let album: String
    let genre: String
    let duration: TimeInterval
    let trackNumber: Int
    /// Total tracks on the disc, when the tags provide it.
    let trackTotal: Int
    /// Disc number and total discs, when the tags provide them.
    let discNumber: Int
    let discTotal: Int
    let comments: String
    /// Raw date/year tag text. Empty means unknown.
    let year: String
    let plays: Int
    /// First-discovery baseline used by Recently Added. Newly imported tracks
    /// use the file's modification date; existing rows keep this value even
    /// when their tags or artwork are edited later.
    let dateAdded: TimeInterval
    let fileURL: URL?
    /// File size reported by the last scan. Used by the status bar total.
    let fileSize: Int64?
    /// Mirrors the track table's `loved` column. It powers the built-in
    /// "Stared" playlist and the star buttons on every track list.
    let isStarred: Bool

    init(id: UUID = UUID(), title: String, artist: String, album: String,
         albumArtist: String? = nil, genre: String,
         duration: TimeInterval, trackNumber: Int,
         trackTotal: Int = 0, discNumber: Int = 0, discTotal: Int = 0,
         comments: String = "",
         year: String = "", plays: Int,
         dateAdded: TimeInterval = 0,
         fileURL: URL? = nil, fileSize: Int64? = nil, isStarred: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist ?? artist
        self.album = album
        self.genre = genre
        self.duration = duration
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.comments = comments
        self.year = year
        self.plays = plays
        self.dateAdded = dateAdded
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.isStarred = isStarred
    }

    var yearNumber: Int { Self.yearNumber(from: year) }
    var trackNumberLabel: String { trackNumber > 0 ? String(trackNumber) : "" }

    fileprivate static func yearNumber(from value: String) -> Int {
        Int(value.prefix(4)) ?? 0
    }
}

/// One position in the active play queue. `id` is the stable queue-entry
/// identity exposed as MPD's `Id`; it is not the library `Song.id`.
struct QueueEntry: Identifiable, Equatable {
    let id: UInt32
    var song: Song
}

struct Album: Identifiable, Hashable {
    let id: UUID
    let title: String
    /// Album artist (the album-level credit); per-track credits live on Song.
    let artist: String
    let genre: String
    /// Raw date/year tag text. Empty means unknown.
    let year: String
    let artwork: Artwork
    let songs: [Song]

    init(id: UUID = UUID(), title: String, artist: String, genre: String, year: String = "",
         artwork: Artwork, songs: [Song]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.genre = genre
        self.year = year
        self.artwork = artwork
        self.songs = songs
    }

    var yearNumber: Int { Song.yearNumber(from: year) }
}

extension Album {
    var addedAt: TimeInterval {
        songs.map(\.dateAdded).max() ?? 0
    }

    /// Disc numbers present in the album, ignoring unknown/zero values.
    var discNumbers: Set<Int> {
        Set(songs.map(\.discNumber).filter { $0 > 0 })
    }

    /// An album is multi-disc when more than one disc number is present, or
    /// when any track explicitly declares a total greater than one. The total
    /// disc tag is optional; a missing total must not hide a multi-disc album.
    var isMultiDisc: Bool {
        (discNumbers.max() ?? 0) > 1 || songs.contains { $0.discTotal > 1 }
    }

    /// Best available disc count: the highest explicit total, or the highest
    /// disc number when totals are missing.
    var effectiveDiscTotal: Int {
        max(discNumbers.max() ?? 0, songs.map(\.discTotal).max() ?? 0)
    }
}

struct PlaylistItemInfo: Hashable {
    /// UNIX timestamp for when the song was added to this playlist.
    let addedAt: TimeInterval
    /// One-based position in the playlist's add order, derived from `addedAt`.
    let sequence: Int
}

struct Playlist: Identifiable, Hashable {
    let id: UUID
    let name: String
    let songs: [Song]
    /// Per-item add timestamps. Keyed by song ID because a song can appear in
    /// more than one playlist with different add times.
    let addedAtBySongID: [UUID: TimeInterval]
    /// UNIX timestamp used by MPD's `Last-Modified` field.
    let dateModified: TimeInterval

    init(id: UUID = UUID(), name: String, songs: [Song],
         addedAtBySongID: [UUID: TimeInterval] = [:],
         dateModified: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.songs = songs
        self.addedAtBySongID = addedAtBySongID
        self.dateModified = dateModified
    }

    /// Add-order metadata for table display and sorting. Ties fall back to the
    /// current playlist position so the sequence order stays deterministic.
    var itemInfo: [UUID: PlaylistItemInfo] {
        let ordered = songs.enumerated().sorted { lhs, rhs in
            let left = addedAtBySongID[lhs.element.id] ?? 0
            let right = addedAtBySongID[rhs.element.id] ?? 0
            if left == right { return lhs.offset < rhs.offset }
            return left < right
        }
        var result: [UUID: PlaylistItemInfo] = [:]
        result.reserveCapacity(ordered.count)
        for (index, entry) in ordered.enumerated() {
            result[entry.element.id] = PlaylistItemInfo(
                addedAt: addedAtBySongID[entry.element.id] ?? 0,
                sequence: index + 1
            )
        }
        return result
    }
}

struct PersistedQueueEntry: Codable, Equatable {
    let id: UInt32
    let songID: UUID
}

struct PersistedPlayerQueue {
    let entries: [PersistedQueueEntry]
    let baseEntries: [PersistedQueueEntry]
    let nextQueueID: UInt32
    let currentIndex: Int?
    let elapsed: TimeInterval
}

/// One of the two kinds of music library.
///
/// - `internal`: the single, writable library whose database lives inside the
///   same folder (and whose music lives in its `Music` subfolder).
/// - `external`: a folder managed by another application (iTunes, etc.). It is
///   indexed read-only; tag edits are never written back.
struct MusicLibrary: Identifiable, Hashable {
    enum Kind: String {
        case internalLibrary = "internal"
        case external = "external"
    }

    let id: UUID
    var path: String
    var name: String
    var kind: Kind
    var isEnabled: Bool

    init(id: UUID, path: String, name: String, kind: Kind, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
    }

    var isReadOnly: Bool { kind == .external }
    var isInternal: Bool { kind == .internalLibrary }
    var isExternal: Bool { kind == .external }

    /// The folder that is actually scanned: `Music` for the internal library,
    /// the root itself for external libraries.
    var scanPath: String {
        isInternal
            ? URL(fileURLWithPath: path).appendingPathComponent("Music").path
            : path
    }

    var musicPath: String {
        URL(fileURLWithPath: path).appendingPathComponent("Music").path
    }
}

struct ArtistSummary: Identifiable, Hashable {
    let name: String
    let albums: [Album]

    var id: String { name }
}

struct GenreItem: Identifiable, Hashable {
    /// Raw genre value. Empty means the tag is missing.
    let name: String
    let count: Int
    var id: String { name }
    var displayName: String { name.isEmpty ? "#Unknown" : name }
    var isUnknown: Bool { name.isEmpty }
}

// MARK: - Navigation

enum LibrarySection: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case albums = "Albums"
    case artists = "Artists"
    case songs = "Songs"
    case genres = "Genres"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .recentlyAdded: return "clock"
        case .albums: return "square.stack"
        case .artists: return "person"
        case .songs: return "music.note"
        case .genres: return "tag"
        }
    }
}

enum SidebarSelection: Hashable {
    case library(LibrarySection)
    /// Built-in playlist backed by `songs.loved`; not stored in `playlists`.
    case starred
    case playlist(UUID)
}

extension SidebarSelection {
    var persistenceValue: String {
        switch self {
        case .library(let section):
            return "library:\(section.rawValue)"
        case .starred:
            return "starred"
        case .playlist(let id):
            return "playlist:\(id.uuidString)"
        }
    }

    init?(persistenceValue: String) {
        if persistenceValue == "starred" {
            self = .starred
            return
        }
        let libraryPrefix = "library:"
        if persistenceValue.hasPrefix(libraryPrefix),
           let section = LibrarySection(rawValue: String(persistenceValue.dropFirst(libraryPrefix.count))) {
            self = .library(section)
            return
        }
        let playlistPrefix = "playlist:"
        if persistenceValue.hasPrefix(playlistPrefix),
           let id = UUID(uuidString: String(persistenceValue.dropFirst(playlistPrefix.count))) {
            self = .playlist(id)
            return
        }
        return nil
    }
}

enum SidebarSelectionStore {
    static let defaultsKey = "sidebarSelection"
    static let fallback: SidebarSelection = .library(.recentlyAdded)

    static func load() -> SidebarSelection? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return SidebarSelection(persistenceValue: raw)
    }

    static func save(_ selection: SidebarSelection) {
        UserDefaults.standard.set(selection.persistenceValue, forKey: defaultsKey)
    }
}
