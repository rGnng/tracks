import SwiftUI

/// Cross-view navigation requests (e.g. "Go to Current Song" from the now
/// playing menu).
@MainActor
final class NavigationCenter: ObservableObject {
    static let shared = NavigationCenter()

    @Published var albumToOpen: UUID?
    /// Artist name to select after switching to the Artists browser.
    @Published var artistToOpen: String?
}
