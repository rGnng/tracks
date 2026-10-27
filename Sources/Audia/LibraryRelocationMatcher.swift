import Foundation

struct LibrarySongPath: Sendable {
    let id: UUID
    let path: String
}

struct LibraryRelocationMatch: Sendable {
    let songPaths: [UUID: String]
    let unmatchedIDs: Set<UUID>
}

enum LibraryRelocationMatcher {
    static func match(oldRoot: String,
                      newRoot: String,
                      songs: [LibrarySongPath],
                      discoveredPaths: Set<String>) -> LibraryRelocationMatch {
        let old = canonicalPath(oldRoot)
        let new = canonicalPath(newRoot)
        let discovered = Set(discoveredPaths.map(canonicalPath))
        var matched: [UUID: String] = [:]

        for song in songs {
            let oldPath = canonicalPath(song.path)
            guard isUnder(oldPath, root: old) else { continue }
            var relative = String(oldPath.dropFirst(old.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            let candidate = canonicalPath(URL(fileURLWithPath: new)
                .appendingPathComponent(relative).path)
            if discovered.contains(candidate) {
                matched[song.id] = candidate
            }
        }

        let unmatched = Set(songs.map(\.id)).subtracting(matched.keys)
        return LibraryRelocationMatch(songPaths: matched, unmatchedIDs: unmatched)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isUnder(_ path: String, root: String) -> Bool {
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }
}
