#!/usr/bin/env swift
import Foundation
import AppKit

// Generates a sample library of silent FLAC files with tags and cover art.
// Usage: swift scripts/generate_library.swift [output-directory]

let rootPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/Music/Tracks Sample Library").expandingTildeInPath
let root = URL(fileURLWithPath: rootPath)
let fm = FileManager.default
try? fm.removeItem(at: root)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

let artists = [
    "Elena Voss", "Lunar Veil", "Mira Sol", "Copperfield", "Nova Reyes",
    "Fern & Fable", "Kai Drift", "The Paper Foxes", "Jonas Hale", "Aster Bloom",
    "Marisol", "Night Archive", "The Quiet Hours", "Sable Coast", "Iris North",
    "Ember & Ash", "Glass Atlas", "Rowan Pike", "Vela", "Tidal Theory"
]
let albums = [
    "Motion", "Paper Moons", "Sol y Sombra", "Static Bloom", "Afterlight",
    "Woodland Echoes", "Neon Reverie", "Gravity Well", "Saltwater", "Glass Cathedral",
    "Slow Cinema", "Amber Hours", "Velvet Static", "Northern Lines", "Hollow Sun",
    "Tidal", "Low Orbit", "Silver Lining", "Night Drive", "Soft Machines",
    "Copper Wire", "Distant Signals", "Sea Change", "Golden Hour", "Parallel Rails",
    "Quiet Noise", "Fever Dream", "Blue Hour", "Wildflower", "Signal Lost",
    "Ocean Floor", "Winter Light", "Paper Planes", "Echo Chamber", "Half Light",
    "Small Hours", "Open Roads", "City Lights", "Slow Burn", "Dust & Rain"
]
let genres = ["Electronic", "Indie Rock", "Ambient", "Folk", "Synthpop", "R&B", "Alternative", "Jazz", "Pop", "Downtempo"]
let words = [
    "Glass", "Neon", "Paper", "Static", "Golden", "Silver", "Velvet", "Electric",
    "Midnight", "Summer", "Winter", "Ocean", "Garden", "Shadow", "Light", "Slow",
    "Hidden", "Open", "Broken", "Endless", "Quiet", "Loud", "Distant", "Fading",
    "Crystal", "Marble", "River", "Mountain", "Copper", "Amber", "Violet", "Blue",
    "Wild", "Soft", "Hard", "City", "Country", "Northern", "Southern", "East"
]
let nouns = [
    "Facade", "Undertow", "Waves", "Sky", "Circuit", "Static", "Image", "Rails",
    "Heart", "Stars", "Light", "Moons", "Bloom", "Wire", "Frequency", "Radio",
    "Tide", "Echo", "Trail", "Echoes", "Song", "Lantern", "Hollow", "Wren",
    "Signal", "Prism", "Overdrive", "Wavelength", "Subsonic", "Aurora", "Grid",
    "Horizon", "Orbit", "Starfall", "Velocity", "Rain", "Driftwood", "Coral"
]

func be32(_ v: UInt32) -> [UInt8] {
    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}
func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
}
func be24(_ v: Int) -> [UInt8] {
    [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}
func le16(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8(v >> 8)]
}

func writeSilentWAV(seconds: Int, to url: URL) throws {
    let sampleRate = 44100
    let channels = 2
    let bits = 16
    let frameCount = sampleRate * seconds
    let dataSize = frameCount * channels * bits / 8
    var data: [UInt8] = []
    data += Array("RIFF".utf8)
    data += le32(UInt32(36 + dataSize))
    data += Array("WAVE".utf8)
    data += Array("fmt ".utf8)
    data += le32(16)
    data += le16(1)
    data += le16(UInt16(channels))
    data += le32(UInt32(sampleRate))
    data += le32(UInt32(sampleRate * channels * bits / 8))
    data += le16(UInt16(channels * bits / 8))
    data += le16(UInt16(bits))
    data += Array("data".utf8)
    data += le32(UInt32(dataSize))
    data += [UInt8](repeating: 0, count: dataSize)
    try Data(data).write(to: url)
}

func parseFLAC(_ data: Data) -> (streamInfo: [UInt8], frames: [UInt8])? {
    let bytes = [UInt8](data)
    guard bytes.count > 4, String(bytes: bytes[0..<4], encoding: .ascii) == "fLaC" else { return nil }
    var offset = 4
    var streamInfo: [UInt8]?
    while true {
        guard offset + 4 <= bytes.count else { return nil }
        let header = bytes[offset]
        offset += 1
        let isLast = header & 0x80 != 0
        let type = header & 0x7F
        let length = Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
        offset += 3
        guard offset + length <= bytes.count else { return nil }
        if type == 0 { streamInfo = Array(bytes[offset..<offset + length]) }
        offset += length
        if isLast { break }
    }
    guard let streamInfo else { return nil }
    return (streamInfo, Array(bytes[offset...]))
}

func makeTemplate(seconds: Int) -> (streamInfo: [UInt8], frames: [UInt8])? {
    let temp = FileManager.default.temporaryDirectory
    let wavURL = temp.appendingPathComponent("silence_\(seconds).wav")
    let flacURL = temp.appendingPathComponent("silence_\(seconds).flac")
    do {
        try writeSilentWAV(seconds: seconds, to: wavURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", wavURL.path, flacURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: flacURL) else { return nil }
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: flacURL)
        }
        return parseFLAC(data)
    } catch {
        return nil
    }
}

func makeCover(album: String, artist: String) -> Data {
    let size = 400
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let hue = CGFloat.random(in: 0...1)
    let c1 = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
    let c2 = NSColor(calibratedHue: (hue + 0.15).truncatingRemainder(dividingBy: 1),
                     saturation: 0.75, brightness: 0.35, alpha: 1)
    NSGradient(starting: c1, ending: c2)?.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                                               angle: CGFloat.random(in: -90...90))

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 34, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        .paragraphStyle: paragraph
    ]
    let artistAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 18, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.7)
    ]
    (album as NSString).draw(in: NSRect(x: 30, y: 90, width: size - 60, height: 120), withAttributes: titleAttrs)
    (artist as NSString).draw(in: NSRect(x: 30, y: 60, width: size - 60, height: 30), withAttributes: artistAttrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) ?? Data()
}

func block(_ type: UInt8, _ payload: [UInt8], last: Bool) -> [UInt8] {
    [last ? (0x80 | type) : type] + be24(payload.count) + payload
}

func streamInfo(duration: Double) -> [UInt8] {
    let sampleRate = 44100
    let channels = 2
    let bps = 16
    let total = UInt64(duration * Double(sampleRate))
    var bytes = [UInt8](repeating: 0, count: 34)
    bytes[0] = 0x10; bytes[1] = 0x00 // min block size 4096
    bytes[2] = 0x10; bytes[3] = 0x00 // max block size 4096
    bytes[10] = UInt8((sampleRate >> 12) & 0xFF)
    bytes[11] = UInt8((sampleRate >> 4) & 0xFF)
    let srLow = UInt8(sampleRate & 0xF)
    let chBits = UInt8((channels - 1) & 0x7)
    let bpsHigh = UInt8(((bps - 1) >> 4) & 0x1)
    bytes[12] = (srLow << 4) | (chBits << 1) | bpsHigh
    let bpsLow = UInt8(((bps - 1) & 0xF) << 4)
    let totalHigh = UInt8((total >> 32) & 0xF)
    bytes[13] = bpsLow | totalHigh
    bytes[14] = UInt8((total >> 24) & 0xFF)
    bytes[15] = UInt8((total >> 16) & 0xFF)
    bytes[16] = UInt8((total >> 8) & 0xFF)
    bytes[17] = UInt8(total & 0xFF)
    return bytes
}

func vorbisComments(_ tags: [(String, String)]) -> [UInt8] {
    var payload: [UInt8] = []
    let vendor = Array("Tracks".utf8)
    payload += le32(UInt32(vendor.count)) + vendor
    payload += le32(UInt32(tags.count))
    for (key, value) in tags {
        let bytes = Array("\(key)=\(value)".utf8)
        payload += le32(UInt32(bytes.count)) + bytes
    }
    return payload
}

func pictureBlock(_ image: Data) -> [UInt8] {
    var payload: [UInt8] = []
    payload += be32(3) // front cover
    let mime = Array("image/jpeg".utf8)
    payload += be32(UInt32(mime.count)) + mime
    payload += be32(0)
    payload += be32(400) + be32(400) + be32(24) + be32(0)
    payload += be32(UInt32(image.count)) + [UInt8](image)
    return payload
}

let durationChoices = [120, 150, 180, 210, 240, 270, 300, 330]
var templates: [(duration: Int, streamInfo: [UInt8], frames: [UInt8])] = []
for duration in durationChoices {
    if let template = makeTemplate(seconds: duration) {
        templates.append((duration, template.streamInfo, template.frames))
    }
}
print("Prepared \(templates.count) silent FLAC templates")

var createdAlbums = 0
var createdSongs = 0

for index in 0..<100 {
    let artist = artists.randomElement() ?? "Unknown Artist"
    let album = (albums.randomElement() ?? "Album") + " " + String(index + 1)
    let genre = genres.randomElement() ?? "Pop"
    let year = Int.random(in: 1995...2026)
    let trackCount = Int.random(in: 10...20)
    let cover = makeCover(album: album, artist: artist)

    let albumDir = root.appendingPathComponent(artist, isDirectory: true)
        .appendingPathComponent(album, isDirectory: true)
    try? fm.createDirectory(at: albumDir, withIntermediateDirectories: true)

    for track in 1...trackCount {
        let title = "\(words.randomElement() ?? "Untitled") \(nouns.randomElement() ?? "Song")"
        let duration = Double(Int.random(in: 120...330))
        let tags: [(String, String)] = [
            ("TITLE", title),
            ("ARTIST", artist),
            ("ALBUM", album),
            ("ALBUMARTIST", artist),
            ("GENRE", genre),
            ("DATE", String(year)),
            ("TRACKNUMBER", String(track)),
            ("TRACKTOTAL", String(trackCount))
        ]

        guard let template = templates.min(by: { abs($0.duration - Int(duration)) < abs($1.duration - Int(duration)) }) else { continue }
        var file: [UInt8] = Array("fLaC".utf8)
        file += block(0, template.streamInfo, last: false)
        file += block(4, vorbisComments(tags), last: false)
        file += block(6, pictureBlock(cover), last: true)
        file += template.frames

        let name = String(format: "%02d %@.flac", track, title)
        try? Data(file).write(to: albumDir.appendingPathComponent(name))
        createdSongs += 1
    }
    createdAlbums += 1
}

print("Generated \(createdAlbums) albums, \(createdSongs) songs at \(root.path)")
