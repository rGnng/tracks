import SwiftUI

/// What the status bar should describe. Views update this as the user changes
/// the sidebar, album, artist, genre, playlist or song selection.
enum StatusContext: Equatable {
    case library
    case album(UUID)
    case albums([UUID])
    case artist(String)
    case genre(String)
    case playlist(UUID)
    case starred
    case tracks([UUID])
}

@MainActor
final class StatusBarCenter: ObservableObject {
    static let shared = StatusBarCenter()
    @Published var context: StatusContext = .library
}

struct StatusBarView: View {
    @EnvironmentObject private var player: PlayerState
    @ObservedObject private var library = Library.shared
    @ObservedObject private var status = StatusBarCenter.shared

    private var summary: String {
        switch status.context {
        case .tracks(let ids):
            let songs = ids.compactMap { library.song(withID: $0)?.song }
            return stats(for: songs)
        case .album(let id):
            return stats(for: library.album(withID: id)?.songs ?? library.allSongs)
        case .albums(let ids):
            let songs = ids.compactMap { library.album(withID: $0)?.songs }.flatMap { $0 }
            return stats(for: songs)
        case .artist(let name):
            return stats(for: library.albums.filter { $0.artist == name }.flatMap(\.songs))
        case .genre(let name):
            return stats(for: library.albums.filter { $0.genre == name }.flatMap(\.songs))
        case .playlist(let id):
            guard library.playlists.contains(where: { $0.id == id }) else {
                return stats(for: library.allSongs)
            }
            return stats(for: library.playlistSongs(id))
        case .starred:
            return stats(for: library.starredSongs)
        case .library:
            return stats(for: library.allSongs)
        }
    }

    private func stats(for songs: [Song]) -> String {
        let total = Int(songs.reduce(0) { $0 + $1.duration }.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let duration = h > 0 ? "\(h) hr \(m) min" : "\(m) min"
        let bytes = songs.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        let count = songs.count == 1 ? "1 item" : "\(songs.count) items"
        return "\(count), \(duration), \(formatSize(bytes))"
    }

    /// Decimal units, matching Finder's MB/GB labels (1 MB = 1,000,000 B).
    private func formatSize(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let kb = 1_000.0
        let mb = 1_000_000.0
        let gb = 1_000_000_000.0
        if value >= gb {
            return String(format: "%.1f GB", value / gb)
        }
        if value >= mb {
            return String(format: "%.1f MB", value / mb)
        }
        if value >= kb {
            return String(format: "%.0f KB", value / kb)
        }
        return "\(Int(value)) B"
    }

    var body: some View {
        ZStack {
            Text(summary)
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 40)

            HStack(spacing: 12) {
                Spacer()
                if player.currentSong != nil {
                    Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .background(Theme.toolbarBottom)
    }
}
