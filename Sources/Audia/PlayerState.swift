import SwiftUI
import Combine
import AVFoundation

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one
}

/// Shared playback state and audio engine.
///
/// Tracks that come from the file-based library carry a `fileURL` and are played
/// with `AVPlayer`. On macOS AVPlayer exposes `audioOutputDeviceUniqueID`, which
/// lets playback follow the device chosen in the Output Device menu. Library
/// entries without a decodable file fall back to simulated transport so the UI
/// still works.
@MainActor
final class PlayerState: ObservableObject {
    static let shared = PlayerState()

    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int?
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var volume: Double = 0.65
    /// While MPD owns the system volume, AVPlayer stays at 100% and the app's
    /// volume controls are locked.
    @Published private(set) var isVolumeLocked = false
    @Published private(set) var isSystemMuted = false
    @Published private(set) var isShuffleOn = false
    @Published private(set) var repeatMode: RepeatMode = .off
    /// Most-recent-first play history, independent of the active queue.
    @Published private(set) var history: [Song] = []

    /// The queue in the order the user started it. Toggling shuffle off restores
    /// this order while keeping the current track at its original position.
    private var baseQueue: [Song] = []
    private var historyIDs: [UUID] = []

    private static let shuffleDefaultsKey = "player.shuffleEnabled"
    private static let repeatDefaultsKey = "player.repeatMode"
    private static let historyDefaultsKey = "player.historyIDs"
    private static let volumeDefaultsKey = "player.volume"
    private static let volumeBeforeSystemControlKey = "player.volumeBeforeSystemControl"
    private static let historyLimit = 50

    private var avPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timer: Timer?
    private var volumeBeforeMute: Double = 0.65
    private var volumeBeforeSystemControl: Double = 0.65
    private var systemVolumeBeforeMute: Double = 0.5
    private var deviceCancellable: AnyCancellable?
    /// While the seek bar is being dragged, don't let the timer overwrite the
    /// dragged position with AVPlayer's still-old current time.
    private var seekGraceUntil: Date?

    private init() {
        isShuffleOn = UserDefaults.standard.bool(forKey: Self.shuffleDefaultsKey)
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: Self.repeatDefaultsKey) ?? "") ?? .off
        historyIDs = (UserDefaults.standard.stringArray(forKey: Self.historyDefaultsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
        let storedVolume = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) as? Double
        volume = min(max(storedVolume ?? 0.65, 0), 1)
        if SystemVolume.isEnabled {
            let storedBefore = UserDefaults.standard.object(forKey: Self.volumeBeforeSystemControlKey) as? Double
            volumeBeforeSystemControl = min(max(storedBefore ?? (volume > 0 ? volume : 0.65), 0), 1)
            isVolumeLocked = true
            volume = 1
            let currentSystem = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? 0
            isSystemMuted = currentSystem <= 0
            if currentSystem > 0 { systemVolumeBeforeMute = currentSystem }
        }
        volumeBeforeMute = volume > 0 ? volume : 0.65

        // Keep the current player on the device selected in the toolbar menu.
        deviceCancellable = AudioDevices.shared.$selectedUID
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyOutputDevice() }
            }
    }

    var currentSong: Song? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    /// Songs still queued after the current track.
    var upNext: [Song] {
        guard let i = currentIndex, queue.indices.contains(i) else { return [] }
        return Array(queue.dropFirst(i + 1))
    }


    /// Drops everything after the current track, keeping the current song.
    func clearUpNext() {
        guard let i = currentIndex, queue.indices.contains(i) else { return }
        let keptIDs = Set(queue.prefix(i + 1).map(\.id))
        queue = Array(queue.prefix(i + 1))
        // Keep the normal-order copy in sync so disabling shuffle later does
        // not resurrect tracks the user just cleared.
        baseQueue = baseQueue.filter { keptIDs.contains($0.id) }
    }

    /// Stops playback and forgets the queue. Used when switching libraries.
    func stopAndClear() {
        releasePlayer()
        stopTimer()
        queue = []
        baseQueue = []
        currentIndex = nil
        isPlaying = false
        elapsed = 0
    }

    var duration: TimeInterval {
        if let seconds = avPlayer?.currentItem?.duration.seconds,
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }
        return currentSong?.duration ?? 0
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var isMuted: Bool { volume == 0 }

    /// The mute state the volume UI should display. In system-volume mode this
    /// comes from the macOS output rather than the locked player volume.
    var isMutedForUI: Bool { isVolumeLocked ? isSystemMuted : isMuted }

    private func syncPlayerMuteState() {
        avPlayer?.isMuted = isVolumeLocked && isSystemMuted
    }

    var isDecodingAudio: Bool { avPlayer != nil }

    // MARK: Transport

    func play(_ songs: [Song], startAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        // A normal Play action starts a collection in order. It deliberately
        // clears Shuffle and Repeat; Shuffle has its own entry point.
        if isShuffleOn {
            isShuffleOn = false
            persistShuffle()
        }
        if repeatMode != .off {
            repeatMode = .off
            UserDefaults.standard.set(RepeatMode.off.rawValue, forKey: Self.repeatDefaultsKey)
        }
        baseQueue = songs
        queue = songs
        currentIndex = min(max(index, 0), songs.count - 1)
        beginCurrentTrack()
    }

    func play(_ song: Song, in songs: [Song]) {
        let idx = songs.firstIndex(where: { $0.id == song.id }) ?? 0
        play(songs, startAt: idx)
    }

    /// Appends tracks to the end of the current queue without starting playback.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            baseQueue = songs
            queue = isShuffleOn ? songs.shuffled() : songs
            currentIndex = nil
        } else {
            queue.append(contentsOf: songs)
            baseQueue.append(contentsOf: songs)
            if isShuffleOn {
                shuffleUnplayedQueue()
            }
        }
    }

    /// Re-shuffles the part of the queue that has not been played yet while
    /// keeping the current track in place. Used when random/shuffle is enabled
    /// after tracks were already queued, or when tracks are appended.
    private func shuffleUnplayedQueue() {
        guard isShuffleOn, queue.count > 1 else { return }
        if let i = currentIndex, queue.indices.contains(i) {
            let head = Array(queue.prefix(i + 1))
            queue = head + Array(queue.dropFirst(i + 1)).shuffled()
        } else {
            queue.shuffle()
        }
    }

    func insertIntoQueue(_ songs: [Song], at index: Int) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            queue = songs
            baseQueue = songs
            currentIndex = nil
            return
        }
        let insertion = min(max(index, 0), queue.count)
        queue.insert(contentsOf: songs, at: insertion)
        baseQueue.insert(contentsOf: songs, at: min(insertion, baseQueue.count))
        if let currentIndex, insertion <= currentIndex {
            self.currentIndex = currentIndex + songs.count
        }
    }

    /// Appends tracks to the bottom of the queue without changing playback.
    func playLater(_ songs: [Song]) {
        appendToQueue(songs)
    }

    func clearQueue() {
        releasePlayer()
        stopTimer()
        queue = []
        baseQueue = []
        currentIndex = nil
        isPlaying = false
        elapsed = 0
    }

    func playQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        beginCurrentTrack()
    }

    func stopPlayback() {
        releasePlayer()
        stopTimer()
        isPlaying = false
        elapsed = 0
    }

    func setPaused(_ paused: Bool) {
        guard currentSong != nil else { return }
        if paused == !isPlaying { return }
        togglePlayPause()
    }

    func removeQueue(at offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        let current = currentIndex
        let removedCurrent = current.map { offsets.contains($0) } ?? false
        let removedIDs = offsets.compactMap { queue.indices.contains($0) ? queue[$0].id : nil }
        queue.remove(atOffsets: offsets)
        baseQueue.removeAll { song in removedIDs.contains(song.id) }

        if removedCurrent {
            releasePlayer()
            stopTimer()
            isPlaying = false
            elapsed = 0
            currentIndex = queue.isEmpty ? nil : min(offsets.min() ?? 0, queue.count - 1)
        } else if let current {
            let removedBefore = offsets.filter { $0 < current }.count
            currentIndex = min(max(current - removedBefore, 0), max(queue.count - 1, 0))
            if queue.isEmpty { currentIndex = nil }
        }
    }

    /// Removes songs that were deleted from the library from the queue and
    /// history, stopping playback if the current track was removed.
    func removeSongs(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let currentID = currentSong?.id
        let removedCurrent = currentID.map { ids.contains($0) } ?? false

        queue.removeAll { ids.contains($0.id) }
        baseQueue.removeAll { ids.contains($0.id) }

        if removedCurrent {
            releasePlayer()
            stopTimer()
            isPlaying = false
            elapsed = 0
        }
        if let currentID, let index = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        } else if queue.isEmpty {
            currentIndex = nil
        } else if removedCurrent {
            currentIndex = min(currentIndex ?? 0, queue.count - 1)
        }

        historyIDs.removeAll { ids.contains($0) }
        history.removeAll { ids.contains($0.id) }
        persistHistory()
    }

    func moveQueue(from: Int, to: Int) {
        guard queue.indices.contains(from), to >= 0, to <= queue.count else { return }
        let currentID = currentSong?.id
        var updated = queue
        let item = updated.remove(at: from)
        let insertion = min(max(to, 0), updated.count)
        updated.insert(item, at: insertion)
        queue = updated
        baseQueue = updated
        if let currentID, let index = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        }
    }

    /// Reorders the portion of the queue shown as Up Next without moving the
    /// currently playing track or touching the already-played prefix.
    func moveUpNext(from: Int, to: Int) {
        guard let current = currentIndex, queue.indices.contains(current) else { return }
        let start = current + 1
        guard start < queue.count else { return }
        var tail = Array(queue[start...])
        guard tail.indices.contains(from) else { return }
        let item = tail.remove(at: from)
        tail.insert(item, at: min(max(to, 0), tail.count))
        queue.replaceSubrange(start..., with: tail)
        baseQueue = queue
    }

    /// Moves an existing queue entry (or a history-only entry) directly after
    /// the current track so it plays next.
    func playNextFromQueue(_ song: Song) {
        guard let current = currentIndex, queue.indices.contains(current) else {
            play([song])
            return
        }
        let currentID = queue[current].id
        if let existing = queue.firstIndex(where: { $0.id == song.id }) {
            guard existing != current, existing != current + 1 else { return }
            var updated = queue
            let moved = updated.remove(at: existing)
            guard let newCurrent = updated.firstIndex(where: { $0.id == currentID }) else { return }
            updated.insert(moved, at: min(newCurrent + 1, updated.count))
            queue = updated
            baseQueue = updated
            currentIndex = updated.firstIndex(where: { $0.id == currentID })
        } else {
            queue.insert(song, at: current + 1)
            if let baseCurrent = baseQueue.firstIndex(where: { $0.id == currentID }) {
                baseQueue.insert(song, at: min(baseCurrent + 1, baseQueue.count))
            } else {
                baseQueue.append(song)
            }
        }
    }

    /// Removes one song from the active queue. This does not delete the file or
    /// remove the song from play history.
    func removeFromQueue(_ song: Song) {
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        removeQueue(at: IndexSet(integer: index))
    }

    func shuffleQueue() {
        guard queue.count > 1 else { return }
        let currentID = currentSong?.id
        queue.shuffle()
        baseQueue = queue
        if let currentID, let index = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        }
    }

    func seek(toSeconds seconds: TimeInterval) {
        seek(toTime: max(0, min(seconds, duration)))
    }

    /// Jumps to a track inside the current queue without rebuilding it. This
    /// preserves the normal-order base queue when shuffle is enabled.
    func playFromQueue(_ song: Song) {
        if let idx = queue.firstIndex(where: { $0.id == song.id }) {
            currentIndex = idx
            beginCurrentTrack()
        } else {
            play([song])
        }
    }

    /// iTunes-style Shuffle action: turn shuffle on and start the collection in
    /// a random order. Turning shuffle off later restores the original order.
    func playShuffled(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        baseQueue = songs
        if !isShuffleOn {
            isShuffleOn = true
            persistShuffle()
        }
        queue = songs.shuffled()
        currentIndex = 0
        beginCurrentTrack()
    }

    func toggleShuffle() {
        setShuffle(!isShuffleOn)
    }

    func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffleOn else { return }
        isShuffleOn = enabled
        persistShuffle()
        guard !queue.isEmpty else { return }

        if enabled {
            shuffleUnplayedQueue()
        } else {
            let restored = baseQueue.isEmpty ? queue : baseQueue
            if let current = currentSong {
                if let idx = restored.firstIndex(where: { $0.id == current.id }) {
                    queue = restored
                    currentIndex = idx
                } else {
                    // Defensive: keep the audible track in the queue even if
                    // the normal-order copy somehow lost it.
                    var repaired = restored
                    let insert = min(currentIndex ?? 0, repaired.count)
                    repaired.insert(current, at: insert)
                    baseQueue = repaired
                    queue = repaired
                    currentIndex = insert
                }
            } else {
                queue = restored
                currentIndex = nil
            }
        }
    }

    private func persistShuffle() {
        UserDefaults.standard.set(isShuffleOn, forKey: Self.shuffleDefaultsKey)
    }

    func setRepeat(enabled: Bool) {
        setRepeatMode(enabled ? .all : .off)
    }

    /// Sets Off/All/One directly. MPD maps its repeat + single flags onto these
    /// modes; the app's repeat button also uses this path.
    func setRepeatMode(_ mode: RepeatMode) {
        guard repeatMode != mode else { return }
        repeatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.repeatDefaultsKey)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        UserDefaults.standard.set(repeatMode.rawValue, forKey: Self.repeatDefaultsKey)
    }

    /// Inserts songs directly after the current track.
    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if let index = currentIndex, queue.indices.contains(index) {
            let current = queue[index]
            queue.insert(contentsOf: songs, at: index + 1)
            if let baseIndex = baseQueue.firstIndex(where: { $0.id == current.id }) {
                baseQueue.insert(contentsOf: songs, at: baseIndex + 1)
            } else {
                baseQueue.append(contentsOf: songs)
            }
        } else {
            play(songs)
        }
    }

    /// Refreshes queued copies after tag edits or star changes.
    func applyUpdatedSongs(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        if !queue.isEmpty || !baseQueue.isEmpty {
            queue = queue.map { byID[$0.id] ?? $0 }
            baseQueue = baseQueue.map { byID[$0.id] ?? $0 }
        }

        // Resolve persisted history IDs against the current library. Prune
        // entries whose songs no longer exist (for example after removing an
        // external library).
        let resolved = historyIDs.compactMap { byID[$0] }
        if resolved.count != historyIDs.count {
            historyIDs = resolved.map(\.id)
            persistHistory()
        }
        history = resolved
    }

    private func recordHistory(_ song: Song) {
        historyIDs.removeAll { $0 == song.id }
        historyIDs.insert(song.id, at: 0)
        if historyIDs.count > Self.historyLimit {
            historyIDs.removeLast(historyIDs.count - Self.historyLimit)
        }
        history = historyIDs.compactMap { id in
            if id == song.id { return song }
            return history.first { $0.id == id }
        }
        persistHistory()
    }

    private func persistHistory() {
        UserDefaults.standard.set(historyIDs.map(\.uuidString), forKey: Self.historyDefaultsKey)
    }

    func togglePlayPause() {
        guard let song = currentSong else { return }

        if isPlaying {
            if let avPlayer {
                let time = avPlayer.currentTime().seconds
                if time.isFinite { elapsed = time }
            }
            avPlayer?.pause()
            isPlaying = false
            stopTimer()
            seekGraceUntil = nil
        } else {
            // Pressing play after the queue reached its end (repeat off)
            // restarts the last track instead of doing nothing at EOF.
            if song.duration > 0, elapsed >= song.duration - 0.1 {
                beginCurrentTrack(countPlay: false)
                return
            }
            if avPlayer == nil, song.fileURL != nil {
                beginCurrentTrack(countPlay: false)
                return
            }
            avPlayer?.play()
            isPlaying = true
            startTimer()
        }
    }

    func next() {
        guard let i = currentIndex, !queue.isEmpty else { return }
        if i + 1 < queue.count {
            currentIndex = i + 1
            beginCurrentTrack()
        } else if repeatMode != .off {
            currentIndex = 0
            beginCurrentTrack()
        } else {
            finishQueue()
        }
    }

    func previous() {
        guard let i = currentIndex, !queue.isEmpty else { return }
        if elapsed > 3 || i == 0 {
            beginCurrentTrack(countPlay: false)
        } else {
            currentIndex = (i - 1 + queue.count) % queue.count
            beginCurrentTrack()
        }
    }

    func seek(to fraction: Double) {
        let total = duration
        guard total > 0 else { return }
        let position = min(max(fraction, 0), 1) * total
        seek(toTime: position)
    }

    func seek(by delta: TimeInterval) {
        let total = duration
        guard total > 0 else { return }
        let position = min(max(elapsed + delta, 0), total)
        seek(toTime: position)
    }

    private func seek(toTime position: TimeInterval) {
        if let avPlayer {
            avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                          toleranceBefore: .zero,
                          toleranceAfter: .zero)
            seekGraceUntil = Date().addingTimeInterval(0.3)
        }
        elapsed = position
    }

    // MARK: Volume

    func setVolume(_ v: Double) {
        guard !isVolumeLocked else { return }
        volume = min(max(v, 0), 1)
        avPlayer?.volume = Float(volume)
        if volume > 0 { volumeBeforeMute = volume }
        persistVolume()
    }

    func toggleMute() {
        if isVolumeLocked {
            if isSystemMuted {
                let target = systemVolumeBeforeMute > 0 ? systemVolumeBeforeMute : 0.5
                setSystemVolume(target)
            } else {
                let current = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? 0
                if current > 0 { systemVolumeBeforeMute = current }
                setSystemVolume(0)
            }
            return
        }
        if isMuted {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 0.65
        } else {
            volumeBeforeMute = volume
            volume = 0
        }
        avPlayer?.volume = Float(volume)
        persistVolume()
    }

    /// Applies volume directly to the macOS output while system mode is active.
    func setSystemVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        if clamped > 0 {
            systemVolumeBeforeMute = clamped
            isSystemMuted = false
        } else {
            isSystemMuted = true
        }
        SystemVolume.set(clamped, deviceID: AudioDevices.shared.effectiveDeviceID)
        syncPlayerMuteState()
    }

    /// Locks/unlocks the player volume for MPD system-volume control. Enabling
    /// remembers the player volume so disabling can restore it.
    func setSystemVolumeControl(_ enabled: Bool) {
        guard enabled != isVolumeLocked else {
            if enabled {
                volume = 1
                avPlayer?.volume = 1
            }
            return
        }

        if enabled {
            volumeBeforeSystemControl = volume > 0 ? volume : max(volumeBeforeMute, 0.65)
            UserDefaults.standard.set(volumeBeforeSystemControl, forKey: Self.volumeBeforeSystemControlKey)
            isVolumeLocked = true
            volume = 1
            let currentSystem = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? 0
            isSystemMuted = currentSystem <= 0
            if currentSystem > 0 { systemVolumeBeforeMute = currentSystem }
        } else {
            isVolumeLocked = false
            isSystemMuted = false
            let stored = UserDefaults.standard.object(forKey: Self.volumeBeforeSystemControlKey) as? Double
            volume = min(max(stored ?? 0.65, 0), 1)
            volumeBeforeMute = volume > 0 ? volume : 0.65
            persistVolume()
        }
        avPlayer?.volume = Float(volume)
        syncPlayerMuteState()
    }

    private func persistVolume() {
        UserDefaults.standard.set(volume, forKey: Self.volumeDefaultsKey)
    }

    // MARK: Engine

    private func beginCurrentTrack(countPlay: Bool = true) {
        releasePlayer()
        stopTimer()
        elapsed = 0
        isPlaying = false
        seekGraceUntil = nil

        guard let song = currentSong else { return }
        if countPlay {
            Library.shared.recordPlay(song.id)
            recordHistory(song)
        }

        if let url = song.fileURL {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.volume = Float(volume)
            player.isMuted = isVolumeLocked && isSystemMuted
            player.audioOutputDeviceUniqueID = AudioDevices.shared.effectiveUID
            avPlayer = player

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.advanceAfterTrackEnds() }
            }

            player.play()
            isPlaying = true
            startTimer()
            return
        }

        // Fallback for entries without a decodable file: simulate transport.
        isPlaying = true
        startTimer()
    }

    private func releasePlayer() {
        avPlayer?.pause()
        avPlayer = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func applyOutputDevice() {
        guard let avPlayer else { return }
        let time = avPlayer.currentTime()
        let wasPlaying = isPlaying
        avPlayer.audioOutputDeviceUniqueID = AudioDevices.shared.effectiveUID
        if time.isValid {
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            seekGraceUntil = Date().addingTimeInterval(0.3)
        }
        if wasPlaying {
            avPlayer.play()
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, let song = currentSong else { return }

        if let player = avPlayer {
            if let item = player.currentItem, item.status == .failed {
                // The file could not be decoded; fall through to the simulated
                // transport so the UI remains usable.
                releasePlayer()
            } else {
                if let until = seekGraceUntil, Date() < until {
                    return
                }
                seekGraceUntil = nil
                let time = player.currentTime().seconds
                if time.isFinite {
                    elapsed = time
                }
                return
            }
        }

        elapsed += 0.2
        if song.duration > 0, elapsed >= song.duration {
            advanceAfterTrackEnds()
        }
    }

    /// Called when a track reaches its natural end. Repeat One replays the
    /// current item; Repeat All wraps; Repeat Off stops at the last item.
    private func advanceAfterTrackEnds() {
        guard let i = currentIndex, !queue.isEmpty else { return }
        if repeatMode == .one {
            beginCurrentTrack()
            return
        }
        if i + 1 < queue.count {
            currentIndex = i + 1
            beginCurrentTrack()
        } else if repeatMode == .all {
            currentIndex = 0
            beginCurrentTrack()
        } else {
            finishQueue()
        }
    }

    private func finishQueue() {
        // Repeat Off reached the end of the queue: clear it so the top-center
        // panel returns to its empty stopped state instead of freezing on the
        // last track.
        releasePlayer()
        stopTimer()
        queue = []
        baseQueue = []
        currentIndex = nil
        isPlaying = false
        elapsed = 0
        seekGraceUntil = nil
    }
}
