import Combine
import Foundation

/// Persists the Library sidebar's windowed and full-screen visibility
/// independently. Full-screen visibility defaults to hidden.
@MainActor
final class SidebarVisibilityStore: ObservableObject {
    static let shared = SidebarVisibilityStore()

    private static let windowedKey = "sidebarVisible"
    private static let fullScreenKey = "sidebarFullScreenVisible"

    @Published private(set) var isVisible: Bool

    private var windowedVisible: Bool
    private var fullScreenVisible: Bool
    private var cancellable: AnyCancellable?

    private init() {
        let defaults = UserDefaults.standard
        windowedVisible = defaults.object(forKey: Self.windowedKey) as? Bool ?? true
        fullScreenVisible = defaults.object(forKey: Self.fullScreenKey) as? Bool ?? false
        isVisible = WindowModeCenter.shared.isFullScreen
            ? fullScreenVisible
            : windowedVisible

        cancellable = WindowModeCenter.shared.$isFullScreen
            .removeDuplicates()
            .sink { [weak self] isFullScreen in
                Task { @MainActor in
                    self?.refresh(for: isFullScreen)
                }
            }
    }

    func toggle() {
        let defaults = UserDefaults.standard
        if WindowModeCenter.shared.isFullScreen {
            fullScreenVisible.toggle()
            defaults.set(fullScreenVisible, forKey: Self.fullScreenKey)
        } else {
            windowedVisible.toggle()
            defaults.set(windowedVisible, forKey: Self.windowedKey)
        }
        refresh(for: WindowModeCenter.shared.isFullScreen)
    }

    private func refresh(for isFullScreen: Bool) {
        isVisible = isFullScreen ? fullScreenVisible : windowedVisible
    }
}
