import AppKit
import Combine
import MediaPlayer

/// Bridges Tracks playback to the macOS Now Playing center and media keys.
///
/// The system uses `MPNowPlayingInfoCenter` for Control Center, the Touch Bar,
/// and the lock screen-style media UI. `MPRemoteCommandCenter` delivers the
/// hardware media keys and the corresponding system transport commands.
@MainActor
final class SystemNowPlaying {
    static let shared = SystemNowPlaying()

    private weak var player: PlayerState?
    private var cancellables: Set<AnyCancellable> = []
    private var currentSongID: UUID?
    private var artworkKey: String?
    private var artworkData: Data?
    private var artworkTask: Task<Void, Never>?

    private init() {
        configureRemoteCommands()
    }

    func attach(to player: PlayerState) {
        guard self.player !== player else { return }
        self.player = player
        cancellables.removeAll()

        player.$currentIndex
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshTrack() }
            }
            .store(in: &cancellables)

        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            .store(in: &cancellables)

        player.$queue
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshTrack() }
            }
            .store(in: &cancellables)

        // The system extrapolates the elapsed time from the playback rate.
        // Periodic updates keep it exact after seeks without writing for every
        // 0.2-second timer tick.
        player.$elapsed
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
            .store(in: &cancellables)

        refreshTrack()
    }

    // MARK: Now Playing metadata

    private func refreshTrack() {
        guard let player else {
            currentSongID = nil
            artworkKey = nil
            artworkData = nil
            publish()
            return
        }

        guard let song = player.currentSong else {
            currentSongID = nil
            artworkKey = nil
            artworkData = nil
            artworkTask?.cancel()
            publish()
            return
        }

        if currentSongID != song.id {
            currentSongID = song.id
            loadArtwork(for: song)
        }
        publish()
    }

    private func loadArtwork(for song: Song) {
        let artwork = Library.shared.artwork(forAlbumTitle: song.album)
        let key: String
        if let cacheKey = artwork.cacheKey {
            key = cacheKey
        } else if let data = artwork.imageData {
            key = "inline-\(data.count)-\(data.hashValue)"
        } else {
            key = "album:\(song.album)"
        }
        guard key != artworkKey else { return }

        artworkKey = key
        artworkData = nil
        artworkTask?.cancel()

        let songID = song.id
        artworkTask = Task { @MainActor [weak self] in
            let data: Data?
            if let inline = artwork.imageData {
                data = inline
            } else if let cacheKey = artwork.cacheKey,
                      let albumID = UUID(uuidString: cacheKey) {
                data = await ArtworkCache.shared.fullData(albumID: albumID)
            } else {
                data = nil
            }
            guard let self, !Task.isCancelled else { return }
            guard self.player?.currentSong?.id == songID,
                  self.artworkKey == key else { return }
            self.artworkData = data
            self.publish()
        }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        guard let player, let song = player.currentSong else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        let duration = player.duration > 0 ? player.duration : song.duration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyAlbumArtist: song.albumArtist,
            MPMediaItemPropertyGenre: song.genre,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: player.queue.count,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: player.currentIndex ?? 0
        ]
        if let artworkData {
            // MPMediaItemArtwork calls this handler on a background queue.
            // Build the artwork in a nonisolated helper: this closure must not
            // inherit SystemNowPlaying's main-actor isolation.
            let size = NSImage(data: artworkData)?.size ?? NSSize(width: 512, height: 512)
            info[MPMediaItemPropertyArtwork] = Self.artwork(from: artworkData, size: size)
        }

        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    nonisolated private static func artwork(from data: Data, size: NSSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { _ in
            NSImage(data: data) ?? NSImage(size: size)
        }
    }

    // MARK: System media keys

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlePlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlePause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.player?.seek(toSeconds: event.positionTime) }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.seek(by: 15) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.seek(by: -15) }
            return .success
        }
    }

    private func handlePlay() {
        guard let player, !player.isPlaying else { return }
        if player.currentSong != nil {
            player.togglePlayPause()
        } else if !player.queue.isEmpty {
            player.playQueue(at: 0)
        }
    }

    private func handlePause() {
        guard let player, player.isPlaying else { return }
        player.togglePlayPause()
    }
}
