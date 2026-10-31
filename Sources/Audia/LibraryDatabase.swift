import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LibraryDatabaseError: LocalizedError {
    case openFailed(String)
    case backupFailed(String)
    case transactionFailed(String)
    case identifierInUse(String)
    case namespaceConflict(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Could not open the library database at \(path)."
        case .backupFailed(let message):
            return "Could not back up the library database: \(message)"
        case .transactionFailed(let message):
            return "Could not update the library database: \(message)"
        case .identifierInUse(let identifier):
            return "The library identifier “\(identifier)” is already in use. Choose another one."
        case .namespaceConflict(let namespace):
            return "ReKey aborted: the library namespace “\(namespace)” is used by more than one library."
        }
    }
}

struct LibraryInspection {
    let path: String
    let songCount: Int
}

/// SQLite-backed library database with iTunes-style persistent IDs.
@MainActor
final class LibraryDatabase {
    private var db: OpaquePointer?
    private(set) var path: String

    var isOpen: Bool { db != nil }

    private struct AlbumMeta {
        let id: String
        let title: String
        let artist: String
        let genre: String
        let year: String
    }

    private struct RekeyArtist {
        let id: UUID
        let name: String
    }

    private struct RekeyAlbum {
        var id: UUID
        var title: String
        var artistID: String
        var genre: String
        var year: String
        var artwork: Data?
    }

    private struct RekeySong {
        var id: UUID
        var path: String
        var libraryID: UUID?
        var title: String
        var artistID: String
        var albumID: String
        var genre: String
        var year: String
        var track: Int
        var trackTotal: Int
        var disc: Int
        var discTotal: Int
        var comments: String
        var duration: Double
        var dateAdded: Double
        var playCount: Int
        var rating: Int
        var loved: Int
        var lastPlayed: Double?
        var skipCount: Int
        var mtime: Double
        var fileSize: Int64
    }

    private struct RekeyPlaylistItem {
        let playlistID: String
        let songID: UUID
        let position: Int
        let addedAt: Double
    }

    init(path: String) {
        self.path = path
        open()
    }

    private func open() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let result = sqlite3_open(path, &db)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle = db { sqlite3_close(handle) }
            db = nil
            AppLog.database.error("Could not open library database (SQLite \(result, privacy: .public)): \(message, privacy: .public)")
            return
        }
        AppLog.database.notice("Opened library database")
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        createSchema()
    }

    private func checkpointAndClose() {
        guard let db else { return }
        let result = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if result != SQLITE_OK {
            AppLog.database.warning("WAL checkpoint failed (SQLite \(result, privacy: .public))")
        }
        sqlite3_close(db)
        self.db = nil
    }

    /// Flushes the WAL into library.sqlite, switches back to a rollback
    /// journal and closes the connection. The resulting database file is
    /// self-contained, so copying just library.sqlite works even without its
    /// -wal/-shm siblings. Reopening switches to WAL again.
    func closeForTermination() {
        guard let db else { return }
        let checkpoint = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if checkpoint != SQLITE_OK {
            AppLog.database.warning("Final WAL checkpoint failed (SQLite \(checkpoint, privacy: .public))")
        }
        exec("PRAGMA journal_mode=DELETE;")
        sqlite3_close(db)
        self.db = nil
        // SQLite can leave the WAL index behind after switching journal modes.
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    /// Switches to another database in place (used by first-launch database
    /// location setup). The current database is restored if the new one cannot
    /// be opened.
    func switchTo(path newPath: String) throws {
        guard newPath != path else { return }
        let oldPath = path
        checkpointAndClose()
        path = newPath
        open()
        guard db != nil else {
            path = oldPath
            open()
            throw LibraryDatabaseError.openFailed(newPath)
        }
    }

    /// Validation of a database that is about to be opened. It verifies the
    /// Tracks table/column signature and deliberately does not create or
    /// migrate anything.
    static func inspect(path: String) -> LibraryInspection? {
        var handle: OpaquePointer?
        // Read-write (but never create) is intentional: a WAL-mode database
        // copied without its -shm file cannot be inspected read-only.
        let openResult = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            AppLog.database.warning("Could not inspect library database (SQLite \(openResult, privacy: .public)): \(message, privacy: .public)")
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1000)

        func query(_ sql: String) -> OpaquePointer? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            return stmt
        }

        var tables = Set<String>()
        if let stmt = query("SELECT name FROM sqlite_master WHERE type = 'table'") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 0) {
                    tables.insert(String(cString: name))
                }
            }
            sqlite3_finalize(stmt)
        }
        let requiredTables: Set<String> = [
            "artists", "albums", "songs", "libraries", "playlists",
            "playlist_items",
        ]
        guard requiredTables.isSubset(of: tables) else { return nil }

        func columns(in table: String) -> Set<String> {
            var result = Set<String>()
            guard let stmt = query("PRAGMA table_info(\(table))") else { return result }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    result.insert(String(cString: name))
                }
            }
            sqlite3_finalize(stmt)
            return result
        }

        guard columns(in: "songs").isSuperset(of: [
            "id", "path", "title", "artist_id", "album_id", "date_added",
        ]),
        columns(in: "albums").isSuperset(of: ["id", "title", "artist_id"]),
        columns(in: "artists").isSuperset(of: ["id", "name"]),
        columns(in: "libraries").isSuperset(of: [
            "id", "path", "kind", "name", "identifier", "id_namespace", "enabled",
        ]),
        columns(in: "playlists").isSuperset(of: ["id", "name"]),
        columns(in: "playlist_items").isSuperset(of: ["playlist_id", "song_id", "position"]) else {
            return nil
        }

        var songCount = 0
        if let stmt = query("SELECT COUNT(*) FROM songs") {
            if sqlite3_step(stmt) == SQLITE_ROW {
                songCount = Int(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        return LibraryInspection(path: path, songCount: songCount)
    }

    // MARK: Schema

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS artists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS albums (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist_id TEXT NOT NULL,
            genre TEXT NOT NULL DEFAULT '',
            year TEXT NOT NULL DEFAULT '',
            artwork BLOB,
            UNIQUE(title, artist_id)
        );
        CREATE TABLE IF NOT EXISTS songs (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            library_id TEXT,
            title TEXT NOT NULL,
            artist_id TEXT NOT NULL,
            album_id TEXT NOT NULL,
            genre TEXT NOT NULL DEFAULT '',
            year TEXT NOT NULL DEFAULT '',
            track INTEGER NOT NULL DEFAULT 0,
            track_total INTEGER NOT NULL DEFAULT 0,
            disc INTEGER NOT NULL DEFAULT 0,
            disc_total INTEGER NOT NULL DEFAULT 0,
            comments TEXT NOT NULL DEFAULT '',
            duration REAL NOT NULL DEFAULT 0,
            date_added REAL NOT NULL,
            play_count INTEGER NOT NULL DEFAULT 0,
            rating INTEGER NOT NULL DEFAULT 0,
            loved INTEGER NOT NULL DEFAULT 0,
            last_played REAL,
            skip_count INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0,
            file_size INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS libraries (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL DEFAULT 'external',
            name TEXT NOT NULL,
            identifier TEXT NOT NULL DEFAULT '',
            id_namespace TEXT NOT NULL DEFAULT '',
            date_added REAL NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            date_created REAL NOT NULL,
            date_modified REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS playlist_items (
            playlist_id TEXT NOT NULL,
            song_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            added_at REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (playlist_id, song_id)
        );
        CREATE TABLE IF NOT EXISTS player_queue (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            queue_entries TEXT NOT NULL DEFAULT '[]',
            base_queue_entries TEXT NOT NULL DEFAULT '[]',
            next_queue_id INTEGER NOT NULL DEFAULT 1,
            current_index INTEGER NOT NULL DEFAULT -1,
            elapsed REAL NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album_id);
        CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist_id);
        CREATE INDEX IF NOT EXISTS idx_songs_library ON songs(library_id);
        CREATE INDEX IF NOT EXISTS idx_playlist_items ON playlist_items(playlist_id, position);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_libraries_identifier
            ON libraries(identifier COLLATE NOCASE);
        """)
    }

    private static func libraryIdentifierNumber(_ identifier: String) -> Int? {
        let lower = identifier.lowercased()
        guard lower.hasPrefix("library") else { return nil }
        let suffix = lower.dropFirst("library".count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }

    func nextLibraryIdentifier() -> String {
        var used = Set<String>()
        var maxNumber = 0
        guard let stmt = prepare("SELECT identifier, id_namespace FROM libraries") else {
            return "library1"
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            for index in 0..<2 {
                let value = SongIdentity.normalizeIdentifier(text(stmt, Int32(index)) ?? "")
                guard !value.isEmpty else { continue }
                used.insert(value)
                if let number = Self.libraryIdentifierNumber(value) {
                    maxNumber = max(maxNumber, number)
                }
            }
        }
        sqlite3_finalize(stmt)
        var number = maxNumber + 1
        var candidate = "library\(number)"
        while used.contains(candidate) {
            number += 1
            candidate = "library\(number)"
        }
        return candidate
    }

    // MARK: Scanning / sync

    func knownFiles() -> [String: KnownFile] {
        var result: [String: KnownFile] = [:]
        guard let stmt = prepare("SELECT path, mtime, file_size FROM songs") else { return result }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let path = text(stmt, 0) {
                result[path] = KnownFile(mtime: double(stmt, 1), size: Int64(int(stmt, 2)))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    @discardableResult
    func sync(tracks: [ScannedTrack], libraries: [MusicLibrary]) -> [String: Data] {
        guard !tracks.isEmpty else { return [:] }
        let discoveredAt = Date().timeIntervalSince1970
        exec("BEGIN;")

        // Cache artist/album IDs during a batch and write each album's cover
        // only once. The old code upserted the same multi-megabyte artwork BLOB
        // for every track in an album, which made large scans extremely slow.
        var artistIDs: [String: String] = [:]
        var albumIDs: [String: String] = [:]
        var albumArtwork: [String: Data] = [:]
        var artworkByAlbumID: [String: Data] = [:]
        for track in tracks {
            let key = track.albumArtist + "\u{1F}" + track.album.lowercased()
            if albumArtwork[key] == nil, let artwork = track.artwork {
                albumArtwork[key] = artwork
            }
        }

        func artistID(_ name: String) -> String {
            if let id = artistIDs[name] { return id }
            let id = ensureArtist(name)
            artistIDs[name] = id
            return id
        }

        for track in tracks {
            let trackArtistID = artistID(track.artist)
            let albumArtistID = artistID(track.albumArtist)
            let key = track.albumArtist + "\u{1F}" + track.album.lowercased()
            let albumID: String
            if let cached = albumIDs[key] {
                albumID = cached
            } else {
                albumID = ensureAlbum(title: track.album,
                                      artistID: albumArtistID,
                                      genre: track.genre,
                                      year: track.year,
                                      artwork: nil)
                albumIDs[key] = albumID
            }
            if let artwork = albumArtwork[key] {
                artworkByAlbumID[albumID] = artwork
            }
            let added = track.mtime > 0 ? track.mtime : discoveredAt
            let path = canonicalPath(track.path)
            let owner = libraries
                .filter { $0.isEnabled }
                .map { (library: $0, root: canonicalPath($0.scanPath)) }
                .filter { isUnder(path, root: $0.root) }
                .max { $0.root.count < $1.root.count }
            upsertSong(track,
                       ownerLibrary: owner?.library,
                       artistID: trackArtistID,
                       albumID: albumID,
                       dateAdded: added)
        }
        exec("COMMIT;")
        return artworkByAlbumID
    }

    /// Recomputes every song, album, and artist UUID from the current library
    /// namespaces, relative paths, and stored metadata. Song rows are rebuilt
    /// in place so play counts, stars, dates, playlists, and the saved queue
    /// survive the ID change.
    func rekeyAllLibraries(reporter: RekeyProgressReporter = RekeyProgressReporter()) throws -> LibraryRekeyResult {
        reporter.phase("Reading database", 0.02)
        let libraries = loadLibraries()
        guard !libraries.isEmpty else {
            reporter.info("No libraries to rekey")
            return LibraryRekeyResult(songIDMap: [:], albumIDMap: [:],
                                      songCount: 0, albumCount: 0, artistCount: 0)
        }
        var namespaceSet = Set<String>()
        for library in libraries {
            let namespace = SongIdentity.normalizeIdentifier(library.identifier)
            guard !namespace.isEmpty else {
                throw LibraryDatabaseError.namespaceConflict("empty")
            }
            guard namespaceSet.insert(namespace).inserted else {
                throw LibraryDatabaseError.namespaceConflict(namespace)
            }
        }
        reporter.info("Validated \(libraries.count) library namespaces")
        reporter.info("Loaded \(libraries.count) libraries")

        var artistNames: [String: String] = [:]
        if let stmt = prepare("SELECT id, name FROM artists") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let id = text(stmt, 0), let name = text(stmt, 1) {
                    artistNames[id] = name
                }
            }
            sqlite3_finalize(stmt)
        }

        var oldAlbums: [String: RekeyAlbum] = [:]
        if let stmt = prepare("""
            SELECT id, title, artist_id, genre, year, artwork FROM albums
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = text(stmt, 0), let uuid = UUID(uuidString: id) else { continue }
                oldAlbums[id] = RekeyAlbum(id: uuid,
                                           title: text(stmt, 1) ?? "",
                                           artistID: text(stmt, 2) ?? "",
                                           genre: text(stmt, 3) ?? "",
                                           year: text(stmt, 4) ?? "",
                                           artwork: blob(stmt, 5))
            }
            sqlite3_finalize(stmt)
        }

        var songs: [RekeySong] = []
        if let stmt = prepare("""
            SELECT id, path, library_id, title, artist_id, album_id, genre, year,
                   track, track_total, disc, disc_total, comments, duration,
                   date_added, play_count, rating, loved, last_played,
                   skip_count, mtime, file_size
            FROM songs
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idString = text(stmt, 0),
                      let id = UUID(uuidString: idString) else { continue }
                songs.append(RekeySong(
                    id: id,
                    path: text(stmt, 1) ?? "",
                    libraryID: text(stmt, 2).flatMap(UUID.init(uuidString:)),
                    title: text(stmt, 3) ?? "",
                    artistID: text(stmt, 4) ?? "",
                    albumID: text(stmt, 5) ?? "",
                    genre: text(stmt, 6) ?? "",
                    year: text(stmt, 7) ?? "",
                    track: int(stmt, 8),
                    trackTotal: int(stmt, 9),
                    disc: int(stmt, 10),
                    discTotal: int(stmt, 11),
                    comments: text(stmt, 12) ?? "",
                    duration: double(stmt, 13),
                    dateAdded: double(stmt, 14),
                    playCount: int(stmt, 15),
                    rating: int(stmt, 16),
                    loved: int(stmt, 17),
                    lastPlayed: optionalDouble(stmt, 18),
                    skipCount: int(stmt, 19),
                    mtime: double(stmt, 20),
                    fileSize: Int64(int(stmt, 21))
                ))
            }
            sqlite3_finalize(stmt)
        }

        var playlistItems: [RekeyPlaylistItem] = []
        if let stmt = prepare("""
            SELECT playlist_id, song_id, position, added_at FROM playlist_items
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let playlistID = text(stmt, 0),
                      let songIDString = text(stmt, 1),
                      let songID = UUID(uuidString: songIDString) else { continue }
                playlistItems.append(RekeyPlaylistItem(
                    playlistID: playlistID,
                    songID: songID,
                    position: int(stmt, 2),
                    addedAt: double(stmt, 3)
                ))
            }
            sqlite3_finalize(stmt)
        }

        let savedQueue = loadPlayerQueue()
        reporter.info("Loaded \(songs.count) songs, \(oldAlbums.count) albums, \(artistNames.count) artists, and \(playlistItems.count) playlist items")
        reporter.phase("Calculating new UUIDs", 0.2)
        let libraryByID = Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, $0) })
        let newNamespaceByLibraryID = Dictionary(uniqueKeysWithValues: libraries.map {
            ($0.id, SongIdentity.normalizeIdentifier($0.identifier))
        })
        let sortedLibraries = libraries.sorted { $0.path.count > $1.path.count }

        func ownerLibrary(for song: RekeySong) -> MusicLibrary? {
            if let libraryID = song.libraryID, let library = libraryByID[libraryID] {
                return library
            }
            let path = canonicalPath(song.path)
            return sortedLibraries.first { isUnder(path, root: canonicalPath($0.path)) }
        }

        var newArtists: [String: RekeyArtist] = [:]
        func ensureNewArtist(name: String) -> String {
            let id = SongIdentity.artistID(name: name).uuidString
            if newArtists[id] == nil {
                newArtists[id] = RekeyArtist(id: UUID(uuidString: id) ?? UUID(), name: name)
            }
            return id
        }

        var newAlbums: [String: RekeyAlbum] = [:]
        var oldToNewAlbum: [String: String] = [:]
        for oldAlbum in oldAlbums.values {
            let albumArtistName = artistNames[oldAlbum.artistID] ?? ""
            let albumArtistID = ensureNewArtist(name: albumArtistName)
            let newID = SongIdentity.albumID(artistID: albumArtistID,
                                             title: oldAlbum.title).uuidString
            oldToNewAlbum[oldAlbum.id.uuidString] = newID
            if var existing = newAlbums[newID] {
                if existing.genre.isEmpty { existing.genre = oldAlbum.genre }
                if existing.year.isEmpty { existing.year = oldAlbum.year }
                if existing.artwork == nil { existing.artwork = oldAlbum.artwork }
                newAlbums[newID] = existing
            } else {
                newAlbums[newID] = RekeyAlbum(id: UUID(uuidString: newID) ?? oldAlbum.id,
                                              title: oldAlbum.title,
                                              artistID: albumArtistID,
                                              genre: oldAlbum.genre,
                                              year: oldAlbum.year,
                                              artwork: oldAlbum.artwork)
            }
        }

        var oldToNewSong: [UUID: UUID] = [:]
        var newToOldSong: [UUID: UUID] = [:]
        var rekeyedSongs: [RekeySong] = []
        rekeyedSongs.reserveCapacity(songs.count)

        for var song in songs {
            let owner = ownerLibrary(for: song)
            let newSongID: UUID
            if let owner,
               let relative = SongIdentity.relativePath(filePath: song.path,
                                                        libraryRoot: owner.path) {
                let namespace = newNamespaceByLibraryID[owner.id] ?? owner.idNamespace
                newSongID = SongIdentity.songID(namespace: namespace,
                                                relativePath: relative)
            } else {
                newSongID = song.id
                AppLog.library.warning("Rekey kept a legacy song ID because no library namespace matched: \(song.path, privacy: .public)")
            }
            if let existing = newToOldSong[newSongID], existing != song.id {
                throw LibraryDatabaseError.transactionFailed(
                    "Rekey produced a duplicate song ID for \(song.path)."
                )
            }
            newToOldSong[newSongID] = song.id
            oldToNewSong[song.id] = newSongID

            let trackArtistName = artistNames[song.artistID] ?? ""
            let newTrackArtistID = ensureNewArtist(name: trackArtistName)

            let oldAlbum = oldAlbums[song.albumID]
            let albumArtistName = oldAlbum.flatMap { artistNames[$0.artistID] } ?? ""
            let albumArtistID = ensureNewArtist(name: albumArtistName)
            let newAlbumID: String
            if let mapped = oldToNewAlbum[song.albumID] {
                newAlbumID = mapped
            } else {
                newAlbumID = SongIdentity.albumID(artistID: albumArtistID,
                                                  title: oldAlbum?.title ?? "").uuidString
                oldToNewAlbum[song.albumID] = newAlbumID
                if newAlbums[newAlbumID] == nil {
                    newAlbums[newAlbumID] = RekeyAlbum(
                        id: UUID(uuidString: newAlbumID) ?? UUID(),
                        title: oldAlbum?.title ?? "",
                        artistID: albumArtistID,
                        genre: oldAlbum?.genre ?? "",
                        year: oldAlbum?.year ?? "",
                        artwork: oldAlbum?.artwork
                    )
                }
            }

            song.id = newSongID
            song.libraryID = owner?.id ?? song.libraryID
            song.artistID = newTrackArtistID
            song.albumID = newAlbumID
            rekeyedSongs.append(song)
        }

        reporter.info("Mapped \(oldToNewSong.count) songs and \(oldToNewAlbum.count) albums")
        reporter.phase("Writing database", 0.45)
        let backupURL = try backup()
        reporter.info("Backup created: \(backupURL.lastPathComponent)")
        try executeThrowing("BEGIN IMMEDIATE;")
        do {
            try executeThrowing("DELETE FROM playlist_items;")
            try executeThrowing("DELETE FROM songs;")
            try executeThrowing("DELETE FROM albums;")
            try executeThrowing("DELETE FROM artists;")

            for artist in newArtists.values {
                guard let stmt = prepare("INSERT INTO artists(id, name) VALUES(?, ?)") else {
                    throw LibraryDatabaseError.transactionFailed("Could not prepare artist insert")
                }
                bind(stmt, 1, artist.id.uuidString)
                bind(stmt, 2, artist.name)
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
                }
            }

            let referencedAlbumIDs = Set(rekeyedSongs.map(\.albumID))
            for album in newAlbums.values where referencedAlbumIDs.contains(album.id.uuidString) {
                guard let stmt = prepare("""
                    INSERT INTO albums(id, title, artist_id, genre, year, artwork)
                    VALUES(?, ?, ?, ?, ?, ?)
                    """) else {
                    throw LibraryDatabaseError.transactionFailed("Could not prepare album insert")
                }
                bind(stmt, 1, album.id.uuidString)
                bind(stmt, 2, album.title)
                bind(stmt, 3, album.artistID)
                bind(stmt, 4, album.genre)
                bind(stmt, 5, album.year)
                bind(stmt, 6, album.artwork)
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
                }
            }

            for song in rekeyedSongs {
                guard let stmt = prepare("""
                    INSERT INTO songs(id, path, library_id, title, artist_id, album_id,
                                      genre, year, track, track_total, disc, disc_total,
                                      comments, duration, date_added, play_count, rating,
                                      loved, last_played, skip_count, mtime, file_size)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """) else {
                    throw LibraryDatabaseError.transactionFailed("Could not prepare song insert")
                }
                bind(stmt, 1, song.id.uuidString)
                bind(stmt, 2, song.path)
                bind(stmt, 3, song.libraryID?.uuidString)
                bind(stmt, 4, song.title)
                bind(stmt, 5, song.artistID)
                bind(stmt, 6, song.albumID)
                bind(stmt, 7, song.genre)
                bind(stmt, 8, song.year)
                bind(stmt, 9, song.track)
                bind(stmt, 10, song.trackTotal)
                bind(stmt, 11, song.disc)
                bind(stmt, 12, song.discTotal)
                bind(stmt, 13, song.comments)
                bind(stmt, 14, song.duration)
                bind(stmt, 15, song.dateAdded)
                bind(stmt, 16, song.playCount)
                bind(stmt, 17, song.rating)
                bind(stmt, 18, song.loved)
                if let lastPlayed = song.lastPlayed {
                    bind(stmt, 19, lastPlayed)
                } else {
                    sqlite3_bind_null(stmt, 19)
                }
                bind(stmt, 20, song.skipCount)
                bind(stmt, 21, song.mtime)
                bind(stmt, 22, Int(song.fileSize))
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
                }
            }

            for item in playlistItems {
                guard let stmt = prepare("""
                    INSERT OR IGNORE INTO playlist_items(playlist_id, song_id, position, added_at)
                    VALUES(?, ?, ?, ?)
                    """) else {
                    throw LibraryDatabaseError.transactionFailed("Could not prepare playlist item insert")
                }
                let songID = oldToNewSong[item.songID] ?? item.songID
                bind(stmt, 1, item.playlistID)
                bind(stmt, 2, songID.uuidString)
                bind(stmt, 3, item.position)
                bind(stmt, 4, item.addedAt)
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
                }
            }

            if let savedQueue {
                let entries = savedQueue.entries.map {
                    PersistedQueueEntry(id: $0.id, songID: oldToNewSong[$0.songID] ?? $0.songID)
                }
                let baseEntries = savedQueue.baseEntries.map {
                    PersistedQueueEntry(id: $0.id, songID: oldToNewSong[$0.songID] ?? $0.songID)
                }
                savePlayerQueue(PersistedPlayerQueue(
                    entries: entries,
                    baseEntries: baseEntries,
                    nextQueueID: savedQueue.nextQueueID,
                    currentIndex: savedQueue.currentIndex,
                    elapsed: savedQueue.elapsed
                ))
            }

            for library in libraries {
                guard let stmt = prepare("UPDATE libraries SET id_namespace = ? WHERE id = ?") else {
                    throw LibraryDatabaseError.transactionFailed("Could not prepare library rekey update")
                }
                bind(stmt, 1, SongIdentity.normalizeIdentifier(library.identifier))
                bind(stmt, 2, library.id.uuidString)
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
                }
            }

            cleanupOrphans()
            try executeThrowing("COMMIT;")
        } catch {
            exec("ROLLBACK;")
            throw error
        }

        reporter.phase("Finalizing", 0.9)
        reporter.info("Rebuilt songs, albums, artists, playlists, and the saved queue")
        let referencedOldAlbumIDs = Set(songs.map(\.albumID))
        var albumIDMap: [UUID: UUID] = [:]
        for (old, new) in oldToNewAlbum where referencedOldAlbumIDs.contains(old) {
            guard let oldID = UUID(uuidString: old),
                  let newID = UUID(uuidString: new) else { continue }
            albumIDMap[oldID] = newID
        }
        let insertedAlbumIDs = Set(rekeyedSongs.map(\.albumID))
        let insertedAlbums = newAlbums.filter { insertedAlbumIDs.contains($0.key) }
        let insertedArtistIDs = Set(rekeyedSongs.map(\.artistID))
            .union(insertedAlbums.values.map(\.artistID))
        AppLog.library.notice("Rekeyed \(rekeyedSongs.count, privacy: .public) songs and \(insertedAlbums.count, privacy: .public) albums")
        return LibraryRekeyResult(songIDMap: oldToNewSong,
                                  albumIDMap: albumIDMap,
                                  songCount: rekeyedSongs.count,
                                  albumCount: insertedAlbums.count,
                                  artistCount: insertedArtistIDs.count)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func isUnder(_ path: String, root: String) -> Bool {
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    // MARK: Libraries

    func loadLibraries() -> [MusicLibrary] {
        var result: [MusicLibrary] = []
        guard let stmt = prepare("""
            SELECT id, path, name, identifier, id_namespace, enabled
            FROM libraries
            ORDER BY identifier COLLATE NOCASE, name COLLATE NOCASE
            """) else { return result }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idString = text(stmt, 0),
                  let path = text(stmt, 1),
                  let name = text(stmt, 2),
                  let identifier = text(stmt, 3) else { continue }
            let id = UUID(uuidString: idString) ?? LibraryScanner.stableUUID("library|" + path)
            result.append(MusicLibrary(id: id,
                                       path: path,
                                       name: name,
                                       identifier: identifier,
                                       idNamespace: text(stmt, 4) ?? "",
                                       isEnabled: int(stmt, 5) != 0))
        }
        sqlite3_finalize(stmt)
        return result
    }

    @discardableResult
    func ensureLibrary(path: String, name: String, identifier: String) throws -> MusicLibrary {
        let libraryID = LibraryScanner.stableUUID("library|" + path).uuidString
        let namespace = SongIdentity.normalizeIdentifier(identifier)
        guard let stmt = prepare("""
            INSERT INTO libraries(id, path, kind, name, identifier, id_namespace, date_added)
            VALUES(?, ?, 'external', ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET kind = 'external', name = excluded.name
            """) else {
            throw LibraryDatabaseError.transactionFailed("Could not prepare library insert")
        }
        bind(stmt, 1, libraryID)
        bind(stmt, 2, path)
        bind(stmt, 3, name)
        bind(stmt, 4, identifier)
        bind(stmt, 5, namespace)
        bind(stmt, 6, Date().timeIntervalSince1970)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if result == SQLITE_CONSTRAINT {
            throw LibraryDatabaseError.identifierInUse(identifier)
        }
        guard result == SQLITE_DONE else {
            throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
        }
        if let select = prepare("""
            SELECT id, path, name, identifier, id_namespace, enabled
            FROM libraries WHERE path = ?
            """) {
            bind(select, 1, path)
            if sqlite3_step(select) == SQLITE_ROW,
               let idString = text(select, 0),
               let storedPath = text(select, 1),
               let storedName = text(select, 2),
               let storedIdentifier = text(select, 3) {
                let id = UUID(uuidString: idString) ?? LibraryScanner.stableUUID("library|" + storedPath)
                let storedNamespace = text(select, 4) ?? namespace
                let isEnabled = int(select, 5) != 0
                sqlite3_finalize(select)
                return MusicLibrary(id: id,
                                    path: storedPath,
                                    name: storedName,
                                    identifier: storedIdentifier,
                                    idNamespace: storedNamespace,
                                    isEnabled: isEnabled)
            }
            sqlite3_finalize(select)
        }
        return MusicLibrary(id: UUID(uuidString: libraryID) ?? UUID(),
                            path: path,
                            name: name,
                            identifier: identifier,
                            idNamespace: namespace,
                            isEnabled: true)
    }

    func setLibraryIdentifier(_ id: UUID, identifier: String) throws {
        guard let stmt = prepare("UPDATE libraries SET identifier = ? WHERE id = ?") else {
            throw LibraryDatabaseError.transactionFailed("Could not prepare identifier update")
        }
        bind(stmt, 1, identifier)
        bind(stmt, 2, id.uuidString)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if result == SQLITE_CONSTRAINT {
            throw LibraryDatabaseError.identifierInUse(identifier)
        }
        guard result == SQLITE_DONE else {
            throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
        }
    }

    func setLibraryEnabled(_ id: UUID, enabled: Bool) throws {
        guard let stmt = prepare("UPDATE libraries SET enabled = ? WHERE id = ?") else {
            throw LibraryDatabaseError.transactionFailed("Could not prepare library status update")
        }
        bind(stmt, 1, enabled ? 1 : 0)
        bind(stmt, 2, id.uuidString)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard result == SQLITE_DONE else {
            throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
        }
    }

    func songPaths(forLibrary id: UUID) -> [(id: UUID, path: String)] {
        var result: [(id: UUID, path: String)] = []
        guard let stmt = prepare("SELECT id, path FROM songs WHERE library_id = ?") else { return result }
        bind(stmt, 1, id.uuidString)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawID = text(stmt, 0), let songID = UUID(uuidString: rawID),
                  let path = text(stmt, 1) else { continue }
            result.append((songID, path))
        }
        sqlite3_finalize(stmt)
        return result
    }

    func missingSongIDs(libraryID: UUID, discoveredPaths: Set<String>) -> [UUID] {
        songPaths(forLibrary: libraryID).compactMap { entry in
            discoveredPaths.contains(canonicalPath(entry.path)) ? nil : entry.id
        }
    }

    func relocateLibrary(id: UUID,
                         to newPath: String,
                         songPaths: [UUID: String],
                         removingSongIDs: Set<UUID> = []) throws {
        try executeThrowing("BEGIN IMMEDIATE;")
        do {
            guard let check = prepare("SELECT enabled FROM libraries WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not validate media library")
            }
            bind(check, 1, id.uuidString)
            let exists = sqlite3_step(check) == SQLITE_ROW
            let enabled = int(check, 0) != 0
            sqlite3_finalize(check)
            guard exists, enabled else {
                throw LibraryDatabaseError.transactionFailed("Only enabled libraries can be relocated.")
            }

            guard let libraryStmt = prepare("UPDATE libraries SET path = ?, name = ? WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not prepare library path update")
            }
            bind(libraryStmt, 1, newPath)
            bind(libraryStmt, 2, URL(fileURLWithPath: newPath).lastPathComponent)
            bind(libraryStmt, 3, id.uuidString)
            let libraryResult = sqlite3_step(libraryStmt)
            sqlite3_finalize(libraryStmt)
            guard libraryResult == SQLITE_DONE else {
                throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
            }

            for (songID, path) in songPaths {
                guard let stmt = prepare("UPDATE songs SET path = ? WHERE id = ? AND library_id = ?") else {
                    throw LibraryDatabaseError.transactionFailed("Could not prepare song path update")
                }
                bind(stmt, 1, path)
                bind(stmt, 2, songID.uuidString)
                bind(stmt, 3, id.uuidString)
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                guard result == SQLITE_DONE else {
                    throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
                }
            }
            try deleteSongRows(removingSongIDs.map(\.uuidString))
            try executeThrowing("COMMIT;")
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    func removeSongsFromLibrary(_ songIDs: Set<UUID>, libraryID: UUID) throws {
        guard !songIDs.isEmpty else { return }
        try executeThrowing("BEGIN IMMEDIATE;")
        do {
            let validIDs = Set(songPaths(forLibrary: libraryID).map(\.id)).intersection(songIDs)
            try deleteSongRows(validIDs.map(\.uuidString))
            try executeThrowing("COMMIT;")
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    private func deleteSongRows(_ ids: [String]) throws {
        for id in ids {
            guard let modifiedStmt = prepare("""
                UPDATE playlists SET date_modified = ?
                WHERE id IN (SELECT playlist_id FROM playlist_items WHERE song_id = ?)
                """) else {
                throw LibraryDatabaseError.transactionFailed("Could not prepare playlist timestamp update")
            }
            bind(modifiedStmt, 1, Date().timeIntervalSince1970)
            bind(modifiedStmt, 2, id)
            let modifiedResult = sqlite3_step(modifiedStmt)
            sqlite3_finalize(modifiedStmt)
            guard modifiedResult == SQLITE_DONE else {
                throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
            }

            guard let playlistStmt = prepare("DELETE FROM playlist_items WHERE song_id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not prepare playlist cleanup")
            }
            bind(playlistStmt, 1, id)
            let playlistResult = sqlite3_step(playlistStmt)
            sqlite3_finalize(playlistStmt)
            guard playlistResult == SQLITE_DONE else {
                throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
            }

            guard let songStmt = prepare("DELETE FROM songs WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not prepare song cleanup")
            }
            bind(songStmt, 1, id)
            let songResult = sqlite3_step(songStmt)
            sqlite3_finalize(songStmt)
            guard songResult == SQLITE_DONE else {
                throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
            }
        }
        cleanupOrphans()
    }

    func deleteLibraryAndSongs(id: UUID) throws {
        try executeThrowing("BEGIN IMMEDIATE;")
        do {
            guard let libraryCheck = prepare("SELECT enabled FROM libraries WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not validate library")
            }
            bind(libraryCheck, 1, id.uuidString)
            let exists = sqlite3_step(libraryCheck) == SQLITE_ROW
            let isEnabled = int(libraryCheck, 0) != 0
            sqlite3_finalize(libraryCheck)
            guard exists, !isEnabled else {
                throw LibraryDatabaseError.transactionFailed("Only disabled libraries can be deleted.")
            }

            guard let songStmt = prepare("SELECT id FROM songs WHERE library_id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not read library songs")
            }
            bind(songStmt, 1, id.uuidString)
            var songIDs: [String] = []
            while sqlite3_step(songStmt) == SQLITE_ROW {
                if let songID = text(songStmt, 0) { songIDs.append(songID) }
            }
            sqlite3_finalize(songStmt)

            try deleteSongRows(songIDs)

            guard let libraryStmt = prepare("DELETE FROM libraries WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not prepare library cleanup")
            }
            bind(libraryStmt, 1, id.uuidString)
            let libraryResult = sqlite3_step(libraryStmt)
            sqlite3_finalize(libraryStmt)
            guard libraryResult == SQLITE_DONE else {
                throw LibraryDatabaseError.transactionFailed(databaseErrorMessage)
            }
            try executeThrowing("COMMIT;")
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    func backup() throws -> URL {
        guard let source = db else {
            throw LibraryDatabaseError.backupFailed("The library database is not open")
        }
        let sourceURL = URL(fileURLWithPath: path)
        let parent = sourceURL.deletingLastPathComponent()
        let stampFormatter = ISO8601DateFormatter()
        stampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = stampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let base = "\(sourceURL.lastPathComponent).backup-\(stamp)"
        var targetURL = parent.appendingPathComponent(base)
        var suffix = 1
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = parent.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }

        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(targetURL.path, &destination,
                                         SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw LibraryDatabaseError.backupFailed("Could not create \(targetURL.path)")
        }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            let message = String(cString: sqlite3_errmsg(destination))
            sqlite3_close(destination)
            try? FileManager.default.removeItem(at: targetURL)
            throw LibraryDatabaseError.backupFailed(message)
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        let closeResult = sqlite3_close(destination)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK, closeResult == SQLITE_OK else {
            try? FileManager.default.removeItem(at: targetURL)
            throw LibraryDatabaseError.backupFailed("SQLite backup failed (\(stepResult)/\(finishResult)/\(closeResult))")
        }
        return targetURL
    }

    /// Removes rows that are no longer referenced by anything. Album artists
    /// are kept even when no track credits them directly (compilations).
    private func cleanupOrphans() {
        exec("DELETE FROM playlist_items WHERE song_id NOT IN (SELECT id FROM songs);")
        exec("DELETE FROM albums WHERE id NOT IN (SELECT DISTINCT album_id FROM songs);")
        exec("""
            DELETE FROM artists WHERE id NOT IN (
                SELECT artist_id FROM songs UNION SELECT artist_id FROM albums
            );
            """)
    }

    private func ensureArtist(_ name: String) -> String {
        let fallbackID = SongIdentity.artistID(name: name).uuidString
        if let stmt = prepare("INSERT OR IGNORE INTO artists(id, name) VALUES(?, ?)") {
            bind(stmt, 1, fallbackID)
            bind(stmt, 2, name)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare("SELECT id FROM artists WHERE name = ?") {
            bind(stmt, 1, name)
            let found = sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : nil
            sqlite3_finalize(stmt)
            if let found { return found }
        }
        return fallbackID
    }

    private func ensureAlbum(title: String, artistID: String, genre: String, year: String, artwork: Data?) -> String {
        let fallbackID = SongIdentity.albumID(artistID: artistID, title: title).uuidString
        if let stmt = prepare("""
            INSERT INTO albums(id, title, artist_id, genre, year, artwork)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT DO UPDATE SET
                genre = excluded.genre,
                year = excluded.year,
                artwork = COALESCE(excluded.artwork, albums.artwork)
            """) {
            bind(stmt, 1, fallbackID)
            bind(stmt, 2, title)
            bind(stmt, 3, artistID)
            bind(stmt, 4, genre)
            bind(stmt, 5, year)
            bind(stmt, 6, artwork)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare("SELECT id FROM albums WHERE title = ? AND artist_id = ?") {
            bind(stmt, 1, title)
            bind(stmt, 2, artistID)
            let found = sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : nil
            sqlite3_finalize(stmt)
            if let found { return found }
        }
        return fallbackID
    }

    private func upsertSong(_ track: ScannedTrack,
                            ownerLibrary: MusicLibrary?,
                            artistID: String,
                            albumID: String,
                            dateAdded: TimeInterval) {
        let songID: String
        if let ownerLibrary,
           let relative = SongIdentity.relativePath(filePath: track.path,
                                                    libraryRoot: ownerLibrary.path) {
            songID = SongIdentity.songID(namespace: ownerLibrary.idNamespace,
                                         relativePath: relative).uuidString
        } else {
            songID = LibraryScanner.stableUUID(track.path).uuidString
        }
        let libraryID = ownerLibrary?.id.uuidString
        guard let stmt = prepare("""
            INSERT INTO songs(id, path, library_id, title, artist_id, album_id, genre, year, track,
                              track_total, disc, disc_total, comments,
                              duration, date_added, mtime, file_size)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                library_id = excluded.library_id,
                title = excluded.title,
                artist_id = excluded.artist_id,
                album_id = excluded.album_id,
                genre = excluded.genre,
                year = excluded.year,
                track = excluded.track,
                track_total = excluded.track_total,
                disc = excluded.disc,
                disc_total = excluded.disc_total,
                comments = excluded.comments,
                duration = excluded.duration,
                mtime = excluded.mtime,
                file_size = excluded.file_size
            """) else { return }
        bind(stmt, 1, songID)
        bind(stmt, 2, track.path)
        bind(stmt, 3, libraryID)
        bind(stmt, 4, track.title)
        bind(stmt, 5, artistID)
        bind(stmt, 6, albumID)
        bind(stmt, 7, track.genre)
        bind(stmt, 8, track.year)
        bind(stmt, 9, track.track)
        bind(stmt, 10, track.trackTotal)
        bind(stmt, 11, track.discNumber)
        bind(stmt, 12, track.discTotal)
        bind(stmt, 13, track.comments)
        bind(stmt, 14, track.duration)
        // Recently Added is anchored at first discovery. ON CONFLICT above
        // deliberately leaves date_added untouched for existing tracks.
        bind(stmt, 15, dateAdded)
        bind(stmt, 16, track.mtime)
        bind(stmt, 17, Int(track.fileSize))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: Loading

    func loadLibrary() -> (albums: [Album], playlists: [Playlist]) {
        var albumSongs: [String: [Song]] = [:]
        var albumMeta: [String: AlbumMeta] = [:]
        var songsByID: [String: Song] = [:]

        if let stmt = prepare("""
            SELECT s.id, s.title, s.path, s.genre, s.year, s.track, s.duration, s.play_count,
                   a.id, a.title, a.genre, a.year, ar.name, sar.name, s.file_size, s.loved,
                   s.date_added, s.track_total, s.disc, s.disc_total, s.comments
            FROM songs s
            JOIN albums a ON a.id = s.album_id
            JOIN artists ar ON ar.id = a.artist_id
            JOIN artists sar ON sar.id = s.artist_id
            LEFT JOIN libraries l ON l.id = s.library_id
            WHERE s.library_id IS NULL OR COALESCE(l.enabled, 1) = 1
            ORDER BY a.title COLLATE NOCASE,
                     CASE WHEN s.disc = 0 THEN 1 ELSE s.disc END,
                     s.track, s.title
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idString = text(stmt, 0) ?? UUID().uuidString
                let albumIDString = text(stmt, 8) ?? UUID().uuidString
                let albumArtist = text(stmt, 12) ?? ""
                let songArtist = text(stmt, 13) ?? albumArtist
                let albumTitle = text(stmt, 9) ?? ""

                let song = Song(id: UUID(uuidString: idString) ?? UUID(),
                                title: text(stmt, 1) ?? "",
                                artist: songArtist,
                                album: albumTitle,
                                albumArtist: albumArtist,
                                genre: text(stmt, 3) ?? "",
                                duration: double(stmt, 6),
                                trackNumber: int(stmt, 5),
                                trackTotal: int(stmt, 17),
                                discNumber: int(stmt, 18),
                                discTotal: int(stmt, 19),
                                comments: text(stmt, 20) ?? "",
                                year: text(stmt, 4) ?? "",
                                plays: int(stmt, 7),
                                dateAdded: double(stmt, 16),
                                fileURL: URL(fileURLWithPath: text(stmt, 2) ?? ""),
                                fileSize: Int64(int(stmt, 14)),
                                isStarred: int(stmt, 15) != 0)

                albumSongs[albumIDString, default: []].append(song)
                songsByID[idString] = song

                if albumMeta[albumIDString] == nil {
                    albumMeta[albumIDString] = AlbumMeta(id: albumIDString,
                                                         title: albumTitle,
                                                         artist: albumArtist,
                                                         genre: text(stmt, 10) ?? "",
                                                         year: text(stmt, 11) ?? "")
                }
            }
            sqlite3_finalize(stmt)
        }

        let albums = albumMeta.values.compactMap { meta -> Album? in
            guard let songs = albumSongs[meta.id], !songs.isEmpty else { return nil }
            return Album(id: UUID(uuidString: meta.id) ?? UUID(),
                         title: meta.title,
                         artist: meta.artist,
                         genre: meta.genre,
                         year: meta.year,
                         artwork: Artwork(colors: [], cacheKey: meta.id),
                         songs: songs)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return (albums, loadPlaylists(songsByID: songsByID))
    }

    /// Reloads only the stored playlists. MPD changes playlists frequently and
    /// should not force a full album/song reload just to refresh the sidebar.
    func loadPlaylists(songsByID: [String: Song]) -> [Playlist] {
        var entries: [(id: String, name: String, created: Double, modified: Double)] = []
        if let stmt = prepare("""
            SELECT id, name, date_created, date_modified
            FROM playlists ORDER BY name COLLATE NOCASE
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                entries.append((text(stmt, 0) ?? "",
                                text(stmt, 1) ?? "",
                                double(stmt, 2),
                                double(stmt, 3)))
            }
            sqlite3_finalize(stmt)
        }

        var playlists: [Playlist] = []
        for entry in entries {
            var songs: [Song] = []
            var addedAtBySongID: [UUID: TimeInterval] = [:]
            if let itemStmt = prepare("SELECT song_id, added_at FROM playlist_items WHERE playlist_id = ? ORDER BY position") {
                bind(itemStmt, 1, entry.id)
                var position = 0
                while sqlite3_step(itemStmt) == SQLITE_ROW {
                    defer { position += 1 }
                    guard let rawID = text(itemStmt, 0),
                          let songID = UUID(uuidString: rawID),
                          let song = songsByID[rawID] else { continue }
                    var addedAt = double(itemStmt, 1)
                    if addedAt <= 0 {
                        let base = entry.created > 0 ? entry.created : entry.modified
                        addedAt = base + Double(position)
                    }
                    songs.append(song)
                    addedAtBySongID[songID] = addedAt
                }
                sqlite3_finalize(itemStmt)
            }
            playlists.append(Playlist(id: UUID(uuidString: entry.id) ?? UUID(),
                                      name: entry.name,
                                      songs: songs,
                                      addedAtBySongID: addedAtBySongID,
                                      dateModified: entry.modified))
        }
        return playlists
    }

    // MARK: Mutations

    func resetPlayCount(songIDs: [String]) {
        guard !songIDs.isEmpty else { return }
        exec("BEGIN;")
        for id in songIDs {
            guard let stmt = prepare("UPDATE songs SET play_count = 0 WHERE id = ?") else { continue }
            bind(stmt, 1, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
    }

    func recordPlay(_ songID: UUID) {
        guard let stmt = prepare("UPDATE songs SET play_count = play_count + 1, last_played = ? WHERE id = ?") else { return }
        bind(stmt, 1, Date().timeIntervalSince1970)
        bind(stmt, 2, songID.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Persists the star flag in the existing `songs.loved` column. Starring is
    /// app metadata, so it is allowed for external-library tracks too.
    func setStarred(_ songIDs: [UUID], starred: Bool) {
        guard !songIDs.isEmpty else { return }
        exec("BEGIN;")
        for songID in songIDs {
            guard let stmt = prepare("UPDATE songs SET loved = ? WHERE id = ?") else { continue }
            bind(stmt, 1, starred ? 1 : 0)
            bind(stmt, 2, songID.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
    }

    func setStarred(_ songID: UUID, starred: Bool) {
        setStarred([songID], starred: starred)
    }

    // MARK: Playlists

    func createPlaylist(name: String) -> Playlist {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        if let stmt = prepare("INSERT INTO playlists(id, name, date_created, date_modified) VALUES(?, ?, ?, ?)") {
            bind(stmt, 1, id)
            bind(stmt, 2, name)
            bind(stmt, 3, now)
            bind(stmt, 4, now)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return Playlist(id: UUID(uuidString: id) ?? UUID(), name: name, songs: [], dateModified: now)
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let stmt = prepare("UPDATE playlists SET name = ?, date_modified = ? WHERE id = ?") else { return }
        bind(stmt, 1, name)
        bind(stmt, 2, Date().timeIntervalSince1970)
        bind(stmt, 3, id.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func deletePlaylist(_ id: UUID) {
        for sql in ["DELETE FROM playlist_items WHERE playlist_id = ?",
                    "DELETE FROM playlists WHERE id = ?"] {
            if let stmt = prepare(sql) {
                bind(stmt, 1, id.uuidString)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    func playlistSongIDs(_ id: UUID) -> [UUID] {
        var result: [UUID] = []
        if let stmt = prepare("SELECT song_id FROM playlist_items WHERE playlist_id = ? ORDER BY position") {
            bind(stmt, 1, id.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let raw = text(stmt, 0), let songID = UUID(uuidString: raw) {
                    result.append(songID)
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Replaces the whole item list, renumbering positions from zero. The
    /// playlist table uses a (playlist, song) primary key, so duplicate song
    /// IDs are deliberately collapsed. Existing items keep their add time;
    /// newly added songs receive monotonically increasing timestamps.
    func replacePlaylistSongs(_ id: UUID, songIDs: [UUID]) {
        var seen = Set<UUID>()
        let unique = songIDs.filter { seen.insert($0).inserted }

        var existingAddedAt: [UUID: TimeInterval] = [:]
        if let stmt = prepare("SELECT song_id, added_at FROM playlist_items WHERE playlist_id = ?") {
            bind(stmt, 1, id.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let rawID = text(stmt, 0), let songID = UUID(uuidString: rawID) {
                    existingAddedAt[songID] = double(stmt, 1)
                }
            }
            sqlite3_finalize(stmt)
        }

        exec("BEGIN;")
        if let stmt = prepare("DELETE FROM playlist_items WHERE playlist_id = ?") {
            bind(stmt, 1, id.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        let now = Date().timeIntervalSince1970
        let latest = existingAddedAt.values.filter { $0 > 0 }.max() ?? 0
        var nextAddedAt = max(now, latest + 0.000001)
        for (position, songID) in unique.enumerated() {
            let storedAddedAt = existingAddedAt[songID] ?? 0
            let addedAt: TimeInterval
            if storedAddedAt > 0 {
                addedAt = storedAddedAt
            } else {
                addedAt = nextAddedAt
                nextAddedAt += 0.000001
            }
            if let stmt = prepare("INSERT OR IGNORE INTO playlist_items(playlist_id, song_id, position, added_at) VALUES(?, ?, ?, ?)") {
                bind(stmt, 1, id.uuidString)
                bind(stmt, 2, songID.uuidString)
                bind(stmt, 3, position)
                bind(stmt, 4, addedAt)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        if let stmt = prepare("UPDATE playlists SET date_modified = ? WHERE id = ?") {
            bind(stmt, 1, Date().timeIntervalSince1970)
            bind(stmt, 2, id.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
    }

    func addSongsToPlaylist(_ id: UUID, songIDs: [UUID], at position: Int? = nil) {
        var ids = playlistSongIDs(id)
        var seen = Set(ids)
        let additions = songIDs.filter { seen.insert($0).inserted }
        guard !additions.isEmpty else { return }
        let insertion = min(max(position ?? ids.count, 0), ids.count)
        ids.insert(contentsOf: additions, at: insertion)
        replacePlaylistSongs(id, songIDs: ids)
    }

    func removeSongFromPlaylist(_ id: UUID, songID: UUID) {
        removeSongsFromPlaylist(id, songIDs: [songID])
    }

    func removeSongsFromPlaylist(_ id: UUID, songIDs: [UUID]) {
        guard !songIDs.isEmpty else { return }
        let ids = playlistSongIDs(id)
        let removal = Set(songIDs)
        let remaining = ids.filter { !removal.contains($0) }
        guard remaining.count != ids.count else { return }
        replacePlaylistSongs(id, songIDs: remaining)
    }

    func clearPlaylist(_ id: UUID) {
        replacePlaylistSongs(id, songIDs: [])
    }

    func movePlaylistItem(_ id: UUID, from: Int, to: Int) {
        var ids = playlistSongIDs(id)
        guard ids.indices.contains(from) else { return }
        let item = ids.remove(at: from)
        let insertion = min(max(to, 0), ids.count)
        ids.insert(item, at: insertion)
        replacePlaylistSongs(id, songIDs: ids)
    }

    // MARK: Player queue

    /// Stores queue entries as stable IDs plus song IDs. An empty queue removes
    /// the saved row; a cleared or finished queue should not reappear.
    func savePlayerQueue(_ state: PersistedPlayerQueue) {
        guard !state.entries.isEmpty else {
            exec("DELETE FROM player_queue WHERE id = 1;")
            return
        }

        let encoder = JSONEncoder()
        guard let queueData = try? encoder.encode(state.entries),
              let baseData = try? encoder.encode(state.baseEntries),
              let queueJSON = String(data: queueData, encoding: .utf8),
              let baseJSON = String(data: baseData, encoding: .utf8) else {
            AppLog.database.error("Could not encode the player queue for saving")
            return
        }
        guard let stmt = prepare("""
                  INSERT OR REPLACE INTO player_queue
                      (id, queue_entries, base_queue_entries, next_queue_id,
                       current_index, elapsed, updated_at)
                  VALUES (1, ?, ?, ?, ?, ?, ?)
                  """) else {
            AppLog.database.error("Could not prepare the player queue save: \(self.databaseErrorMessage, privacy: .public)")
            return
        }
        bind(stmt, 1, queueJSON)
        bind(stmt, 2, baseJSON)
        bind(stmt, 3, Int(state.nextQueueID))
        bind(stmt, 4, state.currentIndex ?? -1)
        bind(stmt, 5, state.elapsed)
        bind(stmt, 6, Date().timeIntervalSince1970)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if result != SQLITE_DONE {
            AppLog.database.error("Could not save the player queue (SQLite \(result, privacy: .public)): \(self.databaseErrorMessage, privacy: .public)")
        }
    }

    func loadPlayerQueue() -> PersistedPlayerQueue? {
        guard let stmt = prepare("""
            SELECT queue_entries, base_queue_entries, next_queue_id,
                   current_index, elapsed
            FROM player_queue WHERE id = 1
            """) else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return nil
        }
        let entriesJSON = text(stmt, 0) ?? ""
        let baseEntriesJSON = text(stmt, 1) ?? ""
        let nextID = int(stmt, 2)
        let index = int(stmt, 3)
        let elapsed = double(stmt, 4)
        sqlite3_finalize(stmt)

        let decoder = JSONDecoder()
        guard let entriesData = entriesJSON.data(using: .utf8),
              let entries = try? decoder.decode([PersistedQueueEntry].self,
                                                 from: entriesData) else {
            if !entriesJSON.isEmpty {
                AppLog.database.warning("Could not decode the saved player queue; starting without it")
            }
            return nil
        }
        guard !entries.isEmpty else { return nil }

        var baseEntries: [PersistedQueueEntry] = []
        if let data = baseEntriesJSON.data(using: .utf8),
           let decoded = try? decoder.decode([PersistedQueueEntry].self, from: data) {
            baseEntries = decoded
        }
        if baseEntries.isEmpty { baseEntries = entries }

        return PersistedPlayerQueue(
            entries: entries,
            baseEntries: baseEntries,
            nextQueueID: normalizedNextQueueID(nextID, entries: entries + baseEntries),
            currentIndex: index >= 0 ? index : nil,
            elapsed: max(elapsed, 0)
        )
    }

    private func normalizedNextQueueID(_ raw: Int,
                                       entries: [PersistedQueueEntry]) -> UInt32 {
        let maxID = entries.map(\.id).max() ?? 0
        let candidate: UInt32
        if raw > 0, raw <= Int(UInt32.max) {
            candidate = UInt32(raw)
        } else {
            candidate = 1
        }
        if candidate > maxID { return candidate }
        if maxID == UInt32.max { return 1 }
        return maxID + 1
    }

    /// Updates only the playback position. This avoids rewriting a potentially
    /// large queue on every periodic position checkpoint.
    func updatePlayerQueuePosition(currentIndex: Int?, elapsed: TimeInterval) {
        guard let stmt = prepare("""
            UPDATE player_queue
            SET current_index = ?, elapsed = ?, updated_at = ?
            WHERE id = 1
            """) else { return }
        bind(stmt, 1, currentIndex ?? -1)
        bind(stmt, 2, elapsed)
        bind(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard result != SQLITE_OK else {
            if let errorPointer { sqlite3_free(errorPointer) }
            return
        }
        let message = errorPointer.map { String(cString: $0) } ?? databaseErrorMessage
        if let errorPointer { sqlite3_free(errorPointer) }
        AppLog.database.error("SQLite statement failed (SQLite \(result, privacy: .public)): \(message, privacy: .public)")
    }

    private var databaseErrorMessage: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }

    private func executeThrowing(_ sql: String) throws {
        guard let db else { throw LibraryDatabaseError.transactionFailed("Database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? databaseErrorMessage
            if let errorPointer { sqlite3_free(errorPointer) }
            throw LibraryDatabaseError.transactionFailed(message)
        }
        if let errorPointer { sqlite3_free(errorPointer) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, SQLITE_TRANSIENT) }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        bind(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data?) {
        if let value {
            _ = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func int(_ stmt: OpaquePointer?, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private func double(_ stmt: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private func optionalDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private func blob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: pointer, count: count)
    }

}
