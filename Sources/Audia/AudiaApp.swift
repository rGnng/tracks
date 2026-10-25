import SwiftUI
@preconcurrency import AppKit

@main
struct AudiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("showStatusBar") private var showStatusBar = true

    var body: some Scene {
        Window("Tracks", id: "main") {
            ContentView(appearanceMode: appearanceMode)
                .environmentObject(PlayerState.shared)
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + (wasMini ? 0.30 : 0.05)) {
                        NotificationCenter.default.post(name: .focusSearch, object: nil)
                    }
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
        }
        .defaultSize(width: 660, height: 640)

        Window("Get Info", id: "get-info") {
            GetInfoView()
        }
        .defaultSize(width: 540, height: 620)

        Window("Set Up Tracks Library", id: "setup") {
            InternalLibrarySetupView()
        }
        .defaultSize(width: 540, height: 410)
        .windowResizability(.contentSize)
    }
}

private enum SettingsAlert: Identifiable {
    case error(String)
    case confirmOpen(String)
    case confirmRemoval(MusicLibrary)

    var id: String {
        switch self {
        case .error(let message): return "error:\(message)"
        case .confirmOpen(let path): return "open:\(path)"
        case .confirmRemoval(let library): return "remove:\(library.id)"
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
    @AppStorage("mpd.enabled") private var mpdEnabled = false
    @AppStorage("mpd.allInterfaces") private var mpdAllInterfaces = false
    @AppStorage("mpd.addresses") private var mpdAddresses = "127.0.0.1"
    @AppStorage("mpd.port") private var mpdPort = 6600
    @AppStorage("mpd.password") private var mpdPassword = ""
    @AppStorage("artworkCacheJPEGQuality") private var artworkCacheJPEGQuality = 0.8
    @State private var starShortcut: KeyboardShortcut? = KeyboardShortcutStore.load()
    @ObservedObject private var library = Library.shared
    @ObservedObject private var artworkCache = ArtworkCache.shared
    @ObservedObject private var mpd = MPDServer.shared
    @Environment(\.openWindow) private var openWindow

    @State private var alert: SettingsAlert?
    @State private var mpdApplyTask: Task<Void, Never>?
    @State private var artworkQualityText = "80"
    @FocusState private var artworkQualityFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Picker("Album display as", selection: $albumViewMode) {
                    Text("Grid").tag("grid")
                    Text("List").tag("list")
                }
                .pickerStyle(.radioGroup)
                .frame(maxWidth: 360, alignment: .leading)

                Picker("Albums sorted by", selection: $albumSort) {
                    ForEach(GridSort.allCases, id: \.self) { sort in
                        Text(sort.rawValue).tag(sort.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .frame(maxWidth: 360, alignment: .leading)

                Divider()

                shortcutsBox

                Divider()

                HStack {
                    Text("Libraries")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(library.albums.count) albums · \(library.allSongs.count) songs")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                if library.isScanning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: library.scanProgress)
                            .progressViewStyle(.linear)
                        Text(library.scanTotal > 0
                             ? "Scanning \(library.scanCompleted) of \(library.scanTotal) files…"
                             : "Scanning…")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }

                internalLibraryBox
                externalLibrariesBox

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Artwork Cache")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Theme.primaryText)
                            Text("Cached album art speeds up browsing. It is rebuilt from library files.")
                                .font(.system(size: 10.5))
                                .foregroundColor(Theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                        Button("Rebuild Cache") {
                            artworkCache.rebuildCache()
                        }
                    }

                    HStack(spacing: 8) {
                        Text("JPEG quality")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryText)
                            .frame(width: 84, alignment: .trailing)
                        TextField("80", text: $artworkQualityText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 46)
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
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryText)
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Text("Cache size")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryText)
                            .frame(width: 84, alignment: .trailing)
                        Text(artworkCacheSizeText)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(Theme.primaryText)
                        Spacer(minLength: 0)
                    }
                }
                .padding(10)
                .background(boxBackground)

                mpdBox

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 660, height: 640, alignment: .topLeading)
        .background(SettingsFocusSink())
        .onAppear {
            artworkQualityText = "\(artworkQualityPercent)"
            starShortcut = KeyboardShortcutStore.load()
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
            case .confirmRemoval(let externalLibrary):
                return Alert(
                    title: Text("Remove External Library?"),
                    message: Text("Songs from “\(externalLibrary.name)” will be removed from Tracks. The files on disk are not deleted."),
                    primaryButton: .destructive(Text("Remove")) {
                        library.removeExternalLibrary(externalLibrary.id)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .onChange(of: mpdEnabled) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdAllInterfaces) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdAddresses) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdPort) { _, _ in scheduleMPDApply() }
        .onChange(of: mpdPassword) { _, _ in scheduleMPDApply() }
    }

    private var shortcutsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("Shortcuts")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Toggle star current item")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryText)
                Spacer()
                ShortcutRecorder(shortcut: $starShortcut)
                    .frame(width: 132, height: 22)
                Button("Reset") { starShortcut = .defaultStar }
                    .controlSize(.small)
            }

            Text("Stars or unstars the playing track or selected tracks. Default: *")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondaryText)
        }
        .padding(10)
        .background(boxBackground)
        .onChange(of: starShortcut) { _, value in
            KeyboardShortcutStore.save(value)
        }
    }

    private var mpdBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("MPD Server")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Enable", isOn: $mpdEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text("Lets MPD clients browse and control the library over TCP.")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondaryText)

            if mpdEnabled {
                Toggle("Listen on all interfaces", isOn: $mpdAllInterfaces)
                    .controlSize(.small)

                HStack(spacing: 8) {
                    Text("Addresses")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 64, alignment: .trailing)
                    TextField("127.0.0.1", text: $mpdAddresses)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .disabled(mpdAllInterfaces)
                    Text("Port")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                    TextField("6600", value: $mpdPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 64)
                }

                HStack(spacing: 8) {
                    Text("Password")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 64, alignment: .trailing)
                    SecureField("optional", text: $mpdPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 180)
                    Spacer()
                    Button("Restart") { mpd.applyPreferences() }
                        .controlSize(.small)
                }

                Text(mpd.status)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("Disabled")
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.secondaryText)
            }
        }
        .padding(10)
        .background(boxBackground)
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

    private var internalLibraryBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("Internal Library")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if let warning = library.openWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.system(size: 10.5))
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
                        .font(.system(size: 11))
                        .foregroundColor(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Rescan") {
                        library.rescan(internalLibrary)
                    }
                    .disabled(library.isScanning)
                }

                HStack(spacing: 10) {
                    Button("Open Music Folder") {
                        openMusicFolder(internalLibrary)
                    }
                    Button("Open Another Library…") {
                        chooseOpenLibrary()
                    }
                    Spacer()
                }

                Text("The database lives in this folder. Music belongs in its Music subfolder.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.secondaryText)
            } else {
                Text("Not set up yet. Create one folder for your Tracks database and music.")
                    .font(.system(size: 11))
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(boxBackground)
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

    private var externalLibrariesBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                Text("External Libraries")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Read-Only")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }

            Text("Folders managed by iTunes or another music app. Tracks indexes them without modifying the files.")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondaryText)

            if library.externalLibraries.isEmpty {
                Text("No external libraries.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryText)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(library.externalLibraries) { externalLibrary in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(externalLibrary.name)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(Theme.primaryText)
                                    .lineLimit(1)
                                Text(externalLibrary.path)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Button("Rescan") {
                                library.rescan(externalLibrary)
                            }
                            .disabled(library.isScanning)
                            Button {
                                alert = .confirmRemoval(externalLibrary)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove library")
                        }
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.contentBackground)
                        )
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(boxBackground)
    }

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.controlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.controlBorder, lineWidth: 1)
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
                    .foregroundColor(Theme.selectionBlue)
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
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.controlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focusMonitor: Any?
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Window tabbing is not used by this app.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installFocusMonitor()
        installKeyMonitor()
        MPDServer.shared.startFromPreferences()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowModeCenter.shared.persistLibraryFrameIfNeeded()
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

        if modifiers == .command, event.charactersIgnoringModifiers == "[" {
            NotificationCenter.default.post(name: .goBackRequested, object: nil)
            return nil
        }

        if !isEditingText,
           !event.isARepeat,
           let shortcut = KeyboardShortcutStore.load(),
           shortcut.matches(event) {
            toggleStarCurrentItem()
            return nil
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

    /// Toggles the current selection (or the playing track when nothing is
    /// selected). If every target is already starred, clears all of them;
    /// otherwise stars all of them.
    private static func toggleStarCurrentItem() {
        let library = Library.shared
        var songs: [Song] = []

        // Prefer the selected track rows. Album/artist/genre selection is not
        // expanded into every contained track; without a track selection the
        // shortcut targets the currently playing track. In MiniPlayer there is
        // no visible selection, so it also targets the playing track.
        if WindowModeCenter.shared.mode == .library,
           case .tracks(let ids) = StatusBarCenter.shared.context {
            songs = ids.compactMap { library.song(withID: $0)?.song }
        }

        if songs.isEmpty, let current = PlayerState.shared.currentSong {
            songs = [current]
        }

        let ids = Array(Set(songs.map(\.id)))
        guard !ids.isEmpty else { return }
        let allStarred = ids.allSatisfy { library.isStarred(songID: $0) }
        library.setStarred(ids, starred: !allStarred)
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
