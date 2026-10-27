import SwiftUI
@preconcurrency import AppKit

@main
struct AudiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("highlightColor") private var highlightColorRaw = HighlightColor.graphite.rawValue
    @AppStorage("showStatusBar") private var showStatusBar = true

    private var highlightColor: Color {
        (HighlightColor(rawValue: highlightColorRaw) ?? .system).color
    }

    var body: some Scene {
        Window("Tracks", id: "main") {
            ContentView()
                .environmentObject(PlayerState.shared)
                .accentColor(highlightColor)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Media…") {
                    MediaImporter.shared.chooseAndImport()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find") {
                    let wasMini = WindowModeCenter.shared.mode == .miniPlayer
                    WindowModeCenter.shared.setMode(.library)
                    WindowModeCenter.shared.showWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + (wasMini ? 0.30 : 0.05)) {
                        NotificationCenter.default.post(name: .focusSearch, object: nil)
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(before: .windowSize) {
                Button("Library") {
                    WindowModeCenter.shared.setMode(.library)
                    WindowModeCenter.shared.showWindow()
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("MiniPlayer") {
                    WindowModeCenter.shared.setMode(.miniPlayer)
                    WindowModeCenter.shared.showWindow()
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()
            }

            CommandMenu("Controls") {
                Button("Play / Pause") { PlayerState.shared.togglePlayPause() }
                Button("Next Track") { PlayerState.shared.next() }
                Button("Previous Track") { PlayerState.shared.previous() }
            }
            // Add these to the standard View menu instead of creating a second
            // top-level menu titled "View".
            CommandGroup(after: .toolbar) {
                Button(showStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                    showStatusBar.toggle()
                }
                .keyboardShortcut("/", modifiers: .command)

                Divider()

                Picker("Appearance", selection: $appearanceMode) {
                    Text("Automatic").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
        }

        Settings {
            SettingsView()
                .accentColor(highlightColor)
        }
        .defaultSize(width: 760, height: 720)

        Window("Get Info", id: "get-info") {
            GetInfoView()
                .accentColor(highlightColor)
        }
        .defaultSize(width: 540, height: 620)

        Window("Set Up Tracks Library", id: "setup") {
            InternalLibrarySetupView()
                .accentColor(highlightColor)
        }
        .defaultSize(width: 540, height: 410)
        .windowResizability(.contentSize)
    }
}

private enum SettingsAlert: Identifiable {
    case error(String)
    case confirmOpen(String)
    case confirmDisable(MusicLibrary)
    case confirmDelete(MusicLibrary)
    case notice(title: String, message: String)

    var id: String {
        switch self {
        case .error(let message): return "error:\(message)"
        case .confirmOpen(let path): return "open:\(path)"
        case .confirmDisable(let library): return "disable:\(library.id)"
        case .confirmDelete(let library): return "delete:\(library.id)"
        case .notice(let title, let message): return "notice:\(title):\(message)"
        }
    }
}

@MainActor
private enum LibraryFolderPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Tracks library folder (it contains library.sqlite and Music), or select its library.sqlite file."
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return url.path }
        if url.lastPathComponent == "library.sqlite" {
            return url.deletingLastPathComponent().path
        }
        return url.path
    }
}

struct SettingsView: View {
    @AppStorage("albumViewMode") private var albumViewMode = "grid"
    @AppStorage("albumSort") private var albumSort = GridSort.album.rawValue
    @AppStorage("albumSortDirection") private var albumSortDirection =
        GridSortDirection.ascending.rawValue
    @AppStorage("highlightColor") private var highlightColor = HighlightColor.graphite.rawValue
    @AppStorage("mpd.enabled") private var mpdEnabled = false
    @AppStorage("mpd.allInterfaces") private var mpdAllInterfaces = false
    @AppStorage("mpd.addresses") private var mpdAddresses = "127.0.0.1"
    @AppStorage("mpd.port") private var mpdPort = 6600
    @AppStorage("mpd.password") private var mpdPassword = ""
    @AppStorage("artworkCacheJPEGQuality") private var artworkCacheJPEGQuality = 0.8
    @AppStorage(TrayController.DefaultsKey.enabled) private var trayEnabled = false
    @AppStorage(TrayController.DefaultsKey.trackChange) private var trayTrackChange = false
    @AppStorage(TrayController.DefaultsKey.starChange) private var trayStarChange = true
    @AppStorage(TrayController.DefaultsKey.onlyWhenLibraryNotFocused)
    private var trayOnlyWhenLibraryNotFocused = true
    @AppStorage(TrayController.DefaultsKey.popupDurationMs)
    private var trayPopupDurationMs = 1500
    @State private var starShortcut: KeyboardShortcut? = KeyboardShortcutStore.loadStar()
    @State private var goToAlbumShortcut: KeyboardShortcut? = KeyboardShortcutStore.loadGoToAlbum()
    @State private var showHideShortcut: KeyboardShortcut? = KeyboardShortcutStore.loadShowHide()
    @State private var muteShortcut: KeyboardShortcut? = KeyboardShortcutStore.loadMute()
    @State private var volumeDownShortcut: KeyboardShortcut? = KeyboardShortcutStore.loadVolumeDown()
    @State private var volumeUpShortcut: KeyboardShortcut? = KeyboardShortcutStore.loadVolumeUp()
    @State private var starScope = KeyboardShortcutStore.scope(for: .starCurrent)
    @State private var goToAlbumScope = KeyboardShortcutStore.scope(for: .goToCurrentAlbum)
    @State private var showHideScope = KeyboardShortcutStore.scope(for: .showHide)
    @State private var muteScope = KeyboardShortcutStore.scope(for: .mute)
    @State private var volumeDownScope = KeyboardShortcutStore.scope(for: .volumeDown)
    @State private var volumeUpScope = KeyboardShortcutStore.scope(for: .volumeUp)
    @State private var enabledShortcuts = Dictionary(
        uniqueKeysWithValues: ShortcutAction.allCases.map {
            ($0, KeyboardShortcutStore.isEnabled($0))
        }
    )
    @ObservedObject private var library = Library.shared
    @ObservedObject private var artworkCache = ArtworkCache.shared
    @ObservedObject private var mpd = MPDServer.shared
    @Environment(\.openWindow) private var openWindow

    @State private var alert: SettingsAlert?
    @State private var mpdApplyTask: Task<Void, Never>?
    @State private var artworkQualityText = "80"
    @State private var selectedSection: SettingsSection? = .general
    @State private var missingFileReport: LibraryMissingReport?
    @FocusState private var artworkQualityFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsPageHeader(selectedSection ?? .general)
                    settingsContent(selectedSection ?? .general)
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(SettingsTypography.body)
        .frame(width: 760, height: 720, alignment: .topLeading)
        .background(SettingsFocusSink())
        .onAppear {
            artworkQualityText = "\(artworkQualityPercent)"
            starShortcut = KeyboardShortcutStore.loadStar()
            goToAlbumShortcut = KeyboardShortcutStore.loadGoToAlbum()
            showHideShortcut = KeyboardShortcutStore.loadShowHide()
            muteShortcut = KeyboardShortcutStore.loadMute()
            volumeDownShortcut = KeyboardShortcutStore.loadVolumeDown()
            volumeUpShortcut = KeyboardShortcutStore.loadVolumeUp()
            starScope = KeyboardShortcutStore.scope(for: .starCurrent)
            goToAlbumScope = KeyboardShortcutStore.scope(for: .goToCurrentAlbum)
            showHideScope = KeyboardShortcutStore.scope(for: .showHide)
            muteScope = KeyboardShortcutStore.scope(for: .mute)
            volumeDownScope = KeyboardShortcutStore.scope(for: .volumeDown)
            volumeUpScope = KeyboardShortcutStore.scope(for: .volumeUp)
            enabledShortcuts = Dictionary(
                uniqueKeysWithValues: ShortcutAction.allCases.map {
                    ($0, KeyboardShortcutStore.isEnabled($0))
                }
            )
            artworkCache.refreshCacheSize()
        }
        .onChange(of: artworkCacheJPEGQuality) { _, _ in
            if !artworkQualityFocused { artworkQualityText = "\(artworkQualityPercent)" }
        }
        .alert(item: $alert) { alert in
            switch alert {
            case .error(let message):
                return Alert(
                    title: Text("Library Error"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            case .confirmOpen(let path):
                return Alert(
                    title: Text("Open Another Library?"),
                    message: Text("The current library will be replaced in Tracks. Its folder and files are not deleted."),
                    primaryButton: .default(Text("Open")) {
                        // Let the confirmation alert dismiss before a potential
                        // error alert is presented.
                        DispatchQueue.main.async { performOpen(path) }
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDisable(let externalLibrary):
                return Alert(
                    title: Text("Disable External Library?"),
                    message: Text("Disabling “\(externalLibrary.name)” stops playback and clears the playback queue and History. Its songs will be hidden throughout Tracks. Library and playlist data remain stored and can be restored by enabling it again."),
                    primaryButton: .destructive(Text("Disable")) {
                        do {
                            try library.setExternalLibrary(externalLibrary.id, enabled: false)
                        } catch {
                            self.alert = .error(error.localizedDescription)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDelete(let externalLibrary):
                return Alert(
                    title: Text("Delete External Library Index?"),
                    message: Text("This removes “\(externalLibrary.name)” and its indexed songs from Tracks, including their playlist entries, play counts, and stars. User-created playlists remain, even if empty. Audio files on the external drive are not deleted. A timestamped database backup will be created first."),
                    primaryButton: .destructive(Text("Delete Index")) {
                        do {
                            let backup = try library.deleteDisabledExternalLibrary(externalLibrary.id)
                            self.alert = .notice(title: "External Library Deleted",
                                                 message: "The library index was deleted. Backup saved at:\n\(backup.path)")
                        } catch {
                            self.alert = .error(error.localizedDescription)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .notice(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .sheet(item: $missingFileReport) { report in
            MissingFilesReviewView(
                report: report,
                onKeep: { missingFileReport = nil },
                onDelete: { ids in
                    do {
                        try library.removeMissingSongs(libraryID: report.libraryID, songIDs: ids)
                        missingFileReport = nil
                    } catch {
                        alert = .error(error.localizedDescription)
                    }
                },
                onRelocate: { ids in
                    Task { @MainActor in
                        do {
                            let backup = try await library.applyRelocation(report, removingMissingIDs: ids)
                            missingFileReport = nil
                            alert = .notice(title: "Library Relocated",
                                            message: "The library was relocated. Backup saved at:\n\(backup.path)")
                        } catch {
                            alert = .error(error.localizedDescription)
                        }
                    }
                }
            )
            .frame(width: 720, height: 620)
        }
        .onChange(of: mpdEnabled) { _, _ in
            mpd.notifyOutputConfigurationChanged()
            scheduleMPDApply()
        }
        .onChange(of: mpdAllInterfaces) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdAddresses) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdPort) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdPassword) { _, _ in scheduleMPDApply() }
        .onChange(of: library.scanError) { _, message in
            if let message, !message.isEmpty { alert = .error(message) }
        }
    }

    private func settingsPageHeader(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(SettingsTypography.pageTitle)
                .foregroundColor(Theme.primaryText)
            Text(section.subtitle)
                .font(SettingsTypography.help)
                .foregroundColor(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private func settingsContent(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            generalSettings
        case .library:
            librarySettings
        case .shortcuts:
            shortcutsSettings
        case .services:
            VStack(alignment: .leading, spacing: 14) {
                traySettings
                Divider()
                mpdSettings
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Album display as", selection: $albumViewMode) {
                Text("Grid").tag("grid")
                Text("List").tag("list")
            }
            .pickerStyle(.menu)
            .frame(width: 260, alignment: .leading)

            HStack(spacing: 12) {
                Picker("Albums sorted by", selection: $albumSort) {
                    ForEach(GridSort.allCases, id: \.self) { sort in
                        Text(sort == .album ? "Album Name" : sort.rawValue)
                            .tag(sort.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Sort", selection: $albumSortDirection) {
                    ForEach(GridSortDirection.allCases) { direction in
                        Text(direction.title).tag(direction.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .frame(maxWidth: 420, alignment: .leading)

            HStack(spacing: 10) {
                Text("Highlights")

                HStack(spacing: 2) {
                    ForEach(HighlightColor.allCases) { choice in
                        let selected = highlightColor == choice.rawValue
                        Button {
                            highlightColor = choice.rawValue
                        } label: {
                            ZStack {
                                if selected {
                                    Circle()
                                        .strokeBorder(Color.primary, lineWidth: 2)
                                        .frame(width: 24, height: 24)
                                }
                                Circle()
                                    .fill(choice.swatch)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                                    )
                            }
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(choice.title)
                        .accessibilityLabel("\(choice.title) highlight")
                    }
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private var librarySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Music Folders")
                    .font(SettingsTypography.sectionTitle)
                    .foregroundColor(Theme.primaryText)
                Spacer()
                Text("\(library.albums.count) albums · \(library.allSongs.count) songs")
                    .font(SettingsTypography.caption.monospacedDigit())
                    .foregroundColor(Theme.secondaryText)
            }

            if library.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: library.scanProgress)
                        .progressViewStyle(.linear)
                    Text(library.scanTotal > 0
                         ? "Scanning \(library.scanCompleted) of \(library.scanTotal) files…"
                         : "Scanning…")
                        .font(SettingsTypography.help)
                        .foregroundColor(Theme.secondaryText)
                }
                .padding(.vertical, 4)
            }

            internalLibrarySection
            Divider()
            externalLibrariesSection
            Divider()
            artworkCacheSection
        }
    }

    private var artworkCacheSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Artwork Cache")
                        .font(SettingsTypography.cardTitle)
                        .foregroundColor(Theme.primaryText)
                    Text("Cached album art speeds up browsing. It is rebuilt from library files.")
                        .font(SettingsTypography.help)
                        .foregroundColor(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Rebuild Cache") {
                    artworkCache.rebuildCache()
                }
            }

            HStack(spacing: 8) {
                Text("JPEG quality")
                    .font(SettingsTypography.body)
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 120, alignment: .leading)
                TextField("80", text: $artworkQualityText)
                    .textFieldStyle(.roundedBorder)
                    .font(SettingsTypography.body.monospacedDigit())
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                    .focused($artworkQualityFocused)
                    .onSubmit { commitArtworkQuality() }
                    .onChange(of: artworkQualityFocused) { _, focused in
                        if !focused { commitArtworkQuality() }
                    }
                    .onChange(of: artworkQualityText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { artworkQualityText = digits }
                    }
                Text("%")
                    .font(SettingsTypography.body)
                    .foregroundColor(Theme.secondaryText)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Cache size")
                    .font(SettingsTypography.body)
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 120, alignment: .leading)
                Text(artworkCacheSizeText)
                    .font(SettingsTypography.body.monospacedDigit())
                    .foregroundColor(Theme.primaryText)
                Spacer(minLength: 0)
            }
        }
    }

    private var shortcutsSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            shortcutTableHeader
            shortcutRow(.mute,
                        enabled: enabledBinding(for: .mute),
                        shortcut: $muteShortcut,
                        scope: $muteScope)
            shortcutRow(.volumeDown,
                        enabled: enabledBinding(for: .volumeDown),
                        shortcut: $volumeDownShortcut,
                        scope: $volumeDownScope)
            shortcutRow(.volumeUp,
                        enabled: enabledBinding(for: .volumeUp),
                        shortcut: $volumeUpShortcut,
                        scope: $volumeUpScope)
            shortcutRow(.showHide,
                        enabled: enabledBinding(for: .showHide),
                        shortcut: $showHideShortcut,
                        scope: $showHideScope)
            shortcutRow(.starCurrent,
                        enabled: enabledBinding(for: .starCurrent),
                        shortcut: $starShortcut,
                        scope: $starScope)
            shortcutRow(.goToCurrentAlbum,
                        enabled: enabledBinding(for: .goToCurrentAlbum),
                        shortcut: $goToAlbumShortcut,
                        scope: $goToAlbumScope)
        }
        .onChange(of: starShortcut) { _, value in
            KeyboardShortcutStore.save(value, for: .starCurrent)
            SystemWideShortcutCenter.shared.reload()
        }
        .onChange(of: goToAlbumShortcut) { _, value in
            KeyboardShortcutStore.save(value, for: .goToCurrentAlbum)
            SystemWideShortcutCenter.shared.reload()
        }
        .onChange(of: showHideShortcut) { _, value in
            KeyboardShortcutStore.save(value, for: .showHide)
            SystemWideShortcutCenter.shared.reload()
        }
        .onChange(of: muteShortcut) { _, value in
            KeyboardShortcutStore.save(value, for: .mute)
            SystemWideShortcutCenter.shared.reload()
        }
        .onChange(of: volumeDownShortcut) { _, value in
            KeyboardShortcutStore.save(value, for: .volumeDown)
            SystemWideShortcutCenter.shared.reload()
        }
        .onChange(of: volumeUpShortcut) { _, value in
            KeyboardShortcutStore.save(value, for: .volumeUp)
            SystemWideShortcutCenter.shared.reload()
        }
        .onChange(of: starScope) { _, value in saveScope(value, for: .starCurrent) }
        .onChange(of: goToAlbumScope) { _, value in saveScope(value, for: .goToCurrentAlbum) }
        .onChange(of: showHideScope) { _, value in saveScope(value, for: .showHide) }
        .onChange(of: muteScope) { _, value in saveScope(value, for: .mute) }
        .onChange(of: volumeDownScope) { _, value in saveScope(value, for: .volumeDown) }
        .onChange(of: volumeUpScope) { _, value in saveScope(value, for: .volumeUp) }
        .onChange(of: enabledShortcuts) { _, values in
            for action in ShortcutAction.allCases {
                KeyboardShortcutStore.setEnabled(values[action] ?? true, for: action)
            }
            SystemWideShortcutCenter.shared.reload()
        }
    }

    private func saveScope(_ scope: ShortcutScope, for action: ShortcutAction) {
        KeyboardShortcutStore.setScope(scope, for: action)
        SystemWideShortcutCenter.shared.reload()
    }

    private var shortcutTableHeader: some View {
        HStack(spacing: 8) {
            Text("Enabled")
                .frame(width: 58)
            Text("Action")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("System-Wide")
                .frame(width: 100)
            Text("Key")
                .frame(width: 132)
            Color.clear
                .frame(width: 48, height: 1)
        }
        .font(SettingsTypography.help.weight(.semibold))
        .foregroundColor(Theme.secondaryText)
        .padding(.bottom, 2)
    }

    private func enabledBinding(for action: ShortcutAction) -> Binding<Bool> {
        Binding(
            get: { enabledShortcuts[action] ?? true },
            set: { enabledShortcuts[action] = $0 }
        )
    }

    private func shortcutRow(_ action: ShortcutAction,
                             enabled: Binding<Bool>,
                             shortcut: Binding<KeyboardShortcut?>,
                             scope: Binding<ShortcutScope>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .frame(width: 58)
                .help("Enable or disable this shortcut")
            Text(action.title)
                .font(SettingsTypography.body)
                .foregroundColor(enabled.wrappedValue ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { scope.wrappedValue == .systemWide },
                set: { scope.wrappedValue = $0 ? .systemWide : .inApp }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .frame(width: 100)
            .help("Checked: system-wide. Unchecked: in-app.")
            ShortcutRecorder(shortcut: shortcut, label: action.title)
                .frame(width: 132, height: 22)
            Button("Reset") { shortcut.wrappedValue = action.defaultShortcut }
                .controlSize(.small)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var traySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("System Tray")
                    .font(SettingsTypography.cardTitle)
                Spacer()
                Toggle("Show icon", isOn: $trayEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text("Shows a disc icon in the menu bar. Popups appear below the icon.")
                .font(SettingsTypography.help)
                .foregroundColor(Theme.secondaryText)

            if trayEnabled {
                Toggle("Track change", isOn: $trayTrackChange)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Add or remove current song from Stared playlist",
                       isOn: $trayStarChange)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Only display popup when Library window is not focused",
                       isOn: $trayOnlyWhenLibraryNotFocused)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                HStack(spacing: 8) {
                    Text("Popup duration")
                        .font(SettingsTypography.body)
                        .foregroundColor(Theme.secondaryText)
                    Spacer()
                    Stepper("\(trayPopupDurationMs) ms",
                            value: $trayPopupDurationMs,
                            in: 300...10000,
                            step: 100)
                        .controlSize(.small)
                }
                Text("Default: 1500 ms. Popups are suppressed while the Library window is focused.")
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: trayEnabled) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayTrackChange) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayStarChange) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayOnlyWhenLibraryNotFocused) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayPopupDurationMs) { _, value in
            trayPopupDurationMs = min(max(value, 300), 10000)
        }
    }

    private var mpdSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("MPD Server")
                    .font(SettingsTypography.cardTitle)
                Spacer()
                Toggle("Enable", isOn: $mpdEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text("Lets MPD clients browse and control the library over TCP.")
                .font(SettingsTypography.help)
                .foregroundColor(Theme.secondaryText)

            if mpdEnabled {
                Toggle("Listen on all interfaces", isOn: $mpdAllInterfaces)
                    .controlSize(.small)

                HStack(spacing: 8) {
                    Text("Addresses")
                        .font(SettingsTypography.body)
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 76, alignment: .leading)
                    TextField("127.0.0.1", text: $mpdAddresses)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body)
                        .disabled(mpdAllInterfaces)
                    Text("Port")
                        .font(SettingsTypography.body)
                        .foregroundColor(Theme.secondaryText)
                    TextField("6600", value: $mpdPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body.monospacedDigit())
                        .frame(width: 72)
                }

                HStack(spacing: 8) {
                    Text("Password")
                        .font(SettingsTypography.body)
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 76, alignment: .leading)
                    SecureField("optional", text: $mpdPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body)
                        .frame(maxWidth: 240)
                    Spacer()
                    Button("Restart") { mpd.applyPreferences() }
                        .controlSize(.small)
                }

                Text(mpd.status)
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("Disabled")
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    private var artworkQualityPercent: Int {
        Int((artworkCacheJPEGQuality * 100).rounded())
    }

    private var artworkCacheSizeText: String {
        if artworkCache.isCalculatingCacheSize && artworkCache.cacheSizeBytes == 0 {
            return "Calculating…"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: artworkCache.cacheSizeBytes)
    }

    private func commitArtworkQuality() {
        let trimmed = artworkQualityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed) else {
            artworkQualityText = "\(artworkQualityPercent)"
            return
        }
        let clamped = min(max(number, 15), 100)
        artworkCacheJPEGQuality = Double(clamped) / 100
        artworkQualityText = "\(clamped)"
    }

    private func scheduleMPDApply() {
        mpdApplyTask?.cancel()
        mpdApplyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            mpd.applyPreferences()
        }
    }

    // MARK: Internal library

    private var internalLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("Internal Library")
                    .font(SettingsTypography.cardTitle)
                Spacer()
            }

            if let warning = library.openWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(SettingsTypography.help)
                        .foregroundColor(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        library.clearOpenWarning()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.orange.opacity(0.10))
                )
            }

            if let internalLibrary = library.internalLibrary {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(internalLibrary.path)
                        .font(SettingsTypography.caption)
                        .foregroundColor(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Quick Scan") {
                        library.rescan(internalLibrary)
                    }
                    .disabled(library.isScanning || !internalLibrary.isEnabled)
                }

                HStack(spacing: 10) {
                    Button("Open Music Folder") {
                        openMusicFolder(internalLibrary)
                    }
                    Button("Full Scan") {
                        runFullScan(internalLibrary)
                    }
                    .disabled(library.isScanning || !internalLibrary.isEnabled)
                    Button("Open Another Library…") {
                        chooseOpenLibrary()
                    }
                    Spacer()
                }

                Text("The database lives in this folder. Music belongs in its Music subfolder.")
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
            } else {
                Text("Not set up yet. Create one folder for your Tracks database and music.")
                    .font(SettingsTypography.body)
                    .foregroundColor(Theme.secondaryText)

                HStack(spacing: 10) {
                    Button("Set Up Internal Library…") {
                        openWindow(id: "setup")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Button("Open Existing Library…") {
                        chooseOpenLibrary()
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openMusicFolder(_ internalLibrary: MusicLibrary) {
        let music = URL(fileURLWithPath: internalLibrary.musicPath)
        if FileManager.default.fileExists(atPath: music.path) {
            NSWorkspace.shared.open(music)
        } else {
            // Do not recreate a missing Music folder here: that would allow a
            // later scan to prune songs whose files have not been restored yet.
            NSWorkspace.shared.open(URL(fileURLWithPath: internalLibrary.path))
        }
    }

    private func chooseOpenLibrary() {
        guard let path = LibraryFolderPicker.choose() else { return }
        if library.internalLibrary != nil || !library.allSongs.isEmpty {
            alert = .confirmOpen(path)
        } else {
            performOpen(path)
        }
    }

    private func performOpen(_ path: String) {
        do {
            try library.openInternalLibrary(atPath: path)
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    // MARK: External libraries

    private var externalLibrariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("External Libraries")
                    .font(SettingsTypography.cardTitle)
                Spacer()
                Text("Read-Only")
                    .font(SettingsTypography.caption)
                    .foregroundColor(.secondary)
            }

            Text("Folders managed by iTunes or another music app. Tracks indexes them without modifying the files.")
                .font(SettingsTypography.help)
                .foregroundColor(Theme.secondaryText)

            if library.externalLibraries.isEmpty {
                Text("No external libraries.")
                    .font(SettingsTypography.body)
                    .foregroundColor(Theme.secondaryText)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(library.externalLibraries.enumerated()), id: \.offset) { index, externalLibrary in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(externalLibrary.name)
                                            .font(SettingsTypography.body)
                                            .foregroundColor(Theme.primaryText)
                                            .lineLimit(1)
                                        Text(externalLibrary.isEnabled ? "Enabled" : "Disabled")
                                            .font(SettingsTypography.caption)
                                            .foregroundColor(externalLibrary.isEnabled ? Theme.secondaryText : .orange)
                                    }
                                    Text(externalLibrary.path)
                                        .font(SettingsTypography.caption)
                                        .foregroundColor(Theme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }

                            HStack(spacing: 8) {
                                Button("Quick Scan") {
                                    library.rescan(externalLibrary)
                                }
                                .disabled(library.isScanning || !externalLibrary.isEnabled)
                                Button("Full Scan") {
                                    runFullScan(externalLibrary)
                                }
                                .disabled(library.isScanning || !externalLibrary.isEnabled)
                                Button("Change Location…") {
                                    chooseRelocation(for: externalLibrary)
                                }
                                .disabled(library.isScanning || !externalLibrary.isEnabled)
                                Spacer(minLength: 0)
                                if externalLibrary.isEnabled {
                                    Button("Disable") {
                                        alert = .confirmDisable(externalLibrary)
                                    }
                                    .disabled(library.isScanning)
                                } else {
                                    Button("Enable") {
                                        do {
                                            try library.setExternalLibrary(externalLibrary.id, enabled: true)
                                        } catch {
                                            alert = .error(error.localizedDescription)
                                        }
                                    }
                                    .disabled(library.isScanning)
                                }
                                Button(role: .destructive) {
                                    alert = .confirmDelete(externalLibrary)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(externalLibrary.isEnabled || library.isScanning)
                            }
                        }
                        .padding(.vertical, 12)
                        if index < library.externalLibraries.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Add External Library…") { addExternalLibraries() }
                Button("Rescan All") { library.rescanAll() }
                    .disabled(library.isScanning)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addExternalLibraries() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders managed by another music app. They will be indexed read-only."
        guard panel.runModal() == .OK else { return }

        let errors = library.addExternalLibraries(panel.urls.map(\.path))
        if !errors.isEmpty {
            alert = .error(errors.joined(separator: "\n"))
        }
    }

    private func runFullScan(_ mediaLibrary: MusicLibrary) {
        Task { @MainActor in
            if let report = await library.fullScan(mediaLibrary) {
                if !report.songs.isEmpty {
                    missingFileReport = report
                }
            }
        }
    }

    private func chooseRelocation(for mediaLibrary: MusicLibrary) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose New Location"
        panel.message = "Choose the new root folder for this media library. Tracks will match files by their relative paths."
        panel.directoryURL = URL(fileURLWithPath: mediaLibrary.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            if let report = await library.previewRelocation(of: mediaLibrary, to: url.path) {
                if report.songs.isEmpty {
                    do {
                        let backup = try await library.applyRelocation(report, removingMissingIDs: [])
                        alert = .notice(title: "Library Relocated",
                                        message: "The library was relocated. Backup saved at:\n\(backup.path)")
                    } catch {
                        alert = .error(error.localizedDescription)
                    }
                } else {
                    missingFileReport = report
                }
            }
        }
    }
}

private struct MissingFilesReviewView: View {
    let report: LibraryMissingReport
    let onKeep: () -> Void
    let onDelete: (Set<UUID>) -> Void
    let onRelocate: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var confirmingRelocation = false

    private var visibleSongs: [Song] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return report.songs }
        return report.songs.filter { song in
            [song.title, song.artist, song.album, song.fileURL?.path ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reviewTitle)
                    .font(.system(size: 18, weight: .semibold))
                Text(reviewSubtitle)
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Search title, artist, album, or path", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Spacer()
                Button("Select All") {
                    selectedIDs = Set(report.songs.map(\.id))
                }
                .disabled(report.songs.isEmpty || selectedIDs.count == report.songs.count)
                Button("Deselect All") {
                    selectedIDs.removeAll()
                }
                .disabled(selectedIDs.isEmpty)
            }

            HStack(spacing: 10) {
                Text("Remove")
                    .frame(width: 54, alignment: .center)
                Text("Track / Path")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Artist")
                    .frame(width: 115, alignment: .leading)
                Text("Album")
                    .frame(width: 115, alignment: .leading)
            }
            .font(SettingsTypography.caption.weight(.semibold))
            .foregroundColor(Theme.secondaryText)

            if visibleSongs.isEmpty {
                ContentUnavailableView(
                    report.relocation == nil ? "No Missing Tracks" : "No Unmatched Tracks",
                    systemImage: "checkmark.circle",
                    description: Text(searchText.isEmpty
                                       ? (report.relocation == nil
                                          ? "Full Scan found no missing tracks."
                                          : "All existing tracks matched by relative path.")
                                       : "No tracks match this search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleSongs) { song in
                            HStack(spacing: 10) {
                                Toggle("", isOn: selectionBinding(for: song.id))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .frame(width: 54)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(SettingsTypography.body)
                                        .lineLimit(1)
                                    Text(song.fileURL?.path ?? "")
                                        .font(.system(size: 10).monospaced())
                                        .foregroundColor(Theme.secondaryText)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(song.artist)
                                    .font(SettingsTypography.caption)
                                    .foregroundColor(Theme.secondaryText)
                                    .lineLimit(1)
                                    .frame(width: 115, alignment: .leading)
                                Text(song.album)
                                    .font(SettingsTypography.caption)
                                    .foregroundColor(Theme.secondaryText)
                                    .lineLimit(1)
                                    .frame(width: 115, alignment: .leading)
                            }
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("\(selectedIDs.count) selected")
                    .font(SettingsTypography.caption)
                    .foregroundColor(Theme.secondaryText)
                Spacer()
                Button(report.relocation == nil ? "Keep" : "Cancel") {
                    onKeep()
                    dismiss()
                }
                if report.relocation != nil {
                    Button("Relocate Library…") { confirmingRelocation = true }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Delete Selected…", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(selectedIDs.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .confirmationDialog("Delete selected missing tracks from Tracks?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Selected Indexes", role: .destructive) {
                onDelete(selectedIDs)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only Tracks database entries and playlist references will be removed. Audio files are not touched.")
        }
        .confirmationDialog("Apply this library relocation?",
                            isPresented: $confirmingRelocation,
                            titleVisibility: .visible) {
            Button("Relocate Library", role: selectedIDs.isEmpty ? nil : .destructive) {
                onRelocate(selectedIDs)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(relocationConfirmation)
        }
    }

    private var relocationSummary: String {
        guard let plan = report.relocation else { return "" }
        return "\(report.libraryName): \(plan.matchedCount) tracks match by relative path, \(report.songs.count) are unmatched, and \(plan.additionalFileCount) new files were found."
    }

    private var reviewTitle: String {
        if report.relocation != nil { return "Review Library Relocation" }
        return report.songs.isEmpty ? "Full Scan Complete" : "Missing Files"
    }

    private var reviewSubtitle: String {
        if report.relocation != nil { return relocationSummary }
        if report.songs.isEmpty { return "\(report.libraryName) was scanned successfully." }
        return "\(report.libraryName) — \(report.songs.count) files were not found. Select entries to remove from Tracks."
    }

    private var relocationConfirmation: String {
        if selectedIDs.isEmpty {
            return "Every stored song path will be updated to its relative location under the new root, even if its file is missing. No database entries or audio files will be deleted."
        }
        return "Unselected song paths will be updated to their relative locations under the new root, even if their files are missing. The \(selectedIDs.count) selected unmatched entries and playlist references will be removed; audio files are not touched."
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected { selectedIDs.insert(id) }
                else { selectedIDs.remove(id) }
            }
        )
    }
}

private enum SettingsTypography {
    static let pageTitle: Font = .system(size: 18, weight: .semibold)
    static let sectionTitle: Font = .system(size: 14, weight: .semibold)
    static let cardTitle: Font = .system(size: 13, weight: .semibold)
    static let body: Font = .system(size: 13)
    static let help: Font = .system(size: 12)
    static let caption: Font = .system(size: 11)
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case library
    case shortcuts
    case services

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .library: return "Library"
        case .shortcuts: return "Shortcuts"
        case .services: return "Services"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Appearance and album browsing"
        case .library: return "Music folders, scanning, and artwork"
        case .shortcuts: return "In-App and system-wide key bindings"
        case .services: return "Menu-bar icon, notifications, and MPD"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .library: return "music.note.list"
        case .shortcuts: return "keyboard"
        case .services: return "menubar.rectangle"
        }
    }
}

struct InternalLibrarySetupView: View {
    @ObservedObject private var library = Library.shared
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var rootPath = InternalLibrarySetupView.defaultRootPath
    @State private var errorMessage: String?
    @State private var existingLibraryAtRoot = false

    private static var defaultRootPath: String {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Tracks").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.highlight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Your Tracks Library")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                    Text("One folder holds your library database and your music.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                }
                Spacer()
            }

            if let internalLibrary = library.internalLibrary {
                Text("Your Internal Library is already set up at:")
                    .font(.system(size: 12))
                Text(internalLibrary.path)
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(boxBackground)
                Spacer()
                HStack {
                    Spacer()
                    Button("Done") { dismissWindow(id: "setup") }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(existingLibraryAtRoot
                     ? "A Tracks library already exists in this folder. Opening it uses its existing database and Music folder, so a library copied from another Mac can be used right away."
                     : "Tracks will create a Music folder inside this library and keep its database there. Creating the folder in your Music folder also lets macOS grant Tracks access to it.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Library folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                    HStack(spacing: 8) {
                        Text(rootPath)
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Choose…") { chooseFolder() }
                    }
                    .padding(8)
                    .background(boxBackground)
                    Text("Default: ~/Music/Tracks")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.secondaryText)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button("Not Now") {
                        library.deferInternalSetup()
                        dismissWindow(id: "setup")
                    }
                    Button("Open Existing Library…") {
                        openExistingLibrary(at: nil)
                    }
                    Spacer()
                    if existingLibraryAtRoot {
                        Button("Open Library") {
                            openExistingLibrary(at: rootPath)
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Create Library") {
                            createLibrary()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 540, height: 410, alignment: .topLeading)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            refreshExistingLibrary()
        }
    }

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.controlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
            )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose or create the folder that will hold your Tracks library."
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootPath = url.path
        errorMessage = nil
        refreshExistingLibrary()
    }

    private func refreshExistingLibrary() {
        let databasePath = URL(fileURLWithPath: rootPath)
            .appendingPathComponent("library.sqlite").path
        existingLibraryAtRoot = FileManager.default.fileExists(atPath: databasePath)
            && LibraryDatabase.inspect(path: databasePath) != nil
    }

    private func openExistingLibrary(at path: String?) {
        let selected: String
        if let path {
            selected = path
        } else {
            guard let picked = LibraryFolderPicker.choose() else { return }
            selected = picked
            rootPath = picked
            refreshExistingLibrary()
        }

        do {
            try library.openInternalLibrary(atPath: selected)
            dismissWindow(id: "setup")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createLibrary() {
        do {
            try library.createInternalLibrary(atPath: rootPath)
            dismissWindow(id: "setup")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let goBackRequested = Notification.Name("audia.goBackRequested")
}

/// Applies the View > Appearance preference at the AppKit level. SwiftUI's
/// `preferredColorScheme(nil)` can leave a previously forced window appearance
/// behind; clearing `NSApp.appearance` and every window override makes Automatic
/// follow live system appearance changes again.
@MainActor
final class AppearanceController {
    static let shared = AppearanceController()

    private var defaultsObserver: NSObjectProtocol?
    private var lastMode: String?

    func start() {
        applyIfNeeded()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyIfNeeded() }
        }
    }

    private func applyIfNeeded() {
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "auto"
        guard mode != lastMode else { return }
        lastMode = mode

        let appearance: NSAppearance?
        switch mode {
        case "light":
            appearance = NSAppearance(named: .aqua)
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        default:
            appearance = nil
        }

        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focusMonitor: Any?
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Window tabbing is not used by this app.
        NSWindow.allowsAutomaticWindowTabbing = false
        AppearanceController.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installFocusMonitor()
        installKeyMonitor()
        MPDServer.shared.startFromPreferences()
        SystemWideShortcutCenter.shared.start()
        TrayController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowModeCenter.shared.persistLibraryFrameIfNeeded()
        PlayerState.shared.persistQueueForTermination()
        // Make library.sqlite self-contained before the process exits so it can
        // be copied to another computer on its own.
        Library.shared.closeDatabaseForTermination()
    }

    /// Clicking non-focusable content (song rows, the toolbar chrome, …) does not
    /// resign the search field on macOS, so the search box kept its focus ring.
    /// Resign it whenever a click lands somewhere that is not a text input.
    private func installFocusMonitor() {
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  window.firstResponder is NSText,
                  let frameView = window.contentView?.superview,
                  let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
            else { return event }

            var view: NSView? = hit
            while let current = view {
                if current is NSTextField || current is NSTextView { return event }
                view = current.superview
            }
            window.makeFirstResponder(nil)
            return event
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                KeyboardShortcuts.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowModeCenter.shared.setMode(.library)
            WindowModeCenter.shared.showWindow()
        }
        return true
    }
}

// MARK: - Window keyboard commands

@MainActor
enum KeyboardShortcuts {
    static func handle(_ event: NSEvent) -> NSEvent? {
        if ShortcutRecorderState.isRecording { return event }
        guard let window = event.window else { return event }
        // Arrow/Page/Home keys carry `.function`/`.numericPad`; ignore those so
        // they don't look like modified keystrokes.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isEditingText = window.firstResponder is NSText

        if modifiers == .command,
           (event.charactersIgnoringModifiers == "[" || event.keyCode == 33) {
            NotificationCenter.default.post(name: .goBackRequested, object: nil)
            return nil
        }

        if !isEditingText {
            for action in ShortcutAction.allCases
                where KeyboardShortcutStore.scope(for: action) == .inApp
                    && KeyboardShortcutStore.isEnabled(action) {
                if event.isARepeat, !action.allowsRepeat { continue }
                guard let shortcut = KeyboardShortcutStore.load(action),
                      shortcut.matches(event) else { continue }
                action.perform()
                return nil
            }
        }

        guard modifiers.isEmpty, !isEditingText else { return event }

        switch event.keyCode {
        case 49: // space
            PlayerState.shared.togglePlayPause()
            return nil
        case 123: // left arrow
            KeyboardNavigator.shared.send(.left)
            return nil
        case 124: // right arrow
            KeyboardNavigator.shared.send(.right)
            return nil
        case 125: // down arrow
            KeyboardNavigator.shared.send(.down)
            return nil
        case 126: // up arrow
            KeyboardNavigator.shared.send(.up)
            return nil
        case 116: // page up
            scrollByPage(up: true, event: event)
            return nil
        case 121: // page down
            scrollByPage(up: false, event: event)
            return nil
        case 115: // home
            scrollToTop(event: event)
            return nil
        case 119: // end
            scrollToBottom(event: event)
            return nil
        case 36, 76: // return / enter
            KeyboardNavigator.shared.activate()
            return nil
        default:
            return event
        }
    }

    private static func scrollByPage(up: Bool, event: NSEvent) {
        guard let scrollView = targetScrollView(for: event) else { return }
        let clip = scrollView.contentView
        let document = scrollView.documentView
        let page = max(clip.bounds.height * 0.9, 40)
        let direction: CGFloat = (document?.isFlipped ?? true) ? 1 : -1
        scroll(scrollView, toY: clip.bounds.origin.y + (up ? -page : page) * direction)
    }

    private static func scrollToTop(event: NSEvent) {
        guard let scrollView = targetScrollView(for: event),
              let document = scrollView.documentView else { return }
        let top = document.isFlipped ? 0 : max(document.bounds.height - scrollView.contentView.bounds.height, 0)
        scroll(scrollView, toY: top)
    }

    private static func scrollToBottom(event: NSEvent) {
        guard let scrollView = targetScrollView(for: event),
              let document = scrollView.documentView else { return }
        let bottom = document.isFlipped ? max(document.bounds.height - scrollView.contentView.bounds.height, 0) : 0
        scroll(scrollView, toY: bottom)
    }

    private static func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(document.bounds.height - clip.bounds.height, 0)
        let clamped = min(max(y, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func targetScrollView(for event: NSEvent) -> NSScrollView? {
        guard let window = event.window, let content = window.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        if let hit = content.hitTest(point) {
            var view: NSView? = hit
            while let current = view {
                if let scroll = current as? NSScrollView, !isTextFieldScrollView(scroll) {
                    return scroll
                }
                view = current.superview
            }
        }
        return largestScrollView(in: content)
    }

    private static func isTextFieldScrollView(_ scrollView: NSScrollView) -> Bool {
        scrollView.documentView is NSTextView
    }

    private static func largestScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                if !isTextFieldScrollView(scroll) { found.append(scroll) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { lhs, rhs in
            let a = lhs.contentView.bounds
            let b = rhs.contentView.bounds
            return a.width * a.height < b.width * b.height
        }
    }
}
