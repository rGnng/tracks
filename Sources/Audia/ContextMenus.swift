import SwiftUI

/// Right-click menu shared by album cards, album rows and album sections.
struct AlbumContextMenu: ViewModifier {
    let album: Album

    @EnvironmentObject private var player: PlayerState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play") { player.play(album.songs) }
            Button("Shuffle") { player.playShuffled(album.songs) }
            Divider()
            AddToPlaylistMenu(songs: album.songs)
            Button("Play Next") { player.playNext(album.songs) }
            Button("Play Later") { player.playLater(album.songs) }
            CopyUUIDURLMenuItem(uuid: album.id)
            Button("Get Info…") {
                InfoCenter.shared.target = .album(album.id)
                openWindow(id: "get-info")
            }
        }
    }
}

/// Right-click menu for song rows.
struct SongContextMenu: ViewModifier {
    let song: Song
    let queue: [Song]
    var selection: [Song] = []

    private var targets: [Song] { selection.isEmpty ? [song] : selection }

    @EnvironmentObject private var player: PlayerState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play") {
                if selection.isEmpty {
                    player.play(song, in: queue)
                } else {
                    player.play(selection)
                }
            }
            Divider()
            AddToPlaylistMenu(songs: targets)
            Button("Play Next") { player.playNext(targets) }
            Button("Play Later") { player.playLater(targets) }
            CopyUUIDURLMenuItem(uuid: song.id)
            Button("Get Info…") {
                InfoCenter.shared.target = .song(song.id)
                openWindow(id: "get-info")
            }
        }
    }
}

extension View {
    func albumContextMenu(_ album: Album) -> some View {
        modifier(AlbumContextMenu(album: album))
    }

    func songContextMenu(_ song: Song, queue: [Song], selection: [Song] = []) -> some View {
        modifier(SongContextMenu(song: song, queue: queue, selection: selection))
    }
}
