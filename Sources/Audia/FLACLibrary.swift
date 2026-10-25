import Foundation
import CryptoKit
import AVFoundation

struct KnownFile: Sendable {
    let mtime: Double
    let size: Int64
}

struct ScannedTrack: Sendable {
    let path: String
    let title: String
    /// Per-track `ARTIST`.
    let artist: String
    /// `ALBUMARTIST` (with common spelling variants), falling back to `artist`.
    let albumArtist: String
    let album: String
    let genre: String
    /// Raw DATE/YEAR tag text. Empty means unknown.
    let year: String
    let track: Int
    let trackTotal: Int
    let discNumber: Int
    let discTotal: Int
    let comments: String
    let duration: TimeInterval
    let artwork: Data?
    let mtime: Double
    let fileSize: Int64
}

enum FLACMetadataReader {
    static func read(url: URL) -> ScannedTrack? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var tags: [String: String] = [:]
        var artwork: Data?
        var sampleRate: Double = 44100
        var totalSamples: UInt64 = 0

        while true {
            guard let headerData = try? handle.read(upToCount: 4), headerData.count == 4 else { break }
            let header = [UInt8](headerData)
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length >= 0, length < 64 * 1024 * 1024,
                  let blockData = try? handle.read(upToCount: length),
                  blockData.count == length else { break }
            let block = [UInt8](blockData)

            switch type {
            case 0:
                if block.count >= 18 {
                    let rate = Double(Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12]) >> 4)
                    if rate > 0 { sampleRate = rate }
                    totalSamples = UInt64(block[13] & 0x0F) << 32
                        | UInt64(block[14]) << 24
                        | UInt64(block[15]) << 16
                        | UInt64(block[16]) << 8
                        | UInt64(block[17])
                }
            case 4:
                parseComments(block, into: &tags)
            case 6:
                if artwork == nil { artwork = parsePicture(block) }
            default:
                break
            }
            if isLast { break }
        }

        func tag(_ key: String) -> String? {
            guard let value = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        func intTag(_ key: String) -> Int? {
            guard let value = tag(key) else { return nil }
            let digits = value.split(separator: "/").first.map(String.init) ?? value
            return Int(digits.filter(\.isNumber))
        }

        func parsePair(_ value: String?) -> (number: Int, total: Int) {
            guard let value, !value.isEmpty else { return (0, 0) }
            let parts = value.split(separator: "/", maxSplits: 1)
            let number = Int(parts.first.map(String.init)?.filter(\.isNumber) ?? "") ?? 0
            let total = parts.count > 1
                ? Int(parts[1].filter(\.isNumber)) ?? 0
                : 0
            return (number, total)
        }

        let title = tags["TITLE"] ?? url.deletingPathExtension().lastPathComponent
        let artist = tag("ARTIST") ?? tag("ALBUMARTIST") ?? "Unknown Artist"
        let albumArtist = tag("ALBUMARTIST")
            ?? tag("ALBUM ARTIST")
            ?? tag("ALBUM_ARTIST")
            ?? tag("ENSEMBLE")
            ?? tag("BAND")
            ?? artist
        let album = tags["ALBUM"] ?? "Unknown Album"
        let genre = tags["GENRE"] ?? "Unknown"
        let rawYear = tag("DATE") ?? tag("YEAR") ?? ""
        let year = rawYear == "0" ? "" : rawYear
        let trackPair = parsePair(tags["TRACKNUMBER"])
        let track = trackPair.number
        let trackTotal = intTag("TRACKTOTAL")
            ?? intTag("TOTALTRACKS")
            ?? trackPair.total
        let discPair = parsePair(tags["DISCNUMBER"] ?? tags["DISC"])
        let discNumber = discPair.number
        let discTotal = intTag("DISCTOTAL")
            ?? intTag("TOTALDISCS")
            ?? discPair.total
        let comments = tag("COMMENT") ?? tag("COMMENTS") ?? tag("DESCRIPTION") ?? ""
        let duration = (sampleRate > 0 && totalSamples > 0) ? Double(totalSamples) / sampleRate : 0
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = Int64(values?.fileSize ?? 0)

        return ScannedTrack(path: url.path,
                            title: title,
                            artist: artist,
                            albumArtist: albumArtist,
                            album: album,
                            genre: genre,
                            year: year,
                            track: track,
                            trackTotal: trackTotal,
                            discNumber: discNumber,
                            discTotal: discTotal,
                            comments: comments,
                            duration: duration,
                            artwork: artwork,
                            mtime: mtime,
                            fileSize: fileSize)
    }

    private static func parseComments(_ block: [UInt8], into tags: inout [String: String]) {
        var offset = 0

        func readUInt32LE() -> UInt32? {
            guard offset + 4 <= block.count else { return nil }
            let value = UInt32(block[offset])
                | UInt32(block[offset + 1]) << 8
                | UInt32(block[offset + 2]) << 16
                | UInt32(block[offset + 3]) << 24
            offset += 4
            return value
        }

        func readString(_ length: Int) -> String? {
            guard length >= 0, offset + length <= block.count else { return nil }
            let value = String(decoding: block[offset..<offset + length], as: UTF8.self)
            offset += length
            return value
        }

        guard let vendorLength = readUInt32LE(),
              readString(Int(vendorLength)) != nil,
              let count = readUInt32LE() else { return }

        for _ in 0..<count {
            guard let length = readUInt32LE(), let entry = readString(Int(length)) else { break }
            if let separator = entry.firstIndex(of: "=") {
                let key = String(entry[..<separator]).uppercased()
                tags[key] = String(entry[entry.index(after: separator)...])
            }
        }
    }

    private static func parsePicture(_ block: [UInt8]) -> Data? {
        var offset = 0

        func readUInt32BE() -> UInt32? {
            guard offset + 4 <= block.count else { return nil }
            let value = UInt32(block[offset]) << 24
                | UInt32(block[offset + 1]) << 16
                | UInt32(block[offset + 2]) << 8
                | UInt32(block[offset + 3])
            offset += 4
            return value
        }

        guard readUInt32BE() != nil,                       // picture type
              let mimeLength = readUInt32BE(),
              offset + Int(mimeLength) <= block.count else { return nil }
        offset += Int(mimeLength)

        guard let descriptionLength = readUInt32BE(),
              offset + Int(descriptionLength) <= block.count else { return nil }
        offset += Int(descriptionLength)

        guard offset + 16 <= block.count else { return nil }
        offset += 16                                        // width, height, depth, colors

        guard let dataLength = readUInt32BE(),
              offset + Int(dataLength) <= block.count else { return nil }
        return Data(block[offset..<offset + Int(dataLength)])
    }
}

/// Metadata reader for the non-FLAC formats supported by AVFoundation. macOS
/// exposes Vorbis comments for Ogg, ID3 for MP3/WAV/AIFF and iTunes/QuickTime
/// metadata for M4A through AVMetadataItem, so one reader covers them.
enum AVAssetMetadataReader {
    private struct Fields {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var genre: String?
        var year: String?
        var track: Int?
        var trackTotal: Int?
        var discNumber: Int?
        var discTotal: Int?
        var comments: String?
        var artwork: Data?
    }

    static func read(url: URL) async -> ScannedTrack? {
        let asset = AVURLAsset(url: url)
        var fields = Fields()

        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    if let value = try? await item.load(.value) {
                        apply(item: item, value: value, to: &fields)
                    }
                }
            }
        }
        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                if let value = try? await item.load(.value) {
                    apply(item: item, value: value, to: &fields)
                }
            }
        }

        var duration: TimeInterval = 0
        if let time = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
        guard duration > 0 else { return nil }

        let title = clean(fields.title) ?? url.deletingPathExtension().lastPathComponent
        let artist = clean(fields.artist) ?? clean(fields.albumArtist) ?? "Unknown Artist"
        let albumArtist = clean(fields.albumArtist) ?? artist
        let album = clean(fields.album) ?? "Unknown Album"
        let genre = clean(fields.genre) ?? "Unknown"
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = Int64(values?.fileSize ?? 0)

        return ScannedTrack(path: url.path,
                            title: title,
                            artist: artist,
                            albumArtist: albumArtist,
                            album: album,
                            genre: genre,
                            year: fields.year ?? "",
                            track: fields.track ?? 0,
                            trackTotal: fields.trackTotal ?? 0,
                            discNumber: fields.discNumber ?? 0,
                            discTotal: fields.discTotal ?? 0,
                            comments: clean(fields.comments) ?? "",
                            duration: duration,
                            artwork: fields.artwork,
                            mtime: mtime,
                            fileSize: fileSize)
    }

    private static func apply(item: AVMetadataItem, value: Any, to fields: inout Fields) {
        let rawKey = (item.key as? String)?.uppercased() ?? ""
        let identifierKey = item.identifier?.rawValue
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: "%C2%A9", with: "©")
            .replacingOccurrences(of: "%A9", with: "©")
            .uppercased() ?? ""
        let key = rawKey.isEmpty ? identifierKey : rawKey
        let common = item.commonKey?.rawValue ?? ""

        if isArtworkKey(key, common: common) {
            if fields.artwork == nil, let image = imageData(from: value, key: key) {
                fields.artwork = image
            }
            return
        }

        switch key {
        case "TITLE", "TIT2", "TT2", "©NAM", "INAM", "NAME":
            fields.title = fields.title ?? text(from: value)
        case "ARTIST", "TPE1", "TP1", "©ART", "IART", "AUTH":
            fields.artist = fields.artist ?? text(from: value)
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST", "TPE2", "TP2",
             "AART", "IAAR", "ENSEMBLE", "BAND":
            fields.albumArtist = fields.albumArtist ?? text(from: value)
        case "ALBUM", "TALB", "TAL", "©ALB", "IPRD":
            fields.album = fields.album ?? text(from: value)
        case "GENRE", "TCON", "TCO", "©GEN", "GNRE", "IGNR":
            fields.genre = fields.genre ?? text(from: value)
        case "DATE", "TDRC", "TYER", "TYE", "©DAY", "ICRD":
            fields.year = fields.year ?? yearString(from: value)
        case "TRACKNUMBER", "TRCK", "TRK", "TRKN", "ITRK":
            let pair = numberPair(from: value)
            if fields.track == nil, pair.number > 0 { fields.track = pair.number }
            if fields.trackTotal == nil, pair.total > 0 { fields.trackTotal = pair.total }
        case "TRACKTOTAL", "TOTALTRACKS":
            fields.trackTotal = fields.trackTotal ?? numberPair(from: value).number
        case "DISCNUMBER", "DISKNUMBER", "TPOS", "DISK":
            let pair = numberPair(from: value)
            if fields.discNumber == nil, pair.number > 0 { fields.discNumber = pair.number }
            if fields.discTotal == nil, pair.total > 0 { fields.discTotal = pair.total }
        case "DISCTOTAL", "TOTALDISCS":
            fields.discTotal = fields.discTotal ?? numberPair(from: value).number
        case "COMMENT", "COMMENTS", "COMM", "ICMT", "©CMT", "DESC":
            fields.comments = fields.comments ?? text(from: value)
        default:
            switch common {
            case "title": fields.title = fields.title ?? text(from: value)
            case "artist": fields.artist = fields.artist ?? text(from: value)
            case "albumName": fields.album = fields.album ?? text(from: value)
            case "type": fields.genre = fields.genre ?? text(from: value)
            case "creationDate": fields.year = fields.year ?? yearString(from: value)
            case "comment": fields.comments = fields.comments ?? text(from: value)
            default: break
            }
        }
    }

    private static func isArtworkKey(_ key: String, common: String) -> Bool {
        if common == "artwork" { return true }
        return ["METADATA_BLOCK_PICTURE", "APIC", "PIC", "COVR", "IPIC", "COVERART"].contains(key)
            || key.contains("PICTURE")
            || key.contains("ARTWORK")
    }

    private static func text(from value: Any) -> String? {
        if let string = value as? String { return clean(string) }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [String] { return array.lazy.compactMap { clean($0) }.first }
        if let array = value as? [Any] {
            for entry in array {
                if let string = text(from: entry) { return string }
            }
        }
        if let data = value as? Data {
            for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
                if let string = String(data: data, encoding: encoding),
                   let cleaned = clean(string) {
                    return cleaned
                }
            }
        }
        return nil
    }

    private static func yearString(from value: Any) -> String? {
        if let date = value as? Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        if let number = value as? NSNumber {
            let value = number.stringValue
            return value == "0" ? nil : value
        }
        guard let string = text(from: value) else { return nil }
        return string == "0" ? nil : string
    }

    private static func numberPair(from value: Any) -> (number: Int, total: Int) {
        if let data = value as? Data, data.count >= 4 {
            // iTunes 'trkn'/'disk' atoms are reserved bytes followed by
            // big-endian number and total fields.
            let number = Int(data[2]) << 8 | Int(data[3])
            let total = data.count >= 6 ? Int(data[4]) << 8 | Int(data[5]) : 0
            return (number, total)
        }
        if let number = value as? NSNumber {
            return (number.intValue, 0)
        }
        guard let string = text(from: value) else { return (0, 0) }
        let parts = string.split(separator: "/", maxSplits: 1)
        let number = Int(parts.first.map(String.init)?.filter(\.isNumber) ?? "") ?? 0
        let total = parts.count > 1
            ? Int(parts[1].filter(\.isNumber)) ?? 0
            : 0
        return (number, total)
    }

    private static func imageData(from value: Any, key: String) -> Data? {
        if let data = value as? Data { return imageData(data) }
        if let array = value as? [Data] {
            for data in array {
                if let image = imageData(data) { return image }
            }
        }
        if let array = value as? [Any] {
            for entry in array {
                if let image = imageData(from: entry, key: key) { return image }
            }
        }
        if key == "COVERART", let string = value as? String,
           let data = base64Data(string) {
            return imageData(data)
        }
        return nil
    }

    private static func base64Data(_ string: String) -> Data? {
        let cleaned = string.filter { !$0.isWhitespace }
        return Data(base64Encoded: cleaned)
    }

    private static func imageData(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(8))
        let isJPEG = bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
        let isPNG = bytes.count >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50
            && bytes[2] == 0x4E && bytes[3] == 0x47
        let isGIF = bytes.count >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46
        let isBMP = bytes.count >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D
        let isTIFF = bytes.count >= 4 && ((bytes[0] == 0x49 && bytes[1] == 0x49)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D))
        if isJPEG || isPNG || isGIF || isBMP || isTIFF { return data }
        if let payload = flacPicturePayload(data), let image = imageData(payload) {
            return image
        }
        return nil
    }

    /// Some metadata backends expose the raw FLAC picture block rather than
    /// decoded image bytes. Skip the type/MIME/description/dimensions prefix.
    private static func flacPicturePayload(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        func uint32(at offset: Int) -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
        }
        var offset = 0
        guard uint32(at: offset) != nil else { return nil }
        offset += 4
        guard let mimeLength = uint32(at: offset) else { return nil }
        offset += 4 + mimeLength
        guard let descriptionLength = uint32(at: offset) else { return nil }
        offset += 4 + descriptionLength + 16
        guard let dataLength = uint32(at: offset) else { return nil }
        offset += 4
        guard dataLength > 0, offset + dataLength <= bytes.count else { return nil }
        return Data(bytes[offset..<offset + dataLength])
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum LibraryScanner {
    static let supportedExtensions: Set<String> = [
        "flac", "mp3", "m4a", "wav", "aiff", "aif", "aifc", "ogg", "oga", "opus",
    ]

    static func scan(folders: [String],
                     known: [String: KnownFile] = [:],
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [ScannedTrack] {
        let pending = pendingFiles(folders: folders, known: known)
        progress?(0, pending.count)

        // AVAsset metadata loading is asynchronous. Process a small batch at a
        // time so a large MP3/M4A library does not create hundreds of parallel
        // AVURLAsset loaders. FLAC keeps its fast synchronous tag reader.
        var tracks: [ScannedTrack] = []
        let batchSize = 8
        var index = 0
        while index < pending.count {
            let end = Swift.min(index + batchSize, pending.count)
            let batch = Array(pending[index..<end])
            await withTaskGroup(of: ScannedTrack?.self) { group in
                for url in batch {
                    group.addTask {
                        if url.pathExtension.lowercased() == "flac" {
                            return FLACMetadataReader.read(url: url)
                        }
                        return await AVAssetMetadataReader.read(url: url)
                    }
                }
                for await track in group {
                    if let track { tracks.append(track) }
                }
            }
            index = end
            progress?(index, pending.count)
        }
        return tracks
    }

    /// DirectoryEnumerator's iterator must stay in a synchronous function; the
    /// Swift 6 concurrency checker rejects it in an async context.
    private static func pendingFiles(folders: [String],
                                     known: [String: KnownFile]) -> [URL] {
        let fileManager = FileManager.default
        var pending: [URL] = []

        for folder in folders {
            // Resolve symlinked library roots; FileManager's enumerator does
            // not descend into a symlink passed as its starting point.
            let folderURL = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
            guard let enumerator = fileManager.enumerator(at: folderURL,
                                                          includingPropertiesForKeys: [.isRegularFileKey,
                                                                                       .contentModificationDateKey,
                                                                                       .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                // Normalize the file URL as well: enumerating /tmp yields
                // /private/tmp paths, while the library/database root is
                // normalized to /tmp. Storing both spellings would create
                // duplicate rows after a library move.
                let normalizedURL = URL(fileURLWithPath: fileURL.path).resolvingSymlinksInPath()
                let storedPath = normalizedURL.path
                let values = try? normalizedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = Int64(values?.fileSize ?? 0)
                if let existing = known[storedPath] ?? known[fileURL.path],
                   abs(existing.mtime - mtime) < 1,
                   existing.size == size {
                    continue
                }
                pending.append(normalizedURL)
            }
        }
        return pending
    }

    static func stableUUID(_ string: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
