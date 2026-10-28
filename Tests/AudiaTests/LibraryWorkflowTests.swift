import XCTest
import SQLite3
@testable import Audia

final class LibraryWorkflowTests: XCTestCase {
    func testBlankTrackNumberHasNoDisplayLabel() {
        let unnumbered = Song(title: "Untitled", artist: "Artist", album: "Album",
                              genre: "", duration: 0, trackNumber: 0, plays: 0)
        let numbered = Song(title: "Numbered", artist: "Artist", album: "Album",
                            genre: "", duration: 0, trackNumber: 7, plays: 0)

        XCTAssertEqual(unnumbered.trackNumberLabel, "")
        XCTAssertEqual(numbered.trackNumberLabel, "7")
    }

    func testShortcutBindingPersistsActionScopeAndShortcut() throws {
        let binding = ShortcutBinding(
            action: .nextTrack,
            shortcut: KeyboardShortcut(key: "n", modifiers: [], display: "N", keyCode: 45),
            scope: .systemWide
        )
        let emptyRow = ShortcutBinding(action: nil, shortcut: nil, scope: .inApp)
        let bindings = [binding, emptyRow]
        let data = try JSONEncoder().encode(bindings)
        let restored = try JSONDecoder().decode([ShortcutBinding].self, from: data)

        XCTAssertEqual(restored, bindings)
    }

    func testSameActionCanHaveIndependentBindingsInBothScopes() throws {
        let inApp = ShortcutBinding(
            action: .mute,
            shortcut: KeyboardShortcut(key: "m", modifiers: [], display: "M", keyCode: 46),
            scope: .inApp
        )
        let systemWide = ShortcutBinding(
            action: .mute,
            shortcut: KeyboardShortcut(key: "keyCode:80", modifiers: [], display: "F19", keyCode: 80),
            scope: .systemWide
        )
        let data = try JSONEncoder().encode([inApp, systemWide])
        let restored = try JSONDecoder().decode([ShortcutBinding].self, from: data)

        XCTAssertEqual(restored, [inApp, systemWide])
    }

    @MainActor
    func testPlayerQueuePersistsEntryIDsAndDuplicates() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let database = LibraryDatabase(path: fixture.appendingPathComponent("library.sqlite").path)
        defer { database.closeForTermination() }

        let first = UUID()
        let second = UUID()
        let entries = [
            PersistedQueueEntry(id: 7, songID: first),
            PersistedQueueEntry(id: 2, songID: second),
            PersistedQueueEntry(id: 9, songID: first),
        ]
        let baseEntries = [
            PersistedQueueEntry(id: 2, songID: second),
            PersistedQueueEntry(id: 7, songID: first),
            PersistedQueueEntry(id: 9, songID: first),
        ]
        database.savePlayerQueue(PersistedPlayerQueue(entries: entries,
                                                       baseEntries: baseEntries,
                                                       nextQueueID: 10,
                                                       currentIndex: 2,
                                                       elapsed: 42))

        let loaded = try XCTUnwrap(database.loadPlayerQueue())
        XCTAssertEqual(loaded.entries, entries)
        XCTAssertEqual(loaded.baseEntries, baseEntries)
        XCTAssertEqual(loaded.nextQueueID, 10)
        XCTAssertEqual(loaded.currentIndex, 2)
        XCTAssertEqual(loaded.elapsed, 42, accuracy: 0.001)
    }

    @MainActor
    func testLegacyPlayerQueueSeedsStableEntryIDs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let path = fixture.appendingPathComponent("library.sqlite").path
        LibraryDatabase(path: path).closeForTermination()

        let first = UUID()
        let second = UUID()
        let queueJSON = "[\"\(first.uuidString)\",\"\(second.uuidString)\"]"
        let baseJSON = "[\"\(second.uuidString)\",\"\(first.uuidString)\"]"
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        let sql = """
        INSERT OR REPLACE INTO player_queue
            (id, queue_ids, base_queue_ids, current_index, elapsed, updated_at)
        VALUES (1, '\(queueJSON)', '\(baseJSON)', 0, 12, 0);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)

        let database = LibraryDatabase(path: path)
        defer { database.closeForTermination() }
        let loaded = try XCTUnwrap(database.loadPlayerQueue())
        XCTAssertEqual(loaded.entries,
                       [PersistedQueueEntry(id: 1, songID: first),
                        PersistedQueueEntry(id: 2, songID: second)])
        XCTAssertEqual(loaded.baseEntries,
                       [PersistedQueueEntry(id: 2, songID: second),
                        PersistedQueueEntry(id: 1, songID: first)])
        XCTAssertEqual(loaded.nextQueueID, 3)
        XCTAssertEqual(loaded.currentIndex, 0)
        XCTAssertEqual(loaded.elapsed, 12, accuracy: 0.001)
    }

    func testShortcutConflictUsesPhysicalKeyAndModifiers() {
        let plainN = KeyboardShortcut(key: "n", modifiers: [], display: "N", keyCode: 45)
        let alternateLayoutN = KeyboardShortcut(key: "ñ", modifiers: [], display: "Ñ", keyCode: 45)
        let commandN = KeyboardShortcut(key: "n", modifiers: [.command], display: "⌘N", keyCode: 45)

        XCTAssertTrue(plainN.conflicts(with: alternateLayoutN))
        XCTAssertFalse(plainN.conflicts(with: commandN))
    }

    @MainActor
    func testDisablePreservesStoredPlaylistAndReenableRestoresTrack() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let mediaRoot = fixture.appendingPathComponent("media", isDirectory: true)
        let otherRoot = fixture.appendingPathComponent("other-media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let audioURL = mediaRoot.appendingPathComponent("song.wav")
        let otherAudioURL = otherRoot.appendingPathComponent("other-song.wav")
        try makeWaveFile().write(to: audioURL)
        try makeWaveFile().write(to: otherAudioURL)

        let database = LibraryDatabase(path: fixture.appendingPathComponent("library.sqlite").path)
        defer { database.closeForTermination() }

        let library = database.ensureLibrary(path: mediaRoot.path,
                                             kind: .external,
                                             name: "Test Media")
        let otherLibrary = database.ensureLibrary(path: otherRoot.path,
                                                  kind: .external,
                                                  name: "Other Media")
        let track = makeTrack(path: audioURL.path, title: "Test Song")
        let otherTrack = makeTrack(path: otherAudioURL.path, title: "Other Song", album: "Other Album")
        _ = database.sync(tracks: [track, otherTrack],
                          internalMusicRoot: nil,
                          libraries: [library, otherLibrary])
        let song = try XCTUnwrap(database.loadLibrary().albums
            .flatMap(\.songs).first { $0.title == "Test Song" })
        let otherSong = try XCTUnwrap(database.loadLibrary().albums
            .flatMap(\.songs).first { $0.title == "Other Song" })
        XCTAssertEqual(database.missingSongIDs(libraryID: library.id, discoveredPaths: []), [song.id])
        let playlist = database.createPlaylist(name: "Fixture Playlist")
        database.addSongsToPlaylist(playlist.id, songIDs: [song.id, otherSong.id])
        database.recordPlay(song.id)
        database.setStarred(song.id, starred: true)

        try database.setLibraryEnabled(library.id, enabled: false)
        let hidden = database.loadLibrary()
        XCTAssertEqual(hidden.albums.flatMap(\.songs).map(\.id), [otherSong.id])
        XCTAssertEqual(hidden.playlists.count, 1)
        XCTAssertEqual(hidden.playlists[0].songs.map(\.id), [otherSong.id])
        XCTAssertEqual(database.playlistSongIDs(playlist.id), [song.id, otherSong.id])

        try database.setLibraryEnabled(library.id, enabled: true)
        let restored = try XCTUnwrap(database.loadLibrary().albums
            .flatMap(\.songs).first { $0.id == song.id })
        XCTAssertEqual(restored.id, song.id)
        XCTAssertEqual(restored.plays, 1)
        XCTAssertTrue(restored.isStarred)
        XCTAssertEqual(database.loadLibrary().playlists.first?.songs.map(\.id), [song.id, otherSong.id])
    }

    @MainActor
    func testBackupRelocationAndLibraryDeletePreservePlaylistShell() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let oldRoot = fixture.appendingPathComponent("old", isDirectory: true)
        let newRoot = fixture.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let oldAudio = oldRoot.appendingPathComponent("Album/song.wav")
        let newAudio = newRoot.appendingPathComponent("Album/song.wav")
        try FileManager.default.createDirectory(at: oldAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeWaveFile().write(to: oldAudio)
        try makeWaveFile().write(to: newAudio)
        let oldMissingAudio = oldRoot.appendingPathComponent("Album/missing.wav")
        let newMissingAudio = newRoot.appendingPathComponent("Album/missing.wav")
        let oldDeletedAudio = oldRoot.appendingPathComponent("Album/deleted.wav")
        let newDeletedAudio = newRoot.appendingPathComponent("Album/deleted.wav")

        let database = LibraryDatabase(path: fixture.appendingPathComponent("library.sqlite").path)
        defer { database.closeForTermination() }
        let library = database.ensureLibrary(path: oldRoot.path,
                                             kind: .external,
                                             name: "Move Me")
        let track = makeTrack(path: oldAudio.path, title: "Move Me")
        let missingTrack = makeTrack(path: oldMissingAudio.path, title: "Keep Missing")
        let deletedTrack = makeTrack(path: oldDeletedAudio.path, title: "Delete Missing")
        _ = database.sync(tracks: [track, missingTrack, deletedTrack],
                          internalMusicRoot: nil,
                          libraries: [library])
        let allSongs = database.loadLibrary().albums.flatMap(\.songs)
        let song = try XCTUnwrap(allSongs.first { $0.title == "Move Me" })
        let missingSong = try XCTUnwrap(allSongs.first { $0.title == "Keep Missing" })
        let deletedSong = try XCTUnwrap(allSongs.first { $0.title == "Delete Missing" })
        let playlist = database.createPlaylist(name: "Keep Empty Playlist")
        database.addSongsToPlaylist(playlist.id, songIDs: [song.id, missingSong.id, deletedSong.id])
        database.recordPlay(song.id)

        let backup = try database.backup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(backup.lastPathComponent.contains(".backup-"))
        XCTAssertEqual(LibraryDatabase.inspect(path: backup.path)?.songCount, 3)

        try database.relocateLibrary(id: library.id,
                                     to: newRoot.path,
                                     songPaths: [song.id: newAudio.path,
                                                 missingSong.id: newMissingAudio.path,
                                                 deletedSong.id: newDeletedAudio.path],
                                     removingSongIDs: [deletedSong.id])
        let relocatedSongs = database.loadLibrary().albums.flatMap(\.songs)
        let relocated = try XCTUnwrap(relocatedSongs.first { $0.id == song.id })
        XCTAssertEqual(relocated.id, song.id)
        XCTAssertEqual(relocated.fileURL?.path, newAudio.path)
        XCTAssertEqual(relocated.plays, 1)
        let relocatedMissing = try XCTUnwrap(relocatedSongs.first { $0.id == missingSong.id })
        XCTAssertEqual(relocatedMissing.fileURL?.path, newMissingAudio.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocatedMissing.fileURL!.path))
        XCTAssertNil(relocatedSongs.first { $0.id == deletedSong.id })
        XCTAssertEqual(database.playlistSongIDs(playlist.id), [song.id, missingSong.id])
        XCTAssertEqual(database.loadLibraries().first?.path, newRoot.path)

        XCTAssertThrowsError(try database.deleteLibraryAndSongs(id: library.id),
                             "An enabled external library must not be deleted")
        try database.setLibraryEnabled(library.id, enabled: false)
        try database.deleteLibraryAndSongs(id: library.id)
        let deleted = database.loadLibrary()
        XCTAssertTrue(deleted.albums.isEmpty)
        XCTAssertEqual(deleted.playlists.count, 1)
        XCTAssertTrue(deleted.playlists[0].songs.isEmpty)
        XCTAssertEqual(database.playlistSongIDs(playlist.id), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newAudio.path),
                      "Deleting an external library index must never delete its audio files")
    }

    func testRelocationMatchesFullRelativePathRatherThanBasename() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let oldRoot = fixture.appendingPathComponent("old", isDirectory: true).path
        let newRoot = fixture.appendingPathComponent("new", isDirectory: true).path
        let firstID = UUID()
        let secondID = UUID()
        let songs = [
            LibrarySongPath(id: firstID, path: "\(oldRoot)/albumA/1-helloworld.mp3"),
            LibrarySongPath(id: secondID, path: "\(oldRoot)/albumB/1-helloworld.mp3"),
        ]
        let found = Set([
            "\(newRoot)/albumA/1-helloworld.mp3",
            "\(newRoot)/albumB/1-helloworld.mp3",
        ])

        let result = LibraryRelocationMatcher.match(oldRoot: oldRoot,
                                                    newRoot: newRoot,
                                                    songs: songs,
                                                    discoveredPaths: found)
        XCTAssertEqual(result.songPaths.count, 2)
        XCTAssertEqual(result.songPaths[firstID], "\(newRoot)/albumA/1-helloworld.mp3")
        XCTAssertEqual(result.songPaths[secondID], "\(newRoot)/albumB/1-helloworld.mp3")
        XCTAssertTrue(result.unmatchedIDs.isEmpty)

        let changedFolder = Set(["\(newRoot)/collection/albumB/1-helloworld.mp3"])
        let partial = LibraryRelocationMatcher.match(oldRoot: oldRoot,
                                                      newRoot: newRoot,
                                                      songs: [songs[1]],
                                                      discoveredPaths: changedFolder)
        XCTAssertEqual(partial.songPaths[secondID], "\(newRoot)/albumB/1-helloworld.mp3")
        XCTAssertTrue(partial.matchedIDs.isEmpty)
        XCTAssertEqual(partial.unmatchedIDs, [secondID])
    }

    func testMissingFileStreakPausesAtOneHundredAndResetsOnSuccess() {
        var streak = MissingFileStreak()
        for _ in 0..<99 {
            XCTAssertFalse(streak.recordMissing())
        }
        XCTAssertTrue(streak.recordMissing())
        streak.reset()
        XCTAssertFalse(streak.recordMissing())
        XCTAssertEqual(streak.count, 1)
    }

    func testExternalVolumeRenameAndRelativeFolderMove() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let oldRoot = fixture.appendingPathComponent("MusicLocal/Media.localized", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldRoot.appendingPathComponent("albumA", isDirectory: true),
            withIntermediateDirectories: true
        )
        let originalTrack = oldRoot.appendingPathComponent("albumA/1-helloworld.wav")
        try makeWaveFile().write(to: originalTrack)

        let renamedRoot = fixture.appendingPathComponent("RenamedMedia.localized", isDirectory: true)
        try FileManager.default.moveItem(at: oldRoot, to: renamedRoot)
        let sameLayoutPaths = Set([renamedRoot.appendingPathComponent("albumA/1-helloworld.wav").path])
        let songID = UUID()
        let afterRootRename = LibraryRelocationMatcher.match(
            oldRoot: oldRoot.path,
            newRoot: renamedRoot.path,
            songs: [LibrarySongPath(id: songID, path: originalTrack.path)],
            discoveredPaths: sameLayoutPaths
        )
        XCTAssertEqual(afterRootRename.songPaths[songID], sameLayoutPaths.first)

        let oldAlbum = renamedRoot.appendingPathComponent("albumA", isDirectory: true)
        let newAlbum = renamedRoot.appendingPathComponent("collection/albumA", isDirectory: true)
        try FileManager.default.createDirectory(at: newAlbum.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldAlbum, to: newAlbum)
        let movedTrack = newAlbum.appendingPathComponent("1-helloworld.wav")
        let afterRelativePathChange = LibraryRelocationMatcher.match(
            oldRoot: oldRoot.path,
            newRoot: renamedRoot.path,
            songs: [LibrarySongPath(id: songID, path: originalTrack.path)],
            discoveredPaths: Set([movedTrack.path])
        )
        XCTAssertEqual(afterRelativePathChange.songPaths[songID],
                       "\(renamedRoot.path)/albumA/1-helloworld.wav")
        XCTAssertEqual(afterRelativePathChange.unmatchedIDs, [songID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedTrack.path))
    }

    func testQuickScanAddsOnlyNewFilesAndFullScanReparsesChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("song.wav")
        try makeWaveFile().write(to: audio)

        let initial = await LibraryScanner.scan(folders: [root.path], mode: .quick)
        XCTAssertTrue(initial.isComplete, initial.errors.joined(separator: "\n"))
        XCTAssertEqual(initial.tracks.count, 1)
        let original = try XCTUnwrap(initial.discoveredFiles[audio.resolvingSymlinksInPath().path])

        var changedWave = makeWaveFile()
        changedWave[changedWave.count - 1] = 1
        try changedWave.write(to: audio)
        let changedDate = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: changedDate],
                                              ofItemAtPath: audio.path)
        let known = [audio.resolvingSymlinksInPath().path: original]

        let quick = await LibraryScanner.scan(folders: [root.path], known: known, mode: .quick)
        XCTAssertTrue(quick.isComplete, quick.errors.joined(separator: "\n"))
        XCTAssertTrue(quick.tracks.isEmpty, "Quick Scan must ignore existing paths, even when changed")

        let full = await LibraryScanner.scan(folders: [root.path], known: known, mode: .full)
        XCTAssertTrue(full.isComplete, full.errors.joined(separator: "\n"))
        XCTAssertEqual(full.tracks.count, 1)

        try FileManager.default.removeItem(at: audio)
        let empty = await LibraryScanner.scan(folders: [root.path], known: known, mode: .full)
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.discoveredFiles.isEmpty,
                      "A readable, completely scanned empty root reports old paths as missing")

        let unavailable = await LibraryScanner.scan(
            folders: [fixture.appendingPathComponent("not-mounted").path],
            known: known,
            mode: .full
        )
        XCTAssertFalse(unavailable.isComplete)
    }

    func testScannerReportsFindingAndMetadataPhasesInOrder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeWaveFile().write(to: root.appendingPathComponent("one.wav"))
        let recorder = ScanProgressRecorder()

        let result = await LibraryScanner.scan(folders: [root.path], mode: .quick) {
            phase, completed, total in
            await recorder.record(phase: phase, completed: completed, total: total)
        }

        XCTAssertTrue(result.isComplete)
        let events = await recorder.events
        XCTAssertEqual(events.map(\.phase), [
            .findingFiles,
            .readingMetadata,
            .readingMetadata,
        ])
        XCTAssertEqual(events[1].completed, 0)
        XCTAssertEqual(events[1].total, 1)
        XCTAssertEqual(events[2].completed, 1)
        XCTAssertEqual(events[2].total, 1)
    }

    func testFullScanDetectsSizeChangeEvenWhenModificationTimeMatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("size-change.wav")
        try makeWaveFile(seconds: 1).write(to: audio)
        // Use a whole-second timestamp so the filesystem round-trip after
        // rewriting the file cannot change sub-second precision.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: audio.path
        )
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        let originalDate = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        let originalSize = try XCTUnwrap(originalAttributes[.size] as? NSNumber).int64Value
        let known = [audio.resolvingSymlinksInPath().path: KnownFile(
            mtime: originalDate.timeIntervalSince1970,
            size: originalSize
        )]

        try makeWaveFile(seconds: 2).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: originalDate],
                                              ofItemAtPath: audio.path)
        let updatedAttributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        let updatedDate = try XCTUnwrap(updatedAttributes[.modificationDate] as? Date)
        let updatedSize = try XCTUnwrap(updatedAttributes[.size] as? NSNumber).int64Value
        XCTAssertEqual(updatedDate, originalDate)
        XCTAssertNotEqual(updatedSize, originalSize)

        let full = await LibraryScanner.scan(folders: [root.path], known: known, mode: .full)
        XCTAssertTrue(full.isComplete, full.errors.joined(separator: "\n"))
        XCTAssertEqual(full.tracks.count, 1)
    }

    @MainActor
    func testLegacySchemaAddsEnabledAndLibraryOwnershipColumns() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let databaseURL = fixture.appendingPathComponent("legacy.sqlite")
        let mediaRoot = fixture.appendingPathComponent("legacy-media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let songPath = mediaRoot.appendingPathComponent("old-song.wav").path
        let libraryID = LibraryScanner.stableUUID("library|\(mediaRoot.path)").uuidString
        let artistID = UUID().uuidString
        let albumID = UUID().uuidString
        let songID = UUID().uuidString
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let legacySchema = """
        CREATE TABLE artists (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE);
        CREATE TABLE albums (id TEXT PRIMARY KEY, title TEXT NOT NULL, artist_id TEXT NOT NULL,
            genre TEXT NOT NULL DEFAULT '', year TEXT NOT NULL DEFAULT '', artwork BLOB,
            UNIQUE(title, artist_id));
        CREATE TABLE songs (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
            artist_id TEXT NOT NULL, album_id TEXT NOT NULL, genre TEXT NOT NULL DEFAULT '',
            year TEXT NOT NULL DEFAULT '', track INTEGER NOT NULL DEFAULT 0,
            track_total INTEGER NOT NULL DEFAULT 0, disc INTEGER NOT NULL DEFAULT 0,
            disc_total INTEGER NOT NULL DEFAULT 0, comments TEXT NOT NULL DEFAULT '',
            duration REAL NOT NULL DEFAULT 0, date_added REAL NOT NULL,
            play_count INTEGER NOT NULL DEFAULT 0, rating INTEGER NOT NULL DEFAULT 0,
            loved INTEGER NOT NULL DEFAULT 0, last_played REAL,
            skip_count INTEGER NOT NULL DEFAULT 0, mtime REAL NOT NULL DEFAULT 0,
            file_size INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE libraries (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL, name TEXT NOT NULL, date_added REAL NOT NULL);
        CREATE TABLE playlists (id TEXT PRIMARY KEY, name TEXT NOT NULL,
            date_created REAL NOT NULL, date_modified REAL NOT NULL DEFAULT 0);
        CREATE TABLE playlist_items (playlist_id TEXT NOT NULL, song_id TEXT NOT NULL,
            position INTEGER NOT NULL, PRIMARY KEY (playlist_id, song_id));
        INSERT INTO libraries(id, path, kind, name, date_added)
            VALUES ('\(libraryID)', '\(mediaRoot.path)', 'external', 'Legacy Media', 1);
        INSERT INTO artists(id, name) VALUES ('\(artistID)', 'Legacy Artist');
        INSERT INTO albums(id, title, artist_id) VALUES ('\(albumID)', 'Legacy Album', '\(artistID)');
        INSERT INTO songs(id, path, title, artist_id, album_id, date_added)
            VALUES ('\(songID)', '\(songPath)', 'Legacy Song', '\(artistID)', '\(albumID)', 1);
        """
        XCTAssertEqual(sqlite3_exec(handle, legacySchema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)

        let database = LibraryDatabase(path: databaseURL.path)
        defer { database.closeForTermination() }
        var migratedHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &migratedHandle), SQLITE_OK)

        func hasColumn(_ table: String, _ column: String) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(migratedHandle,
                                     "PRAGMA table_info(\(table))", -1,
                                     &statement, nil) == SQLITE_OK,
                  let statement else { return false }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == column {
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(hasColumn("libraries", "enabled"))
        XCTAssertTrue(hasColumn("songs", "library_id"))
        XCTAssertEqual(sqlite3_close(migratedHandle), SQLITE_OK)

        let legacyLibrary = try XCTUnwrap(database.loadLibraries().first)
        XCTAssertTrue(legacyLibrary.isEnabled)
        database.assignUnownedSongs(to: database.loadLibraries())
        XCTAssertEqual(database.loadLibrary().albums.first?.songs.first?.id.uuidString, songID)
        try database.setLibraryEnabled(legacyLibrary.id, enabled: false)
        XCTAssertTrue(database.loadLibrary().albums.isEmpty)
        try database.setLibraryEnabled(legacyLibrary.id, enabled: true)
        XCTAssertEqual(database.loadLibrary().albums.first?.songs.first?.id.uuidString, songID)
    }

    private func makeFixture() throws -> URL {
        let basePath = ProcessInfo.processInfo.environment["TRACKS_TEST_ROOT"]
            ?? FileManager.default.temporaryDirectory.path
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fixture = base.appendingPathComponent("tracks-workflow-\(UUID().uuidString)",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        return fixture
    }

    private func makeTrack(path: String, title: String, album: String = "Test Album") -> ScannedTrack {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ScannedTrack(path: path,
                            title: title,
                            artist: "Test Artist",
                            albumArtist: "Test Artist",
                            album: album,
                            genre: "Test",
                            year: "2026",
                            track: 1,
                            trackTotal: 1,
                            discNumber: 1,
                            discTotal: 1,
                            comments: "",
                            duration: 1,
                            artwork: nil,
                            mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                            fileSize: Int64(values?.fileSize ?? 0))
    }

    private func makeWaveFile(seconds: UInt32 = 1) -> Data {
        let sampleRate: UInt32 = 8_000
        let dataSize: UInt32 = sampleRate * 2 * seconds
        var data = Data("RIFF".utf8)
        data.appendLE(36 + dataSize)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(sampleRate)
        data.appendLE(sampleRate * 2)
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLE(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private actor ScanProgressRecorder {
    struct Event: Sendable {
        let phase: ScanPhase
        let completed: Int
        let total: Int
    }

    private(set) var events: [Event] = []

    func record(phase: ScanPhase, completed: Int, total: Int) {
        events.append(Event(phase: phase, completed: completed, total: total))
    }
}
