import AppKit
import SwiftUI

/// Confirmation and error UI for deleting library files. Only files belonging
/// to the Internal Library can be removed; the menu item is disabled otherwise.
@MainActor
enum LibraryDeletion {
    static func canDelete(songs: [Song]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { !Library.shared.isReadOnly(song: $0) }
    }

    static func canDelete(albums: [Album]) -> Bool {
        !albums.isEmpty && albums.allSatisfy { !Library.shared.isReadOnly(album: $0) }
    }

    static func confirmDelete(songs: [Song]) {
        let targets = uniqueSongs(songs)
        guard canDelete(songs: targets) else {
            presentNotInternalAlert()
            return
        }
        let title: String
        if targets.count == 1, let song = targets.first, !song.title.isEmpty {
            title = "Delete “\(song.title)”?"
        } else {
            title = "Delete \(targets.count) songs?"
        }
        let detail = targets.count == 1
            ? "The file will be moved to the Trash and removed from the Tracks library."
            : "\(targets.count) files will be moved to the Trash and removed from the Tracks library."
        confirm(title: title, detail: detail) {
            performDeletion(of: targets)
        }
    }

    static func confirmDelete(albums: [Album]) {
        let targets = albums
        guard canDelete(albums: targets) else {
            presentNotInternalAlert()
            return
        }
        let songs = uniqueSongs(targets.flatMap(\.songs))
        guard !songs.isEmpty else { return }

        let title: String
        if targets.count == 1, let album = targets.first {
            title = "Delete “\(album.title)”?"
        } else {
            title = "Delete \(targets.count) albums?"
        }
        let detail = songs.count == 1
            ? "The file will be moved to the Trash and removed from the Tracks library."
            : "\(songs.count) files will be moved to the Trash and removed from the Tracks library."
        confirm(title: title, detail: detail) {
            performDeletion(of: songs)
        }
    }

    private static func uniqueSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<UUID>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    private static func confirm(title: String, detail: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        // Make Cancel the default so Return never triggers deletion.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        action()
    }

    private static func performDeletion(of songs: [Song]) {
        let result = Library.shared.deleteSongs(songs)
        guard !result.failures.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Some files could not be moved to the Trash"
        alert.informativeText = result.failures.prefix(12).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentNotInternalAlert() {
        let alert = NSAlert()
        alert.messageText = "These items cannot be deleted"
        alert.informativeText = "Only files in the Internal Library can be moved to the Trash."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
