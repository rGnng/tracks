import SwiftUI

/// Cross-view navigation requests (e.g. "Go to Album" from the now playing
/// menu).
@MainActor
final class NavigationCenter: ObservableObject {
    static let shared = NavigationCenter()

    @Published var albumToOpen: UUID?
    /// Artist name to select after switching to the Artists browser.
    @Published var artistToOpen: String?
    /// Sidebar section requested by a Library-only keyboard shortcut.
    @Published var sidebarSelection: SidebarSelection?

    /// Shows the Library window and opens the album detail view.
    func openAlbum(_ albumID: UUID) {
        albumToOpen = albumID
        WindowModeCenter.shared.setMode(.library)
    }

    /// Opens the album containing the currently playing song.
    func openCurrentAlbum() {
        guard let song = PlayerState.shared.currentSong,
              let albumID = Library.shared.song(withID: song.id)?.album.id else {
            return
        }
        openAlbum(albumID)
    }
}
