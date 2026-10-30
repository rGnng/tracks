import SwiftUI

/// A request to select and reveal an album in the Albums grid. The unique
/// request ID lets repeated locations of the same album run again.
struct AlbumLocateRequest: Equatable, Identifiable {
    let id = UUID()
    let albumID: UUID
}

/// Cross-view navigation requests (e.g. "Go to Album" from the now playing
/// menu).
@MainActor
final class NavigationCenter: ObservableObject {
    static let shared = NavigationCenter()

    @Published var albumToOpen: UUID?
    /// Album to select and reveal without opening its detail.
    @Published var albumToLocate: AlbumLocateRequest?
    /// Artist name to select after switching to the Artists browser.
    @Published var artistToOpen: String?
    /// Sidebar section requested by a Library-only keyboard shortcut.
    @Published var sidebarSelection: SidebarSelection?

    /// Shows the Library window and opens the album detail view.
    func openAlbum(_ albumID: UUID) {
        albumToOpen = albumID
        WindowModeCenter.shared.setMode(.library)
    }

    /// Switches to Albums and asks the grid to select and reveal the album.
    func locateAlbum(_ albumID: UUID) {
        albumToLocate = AlbumLocateRequest(albumID: albumID)
        sidebarSelection = .library(.albums)
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
