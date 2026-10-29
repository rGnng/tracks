import AppKit
import Combine
import SwiftUI

@MainActor
final class TrayStatusModel: ObservableObject {
    static let idleLength: CGFloat = 24
    static let expandedLength: CGFloat = 120
    static let cardSize: CGFloat = 18

    @Published var title = ""
    @Published var subtitle = ""
    @Published var isStarred = false
    @Published var artwork: Artwork?
    @Published var coverImage: NSImage?
    @Published var flipAngle: Double = 0
    @Published var showsInfo = false
}

/// Menu-bar icon with an inline now-playing card. A song or star change flips
/// the icon to the current album cover while expanding the status item leftwards
/// to reveal the track details.
@MainActor
final class TrayController: NSObject {
    static let shared = TrayController()

    enum DefaultsKey {
        static let enabled = "tray.enabled"
        static let trackChange = "tray.trackChange"
        static let starChange = "tray.starChange"
        static let displayDurationMs = "tray.popupDurationMs"
    }

    private let model = TrayStatusModel()
    private var statusItem: NSStatusItem?
    private var hostingView: PassthroughHostingView<TrayStatusView>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSongID: UUID?
    private var lastStarred: Bool?
    private var started = false
    private var starCheckScheduled = false

    private var hideWorkItem: DispatchWorkItem?
    private var animationTimer: Timer?
    private var widthTween: Tween?
    private var flipTween: Tween?
    private var sequence = 0
    private var isExpanded = false
    private var isHiding = false

    private let coverCache = NSCache<NSString, NSImage>()
    private var coverLoadTask: Task<Void, Never>?
    private var currentCoverKey: String?
    private var coverReadyKey: String?
    private var coverGeneration = 0
    private var pendingShow = false

    private let flipDuration: TimeInterval = 0.32
    private let expandDuration: TimeInterval = 0.32
    private let shrinkDuration: TimeInterval = 0.32
    private var entranceDuration: TimeInterval { max(flipDuration, expandDuration) }
    private var exitDuration: TimeInterval { max(flipDuration, shrinkDuration) }

    private override init() {
        super.init()
        coverCache.countLimit = 32
        UserDefaults.standard.register(defaults: [
            DefaultsKey.enabled: false,
            DefaultsKey.trackChange: true,
            DefaultsKey.starChange: true,
            DefaultsKey.displayDurationMs: 1500,
        ])
    }

    func start() {
        guard !started else { return }
        started = true
        migrateInfoStripDefaults()
        refresh()
        let player = PlayerState.shared
        lastSongID = player.currentSong?.id
        lastStarred = lastSongID.map { Library.shared.isStarred(songID: $0) }
        if let song = player.currentSong {
            prepareInfo(for: song)
        }
        observePlayer()
    }

    func refresh() {
        refreshStatusItem()
        if !enabled {
            resetInfo()
        } else if model.showsInfo, !isHiding {
            let delay = (isExpanded ? 0 : entranceDuration) + displayDuration
            scheduleHide(after: delay)
        }
    }

    private func migrateInfoStripDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "tray.infostripMigration") else { return }
        defaults.set(true, forKey: DefaultsKey.trackChange)
        defaults.set(true, forKey: "tray.infostripMigration")
    }

    private var enabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    private var trackChangeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.trackChange)
    }

    private var starChangeEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.starChange)
    }

    private var displayDurationMs: Int {
        max(300, UserDefaults.standard.integer(forKey: DefaultsKey.displayDurationMs))
    }

    private var displayDuration: TimeInterval {
        Double(displayDurationMs) / 1000
    }

    private func refreshStatusItem() {
        guard enabled else {
            stopAnimations()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            hostingView = nil
            return
        }

        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: TrayStatusModel.idleLength)
        guard let button = item.button else { return }
        button.image = nil
        button.title = ""
        button.toolTip = "Tracks"
        item.menu = makeMenu()

        let host = PassthroughHostingView(rootView: TrayStatusView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = button.bounds
        host.autoresizingMask = [.width, .height]
        button.addSubview(host)
        host.wantsLayer = true
        host.layer?.masksToBounds = true

        statusItem = item
        hostingView = host
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(title: "Show Tracks", action: #selector(showTracks)))
        menu.addItem(menuItem(title: "Hide Tracks", action: #selector(hideTracks)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Tracks", action: #selector(quitTracks)))
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showTracks() {
        WindowModeCenter.shared.showWindow()
    }

    @objc private func hideTracks() {
        WindowModeCenter.shared.hideWindow()
    }

    @objc private func quitTracks() {
        NSApp.terminate(nil)
    }

    private func observePlayer() {
        let player = PlayerState.shared
        player.$currentIndex
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.currentSongChanged() }
            }
            .store(in: &cancellables)
        player.$queueEntries
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.currentSongChanged() }
            }
            .store(in: &cancellables)

        Library.shared.$starredSongIDs
            .sink { [weak self] _ in
                // @Published emits before the property reflects the new set.
                // Defer one main-queue turn, then query the authoritative
                // Library state and show the value that was actually read.
                self?.scheduleStarCheck()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .artworkDidChange)
            .sink { [weak self] note in
                guard let self else { return }
                if let albumID = note.object as? String,
                   albumID != self.currentCoverKey { return }
                if let albumID = note.object as? String {
                    self.coverCache.removeObject(forKey: albumID as NSString)
                }
                self.currentCoverKey = nil
                self.coverReadyKey = nil
                self.model.coverImage = nil
                if let song = PlayerState.shared.currentSong {
                    self.prepareInfo(for: song)
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleStarCheck() {
        guard !starCheckScheduled else { return }
        starCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.starCheckScheduled = false
            self.checkStarState()
        }
    }

    private func checkStarState() {
        guard let song = PlayerState.shared.currentSong else { return }
        let starred = Library.shared.isStarred(songID: song.id)
        let changed = starred != lastStarred
        lastStarred = starred
        if changed, starChangeEnabled {
            showInfo(starred: starred)
        }
    }

    private func currentSongChanged() {
        let id = PlayerState.shared.currentSong?.id
        let changed = id != lastSongID
        lastSongID = id
        lastStarred = id.map { Library.shared.isStarred(songID: $0) }

        if let song = PlayerState.shared.currentSong {
            prepareInfo(for: song)
        } else {
            coverGeneration += 1
            coverLoadTask?.cancel()
            coverLoadTask = nil
            currentCoverKey = nil
            coverReadyKey = nil
            pendingShow = false
            model.artwork = nil
            model.coverImage = nil
        }

        if changed, id != nil, trackChangeEnabled {
            showInfo()
        }
    }

    private func prepareInfo(for song: Song, starred: Bool? = nil) {
        model.title = song.title
        model.subtitle = subtitle(for: song)
        model.isStarred = starred ?? Library.shared.isStarred(songID: song.id)
        let artwork = Library.shared.artwork(forAlbumTitle: song.album)
        model.artwork = artwork
        prepareCover(for: artwork)
    }

    private func showInfo(starred: Bool? = nil) {
        guard enabled, let song = PlayerState.shared.currentSong else { return }
        prepareInfo(for: song, starred: starred)

        if model.showsInfo {
            if isHiding {
                resumeVisible()
            } else if isExpanded {
                scheduleHide(after: displayDuration)
            }
            return
        }

        pendingShow = true
        if isCoverReady {
            finishPendingShow()
        }
    }

    private func beginShow() {
        guard enabled, !model.showsInfo else { return }
        sequence += 1
        let token = sequence
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isHiding = false
        isExpanded = false

        model.flipAngle = 0
        model.showsInfo = true
        animateFlip(to: 180, duration: flipDuration)
        animateLength(to: TrayStatusModel.expandedLength, duration: expandDuration)
        scheduleHide(after: entranceDuration + displayDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + entranceDuration) { [weak self] in
            guard let self, self.sequence == token else { return }
            self.isExpanded = true
        }
    }

    /// A new event arrived while the card was shrinking. Flip back to the
    /// cover and re-expand instead of letting the hide finish.
    private func resumeVisible() {
        sequence += 1
        let token = sequence
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isHiding = false
        isExpanded = false

        animateFlip(to: 180, duration: flipDuration)
        animateLength(to: TrayStatusModel.expandedLength, duration: expandDuration)
        scheduleHide(after: entranceDuration + displayDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + entranceDuration) { [weak self] in
            guard let self, self.sequence == token else { return }
            self.isExpanded = true
        }
    }

    private func prepareCover(for artwork: Artwork) {
        guard artwork.cacheKey != nil || artwork.imageData != nil else {
            coverGeneration += 1
            coverLoadTask?.cancel()
            coverLoadTask = nil
            currentCoverKey = nil
            coverReadyKey = nil
            model.coverImage = nil
            finishPendingShow()
            return
        }

        let key = coverKey(for: artwork)
        if key == currentCoverKey {
            if coverReadyKey == key {
                finishPendingShow()
            }
            return
        }

        coverGeneration += 1
        let generation = coverGeneration
        coverLoadTask?.cancel()
        coverLoadTask = nil
        currentCoverKey = key
        coverReadyKey = nil

        if let cached = coverCache.object(forKey: key as NSString) {
            model.coverImage = cached
            coverReadyKey = key
            finishPendingShow()
            return
        }

        model.coverImage = nil
        coverLoadTask = Task { [weak self] in
            let loaded = await ArtworkCache.shared.image(for: artwork, maxPixel: 64)
            guard let self, !Task.isCancelled, self.coverGeneration == generation else { return }
            let thumbnail = loaded.flatMap {
                Self.downsampleCover($0,
                                     maxPixel: 64,
                                     pointSize: TrayStatusModel.cardSize)
            }
            if let thumbnail {
                self.coverCache.setObject(thumbnail, forKey: key as NSString)
            }
            self.model.coverImage = thumbnail
            self.coverReadyKey = key
            self.finishPendingShow()
        }
    }

    private func finishPendingShow() {
        guard pendingShow else { return }
        pendingShow = false
        beginShow()
    }

    private func coverKey(for artwork: Artwork) -> String {
        if let key = artwork.cacheKey { return key }
        if let data = artwork.imageData {
            return "inline-\(data.count)-\(data.hashValue)"
        }
        return "placeholder"
    }

    private var isCoverReady: Bool {
        guard let artwork = model.artwork,
              artwork.cacheKey != nil || artwork.imageData != nil else { return true }
        guard let key = currentCoverKey else { return false }
        return coverReadyKey == key
    }

    /// Bilinear-downsample album art once, then keep the tiny image in memory.
    private nonisolated static func downsampleCover(_ image: NSImage,
                                                    maxPixel: Int,
                                                    pointSize: CGFloat) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let side = min(source.width, source.height)
        guard side > 0 else { return nil }
        let crop = CGRect(x: (source.width - side) / 2,
                          y: (source.height - side) / 2,
                          width: side,
                          height: side)
        guard let square = source.cropping(to: crop) else { return nil }

        let pixels = min(max(maxPixel, 1), side)
        guard let context = CGContext(data: nil,
                                      width: pixels,
                                      height: pixels,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(square, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: pointSize, height: pointSize))
    }

    private func subtitle(for song: Song) -> String {
        if song.album.isEmpty { return song.artist }
        if song.artist.isEmpty { return song.album }
        return "\(song.artist) — \(song.album)"
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let token = sequence
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sequence == token else { return }
            self.hideInfo()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideInfo() {
        guard model.showsInfo, !isHiding else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        sequence += 1
        let token = sequence
        isHiding = true
        isExpanded = false

        animateLength(to: TrayStatusModel.idleLength, duration: shrinkDuration)
        animateFlip(to: 0, duration: flipDuration)

        DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration) { [weak self] in
            guard let self, self.sequence == token else { return }
            self.model.showsInfo = false
            self.model.flipAngle = 0
            self.isHiding = false
        }
    }

    private func resetInfo() {
        sequence += 1
        hideWorkItem?.cancel()
        hideWorkItem = nil
        stopAnimations()
        pendingShow = false
        isExpanded = false
        isHiding = false
        model.showsInfo = false
        model.flipAngle = 0
        statusItem?.length = TrayStatusModel.idleLength
    }

    private func stopAnimations() {
        animationTimer?.invalidate()
        animationTimer = nil
        widthTween = nil
        flipTween = nil
    }

    private func animateLength(to target: CGFloat, duration: TimeInterval) {
        guard let item = statusItem else { return }
        let from = item.length
        guard abs(target - from) > 0.5 else {
            item.length = target
            widthTween = nil
            return
        }
        widthTween = Tween(from: Double(from),
                           to: Double(target),
                           start: CACurrentMediaTime(),
                           duration: duration)
        ensureAnimationTimer()
    }

    private func animateFlip(to target: Double, duration: TimeInterval) {
        let from = model.flipAngle
        guard abs(target - from) > 0.5 else {
            model.flipAngle = target
            flipTween = nil
            return
        }
        flipTween = Tween(from: from,
                          to: target,
                          start: CACurrentMediaTime(),
                          duration: duration)
        ensureAnimationTimer()
    }

    private func ensureAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0,
                          target: self,
                          selector: #selector(stepAnimations(_:)),
                          userInfo: nil,
                          repeats: true)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func stepAnimations(_ timer: Timer) {
        let now = CACurrentMediaTime()

        if let tween = widthTween, now >= tween.start {
            statusItem?.length = CGFloat(tween.value(at: now))
            if now >= tween.end {
                statusItem?.length = CGFloat(tween.to)
                widthTween = nil
            }
        }
        if let tween = flipTween, now >= tween.start {
            model.flipAngle = tween.value(at: now)
            if now >= tween.end {
                model.flipAngle = tween.to
                flipTween = nil
            }
        }

        if widthTween == nil, flipTween == nil {
            timer.invalidate()
            animationTimer = nil
        }
    }
}

private struct Tween {
    let from: Double
    let to: Double
    let start: CFTimeInterval
    let duration: TimeInterval

    var end: CFTimeInterval { start + max(duration, 0) }

    func value(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return to }
        let progress = min(max((time - start) / duration, 0), 1)
        return from + (to - from) * CircularEasing.value(progress)
    }
}

/// Circular ease-in-out: `t` maps to a quarter-circle arc, giving a slower
/// start and finish than a cubic timing curve.
private enum CircularEasing {
    static func value(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        if t < 0.5 {
            return (1 - sqrt(1 - pow(2 * t, 2))) / 2
        }
        return (sqrt(1 - pow(-2 * t + 2, 2)) + 1) / 2
    }
}

private struct TrayStatusView: View {
    @ObservedObject var model: TrayStatusModel

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 5) {
                TrayFlipCard(angle: model.flipAngle,
                             image: model.coverImage,
                             artwork: model.artwork)
                    .frame(width: TrayStatusModel.cardSize,
                           height: TrayStatusModel.cardSize)

                if model.showsInfo {
                    VStack(alignment: .leading, spacing: 0.5) {
                        Text(model.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(model.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: model.isStarred ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 11)
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, 5)
            .frame(width: TrayStatusModel.expandedLength,
                   height: 22,
                   alignment: .leading)
        }
        .clipped()
    }
}

private struct TrayFlipCard: View {
    let angle: Double
    let image: NSImage?
    let artwork: Artwork?

    var body: some View {
        let showsCover = angle >= 90
        ZStack {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.primary)
                .opacity(showsCover ? 0 : 1)

            TrayCoverView(image: image, artwork: artwork)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(showsCover ? 1 : 0)
        }
        .frame(width: TrayStatusModel.cardSize,
               height: TrayStatusModel.cardSize)
        .rotation3DEffect(.degrees(angle),
                          axis: (x: 0, y: 1, z: 0),
                          perspective: 0.35)
    }
}

private struct TrayCoverView: View {
    let image: NSImage?
    let artwork: Artwork?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if let artwork, !artwork.colors.isEmpty {
                LinearGradient(colors: artwork.colors,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            } else {
                Rectangle()
                    .fill(Color(white: 0.32))
                Image(systemName: "music.note")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .frame(width: TrayStatusModel.cardSize,
               height: TrayStatusModel.cardSize)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
