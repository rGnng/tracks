import SwiftUI
import AppKit

struct ContentView: View {
    let appearanceMode: String

    @EnvironmentObject private var player: PlayerState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showStatusBar") private var showStatusBar = true
    @ObservedObject private var navigation = NavigationCenter.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var windowMode = WindowModeCenter.shared
    @State private var selection: SidebarSelection = .library(.albums)
    @State private var sidebarWidth: CGFloat = 200
    @State private var dragStartWidth: CGFloat?
    @State private var searchText = ""
    @State private var pendingAlbumID: UUID?

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        Group {
            if windowMode.mode == .miniPlayer {
                MiniPlayerView()
            } else {
                libraryView
            }
        }
        .background(Theme.contentBackground)
        .background(WindowConfigurator())
        .ignoresSafeArea(edges: .top)
        .overlay {
            if windowMode.mode == .library {
                DragPreviewOverlay()
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            // SwiftUI focuses the search field when the window first appears.
            // Clear the first responder so nothing is selected on launch.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }

            // Invite the user to create the writable Internal Library. Doing it
            // from a window (and later via NSOpenPanel) is also what gives the
            // app permission to work inside ~/Music.
            if library.shouldAutoPromptSetup {
                library.markSetupPromptShown()
                openWindow(id: "setup")
            }
        }
        .onChange(of: navigation.albumToOpen) { _, id in
            guard let id else { return }
            pendingAlbumID = id
            selection = .library(.albums)
            navigation.albumToOpen = nil
        }
        .onChange(of: navigation.artistToOpen) { _, artist in
            guard artist != nil else { return }
            selection = .library(.artists)
            searchText = ""
            pendingAlbumID = nil
        }
        .onChange(of: selection) { _, newValue in
            searchText = ""
            switch newValue {
            case .playlist(let id):
                StatusBarCenter.shared.context = .playlist(id)
            case .starred:
                StatusBarCenter.shared.context = .starred
            case .library(.albums), .library(.recentlyAdded), .library(.songs):
                StatusBarCenter.shared.context = .library
            case .library(.artists), .library(.genres):
                // The browser sets the selected artist/genre when it appears.
                break
            }
        }
        .onChange(of: windowMode.mode) { _, _ in
            searchText = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            selection = .library(.albums)
            searchText = ""
            pendingAlbumID = nil
            StatusBarCenter.shared.context = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSetupWindow)) { _ in
            openWindow(id: "setup")
        }
        .alert(
            "Library Opened",
            isPresented: Binding(
                get: { library.openWarning != nil },
                set: { if !$0 { library.clearOpenWarning() } }
            )
        ) {
            Button("OK") { library.clearOpenWarning() }
        } message: {
            Text(library.openWarning ?? "")
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            PlayerToolbar(searchText: $searchText)
            Hairline()
            HStack(spacing: 0) {
                SidebarView(selection: $selection, width: sidebarWidth)
                    .fixedSize(horizontal: true, vertical: false)
                SidebarDivider(width: $sidebarWidth, dragStartWidth: $dragStartWidth)
                ContentPane(selection: selection, searchText: searchText, openAlbumID: $pendingAlbumID)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            if showStatusBar {
                Hairline()
                StatusBarView()
            }
        }
        .frame(minWidth: 1040, minHeight: 640)
    }
}

/// A 1px divider with a wider invisible drag handle and a resize cursor.
private struct SidebarDivider: View {
    @Binding var width: CGFloat
    @Binding var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .onHover { hovering in
                        // `set` instead of push/pop: the hover state can fire
                        // repeatedly while the divider follows the drag, and an
                        // unbalanced push/pop stack makes the cursor flicker.
                        if hovering { NSCursor.resizeLeftRight.set() }
                        else { NSCursor.arrow.set() }
                    }
            }
    }

    /// Global coordinates keep the drag stable: the divider itself moves as the
    /// sidebar is resized, so local-space translations feed back into the gesture
    /// and make the divider jitter back and forth.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragStartWidth == nil { dragStartWidth = width }
                let delta = value.location.x - value.startLocation.x
                width = min(max((dragStartWidth ?? width) + delta, 160), 340)
            }
            .onEnded { _ in dragStartWidth = nil }
    }
}

/// Floating preview for the custom long-press drag session.
private struct DragPreviewOverlay: View {
    @ObservedObject private var drag = DragController.shared

    var body: some View {
        GeometryReader { proxy in
            if let payload = drag.payload, let location = drag.location {
                let origin = proxy.frame(in: .global).origin
                HStack(spacing: 8) {
                    if let artwork = payload.artwork {
                        AlbumArtwork(artwork: artwork)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.primaryText)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.controlBackground)
                            )
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(payload.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                        Text(payload.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundColor(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .position(x: location.x - origin.x + 18,
                          y: location.y - origin.y + 18)
            }
        }
    }
}
