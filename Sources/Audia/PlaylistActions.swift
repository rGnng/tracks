import SwiftUI

/// Shared “Add to Playlist” submenu used by every context menu. The first item
/// creates a fresh playlist with a unique name, followed by the existing ones.
struct AddToPlaylistMenu: View {
    let songs: [Song]

    @ObservedObject private var library = Library.shared

    var body: some View {
        Menu("Add to Playlist") {
            Button("New Playlist") {
                let playlist = library.createPlaylistWithUniqueName()
                library.addToPlaylist(playlist.id, songs: songs)
            }
            .disabled(songs.isEmpty)

            Divider()

            if library.playlists.isEmpty {
                Text("No Playlists")
            } else {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        library.addToPlaylist(playlist.id, songs: songs)
                    }
                }
            }
        }
    }
}
