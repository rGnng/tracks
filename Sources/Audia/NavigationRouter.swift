import AppKit
import Combine

enum NavigationFocus: Equatable {
    case sidebar
    case albumGrid
    case albumDetail
    case browserList
    case browserTracks
    case songTable
}

enum NavigationDirection: Equatable {
    case up
    case down
    case left
    case right
}

struct NavigationArrow: Equatable {
    let id: Int
    let direction: NavigationDirection
}

enum NavigationScrollCommand: Equatable {
    case home
    case end
    case pageUp
    case pageDown
}

struct NavigationScrollEvent: Equatable {
    let id: Int
    let command: NavigationScrollCommand
}

/// Window-scoped navigation keys. This is the beginning of the new navigation
/// layer: command shortcuts and text editing stay outside this router.
@MainActor
final class NavigationRouter: ObservableObject {
    static let shared = NavigationRouter()

    @Published private(set) var focus: NavigationFocus = .albumGrid
    @Published private(set) var arrow: NavigationArrow?
    @Published private(set) var scrollEvent: NavigationScrollEvent?

    private var arrowID = 0
    private var scrollEventID = 0

    private init() {}

    func setFocus(_ focus: NavigationFocus) {
        self.focus = focus
    }

    func focus(for selection: SidebarSelection) -> NavigationFocus {
        switch selection {
        case .library(.albums), .library(.recentlyAdded):
            return .albumGrid
        case .library(.artists), .library(.genres):
            return .browserList
        case .library(.songs), .starred, .playlist:
            return .songTable
        }
    }

    /// Returns true when the event was consumed by navigation.
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard window === WindowModeCenter.shared.mainWindow else { return false }
        guard !(window.firstResponder is NSText) else { return false }

        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift]
        )
        guard modifiers.isEmpty else { return false }

        if let direction = direction(for: event.keyCode) {
            sendArrow(direction)
            return true
        }

        if let command = scrollCommand(for: event.keyCode) {
            sendScroll(command)
            return true
        }

        guard !event.isARepeat else { return false }

        let selection: SidebarSelection
        switch event.keyCode {
        case 18: // 1
            selection = .library(.recentlyAdded)
        case 19: // 2
            selection = .library(.albums)
        case 20: // 3
            selection = .library(.artists)
        case 21: // 4
            selection = .library(.songs)
        case 23: // 5
            selection = .library(.genres)
        case 28: // 8
            selection = .starred
        default:
            return false
        }

        NavigationCenter.shared.sidebarSelection = selection
        setFocus(focus(for: selection))
        return true
    }

    private func direction(for keyCode: UInt16) -> NavigationDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    private func scrollCommand(for keyCode: UInt16) -> NavigationScrollCommand? {
        switch keyCode {
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default: return nil
        }
    }

    private func sendArrow(_ direction: NavigationDirection) {
        arrowID &+= 1
        arrow = NavigationArrow(id: arrowID, direction: direction)
    }

    private func sendScroll(_ command: NavigationScrollCommand) {
        scrollEventID &+= 1
        scrollEvent = NavigationScrollEvent(id: scrollEventID, command: command)
    }
}
