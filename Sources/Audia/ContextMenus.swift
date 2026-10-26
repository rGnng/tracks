import SwiftUI

/// Right-click menu shared by album cards, album rows and album sections.
struct AlbumContextMenu: ViewModifier {
    let album: Album

    @EnvironmentObject private var player: PlayerState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.appContextMenu {
            [
                .action("Play") { player.play(album.songs) },
                .action("Shuffle") { player.playShuffled(album.songs) },
                .separator,
            ] + addToPlaylistMenuItems(songs: album.songs) + [
                .action("Play Next") { player.playNext(album.songs) },
                .action("Play Later") { player.playLater(album.songs) },
                .separator,
                .action("Get Info…") {
                    InfoCenter.shared.target = .album(album.id)
                    openWindow(id: "get-info")
                },
                .separator,
                .action("Delete…",
                        enabled: LibraryDeletion.canDelete(albums: [album]),
                        destructive: true) {
                    LibraryDeletion.confirmDelete(albums: [album])
                },
            ]
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
        content.appContextMenu {
            [
                .action("Play") {
                    if selection.isEmpty {
                        player.play(song, in: queue)
                    } else {
                        player.play(selection)
                    }
                },
                .separator,
            ] + addToPlaylistMenuItems(songs: targets) + [
                .action("Play Next") { player.playNext(targets) },
                .action("Play Later") { player.playLater(targets) },
                .separator,
                .action("Get Info…") {
                    InfoCenter.shared.target = .song(song.id)
                    openWindow(id: "get-info")
                },
                .separator,
                .action("Delete…",
                        enabled: LibraryDeletion.canDelete(songs: targets),
                        destructive: true) {
                    LibraryDeletion.confirmDelete(songs: targets)
                },
            ]
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
