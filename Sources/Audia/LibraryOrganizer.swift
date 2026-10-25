import Foundation

/// Shared naming rules for the Internal Library. MediaImporter and tag edits
/// both use these helpers so a saved file always lands in the canonical place.
enum LibraryOrganizer {
    static func safeComponent(_ raw: String, fallback: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if value.isEmpty || value == "." || value == ".." {
            value = fallback
        }
        if value.count > 180 {
            value = String(value.prefix(180)).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? fallback : value
    }

    static func paddedTrack(_ track: Int) -> String {
        let value = max(0, track)
        let digits = max(2, String(value).count)
        return String(format: "%0*d", digits, value)
    }

    static func filePrefix(track: Int, disc: Int) -> String {
        let track = paddedTrack(track)
        return disc > 0 ? "\(disc)-\(track)" : track
    }

    static func destination(albumArtist: String,
                            artist: String,
                            album: String,
                            title: String,
                            track: Int,
                            disc: Int,
                            extension ext: String,
                            musicRoot: URL) -> URL {
        let folderArtist = safeComponent(
            albumArtist.isEmpty ? artist : albumArtist,
            fallback: "Unknown Artist"
        )
        let folderAlbum = safeComponent(album, fallback: "Unknown Album")
        let fileArtist = safeComponent(
            artist.isEmpty ? albumArtist : artist,
            fallback: folderArtist
        )
        let fileTitle = safeComponent(title, fallback: "Untitled")
        let prefix = filePrefix(track: track, disc: disc)
        let filename = "\(prefix).\(fileTitle)-\(fileArtist).\(ext.lowercased())"

        return musicRoot
            .appendingPathComponent(folderArtist, isDirectory: true)
            .appendingPathComponent(folderAlbum, isDirectory: true)
            .appendingPathComponent(filename)
    }

    static func destination(for track: ScannedTrack, source: URL, musicRoot: URL) -> URL {
        let title = track.title.isEmpty
            ? source.deletingPathExtension().lastPathComponent
            : track.title
        return destination(albumArtist: track.albumArtist,
                           artist: track.artist,
                           album: track.album,
                           title: title,
                           track: track.track,
                           disc: track.discNumber,
                           extension: source.pathExtension,
                           musicRoot: musicRoot)
    }

    static func destination(for song: Song, musicRoot: URL) -> URL? {
        guard let url = song.fileURL else { return nil }
        return destination(albumArtist: song.albumArtist,
                           artist: song.artist,
                           album: song.album,
                           title: song.title,
                           track: song.trackNumber,
                           disc: song.discNumber,
                           extension: url.pathExtension,
                           musicRoot: musicRoot)
    }

    static func uniqueDestination(_ desired: URL) -> URL {
        let directory = desired.deletingLastPathComponent()
        let ext = desired.pathExtension
        let base = desired.deletingPathExtension().lastPathComponent
        var index = 2
        var candidate = desired
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(base) \(index)")
                .appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}
