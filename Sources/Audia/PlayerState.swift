import SwiftUI
import Combine
import AVFoundation

enum RepeatMode: String, CaseIterable {
    case off
    case all
    case one
}

/// Explicit transport actions, used by the menu-bar icon feedback. Automatic
/// state changes (for example a restored paused queue) do not emit these.
enum PlayerTransportAction: Sendable {
    case play
    case pause
    case stop
}

struct MissingFileStreak {
    private(set) var count = 0

    mutating func recordMissing() -> Bool {
        count += 1
        return count >= 100
    }

    mutating func reset() {
        count = 0
    }
}

/// Lightweight playback projection for views that only need status changes.
/// It deliberately excludes elapsed time so 5 Hz progress updates do not
/// invalidate every list in the window.
@MainActor
final class PlaybackStatus: ObservableObject {
    static let shared = PlaybackStatus()

    @Published fileprivate(set) var currentSongID: UUID?
    @Published fileprivate(set) var isPlaying = false
    @Published fileprivate(set) var missingFileIDs: Set<UUID> = []
    @Published fileprivate(set) var missingFilePauseMessage: String?
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
    private enum MediaPathAvailability {
        case present
        case missing
        case inaccessible(String)
    }

    static let shared = PlayerState()

    /// Emits only when playback starts, pauses, or stops so the tray can show
    /// a short transport icon without inferring actions from state changes.
    static let transportActionEvents = PassthroughSubject<PlayerTransportAction, Never>()

    @Published private(set) var queueEntries: [QueueEntry] = []
    @Published private(set) var currentIndex: Int?
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var volume: Double = 0.65
    /// While MPD owns the system volume, AVPlayer stays at 100% and the app's
    /// volume controls operate on the macOS output instead.
    @Published private(set) var isVolumeLocked = false
    @Published private(set) var isSystemMuted = false
    @Published private(set) var systemVolume: Double = 1
    @Published private(set) var isShuffleOn = false
    @Published private(set) var repeatMode: RepeatMode = .off
    /// Most-recent-first play history, independent of the active queue.
    @Published private(set) var history: [Song] = []
    /// Transient file-missing markers. These are deliberately not persisted.
    @Published private(set) var missingFileIDs: Set<UUID> = []
    @Published private(set) var missingFilePauseMessage: String?

    /// The queue in the order the user started it. Toggling shuffle off restores
    /// this order while keeping the current entry at its original position.
    private var baseQueueEntries: [QueueEntry] = []
    private var nextQueueID: UInt32 = 1
    private var historyIDs: [UUID] = []

    private var didAttemptQueueRestore = false
    private var queueChangeCancellables: Set<AnyCancellable> = []
    private var playbackStatusCancellables: Set<AnyCancellable> = []
    private var lastPersistedElapsed: TimeInterval = 0

    private static let shuffleDefaultsKey = "player.shuffleEnabled"
    private static let repeatDefaultsKey = "player.repeatMode"
    private static let historyDefaultsKey = "player.historyIDs"
    private static let volumeDefaultsKey = "player.volume"
    private static let volumeBeforeSystemControlKey = "player.volumeBeforeSystemControl"
    private static let systemVolumeStep = 1.0 / 16.0
    private static let historyLimit = 50

    private var avPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timer: Timer?
    private var volumeBeforeMute: Double = 0.65
    private var volumeBeforeSystemControl: Double = 0.65
    private var systemVolumeBeforeMute: Double = 0.5
    private var systemVolumeTimer: Timer?
    private var deviceCancellable: AnyCancellable?
    /// While the seek bar is being dragged, don't let the timer overwrite the
    /// dragged position with AVPlayer's still-old current time.
    private var seekGraceUntil: Date?
    private var missingFileStreak = MissingFileStreak()
    private var pendingPlayCountSongID: UUID?
    private var didRecordPendingPlay = false

    private init() {
        isShuffleOn = UserDefaults.standard.bool(forKey: Self.shuffleDefaultsKey)
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: Self.repeatDefaultsKey) ?? "") ?? .off
        historyIDs = (UserDefaults.standard.stringArray(forKey: Self.historyDefaultsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
        let storedVolume = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) as? Double
        volume = min(max(storedVolume ?? 0.65, 0), 1)
        let controlsSystemVolume = AudioDevices.shared.selectedDevice.controlsSystemVolume
        if controlsSystemVolume {
            let storedBefore = UserDefaults.standard.object(forKey: Self.volumeBeforeSystemControlKey) as? Double
            volumeBeforeSystemControl = min(max(storedBefore ?? (volume > 0 ? volume : 0.65), 0), 1)
            isVolumeLocked = true
            volume = 1
            let currentSystem = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? 0
            systemVolume = currentSystem
            isSystemMuted = currentSystem <= 0
            if currentSystem > 0 { systemVolumeBeforeMute = currentSystem }
        }
        volumeBeforeMute = volume > 0 ? volume : 0.65

        // Keep the current player on the device selected in the toolbar menu.
        deviceCancellable = AudioDevices.shared.$selectedID
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyOutputDevice() }
            }
        if isVolumeLocked { startSystemVolumeTimer() }

        queueChangeCancellables.removeAll()
        $queueEntries
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.persistQueue() }
            }
            .store(in: &queueChangeCancellables)
        $currentIndex
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.persistQueuePosition() }
            }
            .store(in: &queueChangeCancellables)

        observePlaybackStatus()
        SystemNowPlaying.shared.attach(to: self)
    }

    /// Mirrors only the playback fields the lists need. `elapsed` stays on
    /// `PlayerState` and is observed only by the transport UI.
    private func observePlaybackStatus() {
        PlaybackStatus.shared.currentSongID = currentSong?.id
        PlaybackStatus.shared.isPlaying = isPlaying
        PlaybackStatus.shared.missingFileIDs = missingFileIDs
        PlaybackStatus.shared.missingFilePauseMessage = missingFilePauseMessage

        Publishers.CombineLatest($queueEntries, $currentIndex)
            .map { queue, index -> UUID? in
                guard let index, queue.indices.contains(index) else { return nil }
                return queue[index].song.id
            }
            .removeDuplicates()
            .sink { id in
                Task { @MainActor in PlaybackStatus.shared.currentSongID = id }
            }
            .store(in: &playbackStatusCancellables)

        $isPlaying
            .removeDuplicates()
            .sink { playing in
                Task { @MainActor in PlaybackStatus.shared.isPlaying = playing }
            }
            .store(in: &playbackStatusCancellables)

        $missingFileIDs
            .removeDuplicates()
            .sink { ids in
                Task { @MainActor in PlaybackStatus.shared.missingFileIDs = ids }
            }
            .store(in: &playbackStatusCancellables)

        $missingFilePauseMessage
            .removeDuplicates()
            .sink { message in
                Task { @MainActor in PlaybackStatus.shared.missingFilePauseMessage = message }
            }
            .store(in: &playbackStatusCancellables)
    }

    /// Song projection for UI and integrations that do not need queue-entry
    /// identity. Queue mutation must always go through `queueEntries`.
    var queue: [Song] {
        queueEntries.map(\.song)
    }

    var currentEntry: QueueEntry? {
        guard let i = currentIndex, queueEntries.indices.contains(i) else { return nil }
        return queueEntries[i]
    }

    var currentSong: Song? {
        currentEntry?.song
    }

    /// Entries still queued after the current track.
    var upNextEntries: [QueueEntry] {
        guard let i = currentIndex, queueEntries.indices.contains(i) else { return [] }
        return Array(queueEntries.dropFirst(i + 1))
    }

    /// Song projection of `upNextEntries`.
    var upNext: [Song] {
        upNextEntries.map(\.song)
    }

    func index(ofQueueEntry id: UInt32) -> Int? {
        queueEntries.firstIndex(where: { $0.id == id })
    }

    func isCurrentQueueEntry(_ id: UInt32) -> Bool {
        currentEntry?.id == id
    }

    private func advanceQueueID() {
        nextQueueID &+= 1
        if nextQueueID == 0 { nextQueueID = 1 }
    }

    private func occupiedQueueIDs() -> Set<UInt32> {
        var occupied = Set(queueEntries.lazy.map(\.id))
        occupied.formUnion(baseQueueEntries.lazy.map(\.id))
        return occupied
    }

    private func allocateQueueID(occupied: inout Set<UInt32>) -> UInt32 {
        while occupied.contains(nextQueueID) {
            advanceQueueID()
        }
        let id = nextQueueID
        advanceQueueID()
        occupied.insert(id)
        return id
    }

    private func allocateQueueID() -> UInt32 {
        var occupied = occupiedQueueIDs()
        return allocateQueueID(occupied: &occupied)
    }

    private func makeQueueEntry(_ song: Song) -> QueueEntry {
        QueueEntry(id: allocateQueueID(), song: song)
    }

    /// Allocates IDs for a whole batch with one occupied-ID set. Building the
    /// set inside every allocation made Play/Shuffle on the full library
    /// O(n²): with a restored 20k-entry queue it rebuilt a ~41k-entry set
    /// 20k times.
    private func makeQueueEntries(_ songs: [Song]) -> [QueueEntry] {
        guard !songs.isEmpty else { return [] }
        var occupied = occupiedQueueIDs()
        var entries: [QueueEntry] = []
        entries.reserveCapacity(songs.count)
        for song in songs {
            entries.append(QueueEntry(id: allocateQueueID(occupied: &occupied),
                                      song: song))
        }
        return entries
    }

    private func raiseNextQueueID(above entries: [QueueEntry]) {
        guard let maxID = entries.map(\.id).max() else { return }
        if nextQueueID <= maxID {
            nextQueueID = maxID == UInt32.max ? 1 : maxID + 1
        }
    }

    /// Drops everything after the current track, keeping the current song.
    func clearUpNext() {
        guard let i = currentIndex, queueEntries.indices.contains(i) else { return }
        let keptIDs = Set(queueEntries.prefix(i + 1).map(\.id))
        queueEntries = Array(queueEntries.prefix(i + 1))
        // Keep the normal-order copy in sync so disabling shuffle later does
        // not resurrect tracks the user just cleared.
        baseQueueEntries.removeAll { !keptIDs.contains($0.id) }
    }

    /// Stops playback and forgets the queue. Used when switching libraries.
    func stopAndClear() {
        releasePlayer()
        stopTimer()
        queueEntries = []
        baseQueueEntries = []
        currentIndex = nil
        isPlaying = false
        elapsed = 0
        missingFileStreak.reset()
        missingFilePauseMessage = nil
        persistQueue()
        announceTransportAction(.stop)
    }

    func clearHistory() {
        historyIDs.removeAll()
        history.removeAll()
        persistHistory()
    }

    func markFilesMissing(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        missingFileIDs.formUnion(ids)
    }

    func clearMissingFileIDs(_ ids: Set<UUID>) {
        missingFileIDs.subtract(ids)
    }

    func clearMissingFiles(foundPaths: Set<String>) {
        guard !foundPaths.isEmpty else { return }
        missingFileStreak.reset()
        missingFilePauseMessage = nil
        let canonicalPaths = Set(foundPaths.map(canonicalFilePath))
        let restored = Library.shared.allSongs.compactMap { song -> UUID? in
            guard let url = song.fileURL,
                  canonicalPaths.contains(canonicalFilePath(url.path)) else { return nil }
            return song.id
        }
        missingFileIDs.subtract(restored)
    }

    private func canonicalFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func mediaPathAvailability(_ url: URL) -> MediaPathAvailability {
        let fileManager = FileManager.default
        let parentPath = url.deletingLastPathComponent().path
        guard fileManager.isReadableFile(atPath: parentPath) else {
            return .inaccessible("The containing media directory is unavailable or unreadable.")
        }
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard fileManager.isReadableFile(atPath: url.path) else {
            return .inaccessible("Permission denied")
        }
        return .present
    }

    private func reportMissingFilesPaused() {
        AppLog.playback.error("Playback paused after 100 consecutive missing files")
        missingFilePauseMessage = "Playback paused after 100 consecutive missing files. Check whether the external drive is available."
        releasePlayer()
        stopTimer()
        isPlaying = false
        persistQueuePosition()
    }

    func dismissMissingFilePauseNotice() {
        missingFilePauseMessage = nil
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

    /// Volume shown by the player UI. In system mode this is the macOS output
    /// volume, not the locked AVPlayer volume.
    var displayVolume: Double { isVolumeLocked ? systemVolume : volume }

    func setDisplayVolume(_ value: Double) {
        if isVolumeLocked {
            setSystemVolume(value)
        } else {
            setVolume(value)
        }
    }

    /// Moves the displayed volume by one 6.25% step. Values that are not on the
    /// 16-step system-volume grid snap to the nearest step in the pressed
    /// direction, matching the macOS volume keys.
    func stepDisplayVolume(up: Bool) {
        let step = Self.systemVolumeStep
        let scaled = displayVolume / step
        let epsilon = 1e-9
        let target: Double
        if up {
            target = (floor(scaled + epsilon) + 1) * step
        } else {
            target = max(0, (ceil(scaled - epsilon) - 1) * step)
        }
        setDisplayVolume(min(max(target, 0), 1))
    }

    /// Selects an output and applies its volume policy. Real output devices and
    /// “System Default with Volume Control” keep AVPlayer at 100% and expose
    /// the macOS output volume; plain System Default uses app-controlled volume.
    func selectAudioOutput(_ device: AudioOutputDevice) {
        AudioDevices.shared.select(device)
        setSystemVolumeControl(AudioDevices.shared.selectedDevice.controlsSystemVolume)
    }

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
        let entries = makeQueueEntries(songs)
        baseQueueEntries = entries
        queueEntries = entries
        currentIndex = min(max(index, 0), entries.count - 1)
        beginCurrentTrack()
    }

    func play(_ song: Song, in songs: [Song]) {
        let idx = songs.firstIndex(where: { $0.id == song.id }) ?? 0
        play(songs, startAt: idx)
    }

    /// Appends tracks to the end of the current queue without starting playback.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let entries = makeQueueEntries(songs)
        if queueEntries.isEmpty {
            baseQueueEntries = entries
            queueEntries = isShuffleOn ? entries.shuffled() : entries
            currentIndex = nil
        } else {
            queueEntries.append(contentsOf: entries)
            baseQueueEntries.append(contentsOf: entries)
            if isShuffleOn {
                shuffleUnplayedQueue()
            }
        }
    }

    /// Re-shuffles the part of the queue that has not been played yet while
    /// keeping the current entry in place. Used when random/shuffle is enabled
    /// after tracks were already queued, or when tracks are appended.
    private func shuffleUnplayedQueue() {
        guard isShuffleOn, queueEntries.count > 1 else { return }
        if let i = currentIndex, queueEntries.indices.contains(i) {
            let head = Array(queueEntries.prefix(i + 1))
            queueEntries = head + Array(queueEntries.dropFirst(i + 1)).shuffled()
        } else {
            queueEntries.shuffle()
        }
    }

    func insertIntoQueue(_ songs: [Song], at index: Int) {
        guard !songs.isEmpty else { return }
        let entries = makeQueueEntries(songs)
        if queueEntries.isEmpty {
            queueEntries = entries
            baseQueueEntries = entries
            currentIndex = nil
            return
        }
        let insertion = min(max(index, 0), queueEntries.count)
        queueEntries.insert(contentsOf: entries, at: insertion)
        baseQueueEntries.insert(contentsOf: entries,
                                at: min(insertion, baseQueueEntries.count))
        if let currentIndex, insertion <= currentIndex {
            self.currentIndex = currentIndex + entries.count
        }
    }

    /// Appends tracks to the bottom of the queue without changing playback.
    func playLater(_ songs: [Song]) {
        appendToQueue(songs)
    }

    func clearQueue() {
        releasePlayer()
        stopTimer()
        queueEntries = []
        baseQueueEntries = []
        currentIndex = nil
        isPlaying = false
        elapsed = 0
        persistQueue()
    }

    /// Loads the last queue and its paused playback position after launch.
    /// Nothing starts playing until the user presses Play.
    func restorePersistedQueueIfNeeded() {
        guard !didAttemptQueueRestore else { return }
        didAttemptQueueRestore = true
        guard queueEntries.isEmpty, let saved = Library.shared.loadPlayerQueue() else { return }

        let songsByID = Dictionary(uniqueKeysWithValues: Library.shared.allSongs.map { ($0.id, $0) })
        var restoredEntries: [QueueEntry] = []
        var restoredCurrentIndex: Int?
        for (offset, persisted) in saved.entries.enumerated() {
            guard let song = songsByID[persisted.songID] else { continue }
            if saved.currentIndex == offset {
                restoredCurrentIndex = restoredEntries.count
            }
            restoredEntries.append(QueueEntry(id: persisted.id, song: song))
        }
        guard !restoredEntries.isEmpty else {
            Library.shared.savePlayerQueue(PersistedPlayerQueue(entries: [],
                                                                baseEntries: [],
                                                                nextQueueID: saved.nextQueueID,
                                                                currentIndex: nil,
                                                                elapsed: 0))
            return
        }

        let entriesByID = Dictionary(uniqueKeysWithValues: restoredEntries.map { ($0.id, $0) })
        var restoredBase: [QueueEntry] = saved.baseEntries.compactMap { persisted in
            if let entry = entriesByID[persisted.id] {
                return entry
            }
            guard let song = songsByID[persisted.songID] else { return nil }
            return QueueEntry(id: persisted.id, song: song)
        }
        if restoredBase.isEmpty { restoredBase = restoredEntries }

        queueEntries = restoredEntries
        baseQueueEntries = restoredBase
        nextQueueID = saved.nextQueueID
        raiseNextQueueID(above: restoredEntries + restoredBase)

        if let restoredCurrentIndex {
            currentIndex = restoredCurrentIndex
            let duration = restoredEntries[restoredCurrentIndex].song.duration
            elapsed = duration > 0 ? min(max(saved.elapsed, 0), duration) : max(saved.elapsed, 0)
        } else {
            currentIndex = nil
            elapsed = 0
        }

        isPlaying = false
        avPlayer = nil
        seekGraceUntil = nil
        lastPersistedElapsed = elapsed
        persistQueue()
    }

    /// Called before the database closes during app termination.
    func persistQueueForTermination() {
        if let avPlayer {
            let time = avPlayer.currentTime().seconds
            if time.isFinite { elapsed = max(time, 0) }
        }
        persistQueue()
    }

    private func persistQueue() {
        let entries = queueEntries.map {
            PersistedQueueEntry(id: $0.id, songID: $0.song.id)
        }
        let baseEntries = baseQueueEntries.map {
            PersistedQueueEntry(id: $0.id, songID: $0.song.id)
        }
        Library.shared.savePlayerQueue(PersistedPlayerQueue(entries: entries,
                                                            baseEntries: baseEntries,
                                                            nextQueueID: nextQueueID,
                                                            currentIndex: currentIndex,
                                                            elapsed: elapsed))
        lastPersistedElapsed = elapsed
    }

    private func persistQueuePosition() {
        Library.shared.updatePlayerQueuePosition(currentIndex: currentIndex, elapsed: elapsed)
        lastPersistedElapsed = elapsed
    }

    private func persistQueueIfNeeded() {
        guard abs(elapsed - lastPersistedElapsed) >= 5 else { return }
        persistQueuePosition()
    }

    func playQueue(at index: Int) {
        guard queueEntries.indices.contains(index) else { return }
        currentIndex = index
        beginCurrentTrack()
    }

    func playQueueEntry(id: UInt32) {
        guard let index = index(ofQueueEntry: id) else { return }
        playQueue(at: index)
    }

    func stopPlayback() {
        releasePlayer()
        stopTimer()
        isPlaying = false
        elapsed = 0
        persistQueuePosition()
        announceTransportAction(.stop)
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
        let removedEntryIDs = offsets.compactMap {
            queueEntries.indices.contains($0) ? queueEntries[$0].id : nil
        }
        queueEntries.remove(atOffsets: offsets)
        baseQueueEntries.removeAll { removedEntryIDs.contains($0.id) }

        if removedCurrent {
            releasePlayer()
            stopTimer()
            isPlaying = false
            elapsed = 0
            currentIndex = queueEntries.isEmpty ? nil : min(offsets.min() ?? 0, queueEntries.count - 1)
        } else if let current {
            let removedBefore = offsets.filter { $0 < current }.count
            currentIndex = min(max(current - removedBefore, 0), max(queueEntries.count - 1, 0))
            if queueEntries.isEmpty { currentIndex = nil }
        }
    }

    func removeQueueEntry(id: UInt32) {
        guard let index = index(ofQueueEntry: id) else { return }
        removeQueue(at: IndexSet(integer: index))
    }

    /// Removes songs that were deleted from the library from the queue and
    /// history, stopping playback if the current track was removed.
    func removeSongs(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let currentEntryID = currentEntry?.id
        let removedCurrent = currentEntry.map { ids.contains($0.song.id) } ?? false

        queueEntries.removeAll { ids.contains($0.song.id) }
        baseQueueEntries.removeAll { ids.contains($0.song.id) }

        if removedCurrent {
            releasePlayer()
            stopTimer()
            isPlaying = false
            elapsed = 0
        }
        if let currentEntryID, let index = index(ofQueueEntry: currentEntryID) {
            currentIndex = index
        } else if queueEntries.isEmpty {
            currentIndex = nil
        } else if removedCurrent {
            currentIndex = min(currentIndex ?? 0, queueEntries.count - 1)
        }

        historyIDs.removeAll { ids.contains($0) }
        history.removeAll { ids.contains($0.id) }
        persistHistory()
    }

    func moveQueue(from: Int, to: Int) {
        guard queueEntries.indices.contains(from),
              to >= 0, to <= queueEntries.count else { return }
        let currentEntryID = currentEntry?.id
        var updated = queueEntries
        let item = updated.remove(at: from)
        let insertion = min(max(to, 0), updated.count)
        updated.insert(item, at: insertion)
        queueEntries = updated
        baseQueueEntries = updated
        if let currentEntryID, let index = index(ofQueueEntry: currentEntryID) {
            currentIndex = index
        }
    }

    /// Reorders the portion of the queue shown as Up Next without moving the
    /// currently playing entry or touching the already-played prefix.
    func moveUpNext(from: Int, to: Int) {
        guard let current = currentIndex, queueEntries.indices.contains(current) else { return }
        let start = current + 1
        guard start < queueEntries.count else { return }
        var tail = Array(queueEntries[start...])
        guard tail.indices.contains(from) else { return }
        let item = tail.remove(at: from)
        tail.insert(item, at: min(max(to, 0), tail.count))
        queueEntries.replaceSubrange(start..., with: tail)
        baseQueueEntries = queueEntries
    }

    /// Moves an existing queue entry directly after the current entry.
    func playNextQueueEntry(id: UInt32) {
        guard let current = currentIndex, queueEntries.indices.contains(current) else { return }
        guard let existing = index(ofQueueEntry: id) else { return }
        guard existing != current, existing != current + 1 else { return }
        let currentEntryID = queueEntries[current].id
        var updated = queueEntries
        let moved = updated.remove(at: existing)
        guard let newCurrent = updated.firstIndex(where: { $0.id == currentEntryID }) else { return }
        updated.insert(moved, at: min(newCurrent + 1, updated.count))
        queueEntries = updated
        baseQueueEntries = updated
        currentIndex = updated.firstIndex(where: { $0.id == currentEntryID })
    }

    /// Adds a new occurrence of a song directly after the current track. Used
    /// by history rows, which do not carry a queue-entry ID.
    func playNextFromQueue(_ song: Song) {
        guard let current = currentIndex, queueEntries.indices.contains(current) else {
            play([song])
            return
        }
        let currentEntryID = queueEntries[current].id
        let entry = makeQueueEntry(song)
        queueEntries.insert(entry, at: current + 1)
        if let baseCurrent = baseQueueEntries.firstIndex(where: { $0.id == currentEntryID }) {
            baseQueueEntries.insert(entry, at: min(baseCurrent + 1, baseQueueEntries.count))
        } else {
            baseQueueEntries.append(entry)
        }
    }

    /// Removes the first matching occurrence of a song from the active queue.
    /// Queue UI uses `removeQueueEntry(id:)` to distinguish duplicates.
    func removeFromQueue(_ song: Song) {
        guard let index = queueEntries.firstIndex(where: { $0.song.id == song.id }) else { return }
        removeQueue(at: IndexSet(integer: index))
    }

    func shuffleQueue() {
        guard queueEntries.count > 1 else { return }
        let currentEntryID = currentEntry?.id
        queueEntries.shuffle()
        baseQueueEntries = queueEntries
        if let currentEntryID, let index = index(ofQueueEntry: currentEntryID) {
            currentIndex = index
        }
    }

    func seek(toSeconds seconds: TimeInterval) {
        seek(toTime: max(0, min(seconds, duration)))
    }

    /// Jumps to a track inside the current queue without rebuilding it. This
    /// preserves the normal-order base queue when shuffle is enabled.
    /// Song-level fallback used by history rows, where no queue-entry ID is
    /// available. Queue rows use `playQueueEntry(id:)`.
    func playFromQueue(_ song: Song) {
        if let idx = queueEntries.firstIndex(where: { $0.song.id == song.id }) {
            playQueue(at: idx)
        } else {
            play([song])
        }
    }

    /// iTunes-style Shuffle action: turn shuffle on and start the collection in
    /// a random order. Turning shuffle off later restores the original order.
    func playShuffled(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let entries = makeQueueEntries(songs)
        baseQueueEntries = entries
        if !isShuffleOn {
            isShuffleOn = true
            persistShuffle()
        }
        queueEntries = entries.shuffled()
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
        guard !queueEntries.isEmpty else { return }

        if enabled {
            shuffleUnplayedQueue()
        } else {
            let restored = baseQueueEntries.isEmpty ? queueEntries : baseQueueEntries
            if let currentEntry {
                if let idx = restored.firstIndex(where: { $0.id == currentEntry.id }) {
                    queueEntries = restored
                    currentIndex = idx
                } else {
                    // Defensive: keep the audible entry in the queue even if
                    // the normal-order copy somehow lost it.
                    var repaired = restored
                    let insert = min(currentIndex ?? 0, repaired.count)
                    repaired.insert(currentEntry, at: insert)
                    baseQueueEntries = repaired
                    queueEntries = repaired
                    currentIndex = insert
                }
            } else {
                queueEntries = restored
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
        if let index = currentIndex, queueEntries.indices.contains(index) {
            let currentEntryID = queueEntries[index].id
            let entries = makeQueueEntries(songs)
            queueEntries.insert(contentsOf: entries, at: index + 1)
            if let baseIndex = baseQueueEntries.firstIndex(where: { $0.id == currentEntryID }) {
                baseQueueEntries.insert(contentsOf: entries,
                                        at: min(baseIndex + 1, baseQueueEntries.count))
            } else {
                baseQueueEntries.append(contentsOf: entries)
            }
        } else {
            play(songs)
        }
    }

    /// Refreshes queued copies after tag edits or star changes.
    func applyUpdatedSongs(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        if !queueEntries.isEmpty || !baseQueueEntries.isEmpty {
            queueEntries = queueEntries.map { entry in
                var updated = entry
                if let song = byID[entry.song.id] { updated.song = song }
                return updated
            }
            baseQueueEntries = baseQueueEntries.map { entry in
                var updated = entry
                if let song = byID[entry.song.id] { updated.song = song }
                return updated
            }
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
            persistQueuePosition()
            announceTransportAction(.pause)
        } else {
            // Pressing play after the queue reached its end (repeat off)
            // restarts the last track instead of doing nothing at EOF.
            if song.duration > 0, elapsed >= song.duration - 0.1 {
                beginCurrentTrack(countPlay: false)
                return
            }
            if avPlayer == nil, song.fileURL != nil {
                beginCurrentTrack(countPlay: false, startAt: elapsed)
                return
            }
            avPlayer?.play()
            isPlaying = true
            startTimer()
            persistQueuePosition()
            announceTransportAction(.play)
        }
    }

    func next() {
        guard let i = currentIndex, !queueEntries.isEmpty else { return }
        if i + 1 < queueEntries.count {
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
        guard let i = currentIndex, !queueEntries.isEmpty else { return }
        if elapsed > 3 || i == 0 {
            beginCurrentTrack(countPlay: false)
        } else {
            currentIndex = (i - 1 + queueEntries.count) % queueEntries.count
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
        systemVolume = clamped
        if clamped > 0 {
            systemVolumeBeforeMute = clamped
            isSystemMuted = false
        } else {
            isSystemMuted = true
        }
        SystemVolume.set(clamped, deviceID: AudioDevices.shared.effectiveDeviceID)
        syncPlayerMuteState()
    }

    /// Locks/unlocks the player volume for the selected output policy.
    /// Enabling remembers the player volume so disabling can restore it.
    private func setSystemVolumeControl(_ enabled: Bool) {
        guard enabled != isVolumeLocked else {
            if enabled {
                volume = 1
                avPlayer?.volume = 1
                systemVolume = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? systemVolume
                isSystemMuted = systemVolume <= 0
                startSystemVolumeTimer()
            }
            return
        }

        if enabled {
            volumeBeforeSystemControl = volume > 0 ? volume : max(volumeBeforeMute, 0.65)
            UserDefaults.standard.set(volumeBeforeSystemControl, forKey: Self.volumeBeforeSystemControlKey)
            isVolumeLocked = true
            volume = 1
            let currentSystem = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? 0
            systemVolume = currentSystem
            isSystemMuted = currentSystem <= 0
            if currentSystem > 0 { systemVolumeBeforeMute = currentSystem }
            startSystemVolumeTimer()
        } else {
            isVolumeLocked = false
            isSystemMuted = false
            stopSystemVolumeTimer()
            let stored = UserDefaults.standard.object(forKey: Self.volumeBeforeSystemControlKey) as? Double
            volume = min(max(stored ?? 0.65, 0), 1)
            volumeBeforeMute = volume > 0 ? volume : 0.65
            persistVolume()
        }
        avPlayer?.volume = Float(volume)
        syncPlayerMuteState()
    }

    private func startSystemVolumeTimer() {
        systemVolumeTimer?.invalidate()
        systemVolumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemVolume() }
        }
    }

    private func stopSystemVolumeTimer() {
        systemVolumeTimer?.invalidate()
        systemVolumeTimer = nil
    }

    private func refreshSystemVolume() {
        guard isVolumeLocked else { return }
        let value = SystemVolume.current(deviceID: AudioDevices.shared.effectiveDeviceID) ?? systemVolume
        let clamped = min(max(value, 0), 1)
        if abs(clamped - systemVolume) > 0.0005 {
            systemVolume = clamped
        }
        let muted = clamped <= 0
        if muted != isSystemMuted {
            isSystemMuted = muted
            syncPlayerMuteState()
        }
        if clamped > 0 { systemVolumeBeforeMute = clamped }
    }

    private func persistVolume() {
        UserDefaults.standard.set(volume, forKey: Self.volumeDefaultsKey)
    }

    private func announceTransportAction(_ action: PlayerTransportAction) {
        Self.transportActionEvents.send(action)
    }

    // MARK: Engine

    private func beginCurrentTrack(countPlay: Bool = true, startAt: TimeInterval = 0) {
        releasePlayer()
        stopTimer()
        elapsed = 0
        isPlaying = false
        seekGraceUntil = nil
        pendingPlayCountSongID = nil
        didRecordPendingPlay = false

        guard let song = currentSong else { return }

        if let url = song.fileURL {
            switch mediaPathAvailability(url) {
            case .present:
                break
            case .missing:
                handleMissingFile(song)
                return
            case .inaccessible(let reason):
                pauseForUnavailableFile(song, reason: reason)
                return
            }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.volume = Float(volume)
            player.isMuted = isVolumeLocked && isSystemMuted
            player.audioOutputDeviceUniqueID = AudioDevices.shared.effectiveUID
            avPlayer = player
            pendingPlayCountSongID = countPlay ? song.id : nil

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.advanceAfterTrackEnds() }
            }

            if startAt > 0 {
                let position = song.duration > 0 ? min(startAt, song.duration) : startAt
                player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero)
                elapsed = position
                seekGraceUntil = Date().addingTimeInterval(0.3)
            }

            player.play()
            isPlaying = true
            startTimer()
            announceTransportAction(.play)
            return
        }

        // Fallback for entries without a decodable file: simulate transport.
        missingFileStreak.reset()
        if countPlay {
            Library.shared.recordPlay(song.id)
            recordHistory(song)
        }
        if startAt > 0 {
            elapsed = song.duration > 0 ? min(startAt, song.duration) : startAt
        }
        isPlaying = true
        startTimer()
        announceTransportAction(.play)
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
            if let item = player.currentItem {
                if item.status == .failed {
                    if let url = song.fileURL {
                        switch mediaPathAvailability(url) {
                        case .missing:
                            handleMissingFile(song)
                            return
                        case .inaccessible(let reason):
                            pauseForUnavailableFile(song, reason: reason)
                            return
                        case .present:
                            missingFileStreak.reset()
                            break
                        }
                    }
                    // Preserve simulated transport for present files AVPlayer cannot decode.
                    releasePlayer()
                    recordPendingPlayIfNeeded(song)
                } else {
                    if item.status == .readyToPlay {
                        missingFileStreak.reset()
                        missingFilePauseMessage = nil
                        missingFileIDs.remove(song.id)
                        recordPendingPlayIfNeeded(song)
                    }
                    if let until = seekGraceUntil, Date() < until {
                        return
                    }
                    seekGraceUntil = nil
                    let time = player.currentTime().seconds
                    if time.isFinite {
                        elapsed = time
                    }
                    persistQueueIfNeeded()
                    return
                }
            }
        }

        elapsed += 0.2
        persistQueueIfNeeded()
        if song.duration > 0, elapsed >= song.duration {
            advanceAfterTrackEnds()
        }
    }

    private func recordPendingPlayIfNeeded(_ song: Song) {
        guard !didRecordPendingPlay,
              pendingPlayCountSongID == song.id else { return }
        didRecordPendingPlay = true
        pendingPlayCountSongID = nil
        Library.shared.recordPlay(song.id)
        recordHistory(song)
    }

    private func handleMissingFile(_ song: Song) {
        AppLog.playback.warning("Missing media file for song \(song.id.uuidString, privacy: .public)")
        missingFileIDs.insert(song.id)
        let shouldPause = missingFileStreak.recordMissing()
        pendingPlayCountSongID = nil
        didRecordPendingPlay = false
        releasePlayer()
        stopTimer()
        elapsed = 0
        isPlaying = false

        if shouldPause {
            reportMissingFilesPaused()
            return
        }
        guard let index = currentIndex, !queueEntries.isEmpty else { return }
        if index + 1 < queueEntries.count {
            currentIndex = index + 1
            beginCurrentTrack()
        } else if repeatMode == .all {
            currentIndex = 0
            beginCurrentTrack()
        } else {
            finishQueue()
        }
    }

    private func pauseForUnavailableFile(_ song: Song, reason: String) {
        AppLog.playback.warning("Cannot access song \(song.id.uuidString, privacy: .public): \(reason, privacy: .public)")
        missingFileStreak.reset()
        pendingPlayCountSongID = nil
        didRecordPendingPlay = false
        releasePlayer()
        stopTimer()
        elapsed = 0
        isPlaying = false
        missingFilePauseMessage = "Could not access \(song.title): \(reason)"
        persistQueuePosition()
    }

    /// Called when a track reaches its natural end. Repeat One replays the
    /// current item; Repeat All wraps; Repeat Off stops at the last item.
    private func advanceAfterTrackEnds() {
        guard let i = currentIndex, !queueEntries.isEmpty else { return }
        if repeatMode == .one {
            beginCurrentTrack()
            return
        }
        if i + 1 < queueEntries.count {
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
        queueEntries = []
        baseQueueEntries = []
        currentIndex = nil
        isPlaying = false
        elapsed = 0
        seekGraceUntil = nil
        persistQueue()
        announceTransportAction(.stop)
    }
}
