import SwiftUI
import AppKit
import ImageIO

extension Notification.Name {
    static let artworkDidChange = Notification.Name("tracks.artworkDidChange")
    static let focusSearch = Notification.Name("tracks.focusSearch")
}

private struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// Disk + memory cache for album artwork. Visible views request thumbnails
/// asynchronously; scans write new artwork directly into the disk cache.
@MainActor
final class ArtworkCache: ObservableObject {
    static let shared = ArtworkCache()

    @Published private(set) var cacheSizeBytes: Int64 = 0
    @Published private(set) var isCalculatingCacheSize = false

    private var databasePath: String?
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

    private init() {}

    func setDatabasePath(_ path: String) {
        guard databasePath != path else { return }
        databasePath = path
        memory.removeAllObjects()
        refreshCacheSize()
    }

    func refreshCacheSize() {
        isCalculatingCacheSize = true
        let directory = Self.cacheDirectory
        Task.detached(priority: .utility) {
            let total = Self.directorySize(directory)
            await MainActor.run {
                ArtworkCache.shared.cacheSizeBytes = total
                ArtworkCache.shared.isCalculatingCacheSize = false
            }
        }
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
        refreshCacheSize()
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
        refreshCacheSize()
        NotificationCenter.default.post(name: .artworkDidChange, object: nil)
    }

    func clearCache() {
        memory.removeAllObjects()
        cacheSizeBytes = 0
        isCalculatingCacheSize = false
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    func rebuildCache() {
        // A full scan is already running (including one started by a previous
        // rebuild). Starting another would cancel and restart the scan.
        guard !Library.shared.isScanning else { return }
        clearCache()
        Library.shared.rescanAll(force: true)
    }

    // MARK: - Background work

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
        return nil
    }

    nonisolated private static func ensureFull(albumID: String,
                                   databasePath: String,
                                   directory: URL) -> Data? {
        let thumb = thumbnailURL(directory: directory, albumID: albumID)
        return try? Data(contentsOf: thumb)
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
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
