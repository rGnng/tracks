import CoreGraphics
import Foundation

/// Per-view scroll offsets. Views are recreated when the sidebar selection
/// changes, so each view saves its own offset here and restores it when the
/// same view is shown again. The offset of the viewport that is active when the
/// app quits is also persisted once and restored on the next launch.
///
/// Selections and rendered frames are deliberately not stored.
@MainActor
final class SessionViewState {
    static let shared = SessionViewState()

    struct AlbumState: Equatable {
        var offset: CGFloat
        var itemCount: Int
    }

    struct SongState: Equatable {
        var offset: CGFloat
        var itemCount: Int
    }

    struct BrowserState: Equatable {
        var offset: CGFloat
        var itemCount: Int
    }

    private var albumStates: [String: AlbumState] = [:]
    private var songStates: [String: SongState] = [:]
    private var browserStates: [String: BrowserState] = [:]

    private var activeKey: String?
    private var activeOffset: CGFloat = 0
    private var activeItemCount = 0
    private var didLoadLaunchViewport = false

    private enum PersistedKey {
        static let view = "tracks.lastViewport.key"
        static let offset = "tracks.lastViewport.offset"
        static let itemCount = "tracks.lastViewport.itemCount"
    }

    private init() {}

    func setActiveView(key: String, offset: CGFloat, itemCount: Int) {
        activeKey = key
        activeOffset = offset
        activeItemCount = itemCount
    }

    func persistActiveViewport() {
        guard let activeKey else { return }
        let defaults = UserDefaults.standard
        defaults.set(activeKey, forKey: PersistedKey.view)
        defaults.set(Double(activeOffset), forKey: PersistedKey.offset)
        defaults.set(activeItemCount, forKey: PersistedKey.itemCount)
    }

    private func loadLaunchViewportIfNeeded() {
        guard !didLoadLaunchViewport else { return }
        didLoadLaunchViewport = true

        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: PersistedKey.view),
              defaults.object(forKey: PersistedKey.offset) != nil else { return }
        let offset = CGFloat(defaults.double(forKey: PersistedKey.offset))
        let itemCount = defaults.integer(forKey: PersistedKey.itemCount)

        switch key {
        case "library:Albums", "library:Recently Added",
             "library:albums", "library:recentlyAdded":
            if albumStates[key] == nil {
                albumStates[key] = AlbumState(offset: offset, itemCount: itemCount)
            }
        case "songs", "starred":
            if songStates[key] == nil {
                songStates[key] = SongState(offset: offset, itemCount: itemCount)
            }
        case "artists", "genres":
            if browserStates[key] == nil {
                browserStates[key] = BrowserState(offset: offset, itemCount: itemCount)
            }
        default:
            if key.hasPrefix("playlist:") {
                if songStates[key] == nil {
                    songStates[key] = SongState(offset: offset, itemCount: itemCount)
                }
            } else {
                return
            }
        }

        activeKey = key
        activeOffset = offset
        activeItemCount = itemCount
    }

    func albumState(for key: String) -> AlbumState? {
        loadLaunchViewportIfNeeded()
        return albumStates[key]
    }

    func saveAlbum(_ state: AlbumState, for key: String) {
        albumStates[key] = state
    }

    func songState(for key: String) -> SongState? {
        loadLaunchViewportIfNeeded()
        return songStates[key]
    }

    func saveSong(_ state: SongState, for key: String) {
        songStates[key] = state
    }

    func browserState(for key: String) -> BrowserState? {
        loadLaunchViewportIfNeeded()
        return browserStates[key]
    }

    func saveBrowser(_ state: BrowserState, for key: String) {
        browserStates[key] = state
    }

    func clearAlbum(_ key: String) {
        albumStates[key] = nil
    }

    func clearSong(_ key: String) {
        songStates[key] = nil
    }

    func clearBrowser(_ key: String) {
        browserStates[key] = nil
    }
}
