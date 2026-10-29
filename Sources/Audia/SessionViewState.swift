import CoreGraphics
import Foundation

/// Session-only view state. Views are recreated when the sidebar selection
/// changes, so each view saves its own scroll offset and selection here and
/// restores them when the same view is shown again in this app session.
///
/// This deliberately does not persist anything across launches and does not
/// store rendered frames or viewport anchors.
@MainActor
final class SessionViewState {
    static let shared = SessionViewState()

    struct AlbumState: Equatable {
        var offset: CGFloat
        var selectedIDs: Set<UUID>
        var anchor: UUID?
        var itemCount: Int
    }

    struct SongState: Equatable {
        var offset: CGFloat
        var selectedIDs: Set<UUID>
        var anchor: UUID?
        var itemCount: Int
        var debugTag: String = ""
    }

    struct BrowserState: Equatable {
        var offset: CGFloat
        var selectedID: String?
        var itemCount: Int
    }

    private var albumStates: [String: AlbumState] = [:]
    private var songStates: [String: SongState] = [:]
    private var browserStates: [String: BrowserState] = [:]

    private init() {}

    func albumState(for key: String) -> AlbumState? {
        albumStates[key]
    }

    func saveAlbum(_ state: AlbumState, for key: String) {
        albumStates[key] = state
    }

    func songState(for key: String) -> SongState? {
        songStates[key]
    }

    func saveSong(_ state: SongState, for key: String) {
        songStates[key] = state
        DebugState.shared.sessionSave = "\(key) inst=\(state.debugTag) off=\(String(format: "%.1f", state.offset)) n=\(state.selectedIDs.count) a=\(state.anchor?.uuidString.prefix(8) ?? "nil")"
    }

    func browserState(for key: String) -> BrowserState? {
        browserStates[key]
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
