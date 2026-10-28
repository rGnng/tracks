import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection
    let width: CGFloat

    @ObservedObject private var navigator = KeyboardNavigator.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var drag = DragController.shared
    @ObservedObject private var importer = MediaImporter.shared
    @EnvironmentObject private var player: PlayerState
    @AppStorage("albumSort") private var albumSort = GridSort.album.rawValue
    @AppStorage("albumSortDirection") private var albumSortDirection =
        GridSortDirection.ascending.rawValue
    @State private var hoveringPlaylistHeader = false

    @State private var editingPlaylistID: UUID?
    @State private var creatingPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader("Library")
            ForEach(LibrarySection.allCases) { section in
                SidebarItem(
                    icon: section.icon,
                    title: section.rawValue,
                    isSelected: selection == .library(section)
                ) {
                    selection = .library(section)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard section == .albums || section == .recentlyAdded else { return }
                    player.play(songs(for: section))
                })
                .contextMenu {
                    if section == .albums || section == .recentlyAdded {
                        Button("Play") { player.play(songs(for: section)) }
                            .disabled(library.albums.isEmpty)
                        Button("Shuffle") { player.playShuffled(songs(for: section)) }
                            .disabled(library.albums.isEmpty)
                    }
                }
            }

            HStack(spacing: 4) {
                SidebarHeader("Playlists")
                Spacer()
                Button {
                    editingPlaylistID = nil
                    creatingPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .opacity(hoveringPlaylistHeader ? 1 : 0)
                .allowsHitTesting(hoveringPlaylistHeader)
            }
            .padding(.top, 12)
            .onHover { inside in
                hoveringPlaylistHeader = inside
            }

            SidebarItem(
                icon: "star",
                title: Library.starredPlaylistName,
                isSelected: selection == .starred,
                isDropTarget: drag.targetPlaylistID == Library.starredPlaylistID
            ) {
                selection = .starred
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                player.play(SongSortStore.sorted(library.starredSongs, for: .starred))
            })
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PlaylistFramesKey.self,
                        value: [Library.starredPlaylistID: proxy.frame(in: .global)]
                    )
                }
            )
            .contextMenu {
                Button("Play") { player.play(library.starredSongs) }
                    .disabled(library.starredSongs.isEmpty)
                Button("Shuffle") { player.playShuffled(library.starredSongs) }
                    .disabled(library.starredSongs.isEmpty)
            }

            ForEach(library.playlists) { playlist in
                if editingPlaylistID == playlist.id {
                    InlinePlaylistField(initialText: playlist.name,
                                        onCommit: { name in
                                            library.renamePlaylist(playlist.id, to: name)
                                            editingPlaylistID = nil
                                        },
                                        onCancel: {
                                            editingPlaylistID = nil
                                        })
                } else {
                    SidebarItem(
                        icon: "music.note.list",
                        title: playlist.name,
                        isSelected: selection == .playlist(playlist.id),
                        isDropTarget: drag.targetPlaylistID == playlist.id
                    ) {
                        selection = .playlist(playlist.id)
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        player.play(SongSortStore.sorted(playlist.songs,
                                                         for: .playlist(playlist.id),
                                                         playlistInfo: playlist.itemInfo))
                    })
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PlaylistFramesKey.self,
                                value: [playlist.id: proxy.frame(in: .global)]
                            )
                        }
                    )
                    .contextMenu {
                        Button("Play") { player.play(playlist.songs) }
                            .disabled(playlist.songs.isEmpty)
                        Button("Shuffle") { player.playShuffled(playlist.songs) }
                            .disabled(playlist.songs.isEmpty)
                        Divider()
                        Button("Rename") {
                            creatingPlaylist = false
                            editingPlaylistID = playlist.id
                        }
                        Button("Delete", role: .destructive) {
                            library.deletePlaylist(playlist.id)
                            if selection == .playlist(playlist.id) {
                                selection = .library(.recentlyAdded)
                            }
                        }
                    }
                }
            }

            if creatingPlaylist {
                InlinePlaylistField(initialText: "",
                                    onCommit: { name in
                                        let playlist = library.createPlaylist(name: name)
                                        selection = .playlist(playlist.id)
                                        creatingPlaylist = false
                                    },
                                    onCancel: {
                                        creatingPlaylist = false
                                    })
            }

            Spacer(minLength: 0)
            if let activity = sidebarActivity {
                SidebarActivityView(title: activity.title,
                                    progress: activity.progress,
                                    detail: activity.detail)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: width)
        .background(Theme.sidebarBackground)
        .onHover { inside in
            if inside { navigator.region = .sidebar }
        }
        .onChange(of: navigator.moveCount) { _, _ in
            moveSelection()
        }
        .onPreferenceChange(PlaylistFramesKey.self) { frames in
            drag.playlistFrames = frames
        }
    }

    /// Whole-library Play/Shuffle targets for the sidebar sections. The
    /// returned order mirrors the corresponding content view.
    private func songs(for section: LibrarySection) -> [Song] {
        switch section {
        case .albums:
            let sort = GridSort(rawValue: albumSort) ?? .album
            let direction = GridSortDirection(rawValue: albumSortDirection) ?? .ascending
            return albumsSorted(library.albums, by: sort, direction: direction)
                .flatMap(\.songs)
        case .recentlyAdded:
            return recentAlbumsSorted(library.albums).flatMap(\.songs)
        default:
            return []
        }
    }

    private var sidebarActivity: (title: String, progress: Double?, detail: String?)? {
        if importer.isImporting {
            let detail = importer.importTotal > 0
                ? "\(importer.importCompleted)/\(importer.importTotal)"
                : nil
            return ("Importing", importer.importProgress, detail)
        }
        if library.isScanning {
            return (library.scanPhase.rawValue,
                    library.scanActivityProgress,
                    library.scanActivityDetail)
        }
        return nil
    }

    private var flatSelections: [SidebarSelection] {
        LibrarySection.allCases.map { .library($0) } + [.starred] + library.playlists.map { .playlist($0.id) }
    }

    private func moveSelection() {
        guard navigator.region == .sidebar else { return }
        guard navigator.lastMove == .up || navigator.lastMove == .down else { return }
        let items = flatSelections
        guard !items.isEmpty else { return }
        let delta = navigator.lastMove == .up ? -1 : 1
        if let index = items.firstIndex(of: selection) {
            selection = items[min(max(index + delta, 0), items.count - 1)]
        } else if let first = items.first {
            selection = first
        }
    }
}

private struct SidebarHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.sidebarHeaderText)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 3)
    }
}

private struct SidebarItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    var isDropTarget: Bool = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? Theme.primaryText : Theme.secondaryText)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isDropTarget ? Theme.selectionFill : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .onHover { hover = $0 }
    }

    private var background: AnyShapeStyle {
        if isDropTarget {
            return AnyShapeStyle(Theme.selectionFill.opacity(0.22))
        } else if isSelected {
            return AnyShapeStyle(Theme.sidebarSelection)
        } else if hover {
            return AnyShapeStyle(Theme.sidebarHover)
        }
        return AnyShapeStyle(Color.clear)
    }
}

struct SidebarActivityView: View {
    let title: String
    let progress: Double?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(Theme.secondaryText.opacity(0.85))
                }
            }
            Group {
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

private struct InlinePlaylistField: View {
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(initialText: String,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 18)
            TextField("Playlist Name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.controlBackground)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.highlight, lineWidth: 1))
        )
        .padding(.horizontal, 7)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            onCancel()
        } else {
            onCommit(name)
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}
