import SwiftUI

/// Routes window-level keyboard commands (arrow keys) to whichever list the
/// pointer is currently over. The window key monitor lives in `AppDelegate`;
/// list views observe `moveCount` and consult `region` / `lastMove`.
@MainActor
final class KeyboardNavigator: ObservableObject {    static let shared = KeyboardNavigator()

    enum Region {
        case sidebar
        case content
    }

    enum Move {
        case up
        case down
        case left
        case right
    }

    enum ScrollCommand {
        case top
        case bottom
        case pageUp
        case pageDown
    }

    var region: Region = .content

    @Published private(set) var moveCount = 0
    private(set) var lastMove: Move = .down

    @Published private(set) var activateCount = 0

    /// Home/End/Page keys are routed to the focused SwiftUI list, which scrolls
    /// through its own `ScrollPosition` and geometry. Poking NSScrollView
    /// directly bypasses that bookkeeping and made the view jump back to its
    /// old row.
    @Published private(set) var scrollCount = 0
    private(set) var lastScrollCommand: ScrollCommand = .top

    func send(_ move: Move) {
        lastMove = move
        moveCount += 1
    }

    func activate() {
        activateCount += 1
    }

    func sendScroll(_ command: ScrollCommand) {
        lastScrollCommand = command
        scrollCount += 1
    }
}
