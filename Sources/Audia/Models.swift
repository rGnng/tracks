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

    static func make(_ seed: Int) -> Artwork {
        let p = palettes[abs(seed) % palettes.count]
        return Artwork(colors: p)
    }

    private static let palettes: [[Color]] = [
        [Color(red: 0.95, green: 0.42, blue: 0.34), Color(red: 0.45, green: 0.18, blue: 0.55)],
        [Color(red: 0.20, green: 0.45, blue: 0.90), Color(red: 0.10, green: 0.70, blue: 0.85)],
        [Color(red: 0.20, green: 0.70, blue: 0.45), Color(red: 0.10, green: 0.45, blue: 0.55)],
        [Color(red: 1.00, green: 0.62, blue: 0.20), Color(red: 0.90, green: 0.30, blue: 0.30)],
        [Color(red: 0.75, green: 0.35, blue: 0.85), Color(red: 0.95, green: 0.35, blue: 0.60)],
        [Color(red: 0.15, green: 0.65, blue: 0.60), Color(red: 0.10, green: 0.40, blue: 0.70)],
        [Color(red: 0.95, green: 0.78, blue: 0.30), Color(red: 0.85, green: 0.45, blue: 0.20)],
        [Color(red: 0.35, green: 0.40, blue: 0.50), Color(red: 0.15, green: 0.18, blue: 0.30)],
        [Color(red: 0.95, green: 0.45, blue: 0.55), Color(red: 0.65, green: 0.20, blue: 0.45)],
        [Color(red: 0.20, green: 0.75, blue: 0.90), Color(red: 0.20, green: 0.45, blue: 0.75)],
        [Color(red: 0.60, green: 0.80, blue: 0.30), Color(red: 0.25, green: 0.55, blue: 0.35)],
        [Color(red: 0.40, green: 0.35, blue: 0.85), Color(red: 0.85, green: 0.45, blue: 0.75)],
    ]
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
    fileprivate static func yearNumber(from value: String) -> Int {
        Int(value.prefix(4)) ?? 0
    }
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
}

struct Playlist: Identifiable, Hashable {
    let id: UUID
    let name: String
    let songs: [Song]
    /// UNIX timestamp used by MPD's `Last-Modified` field.
    let dateModified: TimeInterval

    init(id: UUID = UUID(), name: String, songs: [Song],
         dateModified: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.songs = songs
        self.dateModified = dateModified
    }
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

    var isReadOnly: Bool { kind == .external }
    var isInternal: Bool { kind == .internalLibrary }

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
    let name: String
    let count: Int
    var id: String { name }
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

// MARK: - Mock data

enum MockData {
    static let albums: [Album] = [
        Album(title: "Midnight Architecture", artist: "Lunar Veil", genre: "Electronic", year: "2023", artwork: .make(0),
              songs: songs(["Glass Facade", "Neon Undertow", "Concrete Waves", "Halogen Sky", "Slow Circuit", "Rooftop Static", "Afterimage", "Parallel Rails"], "Lunar Veil", "Midnight Architecture", "Electronic", "2023")),
        Album(title: "Paper Moons", artist: "The Paper Foxes", genre: "Indie Rock", year: "2022", artwork: .make(1),
              songs: songs(["Origami Heart", "Cutout Stars", "Folded Light", "Paper Moons", "Ink & Ivory", "Crease", "Unwritten", "Second Draft", "Margins", "Epilogue"], "The Paper Foxes", "Paper Moons", "Indie Rock", "2022")),
        Album(title: "Sol y Sombra", artist: "Mira Sol", genre: "Latin Pop", year: "2021", artwork: .make(2),
              songs: songs(["Amanecer", "Corazón de Fuego", "Media Noche", "Bajo el Sol", "Viento Cálido", "La Orilla", "Sombra y Luz", "Despertar", "Mar Adentro"], "Mira Sol", "Sol y Sombra", "Latin Pop", "2021")),
        Album(title: "Static Bloom", artist: "Copperfield", genre: "Alternative", year: "2024", artwork: .make(3),
              songs: songs(["White Noise Garden", "Half Signal", "Static Bloom", "Copper Wire", "Fever Frequency", "Dandelion Radio", "Transmission", "Low Tide"], "Copperfield", "Static Bloom", "Alternative", "2024")),
        Album(title: "Afterlight", artist: "Nova Reyes", genre: "Synthpop", year: "2023", artwork: .make(4),
              songs: songs(["Afterlight", "Chrome Sunset", "Velvet Static", "Pulse", "Mirrorball", "Night Drive", "Electric Bloom", "Halcyon", "Last Call"], "Nova Reyes", "Afterlight", "Synthpop", "2023")),
        Album(title: "Woodland Echoes", artist: "Fern & Fable", genre: "Folk", year: "2020", artwork: .make(5),
              songs: songs(["Moss & Morning", "The Old Trail", "Woodland Echoes", "Birchlight", "River Song", "Lantern", "Hollow", "Wren"], "Fern & Fable", "Woodland Echoes", "Folk", "2020")),
        Album(title: "Neon Reverie", artist: "Kai Drift", genre: "Electronic", year: "2022", artwork: .make(6),
              songs: songs(["Neon Reverie", "Ghost Signal", "Prism", "Overdrive", "Bloom", "Wavelength", "Subsonic", "Aurora Grid", "Fade to Blue"], "Kai Drift", "Neon Reverie", "Electronic", "2022")),
        Album(title: "Gravity Well", artist: "The Paper Foxes", genre: "Indie Rock", year: "2019", artwork: .make(7),
              songs: songs(["Gravity Well", "Event Horizon", "Low Orbit", "Tidal", "Orbit Decay", "Starfall", "Escape Velocity", "Long Way Down"], "The Paper Foxes", "Gravity Well", "Indie Rock", "2019")),
        Album(title: "Saltwater", artist: "Mira Sol", genre: "R&B", year: "2024", artwork: .make(8),
              songs: songs(["Saltwater", "Tide & Time", "Undertow", "Pearl", "After the Rain", "High Noon", "Driftwood", "Silver Lining", "Horizon"], "Mira Sol", "Saltwater", "R&B", "2024")),
        Album(title: "Glass Cathedral", artist: "Lunar Veil", genre: "Ambient", year: "2021", artwork: .make(9),
              songs: songs(["Vestibule", "Stained Light", "Nave", "Choir of Glass", "Aisle", "Vesper", "Echo Chamber", "Sanctum"], "Lunar Veil", "Glass Cathedral", "Ambient", "2021")),
    ]

    static let allSongs: [Song] = albums.flatMap(\.songs)

    static let playlists: [Playlist] = [
        Playlist(name: "Favorites", songs: pick(seed: 3, count: 14)),
        Playlist(name: "Late Night Drive", songs: pick(seed: 11, count: 12)),
        Playlist(name: "Focus", songs: pick(seed: 21, count: 10)),
        Playlist(name: "Road Trip", songs: pick(seed: 37, count: 16)),
    ]

    static func artworkColors(forAlbum title: String) -> [Color] {
        albums.first { $0.title == title }?.artwork.colors ?? [Color(white: 0.82)]
    }

    static let genres: [GenreItem] = {
        var counts: [String: Int] = [:]
        for a in albums { counts[a.genre, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { GenreItem(name: $0.key, count: $0.value) }
    }()

    static let artists: [ArtistSummary] = {
        var groups: [String: [Album]] = [:]
        for a in albums { groups[a.artist, default: []].append(a) }
        return groups
            .map { ArtistSummary(name: $0.key, albums: $0.value.sorted { $0.yearNumber > $1.yearNumber }) }
            .sorted { $0.name < $1.name }
    }()

    private static func songs(_ titles: [String], _ artist: String, _ album: String, _ genre: String, _ year: String) -> [Song] {
        titles.enumerated().map { i, t in
            Song(
                title: t,
                artist: artist,
                album: album,
                genre: genre,
                duration: TimeInterval(Int.random(in: 158...341)),
                trackNumber: i + 1,
                year: year,
                plays: Int.random(in: 4...480)
            )
        }
    }

    private static func pick(seed: Int, count: Int) -> [Song] {
        var out: [Song] = []
        var i = seed
        while out.count < count {
            let song = allSongs[i % allSongs.count]
            if !out.contains(song) { out.append(song) }
            i += 7
        }
        return out
    }
}
