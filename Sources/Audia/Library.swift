import SwiftUI

enum LibraryError: LocalizedError {
    case internalAlreadyExists
    case notDirectory(String)
    case overlapsInternal(String)
    case overlapsExternal(String)
    case alreadyAdded(String)
    case destinationHasLibrary(String)
    case cannotCreate(String)
    case notLibraryFolder(String)
    case libraryNotFound(String)
    case invalidLibrary(String)
    case readOnlyLibrary(String)

    var errorDescription: String? {
        switch self {
        case .internalAlreadyExists:
            return "An Internal Library is already set up."
        case .notDirectory(let path):
            return "“\(path)” is not a folder."
        case .overlapsInternal(let name):
            return "That folder overlaps the Internal Library “\(name)”. Choose a separate folder."
        case .overlapsExternal(let name):
            return "That folder overlaps the external library “\(name)”."
        case .alreadyAdded(let name):
            return "“\(name)” is already in your libraries."
        case .destinationHasLibrary(let path):
            return "That folder already contains a Tracks library database (\(path)). Choose another folder."
        case .cannotCreate(let message):
            return "Could not create the library folder: \(message). If macOS blocked access, click Choose… and pick the folder in the system dialog."
        case .notLibraryFolder(let path):
            return "“\(path)” is not a Tracks library. Choose the library folder, or its library.sqlite file."
        case .libraryNotFound(let path):
            return "No library.sqlite was found in \(path)."
        case .invalidLibrary(let path):
            return "\(path) is not a valid Tracks library database."
        case .readOnlyLibrary(let path):
            return "The library folder \(path) is read-only. An Internal Library must be writable."
        }
    }
}

struct LibraryDeletionResult {
    let deleted: Int
    let failures: [String]
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

enum ScanPhase {
    case scan
    case parsing
}

/// SQLite-backed music library modeled on iTunes.
///
/// There is at most one **Internal Library**: a writable folder holding both
/// the database and a `Music` subfolder. Any number of **External Libraries**
/// can be added; they are indexed read-only because another application owns
/// those files.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    /// Pseudo playlist ID used for the built-in "Stared" sidebar row and as the
    /// drop target when dragging tracks onto it.
    static let starredPlaylistID = UUID(uuidString: "D8F1A2C4-6B0E-4C2A-9A8E-5F3D7E2B1C90")!
    static let starredPlaylistName = "Stared"
    private static let starredModifiedKey = "library.starredPlaylistModifiedAt"

    @Published var albums: [Album]
    @Published var playlists: [Playlist]
    /// Fast lookup for star buttons; mirrors `Song.isStarred` and survives
    /// without re-reading every album on each row render.
    @Published private(set) var starredSongIDs: Set<UUID>
    /// Timestamp exposed to MPD as the built-in playlist's Last-Modified.
    private(set) var starredPlaylistModified: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "library.starredPlaylistModifiedAt")
        return saved > 0 ? saved : Date().timeIntervalSince1970
    }()
    @Published private(set) var internalLibrary: MusicLibrary?
    @Published private(set) var externalLibraries: [MusicLibrary]
    @Published private(set) var isScanning = false
    @Published private(set) var scanCompleted = 0
    @Published private(set) var scanTotal = 0
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var scanPhase: ScanPhase = .scan
    @Published var openWarning: String?
    @Published private(set) var scanError: String?

    private let db: LibraryDatabase
    private var scanTask: Task<Void, Never>?
    private var didAutoPromptSetup = false

    private static let internalPathKey = "internalLibraryPath"
    private static let setupDismissedKey = "internalSetupDismissed"

    init() {
        albums = []
        playlists = []
        starredSongIDs = []
        internalLibrary = nil
        externalLibraries = []
        isScanning = false
        openWarning = nil
        db = LibraryDatabase(path: Self.databaseURL.path)
        bootstrapLibraries()
        reload()
        rescanAll()
    }

    // MARK: Database location

    private static var appSupportDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.sqlite")
    }

    private static func configuredInternalPath() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: internalPathKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
    }

    /// The database lives next to the internal library's `Music` folder. Until
    /// an Internal Library exists it lives in Application Support.
    private static var databaseURL: URL {
        guard let root = configuredInternalPath() else {
            return appSupportDatabaseURL
        }
        let rootURL = URL(fileURLWithPath: root)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // Do not create Music here: a library opened from another machine may
        // temporarily be missing its Music folder, and we must not make the
        // folder exist (which would let a scan prune its still-missing songs).
        return rootURL.appendingPathComponent("library.sqlite")
    }

    // MARK: Server setup

    private func bootstrapLibraries() {
        if let path = Self.configuredInternalPath() {
            let canonical = canonicalPath(path)
            let library = db.ensureLibrary(path: canonical,
                                           kind: .internalLibrary,
                                           name: displayName(for: canonical))
            internalLibrary = library
        }

        externalLibraries = db.loadLibraries().filter { $0.kind == .external }
        db.assignUnownedSongs(to: [internalLibrary].compactMap { $0 } + externalLibraries)
    }

    // MARK: Setup state

    var shouldAutoPromptSetup: Bool {
        internalLibrary == nil &&
        !UserDefaults.standard.bool(forKey: Self.setupDismissedKey) &&
        !didAutoPromptSetup
    }

    func markSetupPromptShown() {
        didAutoPromptSetup = true
    }

    func deferInternalSetup() {
        UserDefaults.standard.set(true, forKey: Self.setupDismissedKey)
    }

    // MARK: Derived collections

    var allSongs: [Song] { albums.flatMap(\.songs) }

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
        return counts.sorted { $0.key < $1.key }.map { GenreItem(name: $0.key, count: $0.value) }
    }

    func album(withID id: UUID) -> Album? {
        albums.first { $0.id == id }
    }

    func song(withID id: UUID) -> (song: Song, album: Album)? {
        for album in albums {
            if let song = album.songs.first(where: { $0.id == id }) {
                return (song, album)
            }
        }
        return nil
    }

    func artwork(forAlbumTitle title: String?) -> Artwork {
        guard let title, let album = albums.first(where: { $0.title == title }) else {
            return Artwork(colors: [])
        }
        return album.artwork
    }

    // MARK: Library locations

    private var scanRoots: [String] {
        var roots: [String] = []
        if let internalLibrary, internalLibrary.isEnabled { roots.append(internalLibrary.scanPath) }
        roots.append(contentsOf: externalLibraries.filter(\.isEnabled).map(\.path))
        return roots
    }

    private var hasLibraries: Bool {
        (internalLibrary?.isEnabled ?? false) || externalLibraries.contains(where: \.isEnabled)
    }

    var internalMusicPath: String? { internalLibrary?.musicPath }

    @discardableResult
    func addExternalLibraries(_ rawPaths: [String]) -> [String] {
        scanTask?.cancel()
        isScanning = false
        var errors: [String] = []
        var pending = externalLibraries
        var added = false

        for raw in rawPaths {
            let path = canonicalPath(NSString(string: raw).expandingTildeInPath)
            do {
                try validateExternalLibrary(path, existing: pending)
                let library = db.ensureLibrary(path: path, kind: .external, name: displayName(for: path))
                pending.append(library)
                added = true
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if added {
            externalLibraries = db.loadLibraries().filter { $0.kind == .external }
            db.assignUnownedSongs(to: [internalLibrary].compactMap { $0 } + externalLibraries)
            rescanAll()
        }
        return errors
    }

    private func validateExternalLibrary(_ path: String, existing: [MusicLibrary]) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LibraryError.notDirectory(path)
        }
        if let internalLibrary, overlaps(path, internalLibrary.path) {
            throw LibraryError.overlapsInternal(internalLibrary.name)
        }
        if let library = existing.first(where: { canonicalPath($0.path) == path }) {
            throw LibraryError.alreadyAdded(library.name)
        }
        if let library = existing.first(where: { overlaps(path, $0.path) }) {
            throw LibraryError.overlapsExternal(library.name)
        }
    }

    func setExternalLibrary(_ id: UUID, enabled: Bool) throws {
        guard let library = externalLibraries.first(where: { $0.id == id }),
              library.isEnabled != enabled else { return }
        scanTask?.cancel()
        isScanning = false
        try db.setLibraryEnabled(id, enabled: enabled)
        externalLibraries = db.loadLibraries().filter { $0.kind == .external }
        if !enabled {
            PlayerState.shared.stopAndClear()
            PlayerState.shared.clearHistory()
        }
        reload()
        if enabled, let updated = externalLibraries.first(where: { $0.id == id }) {
            rescan(updated)
        }
    }

    @discardableResult
    func deleteDisabledExternalLibrary(_ id: UUID) throws -> URL {
        guard let library = externalLibraries.first(where: { $0.id == id }),
              !library.isEnabled else {
            throw LibraryDatabaseError.transactionFailed("Disable the external library before deleting it.")
        }
        scanTask?.cancel()
        isScanning = false
        let backupURL = try db.backup()
        try db.deleteLibraryAndSongs(id: id)
        externalLibraries = db.loadLibraries().filter { $0.kind == .external }
        db.assignUnownedSongs(to: [internalLibrary].compactMap { $0 } + externalLibraries)
        reload()
        return backupURL
    }

    func createInternalLibrary(atPath rawPath: String) throws {
        guard internalLibrary == nil else { throw LibraryError.internalAlreadyExists }
        scanTask?.cancel()
        isScanning = false
        let path = canonicalPath(NSString(string: rawPath).expandingTildeInPath)

        for library in externalLibraries where overlaps(path, library.path) {
            throw LibraryError.overlapsExternal(library.name)
        }

        let rootURL = URL(fileURLWithPath: path)
        let newDatabaseURL = rootURL.appendingPathComponent("library.sqlite")
        if db.path != newDatabaseURL.path,
           FileManager.default.fileExists(atPath: newDatabaseURL.path) {
            throw LibraryError.destinationHasLibrary(newDatabaseURL.path)
        }

        do {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent("Music", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            throw LibraryError.cannotCreate(error.localizedDescription)
        }

        if db.path != newDatabaseURL.path {
            try db.relocate(to: newDatabaseURL.path)
        }
        UserDefaults.standard.set(path, forKey: Self.internalPathKey)
        UserDefaults.standard.removeObject(forKey: Self.setupDismissedKey)

        let library = db.ensureLibrary(path: path, kind: .internalLibrary, name: displayName(for: path))
        internalLibrary = library
        externalLibraries = db.loadLibraries().filter { $0.kind == .external }
        db.assignUnownedSongs(to: [library] + externalLibraries)
        reload()
        rescanAll()
    }

    /// Opens an existing Tracks library in place. The selected URL may be the
    /// library folder or its `library.sqlite` file.
    ///
    /// Song paths are rebased from the library's old root to the new folder so
    /// a library folder can be copied to another computer. Persistent song IDs
    /// do not change, so playlists and play counts survive the move.
    func openInternalLibrary(atPath rawPath: String) throws {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        let folderURL: URL
        if exists && isDirectory.boolValue {
            folderURL = url
        } else if url.lastPathComponent == "library.sqlite" {
            folderURL = url.deletingLastPathComponent()
        } else {
            throw LibraryError.notLibraryFolder(url.path)
        }

        let folder = canonicalPath(folderURL.path)
        let newDatabasePath = URL(fileURLWithPath: folder)
            .appendingPathComponent("library.sqlite").path
        guard FileManager.default.fileExists(atPath: newDatabasePath) else {
            throw LibraryError.libraryNotFound(folder)
        }
        guard FileManager.default.isWritableFile(atPath: newDatabasePath),
              FileManager.default.isWritableFile(atPath: folder) else {
            throw LibraryError.readOnlyLibrary(folder)
        }
        var inspection: LibraryInspection?
        for attempt in 0..<3 {
            inspection = LibraryDatabase.inspect(path: newDatabasePath)
            if inspection != nil { break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard let inspection else {
            throw LibraryError.invalidLibrary(newDatabasePath)
        }

        scanTask?.cancel()
        isScanning = false
        openWarning = nil

        let oldDefaults = UserDefaults.standard.string(forKey: Self.internalPathKey)
        let oldDismissed = UserDefaults.standard.bool(forKey: Self.setupDismissedKey)
        let oldDatabasePath = db.path
        let oldInternal = internalLibrary
        let oldExternal = externalLibraries
        let switchingDatabase = oldDatabasePath != newDatabasePath

        do {
            if switchingDatabase {
                try db.switchTo(path: newDatabasePath)
            }

            if let oldRoot = inspection.internalLibraryPath, !oldRoot.isEmpty {
                db.rebaseSongs(from: oldRoot, to: folder)
            }

            let opened = db.ensureLibrary(path: folder,
                                          kind: .internalLibrary,
                                          name: displayName(for: folder))
            UserDefaults.standard.set(folder, forKey: Self.internalPathKey)
            UserDefaults.standard.removeObject(forKey: Self.setupDismissedKey)
            internalLibrary = opened
            externalLibraries = db.loadLibraries().filter { $0.kind == .external }
            db.assignUnownedSongs(to: [opened] + externalLibraries)

            if switchingDatabase {
                PlayerState.shared.stopAndClear()
            }
            reload()
            if switchingDatabase {
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }

            var messages: [String] = []
            var shouldScan = true

            if inspection.internalLibraryPath == nil && inspection.songCount > 0 {
                messages.append("This database has no Internal Library record. Its songs were opened without relinking, so some files may be missing.")
                shouldScan = false
            } else {
                let musicRoot = canonicalPath(opened.musicPath)
                let internalSongs = allSongs.filter { song in
                    guard let path = song.fileURL?.path else { return false }
                    return isUnder(canonicalPath(path), root: musicRoot)
                }
                let missing = internalSongs.filter { song in
                    guard let path = song.fileURL?.path else { return true }
                    return !FileManager.default.fileExists(atPath: path)
                }
                if !missing.isEmpty {
                    messages.append("\(missing.count) song\(missing.count == 1 ? "" : "s") could not be found in \(opened.musicPath). They have been kept in the database. Restore the Music folder and choose Scan to refresh.")
                    // Do not scan here: pruning would remove the missing entries
                    // before the user has a chance to restore the Music folder.
                    shouldScan = false
                }
            }

            let unavailableExternal = externalLibraries.filter {
                !FileManager.default.fileExists(atPath: $0.path)
            }
            if !unavailableExternal.isEmpty {
                messages.append("\(unavailableExternal.count) external librar\(unavailableExternal.count == 1 ? "y is" : "ies are") not available on this Mac. You can remove them in Settings, or add them again from their new location.")
            }

            openWarning = messages.isEmpty ? nil : messages.joined(separator: "\n\n")
            if shouldScan {
                rescanAll()
            }
        } catch {
            if let oldDefaults {
                UserDefaults.standard.set(oldDefaults, forKey: Self.internalPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.internalPathKey)
            }
            UserDefaults.standard.set(oldDismissed, forKey: Self.setupDismissedKey)
            if switchingDatabase && db.path != oldDatabasePath {
                try? db.switchTo(path: oldDatabasePath)
            }
            internalLibrary = oldInternal
            externalLibraries = oldExternal
            reload()
            throw error
        }
    }

    func clearOpenWarning() {
        openWarning = nil
    }

    /// Called on app termination so the SQLite WAL is checkpointed and the
    /// main database file can be copied safely to another Mac.
    func closeDatabaseForTermination() {
        scanTask?.cancel()
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
            isScanning = false
            scanCompleted = 0
            scanTotal = 0
            scanProgress = 0
            return
        }

        let roots = libraries.map(\.scanPath)
        let known = force ? [:] : db.knownFiles()
        isScanning = true
        scanError = nil
        scanPhase = .scan
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
        let progress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            Task { @MainActor in
                guard let self else { return }
                if total > 0 { self.scanPhase = .parsing }
                self.scanCompleted = completed
                self.scanTotal = total
                self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
            }
        }

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await LibraryScanner.scan(folders: roots,
                                          known: known,
                                          mode: force ? .full : .quick,
                                          progress: progress)
            }.value

            guard let self, !Task.isCancelled else { return }
            guard result.isComplete else {
                self.scanError = result.errors.joined(separator: "\n")
                self.isScanning = false
                return
            }
            let artwork = self.db.sync(tracks: result.tracks,
                                       internalMusicRoot: self.internalLibrary?.musicPath,
                                       libraries: libraries)
            await ArtworkCache.shared.importArtwork(artwork)
            PlayerState.shared.clearMissingFiles(foundPaths: Set(result.discoveredFiles.keys))
            self.reload()
            self.scanProgress = 1
            self.isScanning = false
        }
    }

    /// Quick-scans one enabled library. Modified files and missing files require
    /// an explicit Full Scan.
    func rescan(_ location: MusicLibrary) {
        let stillConfigured = location.isInternal
            ? internalLibrary?.id == location.id
            : externalLibraries.contains { $0.id == location.id && $0.isEnabled }
        guard stillConfigured, location.isEnabled else { return }

        scanTask?.cancel()
        let root = location.scanPath
        let known = db.knownFiles()
        isScanning = true
        scanError = nil
        scanPhase = .scan
        scanCompleted = 0
        scanTotal = 0
        scanProgress = 0
        let progress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            Task { @MainActor in
                guard let self else { return }
                if total > 0 { self.scanPhase = .parsing }
                self.scanCompleted = completed
                self.scanTotal = total
                self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
            }
        }

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await LibraryScanner.scan(folders: [root],
                                          known: known,
                                          mode: .quick,
                                          progress: progress)
            }.value

            guard let self, !Task.isCancelled else { return }
            guard result.isComplete else {
                self.scanError = result.errors.joined(separator: "\n")
                self.isScanning = false
                return
            }
            let artwork = self.db.sync(tracks: result.tracks,
                                       internalMusicRoot: self.internalLibrary?.musicPath,
                                       libraries: self.enabledLibraries)
            await ArtworkCache.shared.importArtwork(artwork)
            PlayerState.shared.clearMissingFiles(foundPaths: Set(result.discoveredFiles.keys))
            self.reload()
            self.scanProgress = 1
            self.isScanning = false
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
        scanPhase = .scan
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

        let artwork = db.sync(tracks: result.tracks,
                              internalMusicRoot: internalLibrary?.musicPath,
                              libraries: enabledLibraries)
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
        guard location.isExternal,
              enabledLibraries.contains(where: { $0.id == location.id }) else { return nil }
        scanError = nil
        let newRoot = canonicalPath(NSString(string: rawRoot).expandingTildeInPath)
        do {
            try validateExternalLibrary(newRoot,
                                        existing: externalLibraries.filter { $0.id != location.id })
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
        scanPhase = .scan
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
        let matchedPaths = Set(matches.values)
        let additionalCount = max(0, foundPaths.subtracting(matchedPaths).count)
        let plan = LibraryRelocationPlan(libraryID: location.id,
                                         newRoot: newRoot,
                                         matchedSongPaths: matches,
                                         discoveredPaths: foundPaths,
                                         scannedTracks: result.tracks,
                                         matchedCount: matches.count,
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
              externalLibraries.contains(where: { $0.id == plan.libraryID }) else {
            throw LibraryDatabaseError.transactionFailed("The relocation preview is no longer valid.")
        }
        isScanning = true
        defer { isScanning = false }
        let backupURL = try db.backup()
        let validMissingIDs = Set(report.songs.map(\.id)).intersection(removingMissingIDs)
        try db.relocateLibrary(id: plan.libraryID,
                               to: plan.newRoot,
                               songPaths: plan.matchedSongPaths,
                               removingSongIDs: validMissingIDs)
        externalLibraries = db.loadLibraries().filter { $0.kind == .external }
        db.assignUnownedSongs(to: [internalLibrary].compactMap { $0 } + externalLibraries)
        let artwork = db.sync(tracks: plan.scannedTracks,
                              internalMusicRoot: internalLibrary?.musicPath,
                              libraries: enabledLibraries)
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
        ([internalLibrary].compactMap { $0 } + externalLibraries).filter(\.isEnabled)
    }

    private func makeProgressHandler() -> @Sendable (Int, Int) -> Void {
        { [weak self] completed, total in
            Task { @MainActor in
                guard let self else { return }
                if total > 0 { self.scanPhase = .parsing }
                self.scanCompleted = completed
                self.scanTotal = total
                self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
            }
        }
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
        starredSongIDs = Set(loaded.albums.flatMap(\.songs).lazy.filter(\.isStarred).map(\.id))
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

    // MARK: Read-only rules

    /// Only music inside the Internal Library's `Music` folder can be edited.
    func isReadOnly(songID: UUID) -> Bool {
        guard let song = song(withID: songID)?.song else { return true }
        return isReadOnly(song: song)
    }

    func isReadOnly(song: Song) -> Bool {
        guard let filePath = song.fileURL?.path,
              let internalLibrary else { return true }
        return !isUnder(canonicalPath(filePath), root: canonicalPath(internalLibrary.musicPath))
    }

    /// An album is editable only when every track belongs to the Internal
    /// Library. Mixed or external albums stay read-only.
    func isReadOnly(albumID: UUID) -> Bool {
        guard let album = album(withID: albumID) else { return true }
        return isReadOnly(album: album)
    }

    func isReadOnly(album: Album) -> Bool {
        guard !album.songs.isEmpty else { return true }
        return album.songs.contains { isReadOnly(song: $0) }
    }

    /// Moves the given Internal Library files to the Trash and removes their
    /// rows from the database. Files that cannot be moved are left in place and
    /// reported in `failures`.
    @discardableResult
    func deleteSongs(_ songs: [Song]) -> LibraryDeletionResult {
        var seen = Set<UUID>()
        let unique = songs.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return LibraryDeletionResult(deleted: 0, failures: []) }
        guard unique.allSatisfy({ !isReadOnly(song: $0) }) else {
            return LibraryDeletionResult(
                deleted: 0,
                failures: ["Only tracks in the Internal Library can be deleted."]
            )
        }

        var deletedIDs: [UUID] = []
        var failures: [String] = []
        for song in unique {
            guard let url = song.fileURL else {
                deletedIDs.append(song.id)
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    deletedIDs.append(song.id)
                } catch {
                    failures.append("\(song.title): \(error.localizedDescription)")
                }
            } else {
                // The database row can still be pruned when the file is gone.
                deletedIDs.append(song.id)
            }
        }

        guard !deletedIDs.isEmpty else {
            return LibraryDeletionResult(deleted: 0, failures: failures)
        }

        db.deleteSongs(withIDs: deletedIDs)
        PlayerState.shared.removeSongs(withIDs: Set(deletedIDs))
        reload()
        return LibraryDeletionResult(deleted: deletedIDs.count, failures: failures)
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

    // MARK: Tag editing

    func updateSong(_ updated: Song) async throws {
        guard !isReadOnly(songID: updated.id) else { return }
        let albumID = song(withID: updated.id)?.album.id
        let artwork: Data? = if let albumID {
            await ArtworkCache.shared.fullData(albumID: albumID)
        } else {
            nil
        }
        if let url = updated.fileURL {
            let fields = TagFields(title: updated.title,
                                   artist: updated.artist,
                                   albumArtist: updated.albumArtist,
                                   album: updated.album,
                                   genre: updated.genre,
                                   year: updated.year.isEmpty ? nil : updated.year,
                                   track: updated.trackNumber > 0 ? updated.trackNumber : nil,
                                   trackTotal: updated.trackTotal > 0 ? updated.trackTotal : nil,
                                   discNumber: updated.discNumber > 0 ? updated.discNumber : nil,
                                   discTotal: updated.discTotal > 0 ? updated.discTotal : nil,
                                   comments: updated.comments.isEmpty ? nil : updated.comments,
                                   artwork: artwork)
            try await writeTags(fields, to: url)
            updateFileStats(for: url)
        }
        db.updateSong(updated)
        do {
            try organizeInternalSongs([updated])
        } catch {
            reload()
            throw error
        }
        reload()
        PlayerState.shared.applyUpdatedSongs(allSongs)
    }

    func updateAlbum(_ updated: Album) async throws {
        guard !isReadOnly(albumID: updated.id) else { return }
        for song in updated.songs {
            guard let url = song.fileURL else { continue }
            let fields = TagFields(title: song.title,
                                   artist: song.artist,
                                   albumArtist: song.albumArtist,
                                   album: song.album,
                                   genre: song.genre,
                                   year: song.year.isEmpty ? nil : song.year,
                                   track: song.trackNumber > 0 ? song.trackNumber : nil,
                                   trackTotal: song.trackTotal > 0 ? song.trackTotal : nil,
                                   discNumber: song.discNumber > 0 ? song.discNumber : nil,
                                   discTotal: song.discTotal > 0 ? song.discTotal : nil,
                                   comments: song.comments.isEmpty ? nil : song.comments,
                                   artwork: updated.artwork.imageData)
            try await writeTags(fields, to: url)
            updateFileStats(for: url)
        }
        db.updateAlbum(updated)
        db.updateSongMetadata(updated.songs)
        do {
            try organizeInternalSongs(updated.songs)
        } catch {
            await ArtworkCache.shared.storeArtwork(updated.artwork.imageData, albumID: updated.id)
            reload()
            throw error
        }
        await ArtworkCache.shared.storeArtwork(updated.artwork.imageData, albumID: updated.id)
        reload()
        PlayerState.shared.applyUpdatedSongs(allSongs)
    }

    /// Moves edited Internal Library files to the canonical artist/album path.
    /// Song IDs, stars, playlists and added dates are preserved because the
    /// database path is updated in place rather than re-inserting the row.
    private func organizeInternalSongs(_ songs: [Song]) throws {
        guard let internalLibrary else { return }
        let root = URL(fileURLWithPath: internalLibrary.musicPath)
        for song in songs {
            guard let url = song.fileURL, !isReadOnly(songID: song.id),
                  let desired = LibraryOrganizer.destination(for: song, musicRoot: root) else { continue }
            let source = url.resolvingSymlinksInPath()
            if source.path == desired.path { continue }
            try FileManager.default.createDirectory(
                at: desired.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var destination = desired
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = LibraryOrganizer.uniqueDestination(destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            let values = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            db.updateSongPath(songID: song.id,
                              path: destination.path,
                              mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                              size: Int64(values?.fileSize ?? 0))
        }
    }

    func resetPlayCount(songIDs: [UUID]) {
        guard !songIDs.isEmpty else { return }
        db.resetPlayCount(songIDs: songIDs.map(\.uuidString))
        reload()
        PlayerState.shared.applyUpdatedSongs(allSongs)
    }

    private func writeTags(_ fields: TagFields, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try await AudioTagWriter.write(fields, to: url)
        }.value
    }

    private func updateFileStats(for url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        db.updateFileStats(path: url.path,
                           mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                           size: Int64(values?.fileSize ?? 0))
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
