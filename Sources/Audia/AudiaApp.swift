import SwiftUI
@preconcurrency import AppKit

@main
struct AudiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("highlightColor") private var highlightColorRaw = HighlightColor.graphite.rawValue
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("showStatusBarFullScreen") private var showStatusBarFullScreen = true
    @ObservedObject private var sidebar = SidebarVisibilityStore.shared
    @ObservedObject private var windowMode = WindowModeCenter.shared

    private var statusBarVisible: Bool {
        windowMode.isFullScreen ? showStatusBarFullScreen : showStatusBar
    }

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

            // Keep SwiftUI's per-window entries out of the Window menu. The
            // explicit Library and MiniPlayer commands below are the supported
            // window switchers for this app.
            CommandGroup(replacing: .windowList) {}

            CommandGroup(after: .textEditing) {
                Button("Find") {
                    guard let window = NSApp.keyWindow,
                          window === WindowModeCenter.shared.mainWindow else { return }
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
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
                Button(sidebar.isVisible ? "Hide Sidebar" : "Show Sidebar") {
                    sidebar.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button(statusBarVisible ? "Hide Status Bar" : "Show Status Bar") {
                    if windowMode.isFullScreen {
                        showStatusBarFullScreen.toggle()
                    } else {
                        showStatusBar.toggle()
                    }
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
    case shortcutConflict(String)
    case confirmOpen(String)
    case confirmDisable(MusicLibrary)
    case confirmDelete(MusicLibrary)
    case notice(title: String, message: String)

    var id: String {
        switch self {
        case .error(let message): return "error:\(message)"
        case .shortcutConflict(let message): return "shortcut-conflict:\(message)"
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
    @AppStorage(TrayController.DefaultsKey.displayDurationMs)
    private var trayDisplayDurationMs = 1500
    @State private var shortcutBindings = KeyboardShortcutStore.loadBindings()
    @State private var showRawShortcutValues = false
    @State private var selectedInAppBindingID: UUID?
    @State private var selectedSystemWideBindingID: UUID?
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

            VStack(spacing: 0) {
                settingsPageHeader(selectedSection ?? .general)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                Hairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        settingsContent(selectedSection ?? .general)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(Theme.contentBackground)
        }
        .font(SettingsTypography.body)
        .frame(width: 760, height: 720, alignment: .topLeading)
        .background(SettingsFocusSink())
        .onAppear {
            artworkQualityText = "\(artworkQualityPercent)"
            shortcutBindings = KeyboardShortcutStore.loadBindings()
            selectedInAppBindingID = nil
            selectedSystemWideBindingID = nil
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
            case .shortcutConflict(let message):
                return Alert(
                    title: Text("Shortcut Already Assigned"),
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

    private func headerSubtitle(for section: SettingsSection) -> String {
        switch section {
        case .library:
            return "\(library.albums.count.formatted()) albums · \(library.allSongs.count.formatted()) songs"
        default:
            return section.subtitle
        }
    }

    private func settingsPageHeader(_ section: SettingsSection) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(SettingsTypography.pageTitle)
                    .foregroundColor(Theme.primaryText)
                Text(headerSubtitle(for: section))
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            if section == .library, library.isScanning {
                SidebarActivityView(
                    title: library.scanPhase.rawValue,
                    progress: library.scanActivityProgress,
                    detail: library.scanActivityDetail
                )
                .frame(width: 180)
            }
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
            VStack(alignment: .leading, spacing: 22) {
                traySettings
                mpdSettings
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Browsing") {
                SettingsRow(title: "Album display as") {
                    Picker("", selection: $albumViewMode) {
                        Text("Grid").tag("grid")
                        Text("List").tag("list")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(title: "Albums sorted by") {
                    HStack(spacing: 8) {
                        Picker("", selection: $albumSort) {
                            ForEach(GridSort.allCases, id: \.self) { sort in
                                Text(sort == .album ? "Album Name" : sort.rawValue)
                                    .tag(sort.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)

                        Picker("", selection: $albumSortDirection) {
                            ForEach(GridSortDirection.allCases) { direction in
                                Text(direction.title).tag(direction.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
            }

            SettingsCard(title: "Theme") {
                SettingsRow(title: "Highlight color") {
                    highlightColorSwatches
                }
            }
        }
    }

    private var highlightColorSwatches: some View {
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

    private var librarySettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            internalLibrarySection
            externalLibrariesSection
            artworkCacheSection
        }
    }

    private var artworkCacheSection: some View {
        SettingsCard(title: "Artwork Cache") {
            SettingsRow(title: "Rebuild cache",
                        subtitle: "Cached album art speeds up browsing. It is rebuilt from library files.") {
                Button("Rebuild Cache") {
                    artworkCache.rebuildCache()
                }
                .controlSize(.small)
            }

            SettingsDivider()

            SettingsRow(title: "JPEG quality") {
                HStack(spacing: 6) {
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
                }
            }

            SettingsDivider()

            SettingsRow(title: "Cache size") {
                Text(artworkCacheSizeText)
                    .font(SettingsTypography.body.monospacedDigit())
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    private var shortcutsSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "In-App") {
                shortcutBindingTable(for: .inApp,
                                     selectedID: $selectedInAppBindingID)
            }

            SettingsCard(title: "System-Wide") {
                shortcutBindingTable(for: .systemWide,
                                     selectedID: $selectedSystemWideBindingID)
            }

            SettingsCard(title: "Options") {
                SettingsRow(title: "Display raw values",
                            subtitle: "Show physical key codes instead of the formatted shortcut.") {
                    Toggle("", isOn: $showRawShortcutValues)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .onChange(of: shortcutBindings) { _, bindings in
            KeyboardShortcutStore.saveBindings(bindings)
            SystemWideShortcutCenter.shared.reload()
        }
    }

    private func shortcutBindingTable(for scope: ShortcutScope,
                                      selectedID: Binding<UUID?>) -> some View {
        let ids = shortcutBindingIDs(for: scope)
        let visibleRows = max(1, min(ids.count, 6))
        let hasAvailableActions = !availableShortcutActions(for: scope).isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Action")
                        .frame(width: 300, alignment: .leading)
                    Spacer(minLength: 0)
                    Divider()
                    Text("Key")
                        .frame(width: 105, alignment: .leading)
                        .padding(.leading, 10)
                }
                .font(SettingsTypography.body.weight(.semibold))
                .foregroundColor(Theme.primaryText)
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(Theme.controlBackground.opacity(0.7))

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if ids.isEmpty {
                            Text("No shortcuts assigned")
                                .font(SettingsTypography.help)
                                .foregroundColor(Theme.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 20)
                        } else {
                            ForEach(ids, id: \.self) { id in
                                if let index = shortcutBindings.firstIndex(where: { $0.id == id }) {
                                    shortcutBindingRow($shortcutBindings[index],
                                                       selectedID: selectedID)
                                }
                            }
                        }
                    }
                }
                .frame(height: CGFloat(visibleRows * 20))

                Divider()

                HStack(spacing: 0) {
                    ShortcutTableButton(kind: .add,
                                         isEnabled: hasAvailableActions,
                                         actions: availableShortcutActions(for: scope),
                                         onSelect: { action in
                                             addShortcutBinding(action, for: scope, selectedID: selectedID)
                                         })
                    .frame(width: 20, height: 20)
                    .help("Add shortcut")

                    ShortcutTableButton(kind: .remove,
                                         isEnabled: selectedID.wrappedValue.map { ids.contains($0) } == true,
                                         onClick: {
                                             removeShortcutBinding(selectedID.wrappedValue, from: scope)
                                         })
                    .frame(width: 20, height: 20)
                    .help("Remove selected shortcut")

                    Spacer(minLength: 0)
                }
                .frame(height: 20)
                .background(Theme.controlBackground.opacity(0.4))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func availableShortcutActions(for scope: ShortcutScope) -> [ShortcutAction] {
        let assigned = Set(shortcutBindings.compactMap { binding -> ShortcutAction? in
            guard binding.scope == scope else { return nil }
            return binding.action
        })
        return ShortcutAction.allCases.filter { !assigned.contains($0) }
    }

    private func shortcutBindingIDs(for scope: ShortcutScope) -> [UUID] {
        shortcutBindings.filter { $0.scope == scope }.map(\.id)
    }

    private func shortcutBindingRow(_ binding: Binding<ShortcutBinding>,
                                   selectedID: Binding<UUID?>) -> some View {
        let id = binding.wrappedValue.id
        return HStack(spacing: 0) {
            Text(binding.wrappedValue.action?.title ?? "")
                .font(SettingsTypography.body)
                .foregroundColor(Theme.primaryText)
                .frame(width: 300, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { selectedID.wrappedValue = id }

            Spacer(minLength: 0)
            Group {
                if selectedID.wrappedValue == id {
                    ShortcutRecorder(shortcut: shortcutBinding(for: id),
                                     label: binding.wrappedValue.action?.title ?? "Shortcut",
                                     showsRawValue: showRawShortcutValues,
                                     onFocus: { selectedID.wrappedValue = id })
                } else {
                    Text(shortcutDisplayValue(binding.wrappedValue.shortcut))
                        .font(.system(size: 11).monospaced())
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                        .padding(.leading, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID.wrappedValue = id }
                }
            }
            .frame(width: 105, height: 20, alignment: .leading)
            .padding(.leading, 10)
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(selectedID.wrappedValue == id
                    ? Theme.selectionFill.opacity(0.22)
                    : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID.wrappedValue = id }
    }

    private func shortcutDisplayValue(_ shortcut: KeyboardShortcut?) -> String {
        guard let shortcut else { return "" }
        return showRawShortcutValues ? shortcut.rawValue : shortcut.display
    }

    private func shortcutBinding(for id: UUID) -> Binding<KeyboardShortcut?> {
        Binding(
            get: { shortcutBindings.first(where: { $0.id == id })?.shortcut },
            set: { shortcut in updateShortcut(shortcut, for: id) }
        )
    }

    private func updateShortcut(_ shortcut: KeyboardShortcut?, for id: UUID) {
        guard let index = shortcutBindings.firstIndex(where: { $0.id == id }) else { return }
        if let shortcut,
           let conflict = shortcutBindings.first(where: {
               $0.id != id && $0.shortcut?.conflicts(with: shortcut) == true
           }) {
            alert = .shortcutConflict("\(shortcut.display) is already assigned to \(conflict.action?.title ?? "another action"). Choose another shortcut or remove that binding first.")
            return
        }
        shortcutBindings[index].shortcut = shortcut
    }

    private func addShortcutBinding(_ action: ShortcutAction,
                                    for scope: ShortcutScope,
                                    selectedID: Binding<UUID?>) {
        guard !shortcutBindings.contains(where: { $0.scope == scope && $0.action == action }) else { return }
        let binding = ShortcutBinding(action: action, shortcut: nil, scope: scope)
        shortcutBindings.append(binding)
        selectedID.wrappedValue = binding.id
    }

    private func removeShortcutBinding(_ id: UUID?, from scope: ShortcutScope) {
        guard let id,
              let position = shortcutBindingIDs(for: scope).firstIndex(of: id) else { return }
        let rows = shortcutBindingIDs(for: scope)
        let remaining = rows.filter { $0 != id }
        let nextSelection = remaining.dropFirst(min(position, remaining.count)).first
            ?? remaining.last
        shortcutBindings.removeAll { $0.id == id }
        if scope == .inApp { selectedInAppBindingID = nextSelection }
        else { selectedSystemWideBindingID = nextSelection }
    }

    private var traySettings: some View {
        SettingsCard(title: "System Tray") {
            SettingsRow(title: "Show icon",
                        subtitle: "Shows a disc in the menu bar. On song or star changes it flips to the album cover and expands to show the track.") {
                Toggle("", isOn: $trayEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if trayEnabled {
                SettingsDivider()
                SettingsRow(title: "Show on song change") {
                    Toggle("", isOn: $trayTrackChange)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "Show on star/unstar") {
                    Toggle("", isOn: $trayStarChange)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "Display duration") {
                    Stepper("\(trayDisplayDurationMs) ms",
                            value: $trayDisplayDurationMs,
                            in: 300...10000,
                            step: 100)
                        .controlSize(.small)
                }
                SettingsFootnote("How long the track information stays visible after the card finishes opening. Default: 1500 ms.")
            }
        }
        .onChange(of: trayEnabled) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayTrackChange) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayStarChange) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayDisplayDurationMs) { _, value in
            trayDisplayDurationMs = min(max(value, 300), 10000)
        }
    }

    private var mpdSettings: some View {
        SettingsCard(title: "MPD Server") {
            SettingsRow(title: "Enable",
                        subtitle: "Lets MPD clients browse and control the library over TCP.") {
                Toggle("", isOn: $mpdEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if mpdEnabled {
                SettingsDivider()
                SettingsRow(title: "Listen on all interfaces") {
                    Toggle("", isOn: $mpdAllInterfaces)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "Addresses") {
                    TextField("127.0.0.1", text: $mpdAddresses)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body)
                        .frame(width: 220)
                        .disabled(mpdAllInterfaces)
                }
                SettingsDivider()
                SettingsRow(title: "Port") {
                    TextField("6600", value: $mpdPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body.monospacedDigit())
                        .frame(width: 80)
                }
                SettingsDivider()
                SettingsRow(title: "Password") {
                    HStack(spacing: 8) {
                        SecureField("optional", text: $mpdPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(SettingsTypography.body)
                            .frame(width: 150)
                        Button("Restart") { mpd.applyPreferences() }
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
                Text(mpd.status)
                    .font(SettingsTypography.help)
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                SettingsFootnote("Disabled")
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
        SettingsCard(title: "Internal Library") {
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
                .padding(10)
                .background(Color.orange.opacity(0.10))
                SettingsDivider()
            }

            if let internalLibrary = library.internalLibrary {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Location")
                            .font(SettingsTypography.body)
                            .foregroundColor(Theme.primaryText)
                        Text(internalLibrary.path)
                            .font(SettingsTypography.caption)
                            .foregroundColor(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    Button("Quick Scan") {
                        library.rescan(internalLibrary)
                    }
                    .controlSize(.small)
                    .disabled(library.isScanning || !internalLibrary.isEnabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                SettingsDivider()

                HStack(spacing: 8) {
                    Spacer()
                    Button("Open Music Folder") {
                        openMusicFolder(internalLibrary)
                    }
                    .controlSize(.small)
                    Button("Full Scan") {
                        runFullScan(internalLibrary)
                    }
                    .controlSize(.small)
                    .disabled(library.isScanning || !internalLibrary.isEnabled)
                    Button("Open Another Library…") {
                        chooseOpenLibrary()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                SettingsFootnote("The database lives in this folder. Music belongs in its Music subfolder.")
            } else {
                SettingsRow(title: "Not set up yet",
                            subtitle: "Create one folder for your Tracks database and music.") {
                    EmptyView()
                }
                SettingsDivider()
                HStack(spacing: 8) {
                    Spacer()
                    Button("Set Up Internal Library…") {
                        openWindow(id: "setup")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .controlSize(.small)
                    Button("Open Existing Library…") {
                        chooseOpenLibrary()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
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
        SettingsCard(title: "External Libraries") {
            SettingsRow(title: "Read-Only",
                        subtitle: "Folders managed by iTunes or another music app. Tracks indexes them without modifying the files.") {
                EmptyView()
            }

            if library.externalLibraries.isEmpty {
                SettingsDivider()
                SettingsFootnote("No external libraries.")
            } else {
                ForEach(library.externalLibraries) { externalLibrary in
                    SettingsDivider()
                    SettingsRow(title: externalLibrary.name,
                                subtitle: externalLibrary.path) {
                        Toggle("", isOn: externalLibraryEnabledBinding(externalLibrary))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Button("Quick Scan") {
                            library.rescan(externalLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning || !externalLibrary.isEnabled)
                        Button("Full Scan") {
                            runFullScan(externalLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning || !externalLibrary.isEnabled)
                        Button("Change Location…") {
                            chooseRelocation(for: externalLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning || !externalLibrary.isEnabled)
                        Spacer()
                        Button(role: .destructive) {
                            alert = .confirmDelete(externalLibrary)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .controlSize(.small)
                        .disabled(externalLibrary.isEnabled || library.isScanning)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }

            SettingsDivider()

            HStack(spacing: 8) {
                Spacer()
                Button("Rescan All") {
                    library.rescanAll()
                }
                .controlSize(.small)
                .disabled(library.isScanning)
                Button("Add External Library…") {
                    addExternalLibraries()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func externalLibraryEnabledBinding(_ externalLibrary: MusicLibrary) -> Binding<Bool> {
        Binding(
            get: { externalLibrary.isEnabled },
            set: { enabled in
                if enabled {
                    do {
                        try library.setExternalLibrary(externalLibrary.id, enabled: true)
                    } catch {
                        alert = .error(error.localizedDescription)
                    }
                } else {
                    alert = .confirmDisable(externalLibrary)
                }
            }
        )
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

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SettingsTypography.sectionTitle)
                .foregroundColor(Theme.primaryText)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.controlBackground.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.controlBorder.opacity(0.7), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SettingsTypography.body)
                    .foregroundColor(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsTypography.help)
                        .foregroundColor(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(SettingsTypography.help)
            .foregroundColor(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focusMonitor: Any?
    private var keyMonitor: Any?
    private var windowMenuObserver: NSObjectProtocol?
    private var isPruningWindowMenu = false
    private let hiddenWindowMenuTitles: Set<String> = [
        "Tracks",
        "Get Info",
        "Set Up Tracks Library",
    ]

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
        installWindowMenuPruner()
        MPDServer.shared.startFromPreferences()
        SystemWideShortcutCenter.shared.start()
        TrayController.shared.start()
    }

    private func installWindowMenuPruner() {
        pruneWindowMenu()
        DispatchQueue.main.async { [weak self] in
            self?.pruneWindowMenu()
        }
        windowMenuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let menu = notification.object as? NSMenu,
                  menu === NSApp.windowsMenu else { return }
            DispatchQueue.main.async { [weak self] in
                self?.pruneWindowMenu()
            }
        }
    }

    private func pruneWindowMenu() {
        guard !isPruningWindowMenu,
              let menu = NSApp.windowsMenu else { return }
        isPruningWindowMenu = true
        defer { isPruningWindowMenu = false }

        for item in menu.items where hiddenWindowMenuTitles.contains(item.title) {
            menu.removeItem(item)
        }

        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator {
                    menu.removeItem(item)
                    continue
                }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
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

        let bindings = KeyboardShortcutStore.loadBindings()
        if !isEditingText {
            for binding in bindings where binding.scope == .inApp {
                guard let action = binding.action else { continue }
                if event.isARepeat, !action.allowsRepeat { continue }
                guard let shortcut = binding.shortcut,
                      shortcut.matches(event) else { continue }
                action.perform()
                return nil
            }
        }

        guard modifiers.isEmpty, !isEditingText else { return event }

        if window === WindowModeCenter.shared.mainWindow {
            switch event.keyCode {
            case 18: // 1
                NavigationCenter.shared.sidebarSelection = .library(.recentlyAdded)
                return nil
            case 19: // 2
                NavigationCenter.shared.sidebarSelection = .library(.albums)
                return nil
            case 20: // 3
                NavigationCenter.shared.sidebarSelection = .library(.artists)
                return nil
            case 21: // 4
                NavigationCenter.shared.sidebarSelection = .library(.songs)
                return nil
            case 23: // 5
                NavigationCenter.shared.sidebarSelection = .library(.genres)
                return nil
            case 28: // 8
                NavigationCenter.shared.sidebarSelection = .starred
                return nil
            case 53: // escape
                KeyboardNavigator.shared.clearSelection()
                return nil
            default:
                break
            }
        }

        switch event.keyCode {
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
            handleScroll(.pageUp, in: window, event: event)
            return nil
        case 121: // page down
            handleScroll(.pageDown, in: window, event: event)
            return nil
        case 115: // home
            handleScroll(.top, in: window, event: event)
            return nil
        case 119: // end
            handleScroll(.bottom, in: window, event: event)
            return nil
        case 36, 76: // return / enter
            KeyboardNavigator.shared.activate()
            return nil
        default:
            return event
        }
    }

    private static func handleScroll(_ command: KeyboardNavigator.ScrollCommand,
                                     in window: NSWindow,
                                     event: NSEvent) {
        // The Library lists own their scroll view through SwiftUI. Direct
        // NSScrollView scrolling there fought the view's layout and could snap
        // it back to the previous focus row. Other windows still use the
        // AppKit fallback below.
        if window === WindowModeCenter.shared.mainWindow {
            KeyboardNavigator.shared.sendScroll(command)
            return
        }
        switch command {
        case .pageUp:
            scrollByPage(up: true, event: event)
        case .pageDown:
            scrollByPage(up: false, event: event)
        case .top:
            scrollToTop(event: event)
        case .bottom:
            scrollToBottom(event: event)
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
