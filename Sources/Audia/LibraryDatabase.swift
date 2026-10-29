import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LibraryDatabaseError: LocalizedError {
    case destinationExists(String)
    case openFailed(String)
    case backupFailed(String)
    case transactionFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let path):
            return "A library database already exists at \(path)."
        case .openFailed(let path):
            return "Could not open the library database at \(path)."
        case .backupFailed(let message):
            return "Could not back up the library database: \(message)"
        case .transactionFailed(let message):
            return "Could not update the library database: \(message)"
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
        let year: String
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
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
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
        """)
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
    func sync(tracks: [ScannedTrack],
              internalMusicRoot: String?,
              libraries: [MusicLibrary]) -> [String: Data] {
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
            let path = canonicalPath(track.path)
            let owner = libraries
                .filter { $0.isEnabled }
                .map { (library: $0, root: canonicalPath($0.scanPath)) }
                .filter { isUnder(path, root: $0.root) }
                .max { $0.root.count < $1.root.count }
            upsertSong(track,
                       libraryID: owner?.library.id.uuidString,
                       artistID: trackArtistID,
                       albumID: albumID,
                       dateAdded: added)
        }
        exec("COMMIT;")
        return artworkByAlbumID
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
            SELECT id, path, kind, name, enabled FROM libraries
            ORDER BY CASE kind WHEN 'internal' THEN 0 ELSE 1 END, name COLLATE NOCASE
            """) else { return result }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idString = text(stmt, 0),
                  let path = text(stmt, 1),
                  let kindString = text(stmt, 2),
                  let name = text(stmt, 3) else { continue }
            let kind = MusicLibrary.Kind(rawValue: kindString) ?? .external
            let id = UUID(uuidString: idString) ?? LibraryScanner.stableUUID("library|" + path)
            result.append(MusicLibrary(id: id,
                                       path: path,
                                       name: name,
                                       kind: kind,
                                       isEnabled: int(stmt, 4) != 0))
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
        if let stmt = prepare("SELECT id, path, kind, name, enabled FROM libraries WHERE path = ?") {
            bind(stmt, 1, path)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let idString = text(stmt, 0),
               let storedPath = text(stmt, 1),
               let kindString = text(stmt, 2),
               let storedName = text(stmt, 3) {
                let storedKind = MusicLibrary.Kind(rawValue: kindString) ?? kind
                let id = UUID(uuidString: idString) ?? LibraryScanner.stableUUID("library|" + storedPath)
                let isEnabled = int(stmt, 4) != 0
                sqlite3_finalize(stmt)
                return MusicLibrary(id: id,
                                    path: storedPath,
                                    name: storedName,
                                    kind: storedKind,
                                    isEnabled: isEnabled)
            }
            sqlite3_finalize(stmt)
        }
        return MusicLibrary(id: UUID(uuidString: libraryID) ?? UUID(),
                            path: path, name: name, kind: kind, isEnabled: true)
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
            guard let check = prepare("SELECT kind, enabled FROM libraries WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not validate media library")
            }
            bind(check, 1, id.uuidString)
            let exists = sqlite3_step(check) == SQLITE_ROW
            let kind = text(check, 0)
            let enabled = int(check, 1) != 0
            sqlite3_finalize(check)
            guard exists, kind == MusicLibrary.Kind.external.rawValue, enabled else {
                throw LibraryDatabaseError.transactionFailed("Only enabled external libraries can be relocated.")
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
            guard let libraryCheck = prepare("SELECT kind, enabled FROM libraries WHERE id = ?") else {
                throw LibraryDatabaseError.transactionFailed("Could not validate external library")
            }
            bind(libraryCheck, 1, id.uuidString)
            let exists = sqlite3_step(libraryCheck) == SQLITE_ROW
            let kind = text(libraryCheck, 0)
            let isEnabled = int(libraryCheck, 1) != 0
            sqlite3_finalize(libraryCheck)
            guard exists, kind == MusicLibrary.Kind.external.rawValue, !isEnabled else {
                throw LibraryDatabaseError.transactionFailed("Only disabled external libraries can be deleted.")
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

    private func ensureAlbum(title: String, artistID: String, genre: String, year: String, artwork: Data?) -> String {
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
                            libraryID: String?,
                            artistID: String,
                            albumID: String,
                            dateAdded: TimeInterval) {
        let songID = LibraryScanner.stableUUID(track.path).uuidString
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
              let baseJSON = String(data: baseData, encoding: .utf8),
              let stmt = prepare("""
                  INSERT OR REPLACE INTO player_queue
                      (id, queue_entries, base_queue_entries, next_queue_id,
                       current_index, elapsed, updated_at)
                  VALUES (1, ?, ?, ?, ?, ?, ?)
                  """) else { return }
        bind(stmt, 1, queueJSON)
        bind(stmt, 2, baseJSON)
        bind(stmt, 3, Int(state.nextQueueID))
        bind(stmt, 4, state.currentIndex ?? -1)
        bind(stmt, 5, state.elapsed)
        bind(stmt, 6, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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
                                                 from: entriesData),
              !entries.isEmpty else {
            return nil
        }

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
        sqlite3_exec(db, sql, nil, nil, nil)
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

    private func blob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: pointer, count: count)
    }
}
