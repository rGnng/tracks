import SwiftUI

enum LibraryError: LocalizedError {
    case notDirectory(String)
    case notReadable(String)
    case overlapsLibrary(String)
    case alreadyAdded(String)
    case invalidDatabase(String)
    case leftoverDatabaseFiles(String)
    case cannotCreateDatabaseFolder(String)
    case identifierInUse(String)
    case invalidIdentifier

    var errorDescription: String? {
        switch self {
        case .notDirectory(let path):
            return "“\(path)” is not a folder."
        case .notReadable(let path):
            return "“\(path)” cannot be read."
        case .overlapsLibrary(let name):
            return "That folder overlaps the library “\(name)”."
        case .alreadyAdded(let name):
            return "“\(name)” is already in your libraries."
        case .invalidDatabase(let path):
            return "Database schema error: \(path) does not contain a valid Tracks schema. Choose another folder."
        case .leftoverDatabaseFiles(let path):
            return "\(path) contains SQLite sidecar files without a library.sqlite. Choose another folder or remove the leftover files first."
        case .cannotCreateDatabaseFolder(let message):
            return "Could not create the database folder: \(message)."
        case .identifierInUse(let identifier):
            return "The library identifier “\(identifier)” is already in use."
        case .invalidIdentifier:
            return "A library identifier must be non-empty and contain no control characters."
        }
    }
}

struct LibraryMissingReport: Identifiable {
    let id = UUID()
    let libraryID: UUID
    let libraryName: String
    let rootPath: String
    let songs: [Song]
    let relocation: LibraryRelocationPlan?
}

struct LibraryRelocationPlan {
    let libraryID: UUID
    let newRoot: String
    let matchedSongPaths: [UUID: String]
    let discoveredPaths: Set<String>
    let scannedTracks: [ScannedTrack]
    let matchedCount: Int
    let additionalFileCount: Int
}

enum ScanPhase: String, Equatable, Sendable {
    case findingFiles = "Finding files"
    case readingMetadata = "Reading metadata"
    case updatingLibrary = "Updating library"
}

/// Immutable indexes over the loaded album graph. Rebuilt once whenever
/// `Library.albums` changes so hot paths (song lookup, now-playing artwork,
/// and Settings counts) do not repeatedly flatten every album.
struct LibraryCatalog {
    let allSongs: [Song]
    private let albumsByID: [UUID: Album]
    private let albumsBySongID: [UUID: Album]
    private let songsByID: [UUID: Song]

    init(albums: [Album]) {
        let songCount = albums.reduce(0) { $0 + $1.songs.count }
        var all: [Song] = []
        all.reserveCapacity(songCount)
        var albumsByID: [UUID: Album] = [:]
        albumsByID.reserveCapacity(albums.count)
        var albumsBySongID: [UUID: Album] = [:]
        albumsBySongID.reserveCapacity(songCount)
        var songsByID: [UUID: Song] = [:]
        songsByID.reserveCapacity(songCount)

        for album in albums {
            albumsByID[album.id] = album
            for song in album.songs {
                all.append(song)
                songsByID[song.id] = song
                albumsBySongID[song.id] = album
            }
        }

        self.allSongs = all
        self.albumsByID = albumsByID
        self.albumsBySongID = albumsBySongID
        self.songsByID = songsByID
    }

    func album(withID id: UUID) -> Album? {
        albumsByID[id]
    }

    func song(withID id: UUID) -> (song: Song, album: Album)? {
        guard let song = songsByID[id], let album = albumsBySongID[id] else { return nil }
        return (song, album)
    }

    func artwork(forSongID id: UUID) -> Artwork {
        albumsBySongID[id]?.artwork ?? Artwork(colors: [])
    }
}

/// SQLite-backed music library modeled on iTunes.
///
/// Tracks owns one database folder. Any number of read-only music libraries
/// can be registered; audio files, tags, artwork, and folder structure inside
/// those libraries are never modified.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    /// Pseudo playlist ID used for the built-in "Stared" sidebar row and as the
    /// drop target when dragging tracks onto it.
    static let starredPlaylistID = UUID(uuidString: "D8F1A2C4-6B0E-4C2A-9A8E-5F3D7E2B1C90")!
    static let starredPlaylistName = "Stared"
    private static let starredModifiedKey = "library.starredPlaylistModifiedAt"

    @Published private(set) var albums: [Album] {
        didSet { catalog = LibraryCatalog(albums: albums) }
    }
    @Published var playlists: [Playlist]
    /// Fast lookup for star buttons; mirrors `Song.isStarred` and survives
    /// without re-reading every album on each row render.
    @Published private(set) var starredSongIDs: Set<UUID>
    /// Timestamp exposed to MPD as the built-in playlist's Last-Modified.
    private(set) var starredPlaylistModified: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "library.starredPlaylistModifiedAt")
        return saved > 0 ? saved : Date().timeIntervalSince1970
    }()
    @Published private(set) var libraries: [MusicLibrary]
    @Published private(set) var databaseFolderPath: String
    @Published private(set) var needsDatabaseSetup: Bool
    @Published private(set) var isScanning = false
    @Published private(set) var scanCompleted = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var scanPhase: ScanPhase = .findingFiles
    @Published private(set) var scanError: String?

    var scanActivityProgress: Double? {
        guard scanPhase == .readingMetadata, scanTotal > 0 else { return nil }
        return scanProgress
    }

    var scanActivityDetail: String? {
        guard scanPhase == .readingMetadata, scanTotal > 0 else { return nil }
        return "\(scanCompleted)/\(scanTotal)"
    }

    private let db: LibraryDatabase
    private var catalog = LibraryCatalog(albums: [])
    private var scanTask: Task<Void, Never>?

    private static let databaseFolderKey = "databaseFolderPath"
    private static let databaseSetupPendingKey = "databaseSetupPending"
    private static let legacyInternalPathKey = "internalLibraryPath"

    init() {
        albums = []
        playlists = []
        starredSongIDs = []
        libraries = []
        let resolution = Self.resolveDatabaseLocation()
        databaseFolderPath = resolution.folder.path
        needsDatabaseSetup = resolution.isNewInstall
        db = LibraryDatabase(path: resolution.folder.appendingPathComponent("library.sqlite").path)
        bootstrapLibraries()
        reload()
        rescanAll()
    }

    // MARK: Database location

    private struct DatabaseLocationResolution {
        let folder: URL
        let isNewInstall: Bool
    }

    static var defaultDatabaseFolderPath: String {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Tracks", isDirectory: true).path
    }

    private static func resolveDatabaseLocation() -> DatabaseLocationResolution {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: databaseFolderKey),
           let folder = normalizedFolder(raw) {
            defaults.removeObject(forKey: databaseSetupPendingKey)
            return DatabaseLocationResolution(folder: folder, isNewInstall: false)
        }
        if let raw = defaults.string(forKey: legacyInternalPathKey),
           let folder = normalizedFolder(raw) {
            defaults.set(folder.path, forKey: databaseFolderKey)
            defaults.removeObject(forKey: legacyInternalPathKey)
            defaults.removeObject(forKey: databaseSetupPendingKey)
            return DatabaseLocationResolution(folder: folder, isNewInstall: false)
        }
        let setupPending = defaults.bool(forKey: databaseSetupPendingKey)
        let folder = URL(fileURLWithPath: defaultDatabaseFolderPath, isDirectory: true)
        if !setupPending,
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.sqlite").path) {
            defaults.set(folder.path, forKey: databaseFolderKey)
            defaults.removeObject(forKey: databaseSetupPendingKey)
            return DatabaseLocationResolution(folder: folder, isNewInstall: false)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tracks", isDirectory: true)
        if !setupPending,
           FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("library.sqlite").path) {
            defaults.set(appSupport.path, forKey: databaseFolderKey)
            defaults.removeObject(forKey: databaseSetupPendingKey)
            return DatabaseLocationResolution(folder: appSupport, isNewInstall: false)
        }
        defaults.set(true, forKey: databaseSetupPendingKey)
        return DatabaseLocationResolution(folder: folder, isNewInstall: true)
    }

    private static func normalizedFolder(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// Only the three SQLite files managed by Tracks are checked. Overlapping
    /// the database folder with a music library is allowed.
    static func validateDatabaseFolder(_ rawPath: String) throws -> URL {
        guard let folder = normalizedFolder(rawPath) else {
            throw LibraryError.cannotCreateDatabaseFolder("The path is empty.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LibraryError.notDirectory(folder.path)
        }
        let database = folder.appendingPathComponent("library.sqlite")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let shm = URL(fileURLWithPath: database.path + "-shm")
        if FileManager.default.fileExists(atPath: database.path) {
            guard LibraryDatabase.inspect(path: database.path) != nil else {
                throw LibraryError.invalidDatabase(database.path)
            }
        } else if FileManager.default.fileExists(atPath: wal.path)
                    || FileManager.default.fileExists(atPath: shm.path) {
            throw LibraryError.leftoverDatabaseFiles(folder.path)
        }
        return folder
    }

    func completeDatabaseSetup(folder rawPath: String) throws {
        let folder = try Self.validateDatabaseFolder(rawPath)
        let newPath = folder.appendingPathComponent("library.sqlite").path
        let oldPath = db.path
        let removeEmptyDefault = needsDatabaseSetup && libraries.isEmpty && allSongs.isEmpty
        if oldPath != newPath {
            try db.switchTo(path: newPath)
            PlayerState.shared.stopAndClear()
            PlayerState.shared.clearHistory()
        }
        UserDefaults.standard.set(folder.path, forKey: Self.databaseFolderKey)
        UserDefaults.standard.removeObject(forKey: Self.databaseSetupPendingKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyInternalPathKey)
        databaseFolderPath = folder.path
        needsDatabaseSetup = false
        if removeEmptyDefault, oldPath != newPath {
            try? FileManager.default.removeItem(atPath: oldPath)
            try? FileManager.default.removeItem(atPath: oldPath + "-wal")
            try? FileManager.default.removeItem(atPath: oldPath + "-shm")
        }
        bootstrapLibraries()
        reload()
        rescanAll()
    }

    // MARK: Library registry

    private func bootstrapLibraries() {
        libraries = db.loadLibraries()
    }

    func suggestedLibraryIdentifier() -> String {
        db.nextLibraryIdentifier()
    }

    // MARK: Derived collections

    var allSongs: [Song] { catalog.allSongs }

    /// Backing store for the built-in "Stared" playlist.
    var starredSongs: [Song] { allSongs.filter(\.isStarred) }

    /// The built-in playlist is virtual: its contents come from the star flags.
    var starredPlaylist: Playlist {
        Playlist(id: Self.starredPlaylistID,
                 name: Self.starredPlaylistName,
                 songs: starredSongs,
                 dateModified: starredPlaylistModified)
    }

    func isStarred(songID: UUID) -> Bool { starredSongIDs.contains(songID) }

    var artists: [ArtistSummary] {
        var groups: [String: [Album]] = [:]
        for album in albums { groups[album.artist, default: []].append(album) }
        return groups
            .map { ArtistSummary(name: $0.key, albums: $0.value.sorted { $0.yearNumber > $1.yearNumber }) }
            .sorted { $0.name < $1.name }
    }

    var genres: [GenreItem] {
        var counts: [String: Int] = [:]
        for album in albums { counts[album.genre, default: 0] += 1 }
        return counts.sorted { lhs, rhs in
            // Empty genre is a placeholder, not the alphabetically first genre.
            if lhs.key.isEmpty != rhs.key.isEmpty { return !lhs.key.isEmpty }
            return lhs.key < rhs.key
        }.map { GenreItem(name: $0.key, count: $0.value) }
    }

    func album(withID id: UUID) -> Album? {
        catalog.album(withID: id)
    }

    func song(withID id: UUID) -> (song: Song, album: Album)? {
        catalog.song(withID: id)
    }

    /// Resolve artwork through the song's actual album. Matching by album
    /// title alone picks the first same-named album, which is wrong for
    /// compilations and repeated edition titles.
    func artwork(forSongID id: UUID) -> Artwork {
        catalog.artwork(forSongID: id)
    }

    // MARK: Library locations

    private var scanRoots: [String] {
        libraries.filter(\.isEnabled).map(\.path)
    }

    private var hasLibraries: Bool {
        libraries.contains(where: \.isEnabled)
    }

    @discardableResult
    func addLibraries(_ additions: [LibraryAddition]) -> [String] {
        scanTask?.cancel()
        isScanning = false
        var errors: [String] = []
        var pending = libraries
        var added = false

        for addition in additions {
            let path = canonicalPath(NSString(string: addition.path).expandingTildeInPath)
            do {
                try validateLibrary(path, existing: pending)
                let identifier = try normalizedIdentifier(addition.identifier,
                                                          existing: pending)
                let library = try db.ensureLibrary(path: path,
                                                   name: displayName(for: path),
                                                   identifier: identifier)
                pending.append(library)
                added = true
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if added {
            libraries = db.loadLibraries()
            rescanAll()
        }
        return errors
    }

    private func validateLibrary(_ path: String, existing: [MusicLibrary]) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LibraryError.notDirectory(path)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw LibraryError.notReadable(path)
        }
        if let library = existing.first(where: { canonicalPath($0.path) == path }) {
            throw LibraryError.alreadyAdded(library.name)
        }
        if let library = existing.first(where: { overlaps(path, $0.path) }) {
            throw LibraryError.overlapsLibrary(library.name)
        }
    }

    private func normalizedIdentifier(_ raw: String?, existing: [MusicLibrary]) throws -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return db.nextLibraryIdentifier()
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalidIdentifier
        }
        if existing.contains(where: { $0.identifier.caseInsensitiveCompare(value) == .orderedSame }) {
            throw LibraryError.identifierInUse(value)
        }
        return value
    }

    func setLibrary(_ id: UUID, enabled: Bool) throws {
        guard let library = libraries.first(where: { $0.id == id }),
              library.isEnabled != enabled else { return }
        scanTask?.cancel()
        isScanning = false
        try db.setLibraryEnabled(id, enabled: enabled)
        libraries = db.loadLibraries()
        if !enabled {
            PlayerState.shared.stopAndClear()
            PlayerState.shared.clearHistory()
        }
        reload()
        if enabled, let updated = libraries.first(where: { $0.id == id }) {
            rescan(updated)
        }
    }

    @discardableResult
    func deleteDisabledLibrary(_ id: UUID) throws -> URL {
        guard let library = libraries.first(where: { $0.id == id }),
              !library.isEnabled else {
            throw LibraryDatabaseError.transactionFailed("Disable the library before deleting it.")
        }
        scanTask?.cancel()
        isScanning = false
        let backupURL = try db.backup()
        try db.deleteLibraryAndSongs(id: id)
        libraries = db.loadLibraries()
        reload()
        return backupURL
    }

    func renameLibraryIdentifier(_ id: UUID, to rawIdentifier: String) throws {
        let value = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LibraryError.invalidIdentifier }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalidIdentifier
        }
        try db.setLibraryIdentifier(id, identifier: value)
        libraries = db.loadLibraries()
    }

    /// Called on app termination so the SQLite WAL is checkpointed and the
    /// main database file can be copied safely to another Mac.
    func closeDatabaseForTermination() {
        scanTask?.cancel()
        AppLog.library.debug("Closing library database for termination")
        db.closeForTermination()
    }

    // MARK: Scanning

    /// Safely discovers new files in every enabled library. It never deletes
    /// database rows; metadata changes and missing files are handled by Full Scan.
    func rescanAll(force: Bool = false) {
        scanTask?.cancel()
        let libraries = enabledLibraries
        guard !libraries.isEmpty else {
            albums = []
            playlists = []
            starredSongIDs = []
            isScanning = false
            scanCompleted = 0
            scanTotal = 0
            scanProgress = 0
            return
        }

        let roots = libraries.map(\.scanPath)
        let known = force ? [:] : db.knownFiles()
        AppLog.library.notice("Library rescan started (\(libraries.count, privacy: .public) libraries, \(force ? "full" : "quick", privacy: .public))")
        isScanning = true
        scanError = nil
        scanPhase = .findingFiles
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
        let progress = makeProgressHandler()

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await LibraryScanner.scan(folders: roots,
                                          known: known,
                                          mode: force ? .full : .quick,
                                          progress: progress)
            }.value

            guard let self, !Task.isCancelled else { return }
            guard result.isComplete else {
                AppLog.library.error("Library rescan failed: \(result.errors.joined(separator: "; "), privacy: .public)")
                self.scanError = result.errors.joined(separator: "\n")
                self.isScanning = false
                return
            }
            self.beginLibraryUpdate()
            let artwork = self.db.sync(tracks: result.tracks, libraries: libraries)
            await ArtworkCache.shared.importArtwork(artwork)
            PlayerState.shared.clearMissingFiles(foundPaths: Set(result.discoveredFiles.keys))
            self.reload()
            self.scanProgress = 1
            self.isScanning = false
            AppLog.library.notice("Library rescan finished: \(result.tracks.count, privacy: .public) tracks")
        }
    }

    /// Quick-scans one enabled library. Modified files and missing files require
    /// an explicit Full Scan.
    func rescan(_ location: MusicLibrary) {
        let stillConfigured = libraries.contains { $0.id == location.id && $0.isEnabled }
        guard stillConfigured, location.isEnabled else { return }

        scanTask?.cancel()
        let root = location.scanPath
        let known = db.knownFiles()
        AppLog.library.notice("Library rescan started (single library)")
        isScanning = true
        scanError = nil
        scanPhase = .findingFiles
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
        let progress = makeProgressHandler()

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await LibraryScanner.scan(folders: [root],
                                          known: known,
                                          mode: .quick,
                                          progress: progress)
            }.value

            guard let self, !Task.isCancelled else { return }
            guard result.isComplete else {
                AppLog.library.error("Library rescan failed: \(result.errors.joined(separator: "; "), privacy: .public)")
                self.scanError = result.errors.joined(separator: "\n")
                self.isScanning = false
                return
            }
            self.beginLibraryUpdate()
            let artwork = self.db.sync(tracks: result.tracks, libraries: self.enabledLibraries)
            await ArtworkCache.shared.importArtwork(artwork)
            PlayerState.shared.clearMissingFiles(foundPaths: Set(result.discoveredFiles.keys))
            self.reload()
            self.scanProgress = 1
            self.isScanning = false
            AppLog.library.notice("Library rescan finished: \(result.tracks.count, privacy: .public) tracks")
        }
    }

    /// Full-scans one enabled library, updates changed metadata, and reports
    /// missing tracks without deleting them.
    func fullScan(_ location: MusicLibrary) async -> LibraryMissingReport? {
        guard enabledLibraries.contains(where: { $0.id == location.id }) else { return nil }
        scanTask?.cancel()
        let known = db.knownFiles()
        isScanning = true
        scanError = nil
        scanPhase = .findingFiles
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
        let progress = makeProgressHandler()
        let result = await Task.detached(priority: .userInitiated) {
            await LibraryScanner.scan(folders: [location.scanPath],
                                      known: known,
                                      mode: .full,
                                      progress: progress)
        }.value
        guard !Task.isCancelled else {
            isScanning = false
            return nil
        }
        guard result.isComplete else {
            scanError = result.errors.joined(separator: "\n")
            isScanning = false
            return nil
        }

        beginLibraryUpdate()
        let artwork = db.sync(tracks: result.tracks, libraries: enabledLibraries)
        await ArtworkCache.shared.importArtwork(artwork)
        let discovered = Set(result.discoveredFiles.keys)
        let missingIDs = db.missingSongIDs(libraryID: location.id, discoveredPaths: discovered)
        PlayerState.shared.clearMissingFiles(foundPaths: discovered)
        PlayerState.shared.markFilesMissing(missingIDs)
        reload()
        scanProgress = 1
        isScanning = false

        let missingSet = Set(missingIDs)
        let missingSongs = allSongs.filter { missingSet.contains($0.id) }
        return LibraryMissingReport(libraryID: location.id,
                                    libraryName: location.name,
                                    rootPath: location.scanPath,
                                    songs: missingSongs,
                                    relocation: nil)
    }

    func previewRelocation(of location: MusicLibrary, to rawRoot: String) async -> LibraryMissingReport? {
        guard enabledLibraries.contains(where: { $0.id == location.id }) else { return nil }
        scanError = nil
        let newRoot = canonicalPath(NSString(string: rawRoot).expandingTildeInPath)
        do {
            try validateLibrary(newRoot, existing: libraries.filter { $0.id != location.id })
        } catch {
            scanError = error.localizedDescription
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newRoot, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: newRoot) else {
            scanError = "The selected media directory does not exist or cannot be read."
            return nil
        }

        scanTask?.cancel()
        let known = db.knownFiles()
        isScanning = true
        scanError = nil
        scanPhase = .findingFiles
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
        let result = await Task.detached(priority: .userInitiated) {
            await LibraryScanner.scan(folders: [newRoot],
                                      known: known,
                                      mode: .full,
                                      progress: self.makeProgressHandler())
        }.value
        guard !Task.isCancelled else {
            isScanning = false
            return nil
        }
        guard result.isComplete else {
            scanError = result.errors.joined(separator: "\n")
            isScanning = false
            return nil
        }

        // Relocation preview only compares paths; it does not update the
        // library until the user confirms the plan.
        let paths = db.songPaths(forLibrary: location.id)
        let foundPaths = Set(result.discoveredFiles.keys.map(canonicalPath))
        let matching = LibraryRelocationMatcher.match(
            oldRoot: location.scanPath,
            newRoot: newRoot,
            songs: paths.map { LibrarySongPath(id: $0.id, path: $0.path) },
            discoveredPaths: foundPaths
        )
        let matches = matching.songPaths
        let missingIDs = matching.unmatchedIDs
        let songByID = Dictionary(uniqueKeysWithValues: allSongs.map { ($0.id, $0) })
        let missingSongs = missingIDs.compactMap { songByID[$0] }
        let matchedPaths = Set(matching.matchedIDs.compactMap { matches[$0] })
        let additionalCount = max(0, foundPaths.subtracting(matchedPaths).count)
        let plan = LibraryRelocationPlan(libraryID: location.id,
                                         newRoot: newRoot,
                                         matchedSongPaths: matches,
                                         discoveredPaths: foundPaths,
                                         scannedTracks: result.tracks,
                                         matchedCount: matching.matchedIDs.count,
                                         additionalFileCount: additionalCount)
        isScanning = false
        scanProgress = 1
        return LibraryMissingReport(libraryID: location.id,
                                    libraryName: location.name,
                                    rootPath: newRoot,
                                    songs: missingSongs,
                                    relocation: plan)
    }

    func applyRelocation(_ report: LibraryMissingReport, removingMissingIDs: Set<UUID>) async throws -> URL {
        guard let plan = report.relocation,
              libraries.contains(where: { $0.id == plan.libraryID }) else {
            throw LibraryDatabaseError.transactionFailed("The relocation preview is no longer valid.")
        }
        isScanning = true
        beginLibraryUpdate()
        defer { isScanning = false }
        let backupURL = try db.backup()
        let validMissingIDs = Set(report.songs.map(\.id)).intersection(removingMissingIDs)
        try db.relocateLibrary(id: plan.libraryID,
                               to: plan.newRoot,
                               songPaths: plan.matchedSongPaths,
                               removingSongIDs: validMissingIDs)
        libraries = db.loadLibraries()
        let artwork = db.sync(tracks: plan.scannedTracks, libraries: enabledLibraries)
        await ArtworkCache.shared.importArtwork(artwork)
        PlayerState.shared.removeSongs(withIDs: validMissingIDs)
        reload()
        PlayerState.shared.clearMissingFiles(foundPaths: plan.discoveredPaths)
        let remainingMissing = report.songs.map(\.id).filter { !validMissingIDs.contains($0) }
        PlayerState.shared.markFilesMissing(remainingMissing)
        return backupURL
    }

    func removeMissingSongs(libraryID: UUID, songIDs: Set<UUID>) throws {
        guard !songIDs.isEmpty else { return }
        let validIDs = Set(db.songPaths(forLibrary: libraryID).map(\.id)).intersection(songIDs)
        guard !validIDs.isEmpty else { return }
        try db.removeSongsFromLibrary(validIDs, libraryID: libraryID)
        PlayerState.shared.removeSongs(withIDs: validIDs)
        PlayerState.shared.clearMissingFileIDs(validIDs)
        reload()
    }

    private var enabledLibraries: [MusicLibrary] {
        libraries.filter(\.isEnabled)
    }

    private func makeProgressHandler() -> @Sendable (ScanPhase, Int, Int) async -> Void {
        { [weak self] phase, completed, total in
            await MainActor.run {
                guard let self else { return }
                self.scanPhase = phase
                self.scanCompleted = completed
                self.scanTotal = total
                self.scanProgress = phase == .readingMetadata && total > 0
                    ? Double(completed) / Double(total)
                    : 0
            }
        }
    }

    private func beginLibraryUpdate() {
        scanPhase = .updatingLibrary
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
    }

    private func reload() {
        guard hasLibraries else {
            albums = []
            playlists = []
            starredSongIDs = []
            return
        }
        let loaded = db.loadLibrary()
        albums = loaded.albums
        playlists = loaded.playlists
        starredSongIDs = Set(allSongs.lazy.filter(\.isStarred).map(\.id))
        ArtworkCache.shared.setDatabasePath(db.path)
        PlayerState.shared.applyUpdatedSongs(allSongs)
    }

    /// Refreshes stored playlists without rebuilding albums or reloading every
    /// song row. Used by playlist edits and the MPD server.
    func reloadPlaylists() {
        guard hasLibraries else {
            playlists = []
            return
        }
        var songsByID: [String: Song] = [:]
        songsByID.reserveCapacity(allSongs.count)
        for song in allSongs {
            songsByID[song.id.uuidString] = song
        }
        playlists = db.loadPlaylists(songsByID: songsByID)
    }

    // MARK: Playback bookkeeping

    func recordPlay(_ songID: UUID) {
        db.recordPlay(songID)

        if let albumIndex = albums.firstIndex(where: { album in
               album.songs.contains { $0.id == songID }
           }),
           let songIndex = albums[albumIndex].songs.firstIndex(where: { $0.id == songID }) {
            let album = albums[albumIndex]
            var songs = album.songs
            songs[songIndex] = songs[songIndex].incrementingPlays()
            albums[albumIndex] = Album(id: album.id,
                                       title: album.title,
                                       artist: album.artist,
                                       genre: album.genre,
                                       year: album.year,
                                       artwork: album.artwork,
                                       songs: songs)
        }

        for (index, playlist) in playlists.enumerated() {
            guard let songIndex = playlist.songs.firstIndex(where: { $0.id == songID }) else { continue }
            var songs = playlist.songs
            songs[songIndex] = songs[songIndex].incrementingPlays()
            playlists[index] = Playlist(id: playlist.id,
                                        name: playlist.name,
                                        songs: songs,
                                        addedAtBySongID: playlist.addedAtBySongID,
                                        dateModified: playlist.dateModified)
        }
    }

    // MARK: Stars

    func toggleStar(_ songID: UUID) {
        setStarred([songID], starred: !isStarred(songID: songID))
    }

    /// Updates the `loved` column and every in-memory copy (albums, playlists
    /// and the player queue) in one pass. Starred tracks are app metadata, so
    /// this works for external libraries too.
    func setStarred(_ songIDs: [UUID], starred: Bool) {
        guard !songIDs.isEmpty else { return }
        let targets = songIDs.filter { id in
            guard let song = song(withID: id)?.song else { return false }
            return song.isStarred != starred
        }
        guard !targets.isEmpty else { return }

        db.setStarred(targets, starred: starred)
        starredPlaylistModified = Date().timeIntervalSince1970
        UserDefaults.standard.set(starredPlaylistModified, forKey: Self.starredModifiedKey)
        let targetSet = Set(targets)

        for index in albums.indices {
            var songs = albums[index].songs
            var changed = false
            for songIndex in songs.indices where targetSet.contains(songs[songIndex].id) {
                songs[songIndex] = songs[songIndex].settingStarred(starred)
                changed = true
            }
            if changed {
                let album = albums[index]
                albums[index] = Album(id: album.id,
                                      title: album.title,
                                      artist: album.artist,
                                      genre: album.genre,
                                      year: album.year,
                                      artwork: album.artwork,
                                      songs: songs)
            }
        }

        for index in playlists.indices {
            var songs = playlists[index].songs
            var changed = false
            for songIndex in songs.indices where targetSet.contains(songs[songIndex].id) {
                songs[songIndex] = songs[songIndex].settingStarred(starred)
                changed = true
            }
            if changed {
                playlists[index] = Playlist(id: playlists[index].id,
                                            name: playlists[index].name,
                                            songs: songs,
                                            addedAtBySongID: playlists[index].addedAtBySongID,
                                            dateModified: playlists[index].dateModified)
            }
        }

        if starred {
            starredSongIDs.formUnion(targets)
        } else {
            starredSongIDs.subtract(targets)
        }
        PlayerState.shared.applyUpdatedSongs(allSongs)
    }

    func resetPlayCount(songIDs: [UUID]) {
        guard !songIDs.isEmpty else { return }
        db.resetPlayCount(songIDs: songIDs.map(\.uuidString))
        reload()
        PlayerState.shared.applyUpdatedSongs(allSongs)
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylistWithUniqueName(base: String = "New Playlist") -> Playlist {
        let existing = Set(playlists.map { $0.name.lowercased() })
        var name = base
        var index = 2
        while existing.contains(name.lowercased()) {
            name = "\(base) \(index)"
            index += 1
        }
        return createPlaylist(name: name)
    }

    @discardableResult
    func createPlaylist(name: String) -> Playlist {
        let created = db.createPlaylist(name: name)
        reloadPlaylists()
        return playlists.first { $0.id == created.id } ?? created
    }

    /// MPD playlist names are case-sensitive; Tracks itself is more forgiving.
    /// Prefer an exact match, then fall back to a case-insensitive one. The
    /// virtual Stared playlist wins over any stored playlist with that name.
    func playlist(named name: String) -> Playlist? {
        if name.caseInsensitiveCompare(Self.starredPlaylistName) == .orderedSame {
            return starredPlaylist
        }
        if let exact = playlists.first(where: { $0.name == name }) {
            return exact
        }
        return playlists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func createOrReplacePlaylist(named name: String, songs newSongs: [Song]) -> Playlist {
        if name.caseInsensitiveCompare(Self.starredPlaylistName) == .orderedSame {
            return starredPlaylist
        }
        let target: Playlist
        if let existing = playlist(named: name) {
            target = existing
        } else {
            target = db.createPlaylist(name: name)
        }
        db.replacePlaylistSongs(target.id, songIDs: newSongs.map(\.id))
        reloadPlaylists()
        return playlists.first { $0.id == target.id } ?? target
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard id != Self.starredPlaylistID else { return }
        db.renamePlaylist(id, to: name)
        reloadPlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        guard id != Self.starredPlaylistID else { return }
        db.deletePlaylist(id)
        reloadPlaylists()
    }

    func addToPlaylist(_ playlistID: UUID, songs newSongs: [Song]) {
        guard playlistID != Self.starredPlaylistID else { return }
        guard !newSongs.isEmpty else { return }
        db.addSongsToPlaylist(playlistID, songIDs: newSongs.map(\.id))
        reloadPlaylists()
    }

    func insertIntoPlaylist(_ playlistID: UUID, songs newSongs: [Song], at position: Int) {
        guard playlistID != Self.starredPlaylistID else { return }
        guard !newSongs.isEmpty else { return }
        db.addSongsToPlaylist(playlistID, songIDs: newSongs.map(\.id), at: position)
        reloadPlaylists()
    }

    func removeFromPlaylist(_ playlistID: UUID, songID: UUID) {
        removeFromPlaylist(playlistID, songIDs: [songID])
    }

    func removeFromPlaylist(_ playlistID: UUID, songIDs: [UUID]) {
        guard playlistID != Self.starredPlaylistID else { return }
        guard !songIDs.isEmpty else { return }
        db.removeSongsFromPlaylist(playlistID, songIDs: songIDs)
        reloadPlaylists()
    }

    func removeFromPlaylist(_ playlistID: UUID, at positions: IndexSet) {
        guard !positions.isEmpty,
              let playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        let ids = positions.compactMap { playlist.songs.indices.contains($0) ? playlist.songs[$0].id : nil }
        removeFromPlaylist(playlistID, songIDs: ids)
    }

    func clearPlaylist(_ playlistID: UUID) {
        guard playlistID != Self.starredPlaylistID else { return }
        db.clearPlaylist(playlistID)
        reloadPlaylists()
    }

    func moveInPlaylist(_ playlistID: UUID, from: Int, to: Int) {
        guard playlistID != Self.starredPlaylistID else { return }
        db.movePlaylistItem(playlistID, from: from, to: to)
        reloadPlaylists()
    }

    func playlistSongs(_ id: UUID) -> [Song] {
        playlists.first { $0.id == id }?.songs ?? []
    }

    func playlistItemInfo(_ id: UUID) -> [UUID: PlaylistItemInfo] {
        playlists.first { $0.id == id }?.itemInfo ?? [:]
    }

    func savePlayerQueue(_ state: PersistedPlayerQueue) {
        db.savePlayerQueue(state)
    }

    func loadPlayerQueue() -> PersistedPlayerQueue? {
        db.loadPlayerQueue()
    }

    func updatePlayerQueuePosition(currentIndex: Int?, elapsed: TimeInterval) {
        db.updatePlayerQueuePosition(currentIndex: currentIndex, elapsed: elapsed)
    }

    // MARK: Path helpers

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func isUnder(_ path: String, root: String) -> Bool {
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    private func overlaps(_ a: String, _ b: String) -> Bool {
        let first = canonicalPath(a)
        let second = canonicalPath(b)
        return first == second || isUnder(first, root: second) || isUnder(second, root: first)
    }

    private func displayName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Music Library" : name
    }
}

extension Notification.Name {
    static let libraryDidChange = Notification.Name("audia.libraryDidChange")
}

private extension Song {
    func incrementingPlays() -> Song {
        Song(id: id,
             title: title,
             artist: artist,
             album: album,
             albumArtist: albumArtist,
             genre: genre,
             duration: duration,
             trackNumber: trackNumber,
             trackTotal: trackTotal,
             discNumber: discNumber,
             discTotal: discTotal,
             comments: comments,
             year: year,
             plays: plays + 1,
             dateAdded: dateAdded,
             fileURL: fileURL,
             fileSize: fileSize,
             isStarred: isStarred)
    }

    func settingStarred(_ value: Bool) -> Song {
        Song(id: id,
             title: title,
             artist: artist,
             album: album,
             albumArtist: albumArtist,
             genre: genre,
             duration: duration,
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
             isStarred: value)
    }
}
