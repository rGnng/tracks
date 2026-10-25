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

    var region: Region = .content

    @Published private(set) var moveCount = 0
    private(set) var lastMove: Move = .down

    @Published private(set) var activateCount = 0

    func send(_ move: Move) {
        lastMove = move
        moveCount += 1
    }

    func activate() {
        activateCount += 1
    }
}
