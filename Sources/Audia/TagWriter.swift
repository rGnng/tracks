import Foundation
import AVFoundation

struct TagFields: Sendable {
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

enum TagWriterError: LocalizedError {
    case unsupported(String)
    case invalid(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return "Writing tags is not supported for .\(ext) files."
        case .invalid(let message):
            return "Could not update the audio file: \(message)"
        case .exportFailed(let message):
            return "Could not rewrite the M4A metadata: \(message)"
        }
    }
}

enum AudioTagWriter {
    static func write(_ fields: TagFields, to url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "flac":
            let data = try Data(contentsOf: url)
            let output = try FLACTagWriter.rewrite(data, fields: fields)
            try atomicWrite(output, to: url)
        case "mp3":
            let data = try Data(contentsOf: url)
            let output = ID3TagWriter.rewriteMP3(data, fields: fields)
            try atomicWrite(output, to: url)
        case "wav":
            let data = try Data(contentsOf: url)
            let output = try RIFFTagWriter.rewriteWAV(data, fields: fields)
            try atomicWrite(output, to: url)
        case "aiff", "aif", "aifc":
            let data = try Data(contentsOf: url)
            let output = try RIFFTagWriter.rewriteAIFF(data, fields: fields)
            try atomicWrite(output, to: url)
        case "m4a":
            try await M4ATagWriter.write(fields, to: url)
        case "ogg", "oga", "opus":
            let data = try Data(contentsOf: url)
            let output = try OggTagWriter.rewrite(data, fields: fields)
            try atomicWrite(output, to: url)
        default:
            throw TagWriterError.unsupported(ext)
        }
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    static func imageMime(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return "image/gif"
        }
        return "image/jpeg"
    }

    static func flacPictureBlock(_ image: Data) -> Data {
        var block = Data()
        appendUInt32BE(3, to: &block)                       // front cover
        let mime = Data(imageMime(image).utf8)
        appendUInt32BE(mime.count, to: &block)
        block.append(mime)
        appendUInt32BE(0, to: &block)                       // description
        appendUInt32BE(0, to: &block)                       // width
        appendUInt32BE(0, to: &block)                       // height
        appendUInt32BE(0, to: &block)                       // depth
        appendUInt32BE(0, to: &block)                       // colors
        appendUInt32BE(image.count, to: &block)
        block.append(image)
        return block
    }

    static func appendUInt32BE(_ value: Int, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func appendUInt32LE(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    static func uint32BE(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
    }

    static func uint32LE(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset])
            | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16
            | Int(bytes[offset + 3]) << 24
    }

    static func syncsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    static func syncsafeValue(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        return Int(bytes[offset] & 0x7F) << 21
            | Int(bytes[offset + 1] & 0x7F) << 14
            | Int(bytes[offset + 2] & 0x7F) << 7
            | Int(bytes[offset + 3] & 0x7F)
    }

    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - ID3 (MP3, WAV, AIFF)

enum ID3TagWriter {
    private struct Frame {
        let id: String
        let data: Data
    }

    private static let managedIDs: Set<String> = [
        "TIT2", "TPE1", "TPE2", "TALB", "TCON", "TDRC", "TYER", "TRCK", "TPOS",
        "COMM", "APIC", "TT2", "TP1", "TP2", "TAL", "TCO", "TYE", "TRK", "TPA", "PIC",
    ]

    static func rewriteMP3(_ data: Data, fields: TagFields) -> Data {
        let bytes = [UInt8](data)
        let parsed = parseTag(bytes)
        let oldFrames = parsed.frames
        let audioStart = parsed.audioStart
        let tag = makeTag(fields, preserving: oldFrames)
        var output = Data(tag)
        if audioStart < bytes.count {
            output.append(Data(bytes[audioStart...]))
        }
        return output
    }

    /// Builds an ID3v2.4 tag. The original tag's non-managed frames are
    /// preserved (including comments, ReplayGain and custom TXXX frames).
    static func makeTag(_ fields: TagFields, preserving oldFrames: [Data] = []) -> Data {
        var managed: [Frame] = []
        func text(_ id: String, _ value: String?) {
            guard let value = AudioTagWriter.text(value) else { return }
            managed.append(Frame(id: id, data: Data([0x03]) + Data(value.utf8)))
        }
        text("TIT2", fields.title)
        text("TPE1", fields.artist)
        text("TPE2", fields.albumArtist)
        text("TALB", fields.album)
        text("TCON", fields.genre)
        if let year = fields.year, !year.isEmpty { text("TDRC", year) }
        let track = fields.track ?? 0
        let trackTotal = fields.trackTotal ?? 0
        if track > 0 || trackTotal > 0 {
            text("TRCK", trackTotal > 0 ? "\(track)/\(trackTotal)" : "\(track)")
        }
        let disc = fields.discNumber ?? 0
        let discTotal = fields.discTotal ?? 0
        if disc > 0 || discTotal > 0 {
            text("TPOS", discTotal > 0 ? "\(disc)/\(discTotal)" : "\(disc)")
        }
        if let comments = AudioTagWriter.text(fields.comments) {
            var data = Data([0x03])
            data.append(Data("eng".utf8))
            data.append(0)
            data.append(Data(comments.utf8))
            managed.append(Frame(id: "COMM", data: data))
        }
        if let artwork = fields.artwork {
            var data = Data([0x03])
            data.append(Data(AudioTagWriter.imageMime(artwork).utf8))
            data.append(0)
            data.append(0x03)                                   // front cover
            data.append(0)                                      // description
            data.append(artwork)
            managed.append(Frame(id: "APIC", data: data))
        }

        var body = Data()
        for frame in managed {
            body.append(makeFrame(id: frame.id, data: frame.data))
        }
        for raw in oldFrames {
            guard let parsed = parseFrame(raw), !managedIDs.contains(parsed.id) else { continue }
            body.append(makeFrame(id: parsed.id, data: parsed.data))
        }

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [4, 0, 0])
        tag.append(AudioTagWriter.syncsafe(body.count))
        tag.append(body)
        return tag
    }

    static func preservedFrames(from tag: Data) -> [Data] {
        parseTag([UInt8](tag)).frames
    }

    private static func makeFrame(id: String, data: Data) -> Data {
        var frame = Data(id.utf8.prefix(4))
        while frame.count < 4 { frame.append(0) }
        frame.append(AudioTagWriter.syncsafe(data.count))
        frame.append(contentsOf: [0, 0])
        frame.append(data)
        return frame
    }

    private static func parseTag(_ bytes: [UInt8]) -> (audioStart: Int, frames: [Data]) {
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              let size = AudioTagWriter.syncsafeValue(bytes, 6) else {
            return (0, [])
        }
        let major = bytes[3]
        let flags = bytes[5]
        var audioStart = min(10 + size, bytes.count)
        if major == 4, flags & 0x10 != 0 { audioStart = min(audioStart + 10, bytes.count) }
        // Unsynchronization and extended headers make frame offsets nontrivial.
        // Replace the tag but don't try to preserve unknown frames.
        guard major >= 3, flags & 0x80 == 0, flags & 0x40 == 0 else {
            return (audioStart, [])
        }

        var offset = 10
        var frames: [Data] = []
        while offset + 10 <= audioStart {
            let idBytes = Array(bytes[offset..<offset + 4])
            if idBytes.allSatisfy({ $0 == 0 }) { break }
            let id = String(decoding: idBytes, as: UTF8.self)
            guard id.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil else { break }
            let size: Int
            if major == 4 {
                guard let s = AudioTagWriter.syncsafeValue(bytes, offset + 4) else { break }
                size = s
            } else {
                guard let s = AudioTagWriter.uint32BE(bytes, offset + 4) else { break }
                size = s
            }
            let frameFlags = (Int(bytes[offset + 8]) << 8) | Int(bytes[offset + 9])
            let end = offset + 10 + size
            guard size >= 0, end <= audioStart else { break }
            if frameFlags == 0 {
                frames.append(Data(bytes[offset..<end]))
            }
            offset = end
        }
        return (audioStart, frames)
    }

    private static func parseFrame(_ raw: Data) -> (id: String, data: Data)? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 10, let size = AudioTagWriter.syncsafeValue(bytes, 4) else { return nil }
        guard 10 + size <= bytes.count else { return nil }
        let id = String(decoding: bytes[0..<4], as: UTF8.self)
        return (id, Data(bytes[10..<10 + size]))
    }
}

// MARK: - FLAC

enum FLACTagWriter {
    private static let managedKeys: Set<String> = [
        "TITLE", "ARTIST", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST",
        "ALBUM", "GENRE", "DATE", "YEAR", "TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS",
        "DISCNUMBER", "DISC", "DISCTOTAL", "TOTALDISCS",
        "COMMENT", "COMMENTS", "DESCRIPTION",
        "COVERART", "COVERARTMIME", "METADATA_BLOCK_PICTURE",
    ]

    static func rewrite(_ data: Data, fields: TagFields) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            throw TagWriterError.invalid("not a FLAC stream")
        }

        var blocks: [(type: UInt8, data: Data)] = []
        var offset = 4
        var audioStart: Int?
        var vendor = "Tracks"
        var oldComments: [(String, String)] = []

        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let type = header & 0x7F
            let last = header & 0x80 != 0
            let length = Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard length >= 0, offset + length <= bytes.count else {
                throw TagWriterError.invalid("truncated metadata block")
            }
            let block = Data(bytes[offset..<offset + length])
            switch type {
            case 0:
                blocks.append((0, block))
            case 4:
                if let parsed = parseVorbisComment(block) {
                    vendor = parsed.vendor.isEmpty ? vendor : parsed.vendor
                    oldComments = parsed.entries
                }
            case 6:
                break                                           // replaced below
            default:
                blocks.append((type, block))
            }
            offset += length
            if last {
                audioStart = offset
                break
            }
        }

        guard let audioStart, blocks.contains(where: { $0.type == 0 }) else {
            throw TagWriterError.invalid("missing STREAMINFO")
        }

        var entries = oldComments.filter { key, _ in
            !managedKeys.contains(key.uppercased())
        }
        addFields(fields, to: &entries)
        let comment = makeVorbisComment(vendor: vendor, entries: entries, framing: false)
        blocks.append((4, comment))
        if let artwork = fields.artwork {
            blocks.append((6, AudioTagWriter.flacPictureBlock(artwork)))
        }

        var output = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            guard block.data.count < 0x1000000 else {
                throw TagWriterError.invalid("metadata block is too large")
            }
            let last = index == blocks.count - 1
            output.append(UInt8((last ? 0x80 : 0) | (block.type & 0x7F)))
            output.append(UInt8((block.data.count >> 16) & 0xFF))
            output.append(UInt8((block.data.count >> 8) & 0xFF))
            output.append(UInt8(block.data.count & 0xFF))
            output.append(block.data)
        }
        output.append(Data(bytes[audioStart...]))
        return output
    }

    private static func parseVorbisComment(_ data: Data) -> (vendor: String, entries: [(String, String)])? {
        let bytes = [UInt8](data)
        var offset = 0
        guard let vendorLength = AudioTagWriter.uint32LE(bytes, offset),
              offset + 4 + vendorLength <= bytes.count else { return nil }
        offset += 4
        let vendor = String(decoding: bytes[offset..<offset + vendorLength], as: UTF8.self)
        offset += vendorLength
        guard let count = AudioTagWriter.uint32LE(bytes, offset),
              offset + 4 <= bytes.count else { return nil }
        offset += 4
        var entries: [(String, String)] = []
        for _ in 0..<count {
            guard let length = AudioTagWriter.uint32LE(bytes, offset),
                  offset + 4 + length <= bytes.count else { break }
            offset += 4
            let value = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
            offset += length
            if let separator = value.firstIndex(of: "=") {
                entries.append((String(value[..<separator]), String(value[value.index(after: separator)...])))
            }
        }
        return (vendor, entries)
    }

    private static func makeVorbisComment(vendor: String,
                                          entries: [(String, String)],
                                          framing: Bool) -> Data {
        var data = Data()
        let vendorData = Data(vendor.utf8)
        AudioTagWriter.appendUInt32LE(vendorData.count, to: &data)
        data.append(vendorData)
        AudioTagWriter.appendUInt32LE(entries.count, to: &data)
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8)
            AudioTagWriter.appendUInt32LE(entry.count, to: &data)
            data.append(entry)
        }
        if framing { data.append(0x01) }
        return data
    }

    private static func addFields(_ fields: TagFields, to entries: inout [(String, String)]) {
        func add(_ key: String, _ value: String?) {
            guard let value = AudioTagWriter.text(value) else { return }
            entries.append((key, value))
        }
        add("TITLE", fields.title)
        add("ARTIST", fields.artist)
        add("ALBUMARTIST", fields.albumArtist)
        add("ALBUM", fields.album)
        add("GENRE", fields.genre)
        if let year = fields.year, !year.isEmpty { add("DATE", year) }
        if let track = fields.track, track > 0 { add("TRACKNUMBER", String(track)) }
        if let total = fields.trackTotal, total > 0 { add("TRACKTOTAL", String(total)) }
        if let disc = fields.discNumber, disc > 0 { add("DISCNUMBER", String(disc)) }
        if let total = fields.discTotal, total > 0 { add("DISCTOTAL", String(total)) }
        add("COMMENT", fields.comments)
    }
}

// MARK: - WAV / AIFF

enum RIFFTagWriter {
    static func rewriteWAV(_ data: Data, fields: TagFields) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
              bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 else {
            throw TagWriterError.invalid("not a RIFF/WAVE file")
        }
        var output = Data()
        output.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        output.append(Data(repeating: 0, count: 4))
        output.append(contentsOf: [0x57, 0x41, 0x56, 0x45])

        var offset = 12
        var existingID3: Data?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            guard let size = AudioTagWriter.uint32LE(bytes, offset + 4) else { break }
            let bodyStart = offset + 8
            let bodyEnd = bodyStart + size
            guard size >= 0, bodyEnd <= bytes.count else { break }
            if id.uppercased() == "ID3 " || id == "ID3\u{0}" {
                existingID3 = Data(bytes[bodyStart..<bodyEnd])
            } else {
                output.append(contentsOf: bytes[offset..<bodyStart])
                output.append(contentsOf: bytes[bodyStart..<bodyEnd])
                if size.isMultiple(of: 2) == false { output.append(0) }
            }
            offset = bodyEnd + (size % 2)
        }

        let tag = ID3TagWriter.makeTag(fields, preserving: oldFrames(from: existingID3))
        output.append(Data("ID3 ".utf8))
        AudioTagWriter.appendUInt32LE(tag.count, to: &output)
        output.append(tag)
        if tag.count % 2 != 0 { output.append(0) }

        let riffSize = output.count - 8
        output.replaceSubrange(4..<8, with: Data([
            UInt8(riffSize & 0xFF),
            UInt8((riffSize >> 8) & 0xFF),
            UInt8((riffSize >> 16) & 0xFF),
            UInt8((riffSize >> 24) & 0xFF),
        ]))
        return output
    }

    static func rewriteAIFF(_ data: Data, fields: TagFields) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0] == 0x46, bytes[1] == 0x4F, bytes[2] == 0x52, bytes[3] == 0x4D else {
            throw TagWriterError.invalid("not an AIFF file")
        }
        var output = Data()
        output.append(contentsOf: [0x46, 0x4F, 0x52, 0x4D])
        output.append(Data(repeating: 0, count: 4))
        output.append(contentsOf: bytes[8..<12])

        var offset = 12
        var existingID3: Data?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            guard let size = AudioTagWriter.uint32BE(bytes, offset + 4) else { break }
            let bodyStart = offset + 8
            let bodyEnd = bodyStart + size
            guard size >= 0, bodyEnd <= bytes.count else { break }
            if id.uppercased() == "ID3 " || id == "ID3\u{0}" {
                existingID3 = Data(bytes[bodyStart..<bodyEnd])
            } else {
                output.append(contentsOf: bytes[offset..<bodyStart])
                output.append(contentsOf: bytes[bodyStart..<bodyEnd])
                if size % 2 != 0 { output.append(0) }
            }
            offset = bodyEnd + (size % 2)
        }

        let tag = ID3TagWriter.makeTag(fields, preserving: oldFrames(from: existingID3))
        output.append(Data("ID3 ".utf8))
        AudioTagWriter.appendUInt32BE(tag.count, to: &output)
        output.append(tag)
        if tag.count % 2 != 0 { output.append(0) }

        let formSize = output.count - 8
        output.replaceSubrange(4..<8, with: Data([
            UInt8((formSize >> 24) & 0xFF),
            UInt8((formSize >> 16) & 0xFF),
            UInt8((formSize >> 8) & 0xFF),
            UInt8(formSize & 0xFF),
        ]))
        return output
    }

    private static func oldFrames(from tag: Data?) -> [Data] {
        guard let tag else { return [] }
        return ID3TagWriter.preservedFrames(from: tag)
    }
}

// MARK: - OGG / Opus

enum OggTagWriter {
    private struct Page {
        var headerType: UInt8
        var granule: UInt64
        var serial: UInt32
        var sequence: UInt32
        var segments: [UInt8]
        var data: Data
    }

    private struct Packet {
        var data: Data
        var endPage: Int
    }

    private static let managedKeys: Set<String> = [
        "TITLE", "ARTIST", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST",
        "ALBUM", "GENRE", "DATE", "YEAR", "TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS",
        "DISCNUMBER", "DISC", "DISCTOTAL", "TOTALDISCS",
        "COMMENT", "COMMENTS", "DESCRIPTION",
        "COVERART", "COVERARTMIME", "METADATA_BLOCK_PICTURE",
    ]

    static func rewrite(_ data: Data, fields: TagFields) throws -> Data {
        let bytes = [UInt8](data)
        let pages = try parsePages(bytes)
        guard pages.count >= 2 else { throw TagWriterError.invalid("too few Ogg pages") }
        let packets = parsePackets(pages)
        guard packets.count >= 2 else { throw TagWriterError.invalid("missing Ogg headers") }

        let first = [UInt8](packets[0].data.prefix(8))
        let isVorbis = first.count >= 7 && first[0] == 0x01
            && String(decoding: first[1..<7], as: UTF8.self) == "vorbis"
        let isOpus = first.count >= 8 && String(decoding: first[0..<8], as: UTF8.self) == "OpusHead"
        guard isVorbis || isOpus else { throw TagWriterError.invalid("unsupported Ogg codec") }

        let headerCount = isVorbis ? 3 : 2
        guard packets.count >= headerCount else { throw TagWriterError.invalid("missing Ogg header packets") }
        let lastHeaderPage = packets[headerCount - 1].endPage
        let firstAudioPage = lastHeaderPage + 1
        guard firstAudioPage < pages.count else { throw TagWriterError.invalid("no Ogg audio pages") }

        let prefix = isVorbis ? Data([0x03]) + Data("vorbis".utf8) : Data("OpusTags".utf8)
        let commentPacket = packets[1].data
        guard commentPacket.starts(with: prefix) else {
            throw TagWriterError.invalid("missing Ogg comment header")
        }
        let parsed = parseComment(commentPacket.dropFirst(prefix.count), framing: isVorbis)
        var entries = parsed.entries.filter { key, _ in
            !managedKeys.contains(key.uppercased())
        }
        addFields(fields, to: &entries)
        if let artwork = fields.artwork {
            let block = AudioTagWriter.flacPictureBlock(artwork)
            entries.append(("METADATA_BLOCK_PICTURE", block.base64EncodedString()))
        }
        let newComment = prefix + makeComment(vendor: parsed.vendor,
                                              entries: entries,
                                              framing: isVorbis)

        let serial = pages[0].serial
        var sequence: UInt32 = 0
        var output = Data()
        output.append(makePacketPages(packet: packets[0].data,
                                      headerType: 0x02,
                                      serial: serial,
                                      sequence: &sequence))
        output.append(makePacketPages(packet: newComment,
                                      headerType: 0,
                                      serial: serial,
                                      sequence: &sequence))
        if isVorbis {
            output.append(makePacketPages(packet: packets[2].data,
                                          headerType: 0,
                                          serial: serial,
                                          sequence: &sequence))
        }

        for page in pages[firstAudioPage...] {
            output.append(makePage(headerType: page.headerType,
                                   granule: page.granule,
                                   serial: serial,
                                   sequence: sequence,
                                   segments: page.segments,
                                   data: page.data))
            sequence &+= 1
        }
        return output
    }

    private static func parsePages(_ bytes: [UInt8]) throws -> [Page] {
        var pages: [Page] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + 27 <= bytes.count,
                  bytes[offset] == 0x4F, bytes[offset + 1] == 0x67,
                  bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                throw TagWriterError.invalid("bad Ogg page")
            }
            let headerType = bytes[offset + 5]
            var granule: UInt64 = 0
            for index in 0..<8 {
                granule |= UInt64(bytes[offset + 6 + index]) << (8 * UInt64(index))
            }
            var serial: UInt32 = 0
            for index in 0..<4 {
                serial |= UInt32(bytes[offset + 14 + index]) << (8 * UInt32(index))
            }
            var sequence: UInt32 = 0
            for index in 0..<4 {
                sequence |= UInt32(bytes[offset + 18 + index]) << (8 * UInt32(index))
            }
            let segmentCount = Int(bytes[offset + 26])
            guard offset + 27 + segmentCount <= bytes.count else {
                throw TagWriterError.invalid("truncated Ogg segment table")
            }
            let segments = Array(bytes[offset + 27..<offset + 27 + segmentCount])
            let dataStart = offset + 27 + segmentCount
            let dataLength = segments.reduce(0) { $0 + Int($1) }
            guard dataStart + dataLength <= bytes.count else {
                throw TagWriterError.invalid("truncated Ogg page data")
            }
            pages.append(Page(headerType: headerType,
                              granule: granule,
                              serial: serial,
                              sequence: sequence,
                              segments: segments,
                              data: Data(bytes[dataStart..<dataStart + dataLength])))
            offset = dataStart + dataLength
        }
        return pages
    }

    private static func parsePackets(_ pages: [Page]) -> [Packet] {
        var packets: [Packet] = []
        var current = Data()
        for (pageIndex, page) in pages.enumerated() {
            var dataOffset = 0
            for segment in page.segments {
                let length = Int(segment)
                if length > 0 {
                    current.append(page.data[dataOffset..<dataOffset + length])
                }
                dataOffset += length
                if segment < 255 {
                    packets.append(Packet(data: current, endPage: pageIndex))
                    current = Data()
                }
            }
        }
        return packets
    }

    private static func parseComment(_ body: Data.SubSequence,
                                     framing: Bool) -> (vendor: String, entries: [(String, String)]) {
        let bytes = [UInt8](body)
        var offset = 0
        let vendor: String
        if let length = AudioTagWriter.uint32LE(bytes, offset),
           offset + 4 + length <= bytes.count {
            offset += 4
            vendor = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
            offset += length
        } else {
            vendor = "Tracks"
        }
        var entries: [(String, String)] = []
        if let count = AudioTagWriter.uint32LE(bytes, offset), offset + 4 <= bytes.count {
            offset += 4
            for _ in 0..<count {
                guard let length = AudioTagWriter.uint32LE(bytes, offset),
                      offset + 4 + length <= bytes.count else { break }
                offset += 4
                let value = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
                offset += length
                if let separator = value.firstIndex(of: "=") {
                    entries.append((String(value[..<separator]),
                                    String(value[value.index(after: separator)...])))
                }
            }
        }
        _ = framing
        return (vendor.isEmpty ? "Tracks" : vendor, entries)
    }

    private static func makeComment(vendor: String,
                                    entries: [(String, String)],
                                    framing: Bool) -> Data {
        var data = Data()
        let vendorData = Data(vendor.utf8)
        AudioTagWriter.appendUInt32LE(vendorData.count, to: &data)
        data.append(vendorData)
        AudioTagWriter.appendUInt32LE(entries.count, to: &data)
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8)
            AudioTagWriter.appendUInt32LE(entry.count, to: &data)
            data.append(entry)
        }
        if framing { data.append(0x01) }
        return data
    }

    private static func addFields(_ fields: TagFields, to entries: inout [(String, String)]) {
        func add(_ key: String, _ value: String?) {
            guard let value = AudioTagWriter.text(value) else { return }
            entries.append((key, value))
        }
        add("TITLE", fields.title)
        add("ARTIST", fields.artist)
        add("ALBUMARTIST", fields.albumArtist)
        add("ALBUM", fields.album)
        add("GENRE", fields.genre)
        if let year = fields.year, !year.isEmpty { add("DATE", year) }
        if let track = fields.track, track > 0 { add("TRACKNUMBER", String(track)) }
        if let total = fields.trackTotal, total > 0 { add("TRACKTOTAL", String(total)) }
        if let disc = fields.discNumber, disc > 0 { add("DISCNUMBER", String(disc)) }
        if let total = fields.discTotal, total > 0 { add("DISCTOTAL", String(total)) }
        add("COMMENT", fields.comments)
    }

    private static func makePacketPages(packet: Data,
                                        headerType: UInt8,
                                        serial: UInt32,
                                        sequence: inout UInt32) -> Data {
        var segments: [UInt8] = []
        var remaining = packet.count
        while remaining >= 255 {
            segments.append(255)
            remaining -= 255
        }
        segments.append(UInt8(remaining))
        if packet.isEmpty { segments = [0] }

        var output = Data()
        var dataOffset = 0
        var segmentIndex = 0
        var firstChunk = true
        while segmentIndex < segments.count {
            let end = Swift.min(segmentIndex + 255, segments.count)
            let chunk = Array(segments[segmentIndex..<end])
            let length = chunk.reduce(0) { $0 + Int($1) }
            let data = packet.subdata(in: dataOffset..<dataOffset + length)
            let type: UInt8
            if firstChunk {
                type = headerType
            } else {
                type = 0x01
            }
            output.append(makePage(headerType: type,
                                   granule: 0,
                                   serial: serial,
                                   sequence: sequence,
                                   segments: chunk,
                                   data: data))
            sequence &+= 1
            dataOffset += length
            segmentIndex = end
            firstChunk = false
        }
        return output
    }

    private static func makePage(headerType: UInt8,
                                 granule: UInt64,
                                 serial: UInt32,
                                 sequence: UInt32,
                                 segments: [UInt8],
                                 data: Data) -> Data {
        var page = Data("OggS".utf8)
        page.append(0)
        page.append(headerType)
        for index in 0..<8 { page.append(UInt8((granule >> (8 * UInt64(index))) & 0xFF)) }
        for index in 0..<4 { page.append(UInt8((serial >> (8 * UInt32(index))) & 0xFF)) }
        for index in 0..<4 { page.append(UInt8((sequence >> (8 * UInt32(index))) & 0xFF)) }
        page.append(contentsOf: [0, 0, 0, 0])
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(data)
        let checksum = oggCRC([UInt8](page))
        page[22] = UInt8(checksum & 0xFF)
        page[23] = UInt8((checksum >> 8) & 0xFF)
        page[24] = UInt8((checksum >> 16) & 0xFF)
        page[25] = UInt8((checksum >> 24) & 0xFF)
        return page
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value) << 24
        for _ in 0..<8 {
            crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : (crc << 1)
        }
        return crc
    }

    private static func oggCRC(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(byte)) & 0xFF]
        }
        return crc
    }
}

// MARK: - M4A

enum M4ATagWriter {
    static func write(_ fields: TagFields, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw TagWriterError.exportFailed("AVAssetExportSession could not be created")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tracks-tag-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: temp)
        session.shouldOptimizeForNetworkUse = false
        session.metadata = metadataItems(fields)
        do {
            try await session.export(to: temp, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagWriterError.exportFailed(error.localizedDescription)
        }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private static func metadataItems(_ fields: TagFields) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ key: String, _ value: Any) {
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = key as NSString
            item.value = value as? NSCopying & NSObjectProtocol
            items.append(item)
        }
        if let title = AudioTagWriter.text(fields.title) { add("©nam", title as NSString) }
        if let artist = AudioTagWriter.text(fields.artist) { add("©ART", artist as NSString) }
        if let albumArtist = AudioTagWriter.text(fields.albumArtist) { add("aART", albumArtist as NSString) }
        if let album = AudioTagWriter.text(fields.album) { add("©alb", album as NSString) }
        if let genre = AudioTagWriter.text(fields.genre) { add("©gen", genre as NSString) }
        if let year = fields.year, !year.isEmpty { add("©day", year as NSString) }
        let track = fields.track ?? 0
        let trackTotal = fields.trackTotal ?? 0
        if track > 0 || trackTotal > 0 {
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes[2] = UInt8((track >> 8) & 0xFF)
            bytes[3] = UInt8(track & 0xFF)
            bytes[4] = UInt8((trackTotal >> 8) & 0xFF)
            bytes[5] = UInt8(trackTotal & 0xFF)
            add("trkn", Data(bytes) as NSData)
        }
        let disc = fields.discNumber ?? 0
        let discTotal = fields.discTotal ?? 0
        if disc > 0 || discTotal > 0 {
            var bytes = [UInt8](repeating: 0, count: 6)
            bytes[2] = UInt8((disc >> 8) & 0xFF)
            bytes[3] = UInt8(disc & 0xFF)
            bytes[4] = UInt8((discTotal >> 8) & 0xFF)
            bytes[5] = UInt8(discTotal & 0xFF)
            add("disk", Data(bytes) as NSData)
        }
        if let comments = AudioTagWriter.text(fields.comments) {
            add("©cmt", comments as NSString)
        }
        if let artwork = fields.artwork {
            add("covr", artwork as NSData)
        }
        return items
    }
}
