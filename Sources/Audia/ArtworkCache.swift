import SwiftUI
import AppKit
import ImageIO
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Notification.Name {
    static let artworkDidChange = Notification.Name("tracks.artworkDidChange")
    static let focusSearch = Notification.Name("tracks.focusSearch")
}

private struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// Disk + memory cache for album artwork. Library loading never reads every
/// artwork BLOB; visible views request thumbnails asynchronously and the cache
/// worker prebuilds the rest on a background task.
@MainActor
final class ArtworkCache: ObservableObject {
    static let shared = ArtworkCache()

    @Published private(set) var isCaching = false
    @Published private(set) var cacheCompleted = 0
    @Published private(set) var cacheTotal = 0
    @Published private(set) var cacheProgress: Double = 0

    private var databasePath: String?
    private var cacheTask: Task<Void, Never>?
    private let memory = NSCache<NSString, NSImage>()

    private nonisolated static let artworkMaxPixel = 500
    /// Quality is user-configurable in Settings. The default is 80%.
    private nonisolated static var jpegQuality: CGFloat {
        let stored = UserDefaults.standard.object(forKey: "artworkCacheJPEGQuality") as? Double
        let value = stored ?? 0.8
        return CGFloat(min(max(value, 0.15), 1.0))
    }

    nonisolated private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.audia.tracks"
        return base
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    nonisolated private static var legacyCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Tracks/ArtworkCache", isDirectory: true)
    }

    private init() {}

    func setDatabasePath(_ path: String) {
        guard databasePath != path else { return }
        databasePath = path
        cacheTask?.cancel()
        memory.removeAllObjects()
        startPrecache()
    }

    func startPrecache() {
        guard databasePath != nil else { return }
        cacheTask?.cancel()
        isCaching = true
        cacheCompleted = 0
        cacheTotal = 0
        cacheProgress = 0

        let path = databasePath!
        let directory = Self.cacheDirectory
        cacheTask = Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: Self.legacyCacheDirectory)
            let total = await Self.externalizeDatabaseArtwork(path: path, directory: directory) { completed, total in
                Task { @MainActor in
                    ArtworkCache.shared.updateCacheProgress(completed, total)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                ArtworkCache.shared.finishPrecache(total: total)
                NotificationCenter.default.post(name: .artworkDidChange, object: nil)
            }
        }
    }

    private func updateCacheProgress(_ completed: Int, _ total: Int) {
        cacheCompleted = completed
        cacheTotal = total
        cacheProgress = total > 0 ? Double(completed) / Double(total) : 0
    }

    private func finishPrecache(total: Int) {
        isCaching = false
        cacheProgress = 1
        cacheCompleted = max(cacheCompleted, total)
        cacheTotal = max(cacheTotal, total)
    }

    func image(for artwork: Artwork, maxPixel: Int = 512) async -> NSImage? {
        if let data = artwork.imageData {
            let key = "inline-\(data.count)-\(data.hashValue)" as NSString
            if let image = memory.object(forKey: key) { return image }
            let result = await Task.detached(priority: .userInitiated) {
                Self.imageFromInlineData(data, maxPixel: maxPixel)
            }.value
            if let image = result?.image { memory.setObject(image, forKey: key) }
            return result?.image
        }

        guard let albumID = artwork.cacheKey, let path = databasePath else { return nil }
        let key = "\(albumID)-\(maxPixel)" as NSString
        if let image = memory.object(forKey: key) { return image }

        let directory = Self.cacheDirectory
        let result = await Task.detached(priority: .userInitiated) {
            Self.imageFromCache(albumID: albumID,
                                databasePath: path,
                                directory: directory,
                                maxPixel: maxPixel)
        }.value
        if let image = result?.image { memory.setObject(image, forKey: key) }
        return result?.image
    }

    func fullData(albumID: UUID) async -> Data? {
        guard let path = databasePath else { return nil }
        let directory = Self.cacheDirectory
        return await Task.detached(priority: .userInitiated) {
            Self.ensureFull(albumID: albumID.uuidString,
                            databasePath: path,
                            directory: directory)
        }.value
    }

    func storeArtwork(_ data: Data?, albumID: UUID) async {
        let directory = Self.cacheDirectory
        await Task.detached(priority: .userInitiated) {
            Self.writeArtwork(data, albumID: albumID.uuidString, directory: directory)
        }.value
        memory.removeAllObjects()
        NotificationCenter.default.post(name: .artworkDidChange, object: albumID.uuidString)
    }

    /// Writes artwork extracted during a scan into the external cache. The DB
    /// never stores artwork BLOBs; this is the only persistence point.
    /// Synchronous cache lookup for the MPD binary-response commands. Only the
    /// small 500px JPEG cache file is read; the database has no artwork BLOBs.
    func cachedData(forAlbumID albumID: UUID) -> Data? {
        try? Data(contentsOf: Self.thumbnailURL(directory: Self.cacheDirectory,
                                                albumID: albumID.uuidString))
    }

    func importArtwork(_ artwork: [String: Data]) async {
        guard !artwork.isEmpty else { return }
        let directory = Self.cacheDirectory
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (albumID, data) in artwork {
                Self.writeArtwork(data, albumID: albumID, directory: directory)
            }
        }.value
        memory.removeAllObjects()
        NotificationCenter.default.post(name: .artworkDidChange, object: nil)
    }

    func clearCache() {
        cacheTask?.cancel()
        isCaching = false
        cacheCompleted = 0
        cacheTotal = 0
        cacheProgress = 0
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        try? FileManager.default.removeItem(at: Self.legacyCacheDirectory)
    }

    func rebuildCache() {
        clearCache()
        Library.shared.rescanAll(force: true)
    }

    // MARK: - Background work

    nonisolated private static func externalizeDatabaseArtwork(
        path: String,
        directory: URL,
        progress: @Sendable (Int, Int) -> Void
    ) async -> Int {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 10_000)

        var total = 0
        if let stmt = prepare(db, "SELECT COUNT(*) FROM albums WHERE artwork IS NOT NULL") {
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        progress(0, total)
        guard total > 0 else { return 0 }

        guard let select = prepare(db, "SELECT id, artwork FROM albums WHERE artwork IS NOT NULL"),
              let clear = prepare(db, "UPDATE albums SET artwork = NULL WHERE id = ?") else {
            return 0
        }
        defer {
            sqlite3_finalize(select)
            sqlite3_finalize(clear)
        }

        var completed = 0
        while sqlite3_step(select) == SQLITE_ROW {
            if Task.isCancelled { break }
            guard let idText = sqlite3_column_text(select, 0),
                  let blob = sqlite3_column_blob(select, 1) else { continue }
            let albumID = String(cString: idText)
            let count = Int(sqlite3_column_bytes(select, 1))
            let data = Data(bytes: blob, count: count)
            writeArtwork(data, albumID: albumID, directory: directory)

            sqlite3_reset(clear)
            sqlite3_clear_bindings(clear)
            _ = albumID.withCString {
                sqlite3_bind_text(clear, 1, $0, -1, SQLITE_TRANSIENT)
            }
            sqlite3_step(clear)

            completed += 1
            if completed % 8 == 0 || completed == total {
                progress(completed, total)
            }
            if completed % 4 == 0 { await Task.yield() }
        }

        // Reclaim the space occupied by the artwork BLOBs. This is a one-time
        // migration for libraries created before artwork was externalized.
        sqlite3_exec(db, "VACUUM;", nil, nil, nil)
        progress(completed, total)
        return completed
    }

    nonisolated private static func imageFromInlineData(_ data: Data, maxPixel: Int) -> SendableImage? {
        if let thumb = makeJPEG(data, maxPixel: artworkMaxPixel), let image = NSImage(data: thumb) {
            return SendableImage(image: image)
        }
        guard let image = NSImage(data: data) else { return nil }
        return SendableImage(image: image)
    }

    nonisolated private static func imageFromCache(albumID: String,
                                       databasePath: String,
                                       directory: URL,
                                       maxPixel: Int) -> SendableImage? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let thumb = thumbnailURL(directory: directory, albumID: albumID)
        if let data = try? Data(contentsOf: thumb), let image = NSImage(data: data) {
            return SendableImage(image: image)
        }
        guard let full = ensureFull(albumID: albumID,
                                    databasePath: databasePath,
                                    directory: directory) else { return nil }
        if let image = NSImage(data: full) {
            return SendableImage(image: image)
        }
        return nil
    }

    nonisolated private static func ensureFull(albumID: String,
                                   databasePath: String,
                                   directory: URL) -> Data? {
        let thumb = thumbnailURL(directory: directory, albumID: albumID)
        if let data = try? Data(contentsOf: thumb) { return data }
        guard let original = artworkFromDatabase(path: databasePath, albumID: albumID) else { return nil }
        let jpeg = makeJPEG(original, maxPixel: artworkMaxPixel)
        if let jpeg { try? jpeg.write(to: thumb, options: .atomic) }
        return jpeg ?? original
    }

    nonisolated private static func artworkFromDatabase(path: String, albumID: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        guard let stmt = prepare(db, "SELECT artwork FROM albums WHERE id = ?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        _ = albumID.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let pointer = sqlite3_column_blob(stmt, 0) else {
            return nil
        }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    nonisolated private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    nonisolated private static func writeArtwork(_ data: Data?, albumID: String, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let thumb = thumbnailURL(directory: directory, albumID: albumID)
        if let data, let jpeg = makeJPEG(data, maxPixel: artworkMaxPixel) {
            try? jpeg.write(to: thumb, options: .atomic)
        } else if data == nil {
            try? FileManager.default.removeItem(at: thumb)
        }
    }

    nonisolated private static func makeJPEG(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    nonisolated private static func thumbnailURL(directory: URL, albumID: String) -> URL {
        directory.appendingPathComponent(albumID).appendingPathExtension("jpg")
    }
}
