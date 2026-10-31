import Foundation

/// Deterministic identity helpers shared by scanning and manual rekeying.
///
/// A library's `identifier` is user-editable, but `idNamespace` is the value
/// actually used for song UUIDs. The namespace changes only when the user
/// explicitly rekeys the library.
enum SongIdentity {
    static func normalizeIdentifier(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    static func normalizeName(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func normalizeRelativePath(_ raw: String) -> String {
        var value = raw.precomposedStringWithCanonicalMapping
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        return value
    }

    static func songID(namespace: String, relativePath: String) -> UUID {
        LibraryScanner.stableUUID(
            "song|" + normalizeIdentifier(namespace) + "|" + normalizeRelativePath(relativePath)
        )
    }

    static func artistID(name: String) -> UUID {
        LibraryScanner.stableUUID("artist|" + normalizeName(name))
    }

    static func albumID(artistID: String, title: String) -> UUID {
        LibraryScanner.stableUUID("album|" + artistID + "|" + normalizeName(title))
    }

    static func relativePath(filePath: String, libraryRoot: String) -> String? {
        let file = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: libraryRoot).resolvingSymlinksInPath().path
        guard isUnder(file, root: root) else { return nil }
        if file == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return normalizeRelativePath(String(file.dropFirst(prefix.count)))
    }

    private static func isUnder(_ path: String, root: String) -> Bool {
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }
}
