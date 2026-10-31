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
                .environmentObject(DebugSettings.shared)
                .accentColor(highlightColor)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
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
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("MiniPlayer") {
                    WindowModeCenter.shared.setMode(.miniPlayer)
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button("Log") {
                    LogViewer.openConsole()
                }

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

            DebugCommands()
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

        Window("Debug", id: "debug") {
            DebugPanel()
                .environmentObject(DebugSettings.shared)
        }
        .defaultSize(width: 780, height: 760)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Open/Create Database", id: "database-setup") {
            DatabaseSetupView()
                .accentColor(highlightColor)
        }
        .defaultSize(width: 540, height: 360)
        .windowResizability(.contentSize)

        Window("ReKey Database", id: "rekey-progress") {
            RekeyProgressView()
                .accentColor(highlightColor)
        }
        .defaultSize(width: 680, height: 460)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private enum SettingsAlert: Identifiable {
    case error(String)
    case shortcutConflict(String)
    case confirmDisable(MusicLibrary)
    case confirmDelete(MusicLibrary)
    case confirmRekey
    case notice(title: String, message: String)

    var id: String {
        switch self {
        case .error(let message): return "error:\(message)"
        case .shortcutConflict(let message): return "shortcut-conflict:\(message)"
        case .confirmDisable(let library): return "disable:\(library.id)"
        case .confirmDelete(let library): return "delete:\(library.id)"
        case .confirmRekey: return "rekey"
        case .notice(let title, let message): return "notice:\(title):\(message)"
        }
    }
}

struct SettingsView: View {
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
    @AppStorage(TrayController.DefaultsKey.playControlAction) private var trayPlayControlAction = true
    @AppStorage(TrayController.DefaultsKey.displayDurationMs)
    private var trayDisplayDurationMs = 1500
    @AppStorage(UUIDURLDefaults.enabledKey) private var copyUUIDURLEnabled = false
    @AppStorage(UUIDURLDefaults.prefixKey) private var copyUUIDURLPrefix = ""
    @AppStorage(UUIDURLDefaults.styleKey) private var copyUUIDURLStyleRaw = UUIDURLStyle.uuid.rawValue
    @State private var shortcutBindings = KeyboardShortcutStore.loadBindings()
    @State private var showRawShortcutValues = false
    @State private var selectedInAppBindingID: UUID?
    @State private var selectedSystemWideBindingID: UUID?
    @ObservedObject private var library = Library.shared
    @ObservedObject private var artworkCache = ArtworkCache.shared
    @ObservedObject private var mpd = MPDServer.shared
    @Environment(\.openWindow) private var openWindow

    private static var relaunchProcess: Process?

    @State private var alert: SettingsAlert?
    @State private var isRekeying = false
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
            case .confirmDisable(let libraryToDisable):
                return Alert(
                    title: Text("Disable Library?"),
                    message: Text("Disabling “\(libraryToDisable.identifier)” stops playback and clears the playback queue and History. Its songs will be hidden throughout Tracks. Library and playlist data remain stored and can be restored by enabling it again."),
                    primaryButton: .destructive(Text("Disable")) {
                        do {
                            try library.setLibrary(libraryToDisable.id, enabled: false)
                        } catch {
                            self.alert = .error(error.localizedDescription)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDelete(let libraryToDelete):
                return Alert(
                    title: Text("Delete Library Index?"),
                    message: Text("This removes “\(libraryToDelete.identifier)” and its indexed songs from Tracks, including their playlist entries, play counts, and stars. User-created playlists remain, even if empty. Audio files are not deleted. A timestamped database backup will be created first."),
                    primaryButton: .destructive(Text("Delete Index")) {
                        do {
                            let backup = try library.deleteDisabledLibrary(libraryToDelete.id)
                            self.alert = .notice(title: "Library Index Deleted",
                                                 message: "The library index was deleted. Backup saved at:\n\(backup.path)")
                        } catch {
                            self.alert = .error(error.localizedDescription)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .confirmRekey:
                return Alert(
                    title: Text("ReKey Database?"),
                    message: Text("Tracks will stop playback, clear the queue and playback history, refresh all libraries, and recalculate all song/album/artist UUIDs from the current identifiers and files. Playlists, play counts, and stars are preserved. A database backup is created first. Tracks will restart automatically afterward."),
                    primaryButton: .destructive(Text("ReKey")) {
                        performRekey()
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
                copyUUIDURLSettings
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Browsing") {
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
            databaseSection
            librariesSection
            artworkCacheSection
            dangerZoneSection
        }
    }

    private var artworkCacheSection: some View {
        SettingsCard(title: "Artwork Cache") {
            SettingsRow(title: "Rebuild cache") {
                Button("Rebuild Cache") {
                    artworkCache.rebuildCache()
                }
                .controlSize(.small)
                .disabled(library.isScanning)
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
            SettingsRow(title: "Show icon") {
                Toggle("", isOn: $trayEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if trayEnabled {
                SettingsDivider()
                SettingsRow(title: "Song changes") {
                    Toggle("", isOn: $trayTrackChange)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "Star/unstar") {
                    Toggle("", isOn: $trayStarChange)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "Play control") {
                    Toggle("", isOn: $trayPlayControlAction)
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
            }
        }
        .onChange(of: trayEnabled) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayTrackChange) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayStarChange) { _, _ in TrayController.shared.refresh() }
        .onChange(of: trayPlayControlAction) { _, _ in TrayController.shared.refresh() }
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
                    TextField("6600", value: $mpdPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body.monospacedDigit())
                        .frame(width: 80)
                }
                SettingsDivider()
                SettingsRow(title: "Password") {
                    SecureField("optional", text: $mpdPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsTypography.body)
                        .frame(width: 150)
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

    private var copyUUIDURLSettings: some View {
        SettingsCard(title: "Copy UUID URL") {
            SettingsRow(
                title: "Enable Copy UUID URL",
                subtitle: "Show Copy UUID URL above Get Info in song and album menus."
            ) {
                Toggle("", isOn: $copyUUIDURLEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if copyUUIDURLEnabled {
                SettingsDivider()
                SettingsRow(title: "URL Prefix") {
                    TextField("", text: Binding(
                        get: { copyUUIDURLPrefix },
                        set: { value in
                            copyUUIDURLPrefix = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(SettingsTypography.body)
                    .frame(width: 260)
                }

                SettingsDivider()
                SettingsRow(title: "Type") {
                    HStack(spacing: 14) {
                        ForEach(UUIDURLStyle.allCases) { style in
                            let selected = copyUUIDURLStyleRaw == style.rawValue
                            Button {
                                copyUUIDURLStyleRaw = style.rawValue
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: selected
                                          ? "largecircle.fill.circle"
                                          : "circle")
                                        .font(.system(size: 13))
                                        .foregroundColor(selected
                                                         ? Theme.highlight
                                                         : Theme.secondaryText)
                                    Text(style.title)
                                        .font(SettingsTypography.body)
                                        .foregroundColor(Theme.primaryText)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(style.title)
                        }
                    }
                }
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

    // MARK: Danger Zone

    private var dangerZoneSection: some View {
        SettingsCard(title: "Danger Zone") {
            SettingsRow(
                title: "ReKey Database",
                subtitle: "Recalculate all song/album/artist UUIDs and update playlists.\nAll libraries' namespace will be updated."
            ) {
                Button("ReKey All IDs", role: .destructive) {
                    alert = .confirmRekey
                }
                .controlSize(.small)
                .disabled(library.isScanning || isRekeying)
            }
        }
    }

    // MARK: Database

    private var databaseSection: some View {
        SettingsCard(title: "Database") {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Location")
                        .font(SettingsTypography.body)
                        .foregroundColor(Theme.primaryText)
                    Text(library.databaseFolderPath)
                        .font(SettingsTypography.caption)
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: library.databaseFolderPath))
                }
                .controlSize(.small)
                Button("Open/Create Database…") {
                    openWindow(id: "database-setup")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    // MARK: Libraries

    private var librariesSection: some View {
        SettingsCard(title: "Libraries (Read Only)") {
            if library.libraries.isEmpty {
                SettingsFootnote("No libraries.")
            } else {
                ForEach(Array(library.libraries.enumerated()), id: \.element.id) { index, mediaLibrary in
                    if index > 0 {
                        SettingsDivider()
                    }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(mediaLibrary.identifier)
                                    .font(SettingsTypography.body)
                                    .foregroundColor(Theme.primaryText)
                                    .lineLimit(1)
                                Text("Current Namespace:")
                                    .font(SettingsTypography.caption)
                                    .foregroundColor(Theme.secondaryText)
                                    .fixedSize()
                                Text(mediaLibrary.idNamespace)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Text(mediaLibrary.path)
                                .font(SettingsTypography.help)
                                .foregroundColor(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: libraryEnabledBinding(mediaLibrary))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: 40)

                    HStack(spacing: 8) {
                        Button("Quick Scan") {
                            library.rescan(mediaLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning || !mediaLibrary.isEnabled)
                        Button("Full Scan") {
                            runFullScan(mediaLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning || !mediaLibrary.isEnabled)
                        Button("Change Location…") {
                            chooseRelocation(for: mediaLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning || !mediaLibrary.isEnabled)
                        Button("Rename Identifier…") {
                            renameLibraryIdentifier(mediaLibrary)
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning)
                        Spacer()
                        Button(role: .destructive) {
                            alert = .confirmDelete(mediaLibrary)
                        } label: {
                            Label("Delete Index", systemImage: "trash")
                        }
                        .controlSize(.small)
                        .disabled(mediaLibrary.isEnabled || library.isScanning)
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
                .disabled(library.isScanning || isRekeying)
                Button("Add Library…") {
                    addLibraries()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func libraryEnabledBinding(_ mediaLibrary: MusicLibrary) -> Binding<Bool> {
        Binding(
            get: { mediaLibrary.isEnabled },
            set: { enabled in
                if enabled {
                    do {
                        try library.setLibrary(mediaLibrary.id, enabled: true)
                    } catch {
                        alert = .error(error.localizedDescription)
                    }
                } else {
                    alert = .confirmDisable(mediaLibrary)
                }
            }
        )
    }

    private func addLibraries() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose music folders. They will be indexed read-only."
        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }
        var additions: [LibraryAddition] = []
        if urls.count == 1 {
            let identifier = promptForLibraryIdentifier(defaultValue: library.suggestedLibraryIdentifier())
            guard let identifier else { return }
            additions = [LibraryAddition(path: urls[0].path, identifier: identifier)]
        } else {
            additions = urls.map { LibraryAddition(path: $0.path, identifier: nil) }
        }

        let errors = library.addLibraries(additions)
        if !errors.isEmpty {
            alert = .error(errors.joined(separator: "\n"))
        }
    }

    private func promptForLibraryIdentifier(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Library Identifier"
        alert.informativeText = "Choose a unique identifier for this library. Leave it unchanged to use “\(defaultValue)”."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        field.placeholderString = defaultValue
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func renameLibraryIdentifier(_ mediaLibrary: MusicLibrary) {
        let alert = NSAlert()
        alert.messageText = "Rename Library Identifier"
        alert.informativeText = "Identifiers are unique and can be changed at any time."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = mediaLibrary.identifier
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try library.renameLibraryIdentifier(mediaLibrary.id, to: field.stringValue)
        } catch {
            alertError(error.localizedDescription)
        }
    }

    private func alertError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Library Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    private func performRekey() {
        guard !isRekeying else { return }
        isRekeying = true
        let progress = RekeyProgressCenter.shared
        progress.begin()
        openWindow(id: "rekey-progress")
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            defer { isRekeying = false }
            progress.log("Validating library namespaces")
            do {
                try library.validateRekeyNamespaces()
            } catch {
                progress.fail(error.localizedDescription)
                return
            }
            progress.log("Stopping playback")
            PlayerState.shared.stopAndClear()
            progress.log("Cleared playback queue and history")
            PlayerState.shared.clearHistory()
            do {
                let result = try await library.rekeyAllLibraries(reporter: progress.reporter)
                progress.finish(
                    summary: "ReKey complete: \(result.songCount) songs, \(result.albumCount) albums, \(result.artistCount) artists"
                )
                AppLog.app.notice("ReKey finished: \(result.songCount, privacy: .public) songs; relaunching")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !relaunchApplication() {
                    progress.log("Could not relaunch Tracks automatically. Quit and reopen manually.", level: .error)
                }
            } catch {
                progress.fail(error.localizedDescription)
            }
        }
    }

    private func relaunchApplication() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; exec /usr/bin/open -n \"$1\"",
            "tracks-relaunch",
            Bundle.main.bundlePath,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            Self.relaunchProcess = process
            NSApp.terminate(nil)
            return true
        } catch {
            AppLog.app.error("Could not relaunch Tracks: \(error.localizedDescription, privacy: .public)")
            return false
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

struct DatabaseSetupView: View {
    @ObservedObject private var library = Library.shared
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var folderPath = Library.defaultDatabaseFolderPath
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.highlight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open/Create Database")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                    Text("Open an existing Tracks database or create a new one.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                }
                Spacer()
            }

            Text("If the folder contains library.sqlite, Tracks checks its schema and opens it. Otherwise Tracks creates a new database there. Music library folders are never modified.")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Database folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
                HStack(spacing: 8) {
                    Text(folderPath)
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
                Spacer()
                Button("Open/Create") {
                    completeSetup()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540, height: 360, alignment: .topLeading)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if !library.databaseFolderPath.isEmpty {
                folderPath = library.databaseFolderPath
            }
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
        panel.message = "Choose or create the folder that will hold library.sqlite."
        panel.directoryURL = URL(fileURLWithPath: folderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
        errorMessage = nil
    }

    private func completeSetup() {
        do {
            try library.completeDatabaseSetup(folder: folderPath)
            dismissWindow(id: "database-setup")
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
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        AppLog.app.notice("Launched Tracks \(version, privacy: .public) (\(build, privacy: .public)) on \(system, privacy: .public)")

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
        AppLog.app.notice("Terminating")
        SessionViewState.shared.persistActiveViewport()
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

        if NavigationRouter.shared.handle(event, in: window) {
            return nil
        }

        return event
    }
}
