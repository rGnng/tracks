import Foundation

struct LibrarySongPath: Sendable {
    let id: UUID
    let path: String
}

struct LibraryRelocationMatch: Sendable {
    /// New absolute path for every stored song under the old root, including
    /// missing files that the user chooses to keep.
    let songPaths: [UUID: String]
    let matchedIDs: Set<UUID>
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
        var relocated: [UUID: String] = [:]
        var matched = Set<UUID>()

        for song in songs {
            let oldPath = canonicalPath(song.path)
            guard isUnder(oldPath, root: old) else { continue }
            var relative = String(oldPath.dropFirst(old.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            let candidate = canonicalPath(URL(fileURLWithPath: new)
                .appendingPathComponent(relative).path)
            relocated[song.id] = candidate
            if discovered.contains(candidate) {
                matched.insert(song.id)
            }
        }

        let unmatched = Set(songs.map(\.id)).subtracting(matched)
        return LibraryRelocationMatch(songPaths: relocated,
                                      matchedIDs: matched,
                                      unmatchedIDs: unmatched)
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
