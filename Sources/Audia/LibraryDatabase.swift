import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LibraryDatabaseError: LocalizedError {
    case destinationExists(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let path):
            return "A library database already exists at \(path)."
        case .openFailed(let path):
            return "Could not open the library database at \(path)."
        }
    }
}

struct LibraryInspection {
    let path: String
    let songCount: Int
    let internalLibraryPath: String?
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
        let year: Int
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
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        createSchema()
        // The song-ID fix for the very first SQLite build is a one-time
        // migration. Later, IDs deliberately stay put when a library folder
        // (and therefore its song paths) moves to a new location.
        if userVersion() < 1 {
            migrateSongIDsIfNeeded()
            setUserVersion(1)
        }
        importLegacyPlaylistsIfNeeded()
    }

    private func userVersion() -> Int {
        guard let stmt = prepare("PRAGMA user_version") else { return 0 }
        let version = sqlite3_step(stmt) == SQLITE_ROW ? int(stmt, 0) : 0
        sqlite3_finalize(stmt)
        return version
    }

    private func setUserVersion(_ version: Int) {
        exec("PRAGMA user_version = \(version);")
    }

    private func checkpointAndClose() {
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_close(db)
        self.db = nil
    }

    /// Flushes the WAL into library.sqlite, switches back to a rollback
    /// journal and closes the connection. The resulting database file is
    /// self-contained, so copying just library.sqlite works even without its
    /// -wal/-shm siblings. Reopening switches to WAL again.
    func closeForTermination() {
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        exec("PRAGMA journal_mode=DELETE;")
        sqlite3_close(db)
        self.db = nil
        // SQLite can leave the WAL index behind after switching journal modes.
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    /// Moves the database file to a new location, reopening it afterwards.
    /// Used when the Internal Library is created: the index (and everything in
    /// it) moves into the library folder and lives there from then on.
    func relocate(to newPath: String) throws {
        guard newPath != path else { return }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: newPath) else {
            throw LibraryDatabaseError.destinationExists(newPath)
        }

        let oldPath = path
        checkpointAndClose()
        do {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: newPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.moveItem(atPath: oldPath, toPath: newPath)
            } catch {
                try fileManager.copyItem(atPath: oldPath, toPath: newPath)
                try? fileManager.removeItem(atPath: oldPath)
            }
            try? fileManager.removeItem(atPath: oldPath + "-wal")
            try? fileManager.removeItem(atPath: oldPath + "-shm")
            try? fileManager.removeItem(atPath: newPath + "-wal")
            try? fileManager.removeItem(atPath: newPath + "-shm")

            path = newPath
            open()
            guard db != nil else { throw LibraryDatabaseError.openFailed(newPath) }
        } catch {
            // Restore the original database so the running app keeps working.
            if fileManager.fileExists(atPath: newPath) && !fileManager.fileExists(atPath: oldPath) {
                try? fileManager.moveItem(atPath: newPath, toPath: oldPath)
            }
            path = oldPath
            open()
            throw error
        }
    }

    /// Switches to another database in place (used by “Open Library”).
    /// The current database is restored if the new one cannot be opened.
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

    /// Rewrites absolute song paths from an old library root to a new one.
    /// Persistent IDs are deliberately left untouched so playlists and play
    /// counts survive moving a library folder to another computer.
    func rebaseSongs(from oldRoot: String, to newRoot: String) {
        let old = canonicalPath(oldRoot)
        let new = canonicalPath(newRoot)
        guard old != new else { return }

        var updates: [(id: String, newPath: String)] = []
        guard let stmt = prepare("SELECT id, path FROM songs") else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0), let storedPath = text(stmt, 1) else { continue }
            let canonical = canonicalPath(storedPath)
            guard isUnder(canonical, root: old) else { continue }
            let relative = String(canonical.dropFirst(old.count))
            let newPath = relative.isEmpty ? new : new + relative
            if newPath != storedPath {
                updates.append((id, newPath))
            }
        }
        sqlite3_finalize(stmt)
        guard !updates.isEmpty else { return }

        var failed = false
        exec("BEGIN;")
        for update in updates {
            guard let updateStmt = prepare("UPDATE songs SET path = ? WHERE id = ?") else {
                failed = true
                break
            }
            bind(updateStmt, 1, update.newPath)
            bind(updateStmt, 2, update.id)
            if sqlite3_step(updateStmt) != SQLITE_DONE { failed = true }
            sqlite3_finalize(updateStmt)
            if failed { break }
        }
        exec(failed ? "ROLLBACK;" : "COMMIT;")
    }

    /// Read-only validation of a database that is about to be opened. This
    /// deliberately does not create or migrate anything.
    static func inspect(path: String) -> LibraryInspection? {
        var handle: OpaquePointer?
        // Read-write (but never create) is intentional: a WAL-mode database
        // copied without its -shm file cannot be inspected read-only. An
        // Internal Library has to be writable anyway.
        let openResult = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
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
        guard tables.contains("songs"),
              tables.contains("albums"),
              tables.contains("artists") else { return nil }

        var songCount = 0
        if let stmt = query("SELECT COUNT(*) FROM songs") {
            if sqlite3_step(stmt) == SQLITE_ROW {
                songCount = Int(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        var internalPath: String?
        if tables.contains("libraries"),
           let stmt = query("SELECT path FROM libraries WHERE kind = 'internal' ORDER BY rowid LIMIT 1") {
            if sqlite3_step(stmt) == SQLITE_ROW, let name = sqlite3_column_text(stmt, 0) {
                internalPath = String(cString: name)
            }
            sqlite3_finalize(stmt)
        }

        return LibraryInspection(path: path, songCount: songCount, internalLibraryPath: internalPath)
    }

    /// Earlier builds derived song IDs from `"song|" + path`. Keep the
    /// original path-derived persistent IDs (which the file-based library
    /// used) so existing playlists, play counts and references survive.
    private func migrateSongIDsIfNeeded() {
        var updates: [(old: String, new: String)] = []
        guard let stmt = prepare("SELECT id, path FROM songs") else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let old = text(stmt, 0), let path = text(stmt, 1) else { continue }
            let new = LibraryScanner.stableUUID(path).uuidString
            if old != new { updates.append((old, new)) }
        }
        sqlite3_finalize(stmt)
        guard !updates.isEmpty else { return }

        exec("BEGIN;")
        for update in updates {
            if let itemStmt = prepare("UPDATE OR IGNORE playlist_items SET song_id = ? WHERE song_id = ?") {
                bind(itemStmt, 1, update.new)
                bind(itemStmt, 2, update.old)
                sqlite3_step(itemStmt)
                sqlite3_finalize(itemStmt)
            }
            if let songStmt = prepare("UPDATE OR IGNORE songs SET id = ? WHERE id = ?") {
                bind(songStmt, 1, update.new)
                bind(songStmt, 2, update.old)
                sqlite3_step(songStmt)
                sqlite3_finalize(songStmt)
            }
        }
        exec("DELETE FROM playlist_items WHERE song_id NOT IN (SELECT id FROM songs);")
        exec("COMMIT;")
    }

    /// One-time import of the JSON playlists that older builds kept in
    /// UserDefaults. The database is authoritative from now on.
    private func importLegacyPlaylistsIfNeeded() {
        var existing = 0
        if let stmt = prepare("SELECT COUNT(*) FROM playlists") {
            if sqlite3_step(stmt) == SQLITE_ROW { existing = int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        guard existing == 0 else { return }
        guard let data = UserDefaults.standard.data(forKey: "playlists"),
              let legacy = try? JSONDecoder().decode([LegacyPlaylist].self, from: data) else {
            return
        }

        exec("BEGIN;")
        for (index, playlist) in legacy.enumerated() {
            let id = UUID(uuidString: playlist.id)?.uuidString ?? UUID().uuidString
            let name = playlist.name.isEmpty ? "Untitled Playlist" : playlist.name
            if let stmt = prepare("INSERT OR IGNORE INTO playlists(id, name, date_created) VALUES(?, ?, ?)") {
                bind(stmt, 1, id)
                bind(stmt, 2, name)
                bind(stmt, 3, Date().timeIntervalSince1970 + Double(index) / 1000)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            for (position, songID) in playlist.songIDs.enumerated() {
                guard let song = UUID(uuidString: songID)?.uuidString else { continue }
                if let stmt = prepare("INSERT OR IGNORE INTO playlist_items(playlist_id, song_id, position) VALUES(?, ?, ?)") {
                    bind(stmt, 1, id)
                    bind(stmt, 2, song)
                    bind(stmt, 3, position)
                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
        exec("COMMIT;")

        UserDefaults.standard.removeObject(forKey: "playlists")
    }

    private struct LegacyPlaylist: Decodable {
        let id: String
        let name: String
        let songIDs: [String]
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
            year INTEGER NOT NULL DEFAULT 0,
            artwork BLOB,
            UNIQUE(title, artist_id)
        );
        CREATE TABLE IF NOT EXISTS songs (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            artist_id TEXT NOT NULL,
            album_id TEXT NOT NULL,
            genre TEXT NOT NULL DEFAULT '',
            year INTEGER NOT NULL DEFAULT 0,
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
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            date_added REAL NOT NULL
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
            PRIMARY KEY (playlist_id, song_id)
        );
        CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album_id);
        CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist_id);
        CREATE INDEX IF NOT EXISTS idx_playlist_items ON playlist_items(playlist_id, position);
        """)

        // Older databases predate the star/love flag. Keep the column available
        // even when an existing table was created without it.
        if !hasColumn("songs", "loved") {
            exec("ALTER TABLE songs ADD COLUMN loved INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasColumn("songs", "track_total") {
            exec("ALTER TABLE songs ADD COLUMN track_total INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasColumn("songs", "disc") {
            exec("ALTER TABLE songs ADD COLUMN disc INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasColumn("songs", "disc_total") {
            exec("ALTER TABLE songs ADD COLUMN disc_total INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasColumn("songs", "comments") {
            exec("ALTER TABLE songs ADD COLUMN comments TEXT NOT NULL DEFAULT '';")
        }
        if !hasColumn("playlists", "date_modified") {
            exec("ALTER TABLE playlists ADD COLUMN date_modified REAL NOT NULL DEFAULT 0;")
        }
        exec("UPDATE playlists SET date_modified = date_created WHERE date_modified = 0;")
    }

    private func hasColumn(_ table: String, _ column: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if text(stmt, 1) == column { return true }
        }
        return false
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
    func sync(tracks: [ScannedTrack], internalMusicRoot: String?) -> [String: Data] {
        guard !tracks.isEmpty else { return [:] }
        let internalRoot = internalMusicRoot.map { canonicalPath($0) }
        let importedAt = Date().timeIntervalSince1970
        exec("BEGIN;")

        // Cache artist/album IDs during a batch and write each album's cover
        // only once. The old code upserted the same multi-megabyte artwork BLOB
        // for every track in an album, which made a large import extremely slow.
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
            let isInternal = internalRoot.map {
                track.path == $0 || track.path.hasPrefix($0 + "/")
            } ?? false
            let added = isInternal
                ? importedAt
                : (track.mtime > 0 ? track.mtime : importedAt)
            upsertSong(track, artistID: trackArtistID, albumID: albumID, dateAdded: added)
        }
        exec("COMMIT;")
        return artworkByAlbumID
    }

    /// Keeps songs inside one of the configured scan roots, removing entries
    /// whose library was removed and files that no longer exist.
    func prune(roots: [String]) {
        // With no configured libraries the database is kept intact; the app
        // simply hides it until a library is added again.
        guard !roots.isEmpty else { return }
        let canonicalRoots = roots.map { canonicalPath($0) }
        var doomed: [String] = []

        guard let stmt = prepare("SELECT id, path FROM songs") else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0), let path = text(stmt, 1) else { continue }
            let canonical = canonicalPath(path)
            guard let root = canonicalRoots.first(where: { isUnder(canonical, root: $0) }) else {
                // The song no longer belongs to any configured library.
                doomed.append(id)
                continue
            }
            // If the root itself is unavailable (for example an unmounted
            // drive), keep its entries instead of destroying them.
            if FileManager.default.fileExists(atPath: root),
               !FileManager.default.fileExists(atPath: path) {
                doomed.append(id)
            }
        }
        sqlite3_finalize(stmt)
        deleteSongs(doomed)
    }

    /// Prunes missing files below a single library root, leaving songs from
    /// other libraries untouched.
    func pruneSongs(under root: String) {
        let canonicalRoot = canonicalPath(root)
        guard FileManager.default.fileExists(atPath: canonicalRoot) else { return }
        var doomed: [String] = []

        guard let stmt = prepare("SELECT id, path FROM songs") else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(stmt, 0), let path = text(stmt, 1) else { continue }
            guard isUnder(canonicalPath(path), root: canonicalRoot) else { continue }
            if !FileManager.default.fileExists(atPath: path) {
                doomed.append(id)
            }
        }
        sqlite3_finalize(stmt)
        deleteSongs(doomed)
    }

    func deleteSongs(withIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        deleteSongs(ids.map(\.uuidString))
    }

    private func deleteSongs(_ ids: [String]) {
        for id in ids {
            if let stmt = prepare("DELETE FROM playlist_items WHERE song_id = ?") {
                bind(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            if let stmt = prepare("DELETE FROM songs WHERE id = ?") {
                bind(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        cleanupOrphans()
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
            SELECT id, path, kind, name FROM libraries
            ORDER BY CASE kind WHEN 'internal' THEN 0 ELSE 1 END, name COLLATE NOCASE
            """) else { return result }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idString = text(stmt, 0),
                  let path = text(stmt, 1),
                  let kindString = text(stmt, 2),
                  let name = text(stmt, 3) else { continue }
            let kind = MusicLibrary.Kind(rawValue: kindString) ?? .external
            let id = UUID(uuidString: idString) ?? LibraryScanner.stableUUID("library|" + path)
            result.append(MusicLibrary(id: id, path: path, name: name, kind: kind))
        }
        sqlite3_finalize(stmt)
        return result
    }

    @discardableResult
    func ensureLibrary(path: String, kind: MusicLibrary.Kind, name: String) -> MusicLibrary {
        let libraryID = LibraryScanner.stableUUID("library|" + path).uuidString
        if kind == .internalLibrary {
            // There can only ever be one Internal Library record.
            if let stmt = prepare("DELETE FROM libraries WHERE kind = 'internal' AND path != ?") {
                bind(stmt, 1, path)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        if let stmt = prepare("""
            INSERT INTO libraries(id, path, kind, name, date_added)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET kind = excluded.kind, name = excluded.name
            """) {
            bind(stmt, 1, libraryID)
            bind(stmt, 2, path)
            bind(stmt, 3, kind.rawValue)
            bind(stmt, 4, name)
            bind(stmt, 5, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        if let stmt = prepare("SELECT id, path, kind, name FROM libraries WHERE path = ?") {
            bind(stmt, 1, path)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let idString = text(stmt, 0),
               let storedPath = text(stmt, 1),
               let kindString = text(stmt, 2),
               let storedName = text(stmt, 3) {
                let storedKind = MusicLibrary.Kind(rawValue: kindString) ?? kind
                let id = UUID(uuidString: idString) ?? LibraryScanner.stableUUID("library|" + storedPath)
                sqlite3_finalize(stmt)
                return MusicLibrary(id: id, path: storedPath, name: storedName, kind: storedKind)
            }
            sqlite3_finalize(stmt)
        }
        return MusicLibrary(id: UUID(uuidString: libraryID) ?? UUID(),
                            path: path, name: name, kind: kind)
    }

    func removeLibrary(id: UUID) {
        guard let stmt = prepare("DELETE FROM libraries WHERE id = ?") else { return }
        bind(stmt, 1, id.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func songCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM songs") else { return 0 }
        let count = sqlite3_step(stmt) == SQLITE_ROW ? int(stmt, 0) : 0
        sqlite3_finalize(stmt)
        return count
    }

    func songPaths() -> [String] {
        var paths: [String] = []
        guard let stmt = prepare("SELECT path FROM songs") else { return paths }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let path = text(stmt, 0) { paths.append(path) }
        }
        sqlite3_finalize(stmt)
        return paths
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
        let fallbackID = LibraryScanner.stableUUID("artist|" + name.lowercased()).uuidString
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

    private func ensureAlbum(title: String, artistID: String, genre: String, year: Int, artwork: Data?) -> String {
        let fallbackID = LibraryScanner.stableUUID("album|" + artistID + "|" + title.lowercased()).uuidString
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
                            artistID: String,
                            albumID: String,
                            dateAdded: TimeInterval) {
        let songID = LibraryScanner.stableUUID(track.path).uuidString
        guard let stmt = prepare("""
            INSERT INTO songs(id, path, title, artist_id, album_id, genre, year, track,
                              track_total, disc, disc_total, comments,
                              duration, date_added, mtime, file_size)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
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
        bind(stmt, 3, track.title)
        bind(stmt, 4, artistID)
        bind(stmt, 5, albumID)
        bind(stmt, 6, track.genre)
        bind(stmt, 7, track.year)
        bind(stmt, 8, track.track)
        bind(stmt, 9, track.trackTotal)
        bind(stmt, 10, track.discNumber)
        bind(stmt, 11, track.discTotal)
        bind(stmt, 12, track.comments)
        bind(stmt, 13, track.duration)
        // Recently Added is anchored at first discovery. ON CONFLICT above
        // deliberately leaves date_added untouched for existing tracks.
        bind(stmt, 14, dateAdded)
        bind(stmt, 15, track.mtime)
        bind(stmt, 16, Int(track.fileSize))
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
            ORDER BY a.title COLLATE NOCASE, s.track, s.title
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idString = text(stmt, 0) ?? UUID().uuidString
                let albumIDString = text(stmt, 8) ?? UUID().uuidString
                let albumArtist = text(stmt, 12) ?? "Unknown Artist"
                let songArtist = text(stmt, 13) ?? albumArtist
                let albumTitle = text(stmt, 9) ?? "Unknown Album"

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
                                year: int(stmt, 4),
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
                                                         year: int(stmt, 11))
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
        var entries: [(id: String, name: String, modified: Double)] = []
        if let stmt = prepare("""
            SELECT id, name, COALESCE(NULLIF(date_modified, 0), date_created)
            FROM playlists ORDER BY name COLLATE NOCASE
            """) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                entries.append((text(stmt, 0) ?? "",
                                text(stmt, 1) ?? "",
                                double(stmt, 2)))
            }
            sqlite3_finalize(stmt)
        }

        var playlists: [Playlist] = []
        for entry in entries {
            var songs: [Song] = []
            if let itemStmt = prepare("SELECT song_id FROM playlist_items WHERE playlist_id = ? ORDER BY position") {
                bind(itemStmt, 1, entry.id)
                while sqlite3_step(itemStmt) == SQLITE_ROW {
                    if let songID = text(itemStmt, 0), let song = songsByID[songID] {
                        songs.append(song)
                    }
                }
                sqlite3_finalize(itemStmt)
            }
            playlists.append(Playlist(id: UUID(uuidString: entry.id) ?? UUID(),
                                      name: entry.name,
                                      songs: songs,
                                      dateModified: entry.modified))
        }
        return playlists
    }

    // MARK: Mutations

    func updateSong(_ song: Song) {
        // Editing the track artist does not move the song into a different
        // album; the album is keyed by album artist + album title.
        var currentAlbumID: String?
        var currentAlbumTitle: String?
        var currentAlbumArtist: String?
        var currentAlbumArtwork: Data?
        if let stmt = prepare("""
            SELECT s.album_id, a.title, ar.name, a.artwork FROM songs s
            JOIN albums a ON a.id = s.album_id
            JOIN artists ar ON ar.id = a.artist_id
            WHERE s.id = ?
            """) {
            bind(stmt, 1, song.id.uuidString)
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentAlbumID = text(stmt, 0)
                currentAlbumTitle = text(stmt, 1)
                currentAlbumArtist = text(stmt, 2)
                currentAlbumArtwork = blob(stmt, 3)
            }
            sqlite3_finalize(stmt)
        }

        let trackArtistID = ensureArtist(song.artist)
        let albumArtistID = ensureArtist(song.albumArtist)
        let albumID: String
        if let currentAlbumID,
           currentAlbumTitle == song.album,
           currentAlbumArtist == song.albumArtist {
            albumID = currentAlbumID
        } else {
            albumID = ensureAlbum(title: song.album, artistID: albumArtistID,
                                  genre: song.genre, year: song.year,
                                  artwork: currentAlbumArtwork)
        }

        guard let stmt = prepare("""
            UPDATE songs SET title = ?, artist_id = ?, album_id = ?, genre = ?, year = ?,
                             track = ?, track_total = ?, disc = ?, disc_total = ?, comments = ?
            WHERE id = ?
            """) else { return }
        bind(stmt, 1, song.title)
        bind(stmt, 2, trackArtistID)
        bind(stmt, 3, albumID)
        bind(stmt, 4, song.genre)
        bind(stmt, 5, song.year)
        bind(stmt, 6, song.trackNumber)
        bind(stmt, 7, song.trackTotal)
        bind(stmt, 8, song.discNumber)
        bind(stmt, 9, song.discTotal)
        bind(stmt, 10, song.comments)
        bind(stmt, 11, song.id.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        cleanupOrphans()
    }

    /// Applies per-track edits made from an album's Get Info sheet. The album
    /// row itself is updated separately; this keeps every song on the same
    /// album ID while updating its editable metadata columns.
    func updateSongMetadata(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        exec("BEGIN;")
        for song in songs {
            let artistID = ensureArtist(song.artist)
            guard let stmt = prepare("""
                UPDATE songs SET title = ?, artist_id = ?, genre = ?, year = ?,
                                 track = ?, track_total = ?, disc = ?, disc_total = ?, comments = ?
                WHERE id = ?
                """) else { continue }
            bind(stmt, 1, song.title)
            bind(stmt, 2, artistID)
            bind(stmt, 3, song.genre)
            bind(stmt, 4, song.year)
            bind(stmt, 5, song.trackNumber)
            bind(stmt, 6, song.trackTotal)
            bind(stmt, 7, song.discNumber)
            bind(stmt, 8, song.discTotal)
            bind(stmt, 9, song.comments)
            bind(stmt, 10, song.id.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
        cleanupOrphans()
    }

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

    func updateAlbum(_ album: Album) {
        let artistID = ensureArtist(album.artist)
        if let stmt = prepare("UPDATE albums SET title = ?, artist_id = ?, genre = ?, year = ?, artwork = NULL WHERE id = ?") {
            bind(stmt, 1, album.title)
            bind(stmt, 2, artistID)
            bind(stmt, 3, album.genre)
            bind(stmt, 4, album.year)
            bind(stmt, 5, album.id.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        cleanupOrphans()
    }

    func updateSongPath(songID: UUID, path: String, mtime: Double, size: Int64) {
        guard let stmt = prepare("UPDATE songs SET path = ?, mtime = ?, file_size = ? WHERE id = ?") else { return }
        bind(stmt, 1, path)
        bind(stmt, 2, mtime)
        bind(stmt, 3, Int(size))
        bind(stmt, 4, songID.uuidString)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func updateFileStats(path: String, mtime: Double, size: Int64) {
        guard let stmt = prepare("UPDATE songs SET mtime = ?, file_size = ? WHERE path = ?") else { return }
        bind(stmt, 1, mtime)
        bind(stmt, 2, Int(size))
        bind(stmt, 3, path)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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
    /// IDs are deliberately collapsed.
    func replacePlaylistSongs(_ id: UUID, songIDs: [UUID]) {
        var seen = Set<UUID>()
        let unique = songIDs.filter { seen.insert($0).inserted }
        exec("BEGIN;")
        if let stmt = prepare("DELETE FROM playlist_items WHERE playlist_id = ?") {
            bind(stmt, 1, id.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        for (position, songID) in unique.enumerated() {
            if let stmt = prepare("INSERT OR IGNORE INTO playlist_items(playlist_id, song_id, position) VALUES(?, ?, ?)") {
                bind(stmt, 1, id.uuidString)
                bind(stmt, 2, songID.uuidString)
                bind(stmt, 3, position)
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

    // MARK: SQLite helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
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

    private func blob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: pointer, count: count)
    }
}
