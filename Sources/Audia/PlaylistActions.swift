import SwiftUI

/// Shared “Add to Playlist” submenu used by every context menu. The first item
/// creates a fresh playlist with a unique name, followed by the existing ones.
///
/// The lazy initializer lets large list rows build their context menu without
/// resolving the selected songs. Resolving happens only when a playlist is
/// actually chosen, so a selection change does not re-evaluate every row.
struct AddToPlaylistMenu: View {
    private let songs: () -> [Song]
    private let isEmpty: Bool

    @ObservedObject private var library = Library.shared

    init(songs: [Song]) {
        self.songs = { songs }
        self.isEmpty = songs.isEmpty
    }

    init(lazySongs: @escaping () -> [Song]) {
        self.songs = lazySongs
        self.isEmpty = false
    }

    var body: some View {
        Menu("Add to Playlist") {
            Button("New Playlist") {
                let songs = songs()
                guard !songs.isEmpty else { return }
                let playlist = library.createPlaylistWithUniqueName()
                library.addToPlaylist(playlist.id, songs: songs)
            }
            .disabled(isEmpty)

            Divider()

            if library.playlists.isEmpty {
                Text("No Playlists")
            } else {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        let songs = songs()
                        guard !songs.isEmpty else { return }
                        library.addToPlaylist(playlist.id, songs: songs)
                    }
                }
            }
        }
    }
}
